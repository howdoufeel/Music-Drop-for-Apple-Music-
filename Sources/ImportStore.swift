import AppKit
import AVFoundation
import Observation
import ServiceManagement

struct ImportServices {
    var playable: (URL) throws -> Bool = { url in
        // AVFoundation loads asynchronously; only this background queue waits.
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Bool, Error> = .success(false)
        Task {
            do { result = .success(try await AVURLAsset(url: url).load(.isPlayable)) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw DropError.message("Проверка MP3 заняла слишком много времени. Загрузи файл на Mac и повтори.")
        }
        return try result.get()
    }
    var add: (URL) throws -> MusicResult = MusicBridge.add
    var cloudStatus: (String) throws -> String = MusicBridge.cloudStatus
    var favorite: (String) throws -> Void = MusicBridge.favorite
    var updateCloudLibrary: () throws -> Void = CloudUpdateBridge.requestUpdate
    var cloudAccessGranted: () -> Bool = { CloudUpdateBridge.isTrusted }
    var musicIsRunning: () -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty }
    var prepareMusic: () throws -> Void = MusicBridge.prepare
    var addToPlaylist: (String, String) throws -> Void = MusicBridge.addToPlaylist
    var playlistNames: () throws -> [String] = MusicBridge.playlistNames
    var deleteTrack: (String) throws -> Void = MusicBridge.deleteTrack
    var adjust: (String, TrackAdjustments) throws -> Void = MusicBridge.adjust
    /// Lyrics are looked up only where the app turns it on, so tests never reach the network.
    var lyricsEnabled: () -> Bool = { false }
    var lyrics: (_ title: String, _ artist: String, _ duration: Double?) throws -> String? = {
        try Lyrics.find(title: $0, artist: $1, album: nil, duration: $2)
    }
    var setLyrics: (String, String) throws -> Void = MusicBridge.setLyrics

    /// What the app itself uses: everything above, with lyrics following the setting.
    static var app: ImportServices {
        var services = ImportServices()
        services.lyricsEnabled = { Lyrics.enabled }
        return services
    }
}

/// Progress of putting many library tracks into one playlist.
struct PlaylistBuild: Equatable {
    let name: String
    let total: Int
    var done = 0
    var failed = 0
}

/// Coalesces history writes off the main thread; the newest snapshot always wins.
private final class HistoryWriter {
    static let queue = DispatchQueue(label: "tech.musicdrop.history", qos: .utility)
    private let lock = NSLock()
    private var pending: [ImportEntry]?

    func submit(_ entries: [ImportEntry], to url: URL, failed: @escaping (Error) -> Void) {
        lock.lock(); let idle = pending == nil; pending = entries; lock.unlock()
        guard idle else { return }
        Self.queue.async {
            self.lock.lock(); let snapshot = self.pending; self.pending = nil; self.lock.unlock()
            guard let snapshot else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async { failed(error) }
            }
        }
    }

    /// Waits for every scheduled write, from any store.
    static func flush() { queue.sync {} }
}

@Observable final class ImportStore {
    var entries: [ImportEntry] = []
    var notice: String?
    var dragActive = false
    var settingsVisible = false
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var refreshInProgress = false
    var lastRefresh: Date?
    var updatingFavorites: Set<UUID> = []
    var cloudUpdateInProgress = false
    /// Music is launching for an import or a download that will need it.
    var musicStarting = false
    /// Where new tracks go after the import; nil keeps them in the library only.
    private(set) var destination: String?
    /// The user's playlists as Music last listed them.
    private(set) var availablePlaylists: [String] = []
    var updatingPlaylists: Set<UUID> = []
    var updatingAdjustments: Set<UUID> = []
    var updatingLyrics: Set<UUID> = []
    private(set) var playlistBuild: PlaylistBuild?
    private let lyricsQueue = DispatchQueue(label: "tech.musicdrop.lyrics", qos: .utility)
    // Derived from entries once per change, so views and timers never rescan the history.
    private(set) var activeImportCount = 0
    private(set) var successfulCount = 0
    private(set) var cloudWaitingCount = 0
    private(set) var hasAutomationError = false
    private(set) var needsCloudPermission = false
    private(set) var soundCloudEntries: [String: ImportEntry] = [:]
    private(set) var youTubeEntries: [String: ImportEntry] = [:]

