import Foundation

/// Imports MP3 files that appear in a chosen folder, such as Downloads. A file is taken only
/// after its size and date stay the same between two looks, so downloads in progress wait.
/// Files changed while Music Drop was closed count as new on the next launch.
final class FolderWatcher {
    static let folderKey = "WatchedFolder"
    static let sinceKey = "WatchedFolderSince"

    let folder: URL
    private let interval: TimeInterval
    private let defaults: UserDefaults
    private let deliver: ([URL]) -> Void
    private let queue = DispatchQueue(label: "tech.musicdrop.folder-watcher", qos: .utility)
    private var known: Set<String> = []
    private var pending: [String: Snapshot] = [:]
    private var timer: DispatchSourceTimer?

    private struct Snapshot: Equatable {
        let size: Int
        let modified: Date
    }

    /// The folder saved in settings, if it still exists.
    static var savedFolder: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: folderKey) else { return nil }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: folderKey)
            // Only files that arrive from now on are imported.
            UserDefaults.standard.set(Date(), forKey: sinceKey)
        }
    }

    /// Music Drop's own storage would import its copies again.
    static func isAllowed(_ folder: URL, storage: URL) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let own = storage.standardizedFileURL.resolvingSymlinksInPath().path
        return path != "/" && path != own && !path.hasPrefix(own + "/")
    }

    init(folder: URL, interval: TimeInterval = 3, defaults: UserDefaults = .standard, deliver: @escaping ([URL]) -> Void) {
        self.folder = folder
        self.interval = interval
        self.defaults = defaults
        self.deliver = deliver
    }

    /// Files older than the last look are known already; newer ones wait for the next look.
    func start() {
        queue.sync { prime() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.look() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { timer?.cancel() }

    /// One look at the folder, the same work the timer does; tests call it directly.
    func poll() {
        queue.sync { look() }
    }

    func prime() {
        let since = defaults.object(forKey: Self.sinceKey) as? Date ?? Date()
        known = []
        pending = [:]
        for (path, snapshot) in scan() {
            if snapshot.modified > since { pending[path] = snapshot } else { known.insert(path) }
        }
    }

    private func look() {
        let current = scan()
        known.formIntersection(current.keys)
        pending = pending.filter { current[$0.key] != nil }
        var ready: [URL] = []
        for (path, snapshot) in current where !known.contains(path) {
            if snapshot.size > 0, pending[path] == snapshot {
                known.insert(path)
                pending[path] = nil
                ready.append(URL(fileURLWithPath: path))
            } else {
                pending[path] = snapshot
            }
        }
        // A file still settling when the app quits must count as new on the next launch.
        let since = pending.values.map(\.modified).min().map { $0.addingTimeInterval(-1) } ?? Date()
        defaults.set(since, forKey: Self.sinceKey)
        guard !ready.isEmpty else { return }
        deliver(ready.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
    }

    /// Top-level MP3s only; hidden files and unfinished browser downloads are skipped.
    private func scan() -> [String: Snapshot] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [:] }
        var result: [String: Snapshot] = [:]
        for item in items where item.pathExtension.lowercased() == "mp3" {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            result[item.standardizedFileURL.path] = Snapshot(size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
        }
        return result
    }
}
