import AppKit
import ApplicationServices

enum NativeCloudUpdateBridge {
    static func requestUpdate() throws {
        guard AXIsProcessTrusted() else { throw CloudUpdateError.accessibilityRequired }
        try ensureMusicRunning()
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first else {
            throw CloudUpdateError.musicUnavailable
        }
        do {
            try CloudMenuRequest.perform(using: MusicAXMenu(pid: app.processIdentifier))
        } catch CloudUpdateError.menuUnavailable {
            // Some Music versions expose their menu only after activation.
            // No command has been pressed on this path, so a single retry is safe.
            DispatchQueue.main.sync { _ = app.activate(options: []) }
            try CloudMenuRequest.perform(using: MusicAXMenu(pid: app.processIdentifier))
        }
    }

    private static func ensureMusicRunning() throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else { throw CloudUpdateError.musicUnavailable }
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in failure = error; ready.signal() }
        }
        guard ready.wait(timeout: .now() + 20) == .success, failure == nil else { throw CloudUpdateError.musicUnavailable }
    }
}