    let directory: URL
    private let queue = DispatchQueue(label: "tech.musicdrop.import", qos: .userInitiated)
    private let cloudQueue = DispatchQueue(label: "tech.musicdrop.cloud", qos: .utility)
    private let writer = HistoryWriter()
    @ObservationIgnored private var timer: Timer?
    private let preview: Bool
    private let services: ImportServices
    private let automaticMonitoring: Bool
    @ObservationIgnored private var pendingCloudUpdateIDs: Set<UUID> = []
    private let now: () -> Date
    @ObservationIgnored private var cloudPollOffset = 0
    @ObservationIgnored var onActivity: ((Bool) -> Void)?
    /// True while SoundCloud or YouTube audio is downloading: its import comes next, so Music is
    /// kept free of status reads and cloud requests until then.
    @ObservationIgnored var downloadsActive: () -> Bool = { false }
    /// Called on the main thread when a track reaches the library or cannot be added.
    @ObservationIgnored var onImported: ((ImportEntry) -> Void)?
    @ObservationIgnored var onFailed: ((ImportEntry) -> Void)?
    private let defaults: UserDefaults
    static let destinationKey = "DestinationPlaylist"
    static let playlistsKey = "KnownPlaylists"

    var activeCount: Int {
        activeImportCount + updatingFavorites.count + updatingPlaylists.count + updatingAdjustments.count + updatingLyrics.count
            + (playlistBuild == nil ? 0 : 1) + (cloudUpdateInProgress ? 1 : 0)
    }
    /// Newest entry for a source track, ignoring ones removed from Music.
    func entry(soundCloudID id: String) -> ImportEntry? { soundCloudEntries[id] }
    func entry(youTubeID id: String) -> ImportEntry? { youTubeEntries[id] }
    private var downloadsDirectory: URL { directory.appendingPathComponent("Downloads", isDirectory: true) }

