import SwiftUI
import AppKit

private let accent = Color(nsColor: .systemPink)

/// Shared by the window, the popover and the menus: one selected tab, and links from any
/// paste, drop or field open in the source they belong to.
@Observable final class PanelNavigation {
    enum Tab: Int { case library, soundCloud, youTube }
    var tab = Tab.library
    /// Bumped to move keyboard focus into the visible search field.
    var focusRequest = 0
    private let soundCloud: SoundCloudStore
    private let youtube: YouTubeStore

    init(soundCloud: SoundCloudStore, youtube: YouTubeStore) {
        self.soundCloud = soundCloud
        self.youtube = youtube
    }

    func open(_ route: LinkRoute, autoAdd: Bool = false) {
        switch route {
        case .youTube(let link):
            tab = .youTube
            youtube.query = link
            youtube.search(autoAdd: autoAdd)
        case .soundCloud(let text):
            tab = .soundCloud
            soundCloud.query = text
            soundCloud.search(autoAdd: autoAdd)
        }
    }

    func focusSearch() {
        if tab == .library { tab = .soundCloud }
        focusRequest += 1
    }
}

/// One download's phase, with a real bar once the size is known.
struct DownloadStatus: View {
    let state: String
    let progress: Double?

    var body: some View {
        HStack(spacing: 6) {
            if let progress {
                ProgressView(value: progress).progressViewStyle(.linear).controlSize(.small).frame(width: 80)
                Text("\(Int((progress * 100).rounded()))%").monospacedDigit()
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(state).lineLimit(1)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// Header of an opened set or playlist: what it holds, how much is chosen and one button for all of it.
struct CollectionHeader: View {
    let title: String
    let subtitle: String
    let artwork: URL?
    let symbol: String
    let tint: Color
    let total: Int
    let selected: Int
    let added: Int
    let inFlight: Int
    @Binding var intoPlaylist: Bool
    var allowsPlaylist = true
    let selectAll: () -> Void
    let selectNone: () -> Void
    let add: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ArtworkView(url: artwork, symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text(summary).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Закрыть").accessibilityLabel("Закрыть «\(title)»")
            }
            if allowsPlaylist {
                Toggle("Добавить в плейлист «\(title)»", isOn: $intoPlaylist).toggleStyle(.checkbox).font(.system(size: 11))
            }
            HStack(spacing: 12) {
                Button("Выбрать все", action: selectAll).buttonStyle(.borderless).disabled(selected == total)
                Button("Снять все", action: selectNone).buttonStyle(.borderless).disabled(selected == 0)
                Spacer()
                Button(action: add) { Text(selected == 0 ? "Ничего не выбрано" : "Добавить \(selected)") }
                    .buttonStyle(.borderedProminent).tint(tint).disabled(selected == 0)
                    .accessibilityLabel("Добавить выбранные: \(selected)")
            }
            .font(.system(size: 11))
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var summary: String {
        var parts = [Self.tracks(total)]
        if added > 0 { parts.append("в медиатеке: \(added)") }
        if inFlight > 0 { parts.append("добавляется: \(inFlight)") }
        return parts.joined(separator: " · ")
    }

    static func tracks(_ count: Int) -> String {
        let tens = count % 100, ones = count % 10
        let word = (11...14).contains(tens) ? "треков" : ones == 1 ? "трек" : (2...4).contains(ones) ? "трека" : "треков"
        return "\(count) \(word)"
    }
}

struct DropPanel: View {
    var store: ImportStore
    var soundCloud: SoundCloudStore
    var youtube: YouTubeStore
    @Bindable var navigation: PanelNavigation
    var player: PreviewPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(YouTubeAudioFormat.defaultsKey) private var youtubeFormat: YouTubeAudioFormat = .m4a
    @AppStorage(YouTubeFallbackRace.defaultsKey) private var raceFallback = true
    @State private var fileTargeted = false
    @State private var extractor = ExtractorUpdateModel()
    @State private var notificationsOn = Notifier.shared.enabled
    @State private var hotKeyOn = HotKey.enabled
    @State private var historyQuery = ""
    @State private var historyFilter = HistoryFilter.all
    @State private var historyLimit = 100
    @State private var creatingPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Раздел", selection: $navigation.tab) {
                Text("Медиатека").tag(PanelNavigation.Tab.library)
                Text("SoundCloud").tag(PanelNavigation.Tab.soundCloud)
                Text("YouTube").tag(PanelNavigation.Tab.youTube)
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 8)
            destinationMenu
            if navigation.tab == .youTube {
                YouTubePanel(model: youtube, imports: store, navigation: navigation)
            } else if navigation.tab == .soundCloud {
                SoundCloudPanel(model: soundCloud, imports: store, navigation: navigation, player: player)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    dropZone
                    if let notice = store.notice { noticeView(notice) }
                    if store.settingsVisible { settings }
                    history
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            }
            footer
        }
        .frame(width: 380, height: 540)
        .background(.regularMaterial)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.dragActive || fileTargeted)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.settingsVisible)
        .onDrop(of: [.fileURL, .url], isTargeted: $fileTargeted, perform: acceptProviders)
    }

    /// Where every new track goes: the library alone, or a playlist chosen once for all sources.
    private var destinationMenu: some View {
        HStack(spacing: 5) {
            Image(systemName: store.destination == nil ? "music.note.house" : "music.note.list").foregroundStyle(.secondary)
            Menu {
                Button { store.setDestination(nil) } label: {
                    if store.destination == nil { Label("Только медиатека", systemImage: "checkmark") } else { Text("Только медиатека") }
                }
                if !store.availablePlaylists.isEmpty {
                    Divider()
                    ForEach(store.availablePlaylists, id: \.self) { name in
                        Button { store.setDestination(name) } label: {
                            if store.destination == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                }
                Divider()
                Button("Новый плейлист…") { newPlaylistName = ""; creatingPlaylist = true }
            } label: {
                Text(store.destination.map { "Добавлять в плейлист «\($0)»" } ?? "Добавлять только в медиатеку").lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Куда добавлять треки")
            Spacer()
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.bottom, 10)
        .onAppear { store.loadPlaylists() }
        .alert("Новый плейлист", isPresented: $creatingPlaylist) {
            TextField("Название", text: $newPlaylistName)
            Button("Создать") { store.setDestination(newPlaylistName) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Плейлист появится в «Музыке» вместе с первым добавленным треком.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Music Drop").font(.system(size: 16, weight: .semibold))
                Text("Твоя музыка. В твоей медиатеке.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { navigation.tab = .library; store.settingsVisible.toggle() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 14))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Настройки")
            .accessibilityLabel("Настройки")
        }
        .padding(20)
    }

    private var dropZone: some View {
        let targeted = store.dragActive || fileTargeted
        return VStack(spacing: 12) {
            Image(systemName: targeted ? "arrow.down.document.fill" : "arrow.down.document")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(accent)
                .frame(height: 38)
                .scaleEffect(targeted ? 1.08 : 1)
            VStack(spacing: 5) {
                Text(targeted ? "Отпусти — и готово" : "Перетащи сюда MP3")
                    .font(.system(size: 18, weight: .semibold))
                Text("Или ссылку SoundCloud/YouTube · ⌘V вставит её из буфера")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button("Выбрать файлы…") { store.chooseFiles() }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.regular)
                .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 23)
        .background(targeted ? accent.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(targeted ? accent : Color.primary.opacity(0.13),
                              style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: targeted ? [] : [5, 4]))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Зона добавления MP3. Можно также нажать «Выбрать файлы».")
    }

    private func noticeView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { store.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.borderless).accessibilityLabel("Скрыть сообщение")
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ПОСЛЕДНИЕ ДОБАВЛЕНИЯ")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                if store.activeCount > 0 {
                    Text("В очереди: \(store.activeCount)").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if !store.entries.isEmpty {
                    Button { store.refreshCloud() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .disabled(store.refreshInProgress)
                    .buttonStyle(.borderless).help("Проверить облачный статус")
                    .accessibilityLabel("Проверить облачный статус")
                }
            }
            if store.entries.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "music.note.list").font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Здесь появятся твои треки").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Оригиналы файлов останутся на месте")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                if store.entries.count > 3 {
                    HStack(spacing: 6) {
                        TextField("Поиск по истории", text: $historyQuery).textFieldStyle(.roundedBorder).controlSize(.small)
                        Menu(historyFilter.label) {
                            ForEach(HistoryFilter.allCases) { filter in
                                Button { historyFilter = filter } label: {
                                    if filter == historyFilter { Label(filter.label, systemImage: "checkmark") } else { Text(filter.label) }
                                }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
                    }
                }
                let shown = store.entries.filter { $0.matches(historyFilter, query: historyQuery) }
                if shown.isEmpty {
                    Text("Ничего не найдено").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                LazyVStack(spacing: 0) {
                    ForEach(Array(shown.prefix(historyLimit))) { entry in
                        HistoryRow(entry: entry, store: store)
                        if entry.id != shown.prefix(historyLimit).last?.id { Divider().padding(.leading, 44) }
                    }
                }
                if shown.count > historyLimit {
                    Button("Показать ещё \(min(100, shown.count - historyLimit))") { historyLimit += 100 }
                        .buttonStyle(.borderless).font(.system(size: 11)).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Запускать при входе в macOS", isOn: Binding(
                get: { store.loginEnabled }, set: { store.setLogin($0) }))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text("Каждый MP3 добавляется в медиатеку и отмечается звездой. При необходимости «Музыка» запускается автоматически в фоне.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Чтобы треки появились на других устройствах, включи «Синхронизацию медиатеки» в настройках «Музыки».")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Формат YouTube", selection: $youtubeFormat) {
                Text("M4A · быстро, без перекодирования").tag(YouTubeAudioFormat.m4a)
                Text(FileTools.ffmpeg() == nil ? "MP3 · нужен FFmpeg (brew install ffmpeg)" : "MP3 · для старых плееров")
                    .tag(YouTubeAudioFormat.mp3)
            }
            .pickerStyle(.menu).controlSize(.small).font(.system(size: 12))
            Toggle("Резервный сервис, если YouTube медлит дольше 5 с", isOn: $raceFallback)
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Toggle("Уведомлять о добавленных треках, когда окно скрыто", isOn: Binding(get: { notificationsOn },
                                                                                       set: { notificationsOn = $0; Notifier.shared.enabled = $0 }))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Toggle("⌃⌥M в любом приложении добавляет ссылку из буфера", isOn: Binding(get: { hotKeyOn }, set: {
                hotKeyOn = $0
                HotKey.enabled = $0
                (NSApp.delegate as? AppDelegate)?.configureHotKey()
            }))
            .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Компонент YouTube: yt-dlp " + (extractor.version ?? "—")).font(.system(size: 12))
                    Spacer()
                    if extractor.checking { ProgressView().controlSize(.mini) }
                    Button("Проверить обновление") { extractor.check() }.disabled(extractor.checking)
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
                if let status = extractor.status {
                    Text(status).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Обновлять автоматически", isOn: Binding(get: { extractor.automatic }, set: { extractor.setAutomatic($0) }))
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                if extractor.usesDownloadedVersion {
                    Button("Вернуть версию из приложения") { extractor.revert() }.buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            .onAppear { extractor.refresh() }
            HStack {
                Button("Открыть «Музыку»") { store.openMusic() }
                Spacer()
                Button("Папка файлов") { NSWorkspace.shared.open(store.directory) }
            }
            .font(.system(size: 11)).buttonStyle(.borderless)
            Text("Music Drop хранит копии MP3. Не удаляй их, если «Музыка» использует эти файлы без собственного копирования.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.hasAutomationError {
                Button("Разрешить управление «Музыкой»…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }.font(.system(size: 11))
            }
            Button("Разрешение для обновления облака…") { CloudUpdateBridge.openPermissionSettings() }
                .font(.system(size: 11))
            Text("Для обновления облака разреши Music Drop Cloud в разделе «Универсальный доступ». Этот отдельный компонент сохраняется при обновлениях Music Drop.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                if store.activeCount > 0 || soundCloud.isDownloading || youtube.isDownloading {
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                    Text(youtube.isDownloading ? "Скачиваем с YouTube…" : soundCloud.isDownloading ? "Скачиваем с SoundCloud…" : store.cloudUpdateInProgress ? "Запрашиваем обновление облака…" : "Добавляем в «Музыку»…")
                } else {
                    Circle().fill(store.cloudWaitingCount > 0 ? Color.orange : Color.green).frame(width: 5, height: 5)
                    Text(store.cloudWaitingCount > 0 ? "Ожидают облака: \(store.cloudWaitingCount)" : "Готово к новым трекам")
                }
                Spacer()
                Menu {
                    Button("Обновить облачную медиатеку") { store.requestCloudUpdate() }
                        .disabled(store.cloudUpdateInProgress || store.successfulCount == 0)
                    Button("Открыть «Музыку»") { store.openMusic() }
                    Button("Показать файлы программы") { NSWorkspace.shared.open(store.directory) }
                    Divider()
                    Text("Music Drop \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.2") · Только личная медиатека")
                    Button("Завершить Music Drop") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }
                .menuStyle(.borderlessButton).fixedSize().help("Меню программы")
                .accessibilityLabel("Меню программы")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 13)
        }
    }

    private func acceptProviders(_ providers: [NSItemProvider]) -> Bool {
        let supported = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        // A link dragged from the browser opens in its source tab.
        if supported.isEmpty, let link = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.url") }) {
            _ = link.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let route = LinkRoute.detect(url.absoluteString) else { return }
                DispatchQueue.main.async { navigation.open(route) }
            }
            return true
        }
        guard !supported.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in supported {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = nil }
                if let url { lock.lock(); urls.append(url); lock.unlock() }
            }
        }
        group.notify(queue: .main) { store.accept(urls); store.dragActive = false }
        return true
    }
}

