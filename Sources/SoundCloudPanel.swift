import SwiftUI
import AppKit

struct SoundCloudPanel: View {
    @Bindable var model: SoundCloudStore
    var imports: ImportStore
    var navigation: PanelNavigation
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                TextField("Название, автор или ссылка", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit(submit)
                    .accessibilityLabel("Поиск треков SoundCloud")
                Button(action: submit) {
                    Image(systemName: "magnifyingglass").frame(width: 20, height: 20)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
                .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Искать на SoundCloud")
            }
            .padding(.horizontal, 20)
            .onAppear { model.prewarm() }
            // Focus on arrival and on every ⌘F.
            .task(id: navigation.focusRequest) { searchFocused = true }
            .onChange(of: model.results) { ArtworkLoader.shared.prefetch(model.results.compactMap(\.artwork)) }
            if model.isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Ищем на SoundCloud…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.results.isEmpty, !model.isSearching, model.error == nil {
                        VStack(spacing: 10) {
                            Image(systemName: "waveform").font(.system(size: 32, weight: .light)).foregroundStyle(.orange)
                            Text(model.didSearch ? "Ничего не найдено" : "Найди новый трек")
                                .font(.system(size: 16, weight: .semibold))
                            Text(model.didSearch ? "Попробуй другое название или ссылку" : "Поиск SoundCloud → медиатека → избранное")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                    ForEach(model.results) { track in
                        trackRow(track)
                        if track.id != model.results.last?.id { Divider().padding(.leading, 54) }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
    }

    /// A pasted YouTube link opens in its own tab instead of becoming a SoundCloud query.
    private func submit() {
        if case .youTube? = LinkRoute.detect(model.query) { navigation.open(.youTube(model.query)) }
        else { model.search() }
    }

    private func trackRow(_ track: SoundCloudTrack) -> some View {
        let entry = imports.entry(soundCloudID: track.id)
        let working = entry?.stage == .queued || entry?.stage == .importing
        let added = entry?.stage == .imported
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                ArtworkView(url: track.artwork, symbol: "waveform", tint: .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("SoundCloud").foregroundStyle(.orange)
                        if !track.durationLabel.isEmpty { Text("· " + track.durationLabel).foregroundStyle(.secondary) }
                    }.font(.system(size: 10))
                }
                Spacer(minLength: 0)
                if model.downloadStates[track.id] != nil {
                    Button { model.cancel(track) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Отменить загрузку")
                        .accessibilityLabel("Отменить загрузку \(track.title)")
                } else if added {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .help("Трек уже в медиатеке")
                } else if working {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Добавить") {
                        if let entry, entry.stage == .failed { imports.retry(entry) }
                        else { model.add(track) }
                    }
                    .controlSize(.small).buttonStyle(.bordered)
                    .accessibilityLabel("Добавить \(track.title) в Apple Music")
                }
            }
            if let state = model.downloadStates[track.id] {
                DownloadStatus(state: state, progress: model.downloadProgress[track.id]).padding(.leading, 54)
            } else if let error = model.downloadErrors[track.id] {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 54)
            } else if let entry {
                Text(entry.stage == .imported ? CloudState.label(entry.cloudStatus) : "Импортируем в «Музыку»…")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 54)
            }
            if let entry, let problem = entry.favoriteError {
                VStack(alignment: .leading, spacing: 5) {
                    Text(problem).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Повторить добавление в избранное") { imports.markFavorite(entry) }
                        .disabled(imports.updatingFavorites.contains(entry.id))
                }.font(.system(size: 10)).buttonStyle(.borderless).padding(.leading, 54)
            }
            if let entry, CloudState.canAutoRetry(entry.cloudStatus), let problem = entry.cloudUpdateError {
                VStack(alignment: .leading, spacing: 5) {
                    Text(problem).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if problem.contains("Универсальный доступ") {
                        Button("Разрешить обновление облака…") { CloudUpdateBridge.openPermissionSettings() }
                    }
                    Button("Повторить обновление облака") { imports.requestCloudUpdate(for: [entry.id]) }
                        .disabled(imports.cloudUpdateInProgress)
                }.font(.system(size: 10)).buttonStyle(.borderless).padding(.leading, 54)
            }
            if let entry, let message = entry.cloudRetryMessage {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 54)
            }
            HStack {
                Spacer()
                Button("Открыть на SoundCloud") { NSWorkspace.shared.open(track.url) }
                    .buttonStyle(.borderless).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 12)
    }
}
