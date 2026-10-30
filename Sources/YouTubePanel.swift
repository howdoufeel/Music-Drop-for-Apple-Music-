import SwiftUI
import AppKit

struct YouTubePanel: View {
    @Bindable var model: YouTubeStore
    var imports: ImportStore
    var navigation: PanelNavigation
    @AppStorage(YouTubeAudioFormat.defaultsKey) private var format: YouTubeAudioFormat = .m4a
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                TextField("Ссылка YouTube или YouTube Music", text: $model.query)
                    .textFieldStyle(.roundedBorder).focused($searchFocused).onSubmit(submit)
                    .accessibilityLabel("Ссылка на трек YouTube")
                    // Focus on arrival and on every ⌘F.
                    .task(id: navigation.focusRequest) { searchFocused = true }
                Button(action: submit) { Image(systemName: "arrow.right").frame(width: 20, height: 20) }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Проверить ссылку YouTube")
            }.padding(.horizontal, 20)
            if model.isSearching, model.verifying.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Получаем сведения о видео…").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.results.isEmpty, !model.isSearching, model.error == nil {
                        VStack(spacing: 10) {
                            Image(systemName: "play.rectangle").font(.system(size: 34, weight: .light)).foregroundStyle(.red)
                            Text("Трек с YouTube — в медиатеку").font(.system(size: 16, weight: .semibold))
                            Text("Вставь ссылку на одно видео. Сохраним аудио и добавим в Apple Music и избранное.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 45)
                    }
                    ForEach(model.results) { track in row(track) }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
            Text("Без входа и данных браузера. При отказе YouTube используется резервный сервис Invidious.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            Text("\(format.label) сохраняется на Mac, формат меняется в настройках. Закрытые, платные и недоступные видео загрузить не получится.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 10)
        }
    }

    /// SoundCloud links and plain words go to SoundCloud; YouTube links and malformed links stay here.
    private func submit() {
        switch LinkRoute.forInput(model.query) {
        case .soundCloud(let text)?: navigation.open(.soundCloud(text))
        default: model.search()
        }
    }

    private func row(_ track: YouTubeTrack) -> some View {
        let entry = imports.entry(youTubeID: track.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ArtworkView(url: URL(string: "https://i.ytimg.com/vi/\(track.id)/mqdefault.jpg"), symbol: "play.rectangle.fill", tint: .red)
                VStack(alignment: .leading, spacing: 5) {
                    Text(track.title).font(.system(size: 13, weight: .medium)).lineLimit(3)
                    Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    Text("YouTube · \(format.label)" + (track.fallbackEndpoint == nil ? "" : " · резервный сервис") + (track.durationLabel.isEmpty ? "" : " · " + track.durationLabel))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if model.verifying.contains(track.id), model.downloadStates[track.id] == nil, entry == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Проверяем доступность аудио…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else if model.prefetchedIDs.contains(track.id), entry == nil {
                Label("Аудио уже скачано — добавится сразу", systemImage: "bolt.fill")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let state = model.downloadStates[track.id] {
                HStack {
                    DownloadStatus(state: state, progress: model.downloadProgress[track.id])
                    Spacer()
                    Button { model.cancel(track) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Отменить загрузку YouTube")
                }
            } else if let entry {
                if entry.stage == .queued || entry.stage == .importing {
                    HStack { ProgressView().controlSize(.small); Text("Добавляем в медиатеку и избранное…").font(.system(size: 11)) }
                } else if entry.stage == .imported {
                    Label(CloudState.label(entry.cloudStatus), systemImage: entry.isFavorite == true ? "star.fill" : "checkmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let error = entry.favoriteError {
                        Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Повторить добавление в избранное") { imports.markFavorite(entry) }
                            .disabled(imports.updatingFavorites.contains(entry.id))
                    }
                    if let error = entry.cloudUpdateError, CloudState.canAutoRetry(entry.cloudStatus) {
                        Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let message = entry.cloudRetryMessage { Text(message).font(.system(size: 10)).foregroundStyle(.secondary) }
                    HStack {
                        Button("Показать в «Музыке»") { imports.openMusic(entry) }
                        Spacer()
                        if let path = entry.managedPath {
                            Button("Показать файл") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        }
                    }.buttonStyle(.borderless).font(.system(size: 11))
                } else {
                    Text(entry.error ?? "Проверь медиатеку перед повтором импорта.").font(.system(size: 11)).foregroundStyle(.secondary)
                    if entry.stage == .failed { Button("Повторить импорт") { imports.retry(entry) } }
                    else { Button("Проверить в «Музыке»") { imports.openMusic(entry) } }
                }
            } else {
                if let error = model.downloadErrors[track.id] {
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button { model.add(track) } label: {
                    Label("Добавить в Apple Music", systemImage: "plus").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.red)
            }
            Button("Открыть на YouTube") { NSWorkspace.shared.open(track.url) }
                .buttonStyle(.borderless).font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(14).background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
    }
}
