import Foundation
import Observation

/// Keeps yt-dlp current between Music Drop releases: YouTube changes often break an older
/// extractor. A newer official release is downloaded from GitHub, checked against the
/// SHA-256 list published with it, unpacked and run once before it replaces the bundled one.
final class ExtractorUpdater {
    enum Outcome: Equatable {
        case upToDate(String)
        case updated(String)
    }

    typealias Fetch = (URL, Int) throws -> Data
    static let shared = ExtractorUpdater()
    static let lastCheckKey = "ExtractorLastCheck"
    static let automaticKey = "ExtractorAutomaticUpdates"

    let root: URL
    let bundledVersion: String?
    private let fetch: Fetch
    private let defaults: UserDefaults
    private let now: () -> Date
    private let lock = NSLock()
    private var running = false

    init(root: URL? = nil, bundledVersion: String? = ExtractorUpdater.bundledVersion(), fetch: Fetch? = nil,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music Drop/Helpers/yt-dlp", isDirectory: true)
        self.bundledVersion = bundledVersion
        self.fetch = fetch ?? ExtractorUpdater.download
        self.defaults = defaults
        self.now = now
    }

    /// The version pinned in the installer's dependency manifest.
    static func bundledVersion(resources: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL) -> String? {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("Helpers/dependencies.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let binaries = root["binaries"] as? [[String: Any]] else { return nil }
        return binaries.first { $0["name"] as? String == "yt-dlp" }?["version"] as? String
    }

    /// yt-dlp tags its releases by date, optionally with a build number: 2026.10.26 or 2026.10.26.1.
    static func isVersion(_ value: String) -> Bool {
        value.range(of: #"^\d{4}\.\d{2}\.\d{2}(\.\d{1,4})?$"#, options: .regularExpression) != nil
    }

    static func isNewer(_ candidate: String, than current: String?) -> Bool {
        guard let current else { return true }
        let left = candidate.split(separator: ".").compactMap { Int($0) }
        let right = current.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0, b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    var installedVersion: String? {
        guard let text = try? String(contentsOf: root.appendingPathComponent("current"), encoding: .utf8) else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isVersion(version) ? version : nil
    }

    /// The downloaded extractor, used only while it is newer than the one in the app.
    var activeExtractor: URL? {
        guard let version = installedVersion, Self.isNewer(version, than: bundledVersion) else { return nil }
        let executable = root.appendingPathComponent(version).appendingPathComponent("yt-dlp_macos")
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    var activeVersion: String? { activeExtractor == nil ? bundledVersion : installedVersion }

    var automaticUpdates: Bool {
        get { defaults.object(forKey: Self.automaticKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.automaticKey) }
    }

    /// Checks at most once per `interval`; a failure of the extractor asks sooner.
    func checkIfDue(interval: TimeInterval = 86_400) {
        guard automaticUpdates else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard now().timeIntervalSince(last) >= interval else { return }
        DispatchQueue.global(qos: .utility).async { _ = try? self.update() }
    }

    /// Blocks while downloading; call it off the main thread.
    @discardableResult
    func update() throws -> Outcome {
        lock.lock()
        guard !running else { lock.unlock(); throw DropError.message("Обновление уже проверяется.") }
        running = true
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }
        defaults.set(now(), forKey: Self.lastCheckKey)

        let latest = try JSONSerialization.jsonObject(with: fetch(URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!, 1_000_000))
        guard let tag = (latest as? [String: Any])?["tag_name"] as? String, Self.isVersion(tag) else {
            throw DropError.message("GitHub не сообщил версию yt-dlp.")
        }
        let current = activeVersion
        guard Self.isNewer(tag, than: current) else { return .upToDate(current ?? tag) }

        let release = "https://github.com/yt-dlp/yt-dlp/releases/download/" + tag + "/"
        let sums = String(decoding: try fetch(URL(string: release + "SHA2-256SUMS")!, 200_000), as: UTF8.self)
        guard let expected = Self.checksum(of: "yt-dlp_macos.zip", in: sums) else {
            throw DropError.message("В релизе yt-dlp нет контрольной суммы для macOS.")
        }
        let archive = try fetch(URL(string: release + "yt-dlp_macos.zip")!, 300_000_000)
        guard FileTools.digest(archive) == expected else { throw DropError.message("Загруженный yt-dlp не совпал с контрольной суммой релиза.") }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let zip = staging.appendingPathComponent("release.zip")
        try archive.write(to: zip)
        let unpacked = staging.appendingPathComponent(tag, isDirectory: true)
        try Self.unpack(zip, to: unpacked)
        let executable = unpacked.appendingPathComponent("yt-dlp_macos")
        guard fm.isExecutableFile(atPath: executable.path) else { throw DropError.message("В архиве yt-dlp нет программы для macOS.") }
        // The new extractor must start and report the release it came from.
        let reported = try Self.output(executable, ["--version"], timeout: 120).trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported == tag else { throw DropError.message("Новый yt-dlp не запустился как ожидалось.") }

        let destination = root.appendingPathComponent(tag, isDirectory: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: unpacked, to: destination)
        try Data((tag + "\n").utf8).write(to: root.appendingPathComponent("current"), options: .atomic)
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where Self.isVersion(item.lastPathComponent) && item.lastPathComponent != tag {
            try? fm.removeItem(at: item)
        }
        return .updated(tag)
    }

    /// Goes back to the extractor shipped with the app.
    func revert() {
        try? FileManager.default.removeItem(at: root)
    }

    static func checksum(of name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name,
                  parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) else { continue }
            return parts[0].lowercased()
        }
        return nil
    }

    /// Lists the archive first: absolute paths and parent references are refused, and no links survive.
    static func unpack(_ zip: URL, to destination: URL) throws {
        let names = try output(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z1", zip.path], timeout: 60).split(whereSeparator: \.isNewline)
        guard !names.isEmpty, names.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
            throw DropError.message("Архив yt-dlp содержит недопустимые пути.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try output(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", "-o", zip.path, "-d", destination.path], timeout: 300)
        let enumerator = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let item = enumerator?.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw DropError.message("Архив yt-dlp содержит ссылки на другие файлы.")
            }
        }
    }

    private static func output(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // Read alongside the process so a long listing cannot fill the pipe and stall it.
        var data = Data()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            read.wait()
            throw DropError.message("yt-dlp долго не отвечает.")
        }
        read.wait()
        guard process.terminationStatus == 0 else { throw DropError.message("Не удалось подготовить новый yt-dlp.") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func download(_ url: URL, maximumBytes: Int) throws -> Data {
        let hosts = ["api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]
        return try BoundedFetch.with(allowed: { $0.scheme == "https" && hosts.contains($0.host?.lowercased() ?? "") }) { fetch in
            var request = URLRequest(url: url)
            request.setValue("MusicDrop", forHTTPHeaderField: "User-Agent")
            return try fetch.data(request, cancellation: SoundCloudCancellation(), maximumBytes: maximumBytes, timeout: 600) { _ in true }.0
        }
    }
}

/// What the settings show about the extractor and its updates.
@Observable final class ExtractorUpdateModel {
    private(set) var version: String?
    private(set) var checking = false
    private(set) var status: String?
    private(set) var usesDownloadedVersion = false
    private(set) var automatic: Bool
    @ObservationIgnored private let updater: ExtractorUpdater

    init(updater: ExtractorUpdater = .shared) {
        self.updater = updater
        automatic = updater.automaticUpdates
        refresh()
    }

    func setAutomatic(_ value: Bool) {
        automatic = value
        updater.automaticUpdates = value
    }

    func refresh() {
        version = updater.activeVersion
        usesDownloadedVersion = updater.activeExtractor != nil
    }

    func check() {
        guard !checking else { return }
        checking = true
        status = "Проверяем…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.updater.update() }
            DispatchQueue.main.async {
                self.checking = false
                switch result {
                case .success(.updated(let version)): self.status = "Установлена версия \(version)"
                case .success(.upToDate): self.status = "Установлена последняя версия"
                case .failure(let error): self.status = error.localizedDescription
                }
                self.refresh()
            }
        }
    }

    func revert() {
        updater.revert()
        status = "Используется версия из приложения"
        refresh()
    }
}
