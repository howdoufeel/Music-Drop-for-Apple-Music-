import AppKit
import SwiftUI
import AVFoundation
import ServiceManagement
import ApplicationServices

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
}

final class ImportStore: ObservableObject {
    @Published var entries: [ImportEntry] = []
    @Published var notice: String?
    @Published var dragActive = false
    @Published var settingsVisible = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var refreshInProgress = false
    @Published var lastRefresh: Date?
    @Published var updatingFavorites: Set<UUID> = []
    @Published var cloudUpdateInProgress = false

    let directory: URL
    private let queue = DispatchQueue(label: "tech.musicdrop.import", qos: .userInitiated)
    private var timer: Timer?
    private let preview: Bool
    private let services: ImportServices
    private let automaticMonitoring: Bool
    private var pendingCloudUpdateIDs: Set<UUID> = []
    private let now: () -> Date
    private var cloudPollOffset = 0
    var onActivity: ((Bool) -> Void)?

    var activeCount: Int {
        entries.filter { $0.stage == .queued || $0.stage == .importing }.count
            + updatingFavorites.count + (cloudUpdateInProgress ? 1 : 0)
    }
    var needsCloudPermission: Bool {
        entries.contains { CloudState.canAutoRetry($0.cloudStatus) && $0.cloudUpdateError?.contains("Универсальный доступ") == true }
    }
    var successfulCount: Int { entries.filter { $0.stage == .imported }.count }
    var cloudWaitingCount: Int {
        entries.filter { $0.stage == .imported && $0.cloudSyncPending == true && CloudState.canAutoRetry($0.cloudStatus) }.count
    }
    var hasAutomationError: Bool { entries.contains {
        $0.error?.contains("Автоматизация") == true || $0.favoriteError?.contains("Автоматизация") == true
    } }

