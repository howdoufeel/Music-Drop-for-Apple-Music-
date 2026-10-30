import Foundation

enum CloudBridgeCommand: String, Codable { case status, update, permission }
struct CloudBridgeRequest: Codable {
    let version: Int
    let id: UUID
    let command: CloudBridgeCommand
    static func decode(_ data: Data, expectedID: UUID) -> CloudBridgeRequest? {
        guard data.count < 4096, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1, value.id == expectedID else { return nil }
        return value
    }
}
struct CloudBridgeReply: Codable {
    let version: Int
    let id: UUID
    let trusted: Bool
    let error: String?
}
enum CloudBridgePaths {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music Drop/Cloud Bridge", isDirectory: true)
    }
    static var requests: URL { directory.appendingPathComponent("Requests", isDirectory: true) }
    static var helper: URL { directory.appendingPathComponent("Music Drop Cloud.app", isDirectory: true) }
    static func request(_ id: UUID) -> URL { requests.appendingPathComponent(id.uuidString + ".request.json") }
    static func reply(_ id: UUID) -> URL { requests.appendingPathComponent(id.uuidString + ".reply.json") }
}
