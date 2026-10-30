import AppKit
import Security

struct CloudHelperManifest: Codable {
    let version: Int
    let executableSHA256: String
}
final class CloudBridgeClient {
    static let shared = CloudBridgeClient()
    private let lock = NSLock()
    private let installLock = NSLock()
    private var trusted = false
    private var checkedAt = Date.distantPast
    private var checking = false
    private let resources: URL
    init(resources: URL? = nil) {
        self.resources = resources ?? Bundle.main.resourceURL ?? Bundle.main.bundleURL
    }
    /// UI callers read cached status; no helper launch blocks the main thread.
    var isTrusted: Bool {
        lock.lock()
        let value = trusted
        let needsCheck = !checking && Date().timeIntervalSince(checkedAt) > 5
        if needsCheck { checking = true }
        lock.unlock()
        if needsCheck {
            DispatchQueue.global(qos: .utility).async {
                _ = try? self.send(.status)
                self.lock.lock(); self.checking = false; self.lock.unlock()
            }
        }
        return value
    }
    func send(_ command: CloudBridgeCommand) throws -> CloudBridgeReply {
        precondition(!Thread.isMainThread, "Cloud helper requests must run off the main thread")
        let helper = try installHelper()
        let id = UUID()
        let requestURL = CloudBridgePaths.request(id)
        let replyURL = CloudBridgePaths.reply(id)
        let request = CloudBridgeRequest(version: 1, id: id, command: command)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: replyURL)
        }
        let launch = DispatchSemaphore(value: 0)
        var launchError: Error?
        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--request", id.uuidString]
            NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { _, error in
                launchError = error
                launch.signal()
            }
        }
        guard launch.wait(timeout: .now() + 15) == .success, launchError == nil else {
            throw DropError.message("Не удалось запустить Music Drop Cloud. Повтори обновление облака.")
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let data = try? Data(contentsOf: replyURL), data.count < 4096 {
                let reply = try Self.decodeReply(data, expectedID: id)
                lock.lock(); trusted = reply.trusted; checkedAt = Date(); lock.unlock()
                return reply
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw DropError.message("Music Drop Cloud не ответил вовремя. Импорт сохранён; очередь повторит запрос.")
    }
    static func decodeReply(_ data: Data, expectedID: UUID) throws -> CloudBridgeReply {
        let reply = try JSONDecoder().decode(CloudBridgeReply.self, from: data)
        guard reply.version == 1, reply.id == expectedID else {
            throw DropError.message("Некорректное подтверждение Music Drop Cloud.")
        }
        return reply
    }
    /// Keep the separate, identical component untouched when the main app changes.
    private func installHelper() throws -> URL {
        installLock.lock(); defer { installLock.unlock() }
        let manifest = try JSONDecoder().decode(CloudHelperManifest.self, from: Data(contentsOf: resources.appendingPathComponent("Cloud/helper-manifest.json")))
        guard manifest.version == 1 else { throw DropError.message("Неподдерживаемая версия Music Drop Cloud.") }
        let source = resources.appendingPathComponent("Cloud/Music Drop Cloud.app", isDirectory: true)
        let destination = CloudBridgePaths.helper
        try FileManager.default.createDirectory(at: CloudBridgePaths.requests, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: CloudBridgePaths.requests.path)
        return try Self.installHelper(source: source, destination: destination, digest: manifest.executableSHA256)
    }
    static func installHelper(source: URL, destination: URL, digest: String) throws -> URL {
        if Self.validHelper(destination, digest: digest) { return destination }
        guard Self.validHelper(source, digest: digest) else {
            throw DropError.message("Повреждён компонент Music Drop Cloud. Переустанови приложение из установщика.")
        }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        var previous: URL?
        if FileManager.default.fileExists(atPath: destination.path) {
            previous = directory.appendingPathComponent("Previous-" + UUID().uuidString + ".app")
            try FileManager.default.moveItem(at: destination, to: previous!)
        }
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch {
            if let previous, !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.moveItem(at: previous, to: destination)
            }
            throw error
        }
        return destination
    }
    static func validHelper(_ bundle: URL, digest: String) -> Bool {
        let executable = bundle.appendingPathComponent("Contents/MacOS/MusicDropCloud")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              (try? FileTools.digest(executable)) == digest else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
    }
}
