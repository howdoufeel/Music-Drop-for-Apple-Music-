import AppKit
import ApplicationServices

final class CloudHelperDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .userInitiated).async {
            defer { DispatchQueue.main.async { NSApp.terminate(nil) } }
            let arguments = CommandLine.arguments
            guard let flag = arguments.firstIndex(of: "--request"), arguments.indices.contains(flag + 1),
                  let id = UUID(uuidString: arguments[flag + 1]),
                  let data = try? Data(contentsOf: CloudBridgePaths.request(id)),
                  let request = CloudBridgeRequest.decode(data, expectedID: id) else { return }
            var problem: String?
            switch request.command {
            case .status: break
            case .permission:
                DispatchQueue.main.sync {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            case .update:
                do { try NativeCloudUpdateBridge.requestUpdate() }
                catch let error as CloudUpdateError {
                    switch error {
                    case .accessibilityRequired: problem = "permission"
                    case .musicUnavailable: problem = "music"
                    case .menuUnavailable: problem = "menu"
                    case .commandDisabled: problem = "busy"
                    case .actionFailed: problem = "action"
                    }
                } catch { problem = "action" }
            }
            let reply = CloudBridgeReply(version: 1, id: id, trusted: AXIsProcessTrusted(), error: problem)
            if let data = try? JSONEncoder().encode(reply) { try? data.write(to: CloudBridgePaths.reply(id), options: .atomic) }
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = CloudHelperDelegate()
app.delegate = delegate
app.run()
