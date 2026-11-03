import AppKit
import UserNotifications

/// Tells the user what happened while Music Drop was in the background. Imports that finish
/// close together become one notification instead of a stack of them.
final class Notifier {
    static let enabledKey = "NotificationsEnabled"
    static let shared = Notifier()
    private var added: [String] = []
    private var playlists: Set<String> = []
    private var flushTimer: Timer?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    func imported(_ entry: ImportEntry) {
        guard enabled, !NSApp.isActive else { return }
        added.append(entry.title)
        if let playlist = entry.playlist { playlists.insert(playlist) }
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.flushAdded() }
    }

    func failed(_ entry: ImportEntry) {
        guard enabled, !NSApp.isActive else { return }
        post(title: "Не удалось добавить «\(entry.title)»", body: entry.error ?? "Открой Music Drop, чтобы повторить.")
    }

    func post(title: String, body: String) {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func flushAdded() {
        guard !added.isEmpty else { return }
        let destination = playlists.count == 1 ? "в плейлисте «\(playlists.first!)»" : "в медиатеке"
        if added.count == 1 {
            post(title: "«\(added[0])» \(destination)", body: "Трек добавлен в «Музыку» и отмечен в избранном.")
        } else {
            post(title: "Добавлено \(CollectionHeader.tracks(added.count))", body: "Треки \(destination): " + added.prefix(3).joined(separator: ", ")
                 + (added.count > 3 ? " и другие." : "."))
        }
        added = []
        playlists = []
    }
}