    init(directory: URL? = nil, preview: Bool = false, services: ImportServices = .init(), startTimer: Bool = true,
         now: @escaping () -> Date = Date.init, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        destination = defaults.string(forKey: Self.destinationKey)?.nonEmpty
        availablePlaylists = defaults.stringArray(forKey: Self.playlistsKey) ?? []
        self.preview = preview
        self.services = services
        self.automaticMonitoring = startTimer
        self.now = now
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music Drop", isDirectory: true)
        if preview {
            entries = [
                ImportEntry(sourcePath: "", title: "Midnight City", stage: .imported, cloudStatus: "uploaded", isFavorite: true),
                ImportEntry(sourcePath: "", title: "Новая запись", stage: .imported, cloudStatus: "not uploaded", isFavorite: true,
                            cloudUpdateError: CloudUpdateError.accessibilityRequired.localizedDescription)
            ]
            reindex()
            return
        }
        load()
        reindex()
        if startTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.cloudSyncTick() }
            if cloudWaitingCount > 0 { DispatchQueue.main.async { [weak self] in self?.cloudSyncTick() } }
        }
    }

    private var historyURL: URL { directory.appendingPathComponent("history.json") }

    deinit { timer?.invalidate() }

    private func load() {
        // Another store in this process may still be writing the same history.
        HistoryWriter.flush()
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            var loaded = try JSONDecoder().decode([ImportEntry].self, from: Data(contentsOf: historyURL))
            for index in loaded.indices {
                if loaded[index].stage == .importing {
                    loaded[index].stage = .needsReview
                    loaded[index].error = "Программа закрылась во время импорта. Проверь «Музыку»: трек мог уже добавиться."
                } else if loaded[index].stage == .queued {
                    loaded[index].stage = .failed
                    loaded[index].error = "Импорт не начался до закрытия программы. Можно повторить."
                }
                // Older releases stopped after one request; resume only unfinished audio uploads.
                if loaded[index].stage == .imported, loaded[index].trackID != nil,
                   loaded[index].cloudSyncPending == nil, CloudState.canAutoRetry(loaded[index].cloudStatus) {
                    loaded[index].cloudSyncPending = true
                    loaded[index].cloudRetryAt = now()
                    loaded[index].cloudPermissionBlocked = loaded[index].cloudUpdateError?.contains("Универсальный доступ") == true
                }
                if loaded[index].cloudSyncPending == true, loaded[index].cloudPermissionBlocked == true {
                    loaded[index].cloudUpdateError = CloudUpdateError.accessibilityRequired.localizedDescription
                }
                if loaded[index].stage == .imported, !CloudState.canAutoRetry(loaded[index].cloudStatus),
                   loaded[index].cloudPermissionBlocked == true || loaded[index].cloudUpdateError?.contains("Универсальный доступ") == true {
                    loaded[index].cloudPermissionBlocked = false
                    loaded[index].cloudUpdateError = nil
                }
            }
            entries = loaded
            save()
        } catch {
            let backup = directory.appendingPathComponent("history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try FileManager.default.moveItem(at: historyURL, to: backup)
                notice = "Не удалось прочитать историю. Её копия сохранена в папке программы."
            } catch {
                notice = "История недоступна. Проверь права доступа к папке программы."
            }
        }
    }

    /// Every change to entries ends here: derived state is refreshed, then the main thread
    /// only hands over a snapshot; encoding and disk writes happen in the background.
    private func save() {
        reindex()
        guard !preview else { return }
        writer.submit(entries, to: historyURL) { [weak self] error in
            self?.notice = "Не удалось сохранить историю: \(error.localizedDescription)"
        }
        onActivity?(activeCount > 0)
    }

    /// Writes pending history before the app quits.
    func flushHistory() { HistoryWriter.flush() }

    private func reindex() {
        var active = 0, successful = 0, waiting = 0
        var automation = false, permission = false
        var bySoundCloud: [String: ImportEntry] = [:], byYouTube: [String: ImportEntry] = [:]
        for entry in entries {
            switch entry.stage {
            case .queued, .importing: active += 1
            case .imported: successful += 1
            case .failed, .needsReview: break
            }
            let retryable = CloudState.canAutoRetry(entry.cloudStatus)
            if entry.stage == .imported, entry.cloudSyncPending == true, retryable { waiting += 1 }
            if entry.error?.contains("Автоматизация") == true || entry.favoriteError?.contains("Автоматизация") == true { automation = true }
            if retryable, entry.cloudUpdateError?.contains("Универсальный доступ") == true { permission = true }
            guard entry.cloudStatus != "missing" else { continue }
            if let id = entry.soundCloudID, bySoundCloud[id] == nil { bySoundCloud[id] = entry }
            if let id = entry.youtubeID, byYouTube[id] == nil { byYouTube[id] = entry }
        }
        // Assign only real changes so unrelated views are not invalidated.
        if activeImportCount != active { activeImportCount = active }
        if successfulCount != successful { successfulCount = successful }
        if cloudWaitingCount != waiting { cloudWaitingCount = waiting }
        if hasAutomationError != automation { hasAutomationError = automation }
        if needsCloudPermission != permission { needsCloudPermission = permission }
        if soundCloudEntries != bySoundCloud { soundCloudEntries = bySoundCloud }
        if youTubeEntries != byYouTube { youTubeEntries = byYouTube }
    }

    func accept(_ urls: [URL]) {
        guard !preview else { notice = "Это предпросмотр интерфейса. Импорт отключён."; return }
        let supported = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "mp3" }
        guard !supported.isEmpty else { notice = "Перетащи один или несколько MP3-файлов."; return }
        if supported.count != urls.count { notice = "Добавлены MP3. Файлы других форматов пропущены." }
        else { notice = nil }
        for url in supported {
            guard !entries.contains(where: {
                $0.sourcePath == url.path && ($0.stage == .queued || $0.stage == .importing)
            }) else { continue }
            let entry = ImportEntry(sourcePath: url.path, title: url.deletingPathExtension().lastPathComponent, playlist: destination)
            entries.insert(entry, at: 0)
            save()
            performImport(entry)
        }
    }

    func retry(_ entry: ImportEntry) {
        guard entry.stage == .failed, let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].stage = .queued
        entries[index].error = nil
        save()
        performImport(entries[index])
    }

    /// `playlist` overrides the chosen destination, as when a whole set goes into its own playlist.
    func acceptSoundCloud(_ url: URL, track: SoundCloudTrack, playlist: String? = nil, adjustments: TrackAdjustments? = nil) {
        guard !preview else { return }
        let target = playlist ?? destination
        if let existing = entries.first(where: {
            $0.soundCloudID == track.id && $0.stage == .imported && $0.cloudStatus != "missing"
        }) {
            notice = "«\(existing.title)» уже в медиатеке. Обновляем избранное и облако."
            markFavorite(existing)
            if let target { addToPlaylist(existing, playlist: target) }
            if let adjustments { adjust(existing, adjustments) }
            return
        }
        let entry = ImportEntry(sourcePath: url.path, title: track.title,
                                soundCloudID: track.id, soundCloudURL: track.url, playlist: target,
                                artist: track.artist, duration: track.duration, adjustments: adjustments)
        entries.insert(entry, at: 0)
        save()
        performImport(entry)
    }

    func acceptYouTube(_ url: URL, track: YouTubeTrack, playlist: String? = nil, adjustments: TrackAdjustments? = nil) {
        guard !preview else { return }
        let target = playlist ?? destination
        if let existing = entries.first(where: {
            $0.youtubeID == track.libraryID && $0.cloudStatus != "missing"
        }) {
            if existing.stage == .imported {
                markFavorite(existing)
                if let target { addToPlaylist(existing, playlist: target) }
            }
            else if existing.stage == .failed { retry(existing) }
            return
        }
        let entry = ImportEntry(sourcePath: url.path, title: track.title,
                                youtubeID: track.libraryID, youtubeURL: track.url, playlist: target,
                                artist: track.artist, duration: track.duration, adjustments: adjustments)
        entries.insert(entry, at: 0)
        save()
        performImport(entry)
    }

    /// Sets where an imported track starts and ends in Music; nil restores that end of the track.
    func trim(_ entry: ImportEntry, start: Double?, finish: Double?) {
        var adjustments = entry.adjustments ?? TrackAdjustments()
        adjustments.start = start
        adjustments.finish = finish
        adjust(entry, adjustments)
    }

    func adjust(_ entry: ImportEntry, _ adjustments: TrackAdjustments) {
        guard !preview, entry.stage == .imported, let trackID = entry.trackID, !updatingAdjustments.contains(entry.id) else { return }
        updatingAdjustments.insert(entry.id)
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.services.adjust(trackID, adjustments) }
            DispatchQueue.main.async {
                self.updatingAdjustments.remove(entry.id)
                self.update(entry.id) {
                    switch result {
                    case .success: $0.adjustments = adjustments.isEmpty ? nil : adjustments; $0.adjustmentError = nil
                    case .failure(let error): $0.adjustmentError = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Looks the lyrics up on LRCLIB and writes them into the track in Music. Automatic lookups stay quiet.
    func findLyrics(_ entry: ImportEntry, automatic: Bool = false) {
        guard !preview, entry.stage == .imported, let trackID = entry.trackID, !updatingLyrics.contains(entry.id) else { return }
        guard let artist = entry.artist?.nonEmpty else {
            if !automatic { notice = "У «\(entry.title)» не указан исполнитель, текст не найти." }
            return
        }
        updatingLyrics.insert(entry.id)
        lyricsQueue.async { [weak self] in
            guard let self else { return }
            let found = Result { try self.services.lyrics(entry.title, artist, entry.duration) }
            guard case .success(let text?) = found else {
                DispatchQueue.main.async {
                    self.updatingLyrics.remove(entry.id)
                    if case .success = found { self.update(entry.id) { $0.hasLyrics = false } }
                    guard !automatic else { return }
                    if case .failure = found { self.notice = "LRCLIB не ответил. Попробуй позже." }
                    else { self.notice = "Текст для «\(entry.title)» не найден." }
                }
                return
            }
            // Music is changed on the import queue, between imports.
            self.queue.async {
                let written = Result { try self.services.setLyrics(trackID, text) }
                DispatchQueue.main.async {
                    self.updatingLyrics.remove(entry.id)
                    switch written {
                    case .success: self.update(entry.id) { $0.hasLyrics = true }
                    case .failure(let error): if !automatic { self.notice = "Не удалось записать текст: " + error.localizedDescription }
                    }
                }
            }
        }
    }

    /// Puts tracks into one playlist in the order they were added; entry records are left alone.
    func buildPlaylist(_ name: String, from candidates: [ImportEntry]) {
        let targets = candidates.filter { $0.stage == .imported && $0.cloudStatus != "missing" }
            .sorted { $0.date < $1.date }.compactMap(\.trackID)
        guard !preview, playlistBuild == nil, !targets.isEmpty, let name = name.nonEmpty else { return }
        playlistBuild = PlaylistBuild(name: name, total: targets.count)
        queue.async { [weak self] in
            guard let self else { return }
            var failed = 0
            for (index, id) in targets.enumerated() {
                do { try self.services.addToPlaylist(id, name) } catch { failed += 1 }
                let done = index + 1, failures = failed
                DispatchQueue.main.async { self.playlistBuild?.done = done; self.playlistBuild?.failed = failures }
            }
            DispatchQueue.main.async {
                self.playlistBuild = nil
                self.notice = failed == 0 ? "Плейлист «\(name)» собран: \(LibraryStats.plural(targets.count, "трек", "трека", "треков"))."
                    : "Плейлист «\(name)»: добавлено \(targets.count - failed), не удалось \(failed)."
            }
        }
    }

    /// The chapters of a video already in the history, by their position.
    func chapterEntries(youTubeID id: String) -> [ImportEntry] {
        youTubeEntries.filter { $0.key.hasPrefix(id + "#") }.map(\.value)
    }

    func markFavorite(_ entry: ImportEntry) {
        guard !preview, entry.stage == .imported, let trackID = entry.trackID,
              !updatingFavorites.contains(entry.id) else { return }
        updatingFavorites.insert(entry.id)
        onActivity?(true)
        queue.async { [weak self] in
            guard let self else { return }
            var problem: String?
            do { try self.services.favorite(trackID) }
            catch { problem = error.localizedDescription }
            DispatchQueue.main.async {
                self.updatingFavorites.remove(entry.id)
                self.update(entry.id) {
                    $0.isFavorite = problem == nil
                    $0.favoriteError = problem
                }
                self.requestCloudUpdate(for: [entry.id])
            }
        }
    }

    private func update(_ id: UUID, _ action: (inout ImportEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        action(&entries[index])
        save()
    }

    /// Applies one change to many entries with a single reindex and save.
    private func updateAll(_ ids: Set<UUID>, _ action: (inout ImportEntry) -> Void) {
        guard !ids.isEmpty else { return }
        var changed = entries
        for index in changed.indices where ids.contains(changed[index].id) { action(&changed[index]) }
        entries = changed
        save()
    }

    private func isOwnDownload(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(downloadsDirectory.standardizedFileURL.path + "/")
    }

    /// Removes a finished download's empty staging folders, keeping each source's own folder.
    private func cleanStaging(of source: URL, removingFile: Bool) {
        let fm = FileManager.default
        if removingFile { try? fm.removeItem(at: source) }
        let root = downloadsDirectory.standardizedFileURL.path
        var folder = source.deletingLastPathComponent()
        while folder.standardizedFileURL.path.hasPrefix(root + "/"),
              folder.deletingLastPathComponent().standardizedFileURL.path != root,
              (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fm.removeItem(at: folder)
            folder = folder.deletingLastPathComponent()
        }
    }

    func setDestination(_ playlist: String?) {
        destination = playlist?.nonEmpty
        defaults.set(destination, forKey: Self.destinationKey)
        if let destination, !availablePlaylists.contains(destination) { rememberPlaylists(availablePlaylists + [destination]) }
    }

    /// Refreshes the playlist menu from Music, only while Music is already running.
    func loadPlaylists() {
        guard !preview, services.musicIsRunning() else { return }
        queue.async { [weak self] in
            guard let self, let names = try? self.services.playlistNames() else { return }
            DispatchQueue.main.async { self.rememberPlaylists(names + [self.destination].compactMap { $0 }) }
        }
    }

    private func rememberPlaylists(_ names: [String]) {
        var seen: Set<String> = []
        let unique = names.filter { seen.insert($0).inserted }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if unique != availablePlaylists { availablePlaylists = unique }
        defaults.set(unique, forKey: Self.playlistsKey)
    }

    /// Forgets the entry; the track stays in Music and its file stays on disk.
    func removeFromHistory(_ entry: ImportEntry) {
        guard entry.stage != .queued, entry.stage != .importing else { return }
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// Deletes the track from Music, then its history entry and Music Drop's own copy of the file.
    func deleteFromLibrary(_ entry: ImportEntry) {
        guard !preview, entry.stage == .imported, let trackID = entry.trackID else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.services.deleteTrack(trackID)
                DispatchQueue.main.async {
                    self.entries.removeAll { $0.id == entry.id }
                    self.save()
                    if let path = entry.managedPath, !self.entries.contains(where: { $0.managedPath == path }) {
                        let file = URL(fileURLWithPath: path)
                        let media = self.directory.appendingPathComponent("Media").standardizedFileURL.path + "/"
                        if file.standardizedFileURL.path.hasPrefix(media) {
                            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.notice = "Не удалось удалить «\(entry.title)» из «Музыки»: " + error.localizedDescription }
            }
        }
    }

    /// Puts an imported track into a playlist without importing it again.
    func addToPlaylist(_ entry: ImportEntry, playlist: String) {
        guard !preview, entry.stage == .imported, let trackID = entry.trackID, !updatingPlaylists.contains(entry.id) else { return }
        updatingPlaylists.insert(entry.id)
        queue.async { [weak self] in
            guard let self else { return }
            var problem: String?
            do { try self.services.addToPlaylist(trackID, playlist) }
            catch { problem = error.localizedDescription }
            DispatchQueue.main.async {
                self.updatingPlaylists.remove(entry.id)
                self.update(entry.id) { $0.playlist = playlist; $0.playlistError = problem }
            }
        }
    }

    /// Called when a download starts: Music launches while the audio is still downloading.
    func prepareMusic() {
        guard !preview, !musicStarting, !services.musicIsRunning() else { return }
        musicStarting = true
        queue.async { [weak self] in
            guard let self else { return }
            let started = Date()
            try? self.services.prepareMusic()
            NSLog("Music Drop: Music ready for imports after %.2f s", Date().timeIntervalSince(started))
            DispatchQueue.main.async { self.musicStarting = false }
        }
    }

    /// Called when the last download finishes, so the deferred cloud request can run.
    func downloadsFinished() {
        beginCloudUpdate()
    }

    private func performImport(_ entry: ImportEntry) {
        let enqueued = Date()
        queue.async { [weak self] in
            guard let self else { return }
            let started = Date()
            DispatchQueue.main.sync { self.update(entry.id) { $0.stage = .importing } }
            let source = URL(fileURLWithPath: entry.managedPath ?? entry.sourcePath)
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                let downloaded = entry.soundCloudID != nil || entry.youtubeID != nil
                // Music Drop's own finished downloads are moved, not copied and hashed twice.
                let ownDownload = downloaded && entry.managedPath == nil && self.isOwnDownload(source)
                try FileTools.validate(source, allowedExtensions: downloaded ? ["mp3", "m4a"] : ["mp3"])
                guard try self.services.playable(source) else {
                    throw DropError.message("Не удалось прочитать аудио. Проверь, что MP3 не повреждён и полностью загружен.")
                }
                let digest = try FileTools.digest(source)
                var existing: ImportEntry?
                DispatchQueue.main.sync {
                    existing = self.entries.first { $0.id != entry.id && $0.digest == digest &&
                        (($0.stage == .imported && $0.cloudStatus != "missing") || $0.stage == .needsReview) }
                }
                if let existing {
                    if ownDownload { self.cleanStaging(of: source, removingFile: true) }
                    DispatchQueue.main.async {
                        self.entries.removeAll { $0.id == entry.id }
                        self.notice = existing.stage == .needsReview
                            ? "Этот файл уже отправлялся в «Музыку». Проверь медиатеку перед повтором."
                            : "«\(existing.title)» уже добавлен через Music Drop."
                        self.save()
                        if existing.stage == .imported {
                            self.markFavorite(existing)
                            if let playlist = entry.playlist { self.addToPlaylist(existing, playlist: playlist) }
                        } else {
                            self.beginCloudUpdate()
                        }
                    }
                    return
                }
                let managed = try FileTools.preserve(source, digest: digest,
                                                     directory: self.directory.appendingPathComponent("Media"), moving: ownDownload)
                if ownDownload { self.cleanStaging(of: source, removingFile: false) }
                DispatchQueue.main.sync {
                    self.update(entry.id) { $0.digest = digest; $0.managedPath = managed.path }
                }
                let launching = !self.services.musicIsRunning()
                if launching { DispatchQueue.main.async { self.musicStarting = true } }
                let adding = Date()
                let result: MusicResult
                do { result = try self.services.add(managed) }
                catch {
                    if launching { DispatchQueue.main.async { self.musicStarting = false } }
                    throw error
                }
                // The playlist step never undoes a successful import; its error is shown on the row.
                var playlistProblem: String?
                if let playlist = entry.playlist {
                    do { try self.services.addToPlaylist(result.id, playlist) }
                    catch { playlistProblem = error.localizedDescription }
                }
                var adjustmentProblem: String?
                if let adjustments = entry.adjustments, !adjustments.isEmpty {
                    do { try self.services.adjust(result.id, adjustments) }
                    catch { adjustmentProblem = error.localizedDescription }
                }
                // Timings in Console.app (process "Music Drop") show where an import waited.
                NSLog("Music Drop import: queued %.2f s, file checks %.2f s, Music %.2f s, Music launched: %d",
                      started.timeIntervalSince(enqueued), adding.timeIntervalSince(started), Date().timeIntervalSince(adding),
                      launching ? 1 : 0)
                DispatchQueue.main.async {
                    if launching { self.musicStarting = false }
                    self.update(entry.id) {
                        $0.trackID = result.id; $0.title = result.title
                        $0.cloudStatus = result.cloudStatus; $0.stage = .imported; $0.error = nil
                        $0.isFavorite = result.isFavorite; $0.favoriteError = result.favoriteError
                        $0.playlistError = playlistProblem
                        $0.adjustmentError = adjustmentProblem
                        $0.artist = result.artist ?? $0.artist
                        $0.duration = result.duration ?? $0.duration
                    }
                    if let imported = self.entries.first(where: { $0.id == entry.id }) {
                        self.onImported?(imported)
                        if self.services.lyricsEnabled() { self.findLyrics(imported, automatic: true) }
                    }
                    self.requestCloudUpdate(for: [entry.id])
                }
            } catch {
                DispatchQueue.main.async {
                    self.update(entry.id) {
                        $0.stage = (error as? AutomationError)?.code == -1712 ? .needsReview : .failed
                        $0.error = error.localizedDescription
                    }
                    if let failed = self.entries.first(where: { $0.id == entry.id }) { self.onFailed?(failed) }
                    // Earlier tracks of the batch may still be waiting for their cloud request.
                    self.beginCloudUpdate()
                }
            }
        }
    }

    /// Waits for queued imports; one menu request covers every completed import in a batch.
    func requestCloudUpdate(for ids: [UUID]? = nil) {
        guard !preview else { return }
        let imported = Set(entries.lazy.filter { $0.stage == .imported }.map(\.id))
        let candidates = ids.map { Set($0).intersection(imported) } ?? imported
        pendingCloudUpdateIDs.formUnion(candidates)
        updateAll(candidates) {
            $0.cloudSyncPending = true
            $0.cloudRetryCount = 0
            $0.cloudRetryAt = nil
            $0.cloudPermissionBlocked = false
        }
        beginCloudUpdate()
    }

    /// The helper runs on its own queue, so a slow menu request never delays the next import.
    private func beginCloudUpdate() {
        guard !pendingCloudUpdateIDs.isEmpty, !cloudUpdateInProgress, activeImportCount == 0, !downloadsActive() else { return }
        cloudUpdateInProgress = true
        onActivity?(true)
        let affected = pendingCloudUpdateIDs
        pendingCloudUpdateIDs.removeAll()
        cloudQueue.async { [weak self] in
            guard let self else { return }
            var problem: String?
            var permissionBlocked = false
            do { try self.services.updateCloudLibrary() }
            catch {
                problem = error.localizedDescription
                permissionBlocked = (error as? CloudUpdateError) == .accessibilityRequired
            }
            let attemptedAt = self.now()
            DispatchQueue.main.async {
                self.cloudUpdateInProgress = false
                self.updateAll(affected) {
                    if problem == nil { $0.cloudUpdateRequestedAt = attemptedAt }
                    $0.cloudUpdateError = problem
                    $0.cloudPermissionBlocked = permissionBlocked
                    let attempt = min(100, ($0.cloudRetryCount ?? 0) + 1)
                    $0.cloudRetryCount = attempt
                    $0.cloudSyncPending = CloudState.canAutoRetry($0.cloudStatus)
                    $0.cloudRetryAt = $0.cloudSyncPending == true
                        ? attemptedAt.addingTimeInterval(CloudState.retryDelay(attempt: attempt, commandAccepted: problem == nil)) : nil
                }
                if !self.pendingCloudUpdateIDs.isEmpty {
                    self.beginCloudUpdate()
                } else if self.automaticMonitoring {
                    self.refreshCloud()
                }
            }
        }
    }

    /// Called by the timer and after status reads. Waiting never blocks an import or quits Music.
    func cloudSyncTick() {
        guard !preview, activeCount == 0, !refreshInProgress, services.musicIsRunning() else { return }
        if cloudWaitingCount > 0 || lastRefresh == nil || now().timeIntervalSince(lastRefresh!) >= 45 {
            refreshCloud()
        }
    }

    private func retryCloudIfDue() {
        guard activeCount == 0, !refreshInProgress, services.musicIsRunning() else { return }
        let waiting = entries.filter {
            $0.stage == .imported && $0.trackID != nil && $0.cloudSyncPending == true && CloudState.canAutoRetry($0.cloudStatus)
        }
        // Never prompt for access from a timer. Resume as soon as the user grants it.
        let permitted = waiting.filter { $0.cloudPermissionBlocked != true || services.cloudAccessGranted() }
        guard permitted.contains(where: {
            ($0.cloudPermissionBlocked == true && services.cloudAccessGranted()) || ($0.cloudRetryAt ?? .distantPast) <= now()
        }) else { return }
        // One library-wide command also covers the other pending tracks in this batch.
        pendingCloudUpdateIDs.formUnion(permitted.map(\.id))
        beginCloudUpdate()
    }

    func refreshCloud() {
        guard !preview, !refreshInProgress, activeCount == 0, !downloadsActive(),
              services.musicIsRunning() else { return }
        // Bound each poll; prefer tracks whose cloud result is still pending.
        let imported = entries.filter { $0.stage == .imported && $0.trackID != nil }
        let waiting = imported.filter { $0.cloudSyncPending == true && CloudState.canAutoRetry($0.cloudStatus) }
        let offset = waiting.isEmpty ? 0 : cloudPollOffset % waiting.count
        let rotated = Array(waiting.dropFirst(offset)) + Array(waiting.prefix(offset))
        let waitingIDs = Set(waiting.map(\.id))
        let selected = Array((rotated + imported.filter { !waitingIDs.contains($0.id) }).prefix(20))
        cloudPollOffset = waiting.isEmpty ? 0 : (offset + min(20, waiting.count)) % waiting.count
        guard !selected.isEmpty else { return }
        refreshInProgress = true
        queue.async { [weak self] in
            guard let self else { return }
            var updates: [UUID: String] = [:]
            var failure: String?
            for entry in selected {
                // Stop at once when an import is queued or a download will soon need Music.
                var hasPendingImports = false
                DispatchQueue.main.sync { hasPendingImports = self.activeCount > 0 || self.downloadsActive() }
                if hasPendingImports { break }
                do { updates[entry.id] = try self.services.cloudStatus(entry.trackID!) }
                catch { failure = error.localizedDescription; break }
            }
            DispatchQueue.main.async {
                self.updateAll(Set(updates.keys)) {
                    guard let status = updates[$0.id] else { return }
                    $0.cloudStatus = status
                    if !CloudState.canAutoRetry(status) {
                        $0.cloudSyncPending = false
                        $0.cloudRetryAt = nil
                        if CloudState.isReady(status) {
                            $0.cloudUpdateError = nil
                            $0.cloudPermissionBlocked = false
                        }
                    }
                }
                self.refreshInProgress = false
                if failure == nil {
                    self.lastRefresh = self.now()
                    self.retryCloudIfDue()
                }
                else if self.hasAutomationError { self.notice = failure }
            }
        }
    }

    func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Добавить"
        panel.message = "Выбери MP3 для добавления в медиатеку «Музыки»."
        panel.begin { [weak self] result in if result == .OK { self?.accept(panel.urls) } }
    }

    func setLogin(_ enabled: Bool) {
        guard !preview else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                notice = "Разреши автозапуск в Системных настройках → Основные → Объекты входа."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { notice = "Не удалось изменить автозапуск: \(error.localizedDescription)" }
    }

    func openMusic(_ entry: ImportEntry? = nil) {
        if let id = entry?.trackID {
            queue.async { try? MusicBridge.reveal(id: id) }
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }
}
