import AppKit
import ApplicationServices

enum CloudUpdateError: LocalizedError, Equatable {
    case accessibilityRequired, musicUnavailable, menuUnavailable, commandDisabled, actionFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            return "Трек в медиатеке. macOS не подтвердила «Универсальный доступ» для Music Drop Cloud. Разреши этот компонент в системных настройках — очередь продолжится автоматически."
        case .musicUnavailable:
            return "«Музыка» не запущена. Не удалось отправить запрос обновления облачной медиатеки."
        case .menuUnavailable:
            return "Не найден пункт «Обновить облачную медиатеку». Проверь, что синхронизация медиатеки включена в «Музыке», и повтори запрос."
        case .commandDisabled:
            return "«Музыка» сейчас занята обновлением медиатеки. Music Drop повторит запрос автоматически."
        case .actionFailed:
            return "«Музыка» не подтвердила нажатие «Обновить облачную медиатеку». Импорт сохранён; можно повторить только обновление облака."
        }
    }
}

/// Abstracts only menu access, allowing the actual request decision to be tested
/// without changing TCC permissions or touching the user's Music account.
protocol CloudMenuAccess {
    associatedtype Element
    var isTrusted: Bool { get }
    func menuBar() throws -> Element
    func children(of element: Element) -> [Element]
    func identifier(of element: Element) -> String?
    func title(of element: Element) -> String?
    func role(of element: Element) -> String?
    func isEnabled(_ element: Element) -> Bool
    func press(_ element: Element) -> Bool
}

enum CloudMenuRequest {
    static let commandID = "kUpdateCloudLibraryCommand"

    static func perform<Access: CloudMenuAccess>(using access: Access) throws {
        guard access.isTrusted else { throw CloudUpdateError.accessibilityRequired }
        let root = try access.menuBar()
        var budget = 300
        let deadline = Date().addingTimeInterval(8)
        // Prefer Apple's stable command identifier, independent of menu language.
        // The two verified titles cover older Music versions that omit the ID.
        func find(_ element: Access.Element, depth: Int, byID: Bool) -> Access.Element? {
            guard depth <= 8, budget > 0, Date() < deadline else { return nil }
            budget -= 1
            if access.role(of: element) == kAXMenuItemRole as String {
                if byID, access.identifier(of: element) == commandID { return element }
                if !byID, let title = access.title(of: element),
                   ["Update Cloud Library", "Обновить облачную медиатеку"].contains(title) { return element }
            }
            for child in access.children(of: element) {
                if let result = find(child, depth: depth + 1, byID: byID) { return result }
            }
            return nil
        }
        var target = find(root, depth: 0, byID: true)
        if target == nil {
            budget = 300
            target = find(root, depth: 0, byID: false)
        }
        guard let target else { throw CloudUpdateError.menuUnavailable }
        guard access.isEnabled(target) else { throw CloudUpdateError.commandDisabled }
        guard access.press(target) else { throw CloudUpdateError.actionFailed }
    }
}

struct MusicAXMenu: CloudMenuAccess {
    let application: AXUIElement
    var isTrusted: Bool { AXIsProcessTrusted() }

    init(pid: pid_t) {
        application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    func menuBar() throws -> AXUIElement {
        guard let value = attribute(kAXMenuBarAttribute, of: application),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { throw CloudUpdateError.menuUnavailable }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }
    func identifier(of element: AXUIElement) -> String? { attribute(kAXIdentifierAttribute, of: element) as? String }
    func title(of element: AXUIElement) -> String? { attribute(kAXTitleAttribute, of: element) as? String }
    func role(of element: AXUIElement) -> String? { attribute(kAXRoleAttribute, of: element) as? String }
    func isEnabled(_ element: AXUIElement) -> Bool { attribute(kAXEnabledAttribute, of: element) as? Bool ?? false }
    func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
}