private struct HistoryRow: View {
    let entry: ImportEntry
    let store: ImportStore
    @State private var confirmingDelete = false

    private var working: Bool {
        entry.stage == .queued || entry.stage == .importing || store.updatingFavorites.contains(entry.id)
    }
    private var warning: Bool {
        entry.stage == .failed || entry.stage == .needsReview || CloudState.isWarning(entry.cloudStatus)
            || entry.favoriteError != nil || entry.isFavorite == false
            || (entry.cloudUpdateError != nil && !CloudState.isReady(entry.cloudStatus)) || entry.playlistError != nil
    }
    private var subtitle: String {
        if store.updatingFavorites.contains(entry.id) { return "Добавляем в избранное…" }
        switch entry.stage {
        case .queued: return store.musicStarting ? "Ждём запуска «Музыки»…" : "В очереди"
        case .importing: return store.musicStarting ? "Запускаем «Музыку»…" : "Добавляем в медиатеку и избранное…"
        case .failed: return "Не удалось добавить"
        case .needsReview: return "Нужно проверить медиатеку"
        case .imported:
            return entry.cloudStatus == "missing" ? "Трек больше не найден в «Музыке»" : CloudState.label(entry.cloudStatus)
        }
    }
    private var symbol: String {
        if warning { return "exclamationmark.triangle" }
        if CloudState.isReady(entry.cloudStatus) { return "checkmark.icloud" }
        return "music.note"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Group {
                    if working { ProgressView().controlSize(.small) }
                    else { Image(systemName: symbol).font(.system(size: 16, weight: .regular)) }
                }
                .foregroundStyle(warning ? Color.orange : accent)
                .frame(width: 34, height: 36)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if entry.isFavorite == true {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(accent)
                                .accessibilityLabel("В избранном")
                        }
                    }
                    Text(subtitle).font(.system(size: 10))
                        .foregroundStyle(warning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if entry.stage == .imported, entry.isFavorite != true, entry.trackID != nil {
                    Button { store.markFavorite(entry) } label: { Image(systemName: "star") }
                        .disabled(store.updatingFavorites.contains(entry.id))
                        .buttonStyle(.borderless).help("Повторить добавление в избранное без импорта")
                        .accessibilityLabel("Добавить \(entry.title) в избранное")
                }
                if entry.stage == .failed {
                    Button { store.retry(entry) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Повторить импорт")
                        .accessibilityLabel("Повторить импорт \(entry.title)")
                } else if entry.stage == .imported || entry.stage == .needsReview {
                    Button { store.openMusic(entry) } label: { Image(systemName: "arrow.up.right") }
                        .buttonStyle(.borderless).help("Показать в «Музыке»")
                        .accessibilityLabel("Показать \(entry.title) в «Музыке»")
                }
            }
            if let error = entry.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 44)
            }
            if let problem = entry.favoriteError {
                Text(problem).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 44)
            }
            if entry.stage == .imported, let playlist = entry.playlist {
                if let problem = entry.playlistError {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Не удалось добавить в «\(playlist)»: " + problem).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Повторить добавление в плейлист") { store.addToPlaylist(entry, playlist: playlist) }
                            .disabled(store.updatingPlaylists.contains(entry.id))
                    }
                    .font(.system(size: 11)).buttonStyle(.borderless).padding(.leading, 44)
                } else {
                    Label("В плейлисте «\(playlist)»", systemImage: "music.note.list")
                        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 44)
                }
            }
            if entry.stage == .imported, CloudState.canAutoRetry(entry.cloudStatus) {
                if let problem = entry.cloudUpdateError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(problem).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if problem.contains("Универсальный доступ") {
                            Button("Разрешить обновление облака…") { CloudUpdateBridge.openPermissionSettings() }
                        }
                        Button("Повторить обновление облака") { store.requestCloudUpdate(for: [entry.id]) }
                            .disabled(store.cloudUpdateInProgress)
                    }
                    .font(.system(size: 11)).buttonStyle(.borderless).padding(.leading, 44)
                } else if entry.cloudUpdateRequestedAt != nil, entry.cloudRetryMessage == nil, CloudState.canAutoRetry(entry.cloudStatus) {
                    Text("Обновление облака запрошено · ждём подтверждения загрузки")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 44)
                }
                if let message = entry.cloudRetryMessage {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 44)
                }
            }
        }
        .padding(.vertical, 10)
        .contextMenu {
            if entry.stage == .imported { Button("Показать в «Музыке»") { store.openMusic(entry) } }
            if entry.stage == .imported, entry.trackID != nil {
                Button("Обновить облачную медиатеку") { store.requestCloudUpdate(for: [entry.id]) }
                    .disabled(store.cloudUpdateInProgress)
                Button("Добавить в избранное") { store.markFavorite(entry) }
                    .disabled(store.updatingFavorites.contains(entry.id))
            }
            if entry.stage == .failed { Button("Повторить") { store.retry(entry) } }
            if let path = entry.managedPath {
                Button("Показать копию файла в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            if let source = entry.sourceURL {
                Button(entry.soundCloudURL != nil ? "Открыть на SoundCloud" : "Открыть на YouTube") { NSWorkspace.shared.open(source) }
            }
            Divider()
            if entry.stage != .queued, entry.stage != .importing {
                Button("Убрать из истории") { store.removeFromHistory(entry) }
            }
            if entry.stage == .imported, entry.trackID != nil {
                Button("Удалить из медиатеки…", role: .destructive) { confirmingDelete = true }
            }
        }
        .confirmationDialog("Удалить «\(entry.title)» из медиатеки «Музыки»?", isPresented: $confirmingDelete) {
            Button("Удалить", role: .destructive) { store.deleteFromLibrary(entry) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Трек пропадёт из «Музыки», её плейлистов и облачной медиатеки на всех устройствах.")
        }
    }
}
