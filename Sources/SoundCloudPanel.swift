import SwiftUI
import AppKit

struct SoundCloudPanel: View {
    @Bindable var model: SoundCloudStore
    var imports: ImportStore
    var navigation: PanelNavigation
    var player: PreviewPlayer
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                TextField("Название, автор, ссылка на трек или сет", text: $model.query)
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
                    if let collection = model.collection {
                        collectionHeader(collection).padding(.bottom, 8)
                        ForEach(collection.tracks) { track in
                            HStack(alignment: .top, spacing: 6) {
                                Toggle("", isOn: selected(track)).toggleStyle(.checkbox).labelsHidden().padding(.top, 26)
                                    .disabled(imports.entry(soundCloudID: track.id)?.stage == .imported)
                                    .accessibilityLabel("Выбрать \(track.title)")
                                trackRow(track)
                            }
                            if track.id != collection.tracks.last?.id { Divider().padding(.leading, 76) }
                        }
                    }
                    if model.collection == nil, model.results.isEmpty, !model.isSearching, model.error == nil {
                        VStack(spacing: 10) {
                            Image(systemName: "waveform").font(.system(size: 32, weight: .light)).foregroundStyle(.orange)
                            Text(model.didSearch ? "Ничего не найдено" : "Найди новый трек")
                                .font(.system(size: 16, weight: .semibold))
                            Text(model.didSearch ? "Попробуй другое название или ссылку" : "Поиск SoundCloud → медиатека → избранное")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                    if model.collection == nil {
                        ForEach(model.results) { track in
                            trackRow(track)
                            if track.id != model.results.last?.id { Divider().padding(.leading, 54) }
                        }
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

    private func selected(_ track: SoundCloudTrack) -> Binding<Bool> {
        Binding(get: { model.selection.contains(track.id) },
                set: { if $0 { model.selection.insert(track.id) } else { model.selection.remove(track.id) } })
    }

    private func collectionHeader(_ collection: SoundCloudCollection) -> some View {
        let entries = collection.tracks.map { imports.entry(soundCloudID: $0.id) }
        let added = entries.filter { $0?.stage == .imported }.count
        let importing = entries.filter { $0?.stage == .queued || $0?.stage == .importing }.count
        let downloading = collection.tracks.filter { model.downloadStates[$0.id] != nil }.count
        return CollectionHeader(title: collection.title, subtitle: collection.artist, artwork: collection.artwork,
                                symbol: "square.stack", tint: .orange, total: collection.tracks.count,
                                selected: model.selection.intersection(collection.tracks.map(\.id)).count,
                                added: added, inFlight: importing + downloading, intoPlaylist: $model.collectionIntoPlaylist,
                                selectAll: { model.selection = Set(collection.tracks.filter { imports.entry(soundCloudID: $0.id)?.stage != .imported }.map(\.id)) },
                                selectNone: { model.selection = [] },
                                add: { addCollection(collection) },
                                close: { model.closeCollection() })
        .onAppear { model.selection.subtract(collection.tracks.filter { imports.entry(soundCloudID: $0.id)?.stage == .imported }.map(\.id)) }
    }

    /// Tracks already in the library are not downloaded again but still join the set's playlist.
    private func addCollection(_ collection: SoundCloudCollection) {
        let imported = Set(collection.tracks.filter { imports.entry(soundCloudID: $0.id)?.stage == .imported }.map(\.id))
        let existing = model.addCollection(skipping: imported)
        guard model.collectionIntoPlaylist else { return }
        for track in existing {
            if let entry = imports.entry(soundCloudID: track.id) { imports.addToPlaylist(entry, playlist: collection.title) }
        }
    }

    /// Play and pause sit on the artwork, so every result can be heard without leaving the list.
    private func previewButton(_ track: SoundCloudTrack) -> some View {
        let active = model.previewID == track.id
        let playing = active && player.isPlaying
        let waiting = active && (model.previewLoading || player.isBuffering)
        return Button {
            if active, !model.previewLoading { player.toggle() } else { model.startPreview(track) }
        } label: {
            ZStack {
                Circle().fill(Color.black.opacity(active ? 0.55 : 0.35)).frame(width: 26, height: 26)
                if waiting {
                    ProgressView().controlSize(.mini).environment(\.colorScheme, .dark)
                } else {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(playing ? "Пауза" : "Прослушать")
        .accessibilityLabel(playing ? "Пауза: \(track.title)" : "Прослушать \(track.title)")
    }

    private func trackRow(_ track: SoundCloudTrack) -> some View {
        let entry = imports.entry(soundCloudID: track.id)
        let working = entry?.stage == .queued || entry?.stage == .importing
        let added = entry?.stage == .imported
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    ArtworkView(url: track.artwork, symbol: "waveform", tint: .orange)
                    previewButton(track)
                }
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
            if model.previewID == track.id, !model.previewLoading {
                PreviewProgress(player: player, isClip: model.previewIsClip).padding(.leading, 54)
            } else if let problem = model.previewErrors[track.id] {
                Text(problem).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 54)
            }
            if let state = model.downloadStates[track.id] {
                DownloadStatus(state: state, progress: model.downloadProgress[track.id]).padding(.leading, 54)
            } else if let error = model.downloadErrors[track.id] {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 54)
            } else if let entry {
                Text(entry.stage == .imported ? CloudState.label(entry.cloudStatus)
                     : imports.musicStarting ? "Запускаем «Музыку»…" : "Импортируем в «Музыку»…")
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

/// Position of the track being heard; a click on the bar jumps there.
private struct PreviewProgress: View {
    let player: PreviewPlayer
    let isClip: Bool

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.orange).frame(width: proxy.size.width * player.progress)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in player.seek(to: location.x / max(1, proxy.size.width)) }
            }
            .frame(height: 4)
            Text(Self.time(player.progress * player.duration) + " / " + Self.time(player.duration)).monospacedDigit()
            if isClip { Text("фрагмент").help("SoundCloud открывает для этого трека только отрывок") }
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Прослушивание")
        .accessibilityValue(Self.time(player.progress * player.duration) + " из " + Self.time(player.duration))
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
