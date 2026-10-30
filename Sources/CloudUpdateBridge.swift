import Foundation

enum CloudUpdateBridge {
    static var isTrusted: Bool { CloudBridgeClient.shared.isTrusted }
    static func requestUpdate() throws {
        let reply = try CloudBridgeClient.shared.send(.update)
        switch reply.error {
        case nil: break
        case "permission": throw CloudUpdateError.accessibilityRequired
        case "music": throw CloudUpdateError.musicUnavailable
        case "menu": throw CloudUpdateError.menuUnavailable
        case "busy": throw CloudUpdateError.commandDisabled
        default: throw CloudUpdateError.actionFailed
        }
    }
    static func openPermissionSettings() {
        DispatchQueue.global(qos: .userInitiated).async { _ = try? CloudBridgeClient.shared.send(.permission) }
    }
}