    init(directory: URL? = nil, preview: Bool = false, services: ImportServices = .init(), startTimer: Bool = true,
         now: @escaping () -> Date = Date.init) {
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
            return
        }
        load()
        if startTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.cloudSyncTick() }
            if cloudWaitingCount > 0 { DispatchQueue.main.async { [weak self] in self?.cloudSyncTick() } }
        }
    }

    private var historyURL: URL { directory.appendingPathComponent("history.json") }

    deinit { timer?.invalidate() }

    private func load() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            entries = try JSONDecoder().decode([ImportEntry].self, from: Data(contentsOf: historyURL))
            for index in entries.indices {
                if entries[index].stage == .importing {
                    entries[index].stage = .needsReview
                    entries[index].error = "Программа закрылась во время импорта. Проверь «Музыку»: трек мог уже добавиться."
                } else if entries[index].stage == .queued {
                    entries[index].stage = .failed
                    entries[index].error = "Импорт не начался до закрытия программы. Можно повторить."
                }
                // Older releases stopped after one request; resume only unfinished audio uploads.
                if entries[index].stage == .imported, entries[index].trackID != nil,
                   entries[index].cloudSyncPending == nil, CloudState.canAutoRetry(entries[index].cloudStatus) {
                    entries[index].cloudSyncPending = true
                    entries[index].cloudRetryAt = now()
                    entries[index].cloudPermissionBlocked = entries[index].cloudUpdateError?.contains("Универсальный доступ") == true
                }
                if entries[index].cloudSyncPending == true, entries[index].cloudPermissionBlocked == true {
                    entries[index].cloudUpdateError = CloudUpdateError.accessibilityRequired.localizedDescription
                }
                if entries[index].stage == .imported, !CloudState.canAutoRetry(entries[index].cloudStatus),
                   entries[index].cloudPermissionBlocked == true || entries[index].cloudUpdateError?.contains("Универсальный доступ") == true {
                    entries[index].cloudPermissionBlocked = false
                    entries[index].cloudUpdateError = nil
                }
            }
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

    private func save() {
        guard !preview else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            notice = "Не удалось сохранить историю: \(error.localizedDescription)"
        }
        onActivity?(activeCount > 0)
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
            let entry = ImportEntry(sourcePath: url.path, title: url.deletingPathExtension().lastPathComponent)
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

    func acceptSoundCloud(_ url: URL, track: SoundCloudTrack) {
        guard !preview else { return }
        if let existing = entries.first(where: {
            $0.soundCloudID == track.id && $0.stage == .imported && $0.cloudStatus != "missing"
        }) {
            notice = "«\(existing.title)» уже в медиатеке. Обновляем избранное и облако."
            markFavorite(existing)
            return
        }
        let entry = ImportEntry(sourcePath: url.path, title: track.title,
                                soundCloudID: track.id, soundCloudURL: track.url)
        entries.insert(entry, at: 0)
        save()
        performImport(entry)
    }

    func acceptYouTube(_ url: URL, track: YouTubeTrack) {
        guard !preview else { return }
        if let existing = entries.first(where: {
            $0.youtubeID == track.id && $0.cloudStatus != "missing"
        }) {
            if existing.stage == .imported { markFavorite(existing) }
            else if existing.stage == .failed { retry(existing) }
            return
        }
        let entry = ImportEntry(sourcePath: url.path, title: track.title,
                                youtubeID: track.id, youtubeURL: track.url)
        entries.insert(entry, at: 0)
        save()
        performImport(entry)
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

    private func performImport(_ entry: ImportEntry) {
        queue.async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.sync { self.update(entry.id) { $0.stage = .importing } }
            let source = URL(fileURLWithPath: entry.managedPath ?? entry.sourcePath)
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                try FileTools.validate(source, allowedExtensions: entry.soundCloudID == nil ? ["mp3"] : ["mp3", "m4a"])
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
                    DispatchQueue.main.async {
                        self.entries.removeAll { $0.id == entry.id }
                        self.notice = existing.stage == .needsReview
                            ? "Этот файл уже отправлялся в «Музыку». Проверь медиатеку перед повтором."
                            : "«\(existing.title)» уже добавлен через Music Drop."
                        self.save()
                        if existing.stage == .imported {
                            self.markFavorite(existing)
                        }
                    }
                    return
                }
                let managed = try FileTools.preserve(source, digest: digest,
                                                     directory: self.directory.appendingPathComponent("Media"))
                DispatchQueue.main.sync {
                    self.update(entry.id) { $0.digest = digest; $0.managedPath = managed.path }
                }
                let result = try self.services.add(managed)
                DispatchQueue.main.async {
                    self.update(entry.id) {
                        $0.trackID = result.id; $0.title = result.title
                        $0.cloudStatus = result.cloudStatus; $0.stage = .imported; $0.error = nil
                        $0.isFavorite = result.isFavorite; $0.favoriteError = result.favoriteError
                    }
                    self.requestCloudUpdate(for: [entry.id])
                }
            } catch {
                DispatchQueue.main.async {
                    self.update(entry.id) {
                        $0.stage = (error as? AutomationError)?.code == -1712 ? .needsReview : .failed
                        $0.error = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Queued behind imports; one menu request covers every completed import in a batch.
    func requestCloudUpdate(for ids: [UUID]? = nil) {
        guard !preview else { return }
        let candidates = ids ?? entries.filter { $0.stage == .imported }.map(\.id)
        for id in candidates where entries.contains(where: { $0.id == id && $0.stage == .imported }) {
            pendingCloudUpdateIDs.insert(id)
            update(id) {
                $0.cloudSyncPending = true
                $0.cloudRetryCount = 0
                $0.cloudRetryAt = nil
                $0.cloudPermissionBlocked = false
            }
        }
        beginCloudUpdate()
    }

    private func beginCloudUpdate() {
        guard !pendingCloudUpdateIDs.isEmpty, !cloudUpdateInProgress else { return }
        cloudUpdateInProgress = true
        onActivity?(true)
        queue.async { [weak self] in
            guard let self else { return }
            var affected: Set<UUID> = []
            DispatchQueue.main.sync {
                affected = self.pendingCloudUpdateIDs
                self.pendingCloudUpdateIDs.removeAll()
            }
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
                for id in affected {
                    self.update(id) {
                        if problem == nil { $0.cloudUpdateRequestedAt = attemptedAt }
                        $0.cloudUpdateError = problem
                        $0.cloudPermissionBlocked = permissionBlocked
                        let attempt = min(100, ($0.cloudRetryCount ?? 0) + 1)
                        $0.cloudRetryCount = attempt
                        $0.cloudSyncPending = CloudState.canAutoRetry($0.cloudStatus)
                        $0.cloudRetryAt = $0.cloudSyncPending == true
                            ? attemptedAt.addingTimeInterval(CloudState.retryDelay(attempt: attempt, commandAccepted: problem == nil)) : nil
                    }
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
        guard !preview, !refreshInProgress, activeCount == 0,
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
                var hasPendingImports = false
                DispatchQueue.main.sync { hasPendingImports = self.activeCount > 0 }
                if hasPendingImports { break }
                do { updates[entry.id] = try self.services.cloudStatus(entry.trackID!) }
                catch { failure = error.localizedDescription; break }
            }
            DispatchQueue.main.async {
                for (id, status) in updates {
                    self.update(id) {
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
