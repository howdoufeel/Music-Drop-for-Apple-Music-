import AppKit
import SwiftUI

final class StatusDropTarget: NSView {
    var onClick: (() -> Void)?
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onLink: ((LinkRoute) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Music Drop — добавить MP3")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "mp3" }
    }
    /// A SoundCloud or YouTube link dragged from the browser.
    private func link(_ sender: NSDraggingInfo) -> LinkRoute? {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            .lazy.filter { !$0.isFileURL }.compactMap { LinkRoute.detect($0.absoluteString) }.first
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !urls(sender).isEmpty { onEnter?(); return .copy }
        return link(sender) == nil ? [] : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty && link(sender) == nil ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onExit?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !urls(sender).isEmpty || link(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        if !files.isEmpty { onDrop?(files); return true }
        guard let route = link(sender) else { return false }
        onLink?(route)
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { onExit?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var store: ImportStore!
    var soundCloud: SoundCloudStore!
    var youtube: YouTubeStore!
    var navigation: PanelNavigation!
    var previewWindow: NSWindow?
    var globalMonitor: Any?
    var localMonitor: Any?
    var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        let preview = CommandLine.arguments.contains("--preview")
        store = ImportStore(preview: preview)
        soundCloud = SoundCloudStore(preview: preview)
        youtube = YouTubeStore(preview: preview)
        navigation = PanelNavigation(soundCloud: soundCloud, youtube: youtube)
        youtube.onReady = { [weak self] file, track in self?.store.acceptYouTube(file, track: track) }
        youtube.onActivity = { [weak self] in self?.updateActivity() }
        youtube.shouldPrefetch = { [weak self] track in self?.store.entry(youTubeID: track.id) == nil }
        soundCloud.onReady = { [weak self] file, track in self?.store.acceptSoundCloud(file, track: track) }
        soundCloud.onActivity = { [weak self] in self?.updateActivity() }
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        updateIcon(busy: false)
        if let button = statusItem.button {
            button.toolTip = "Music Drop — перетащи MP3 или нажми для открытия"
            let target = StatusDropTarget(frame: button.bounds)
            target.autoresizingMask = [.width, .height]
            target.onClick = { [weak self] in self?.toggle() }
            target.onEnter = { [weak self] in
                self?.store.dragActive = true
                self?.show(activate: false)
            }
            target.onExit = { [weak self] in self?.store.dragActive = false }
            target.onDrop = { [weak self] urls in
                self?.store.dragActive = false
                self?.store.accept(urls)
                self?.show()
            }
            target.onLink = { [weak self] route in
                self?.show()
                self?.navigation.open(route)
            }
            button.addSubview(target)
        }
        store.onActivity = { [weak self] _ in self?.updateActivity() }
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 { self.popover.performClose(nil) }
            return event
        }
        if !pendingURLs.isEmpty { store.accept(pendingURLs); pendingURLs.removeAll() }
        showWindow()
        if !preview { UserDefaults.standard.set(true, forKey: "didShowWelcome") }
    }

    private func configureMainMenu() {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String, modifiers: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.target = target
            entry.tag = tag
            return entry
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            let submenu = NSMenu(title: title)
            for menuItem in items { submenu.addItem(menuItem) }
            holder.submenu = submenu
            menu.addItem(holder)
        }
        submenu("Music Drop", [
            item("Открыть Music Drop", #selector(showWindow), "0", target: self),
            item("Настройки…", #selector(showSettings), ",", target: self),
            .separator(),
            item("Завершить Music Drop", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        ])
        // Without these standard items macOS gives text fields no ⌘C/⌘V. Paste with no field
        // focused reaches the app delegate and opens the copied link or MP3.
        submenu("Правка", [
            item("Отменить", Selector(("undo:")), "z"),
            item("Повторить", Selector(("redo:")), "z", modifiers: [.command, .shift]),
            .separator(),
            item("Вырезать", #selector(NSText.cut(_:)), "x"),
            item("Копировать", #selector(NSText.copy(_:)), "c"),
            item("Вставить", #selector(NSText.paste(_:)), "v"),
            item("Выбрать всё", #selector(NSText.selectAll(_:)), "a")
        ])
        submenu("Раздел", [
            item("Медиатека", #selector(selectTab(_:)), "1", target: self, tag: PanelNavigation.Tab.library.rawValue),
            item("SoundCloud", #selector(selectTab(_:)), "2", target: self, tag: PanelNavigation.Tab.soundCloud.rawValue),
            item("YouTube", #selector(selectTab(_:)), "3", target: self, tag: PanelNavigation.Tab.youTube.rawValue),
            .separator(),
            item("Найти", #selector(focusSearch), "f", target: self)
        ])
        NSApp.mainMenu = menu
    }

    /// Keeps the popover if it is open; otherwise brings up the main window.
    private func reveal() {
        if !popover.isShown { showWindow() }
    }

    @objc func selectTab(_ sender: NSMenuItem) {
        reveal()
        navigation.tab = PanelNavigation.Tab(rawValue: sender.tag) ?? .library
    }

    @objc func focusSearch() {
        reveal()
        navigation.focusSearch()
    }

    @objc func showSettings() {
        reveal()
        navigation.tab = .library
        store.settingsVisible = true
    }

    /// Reached only when no text field takes the paste: a copied link opens in its tab, copied MP3s are imported.
    @objc func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "mp3" }
        if !files.isEmpty {
            reveal()
            navigation.tab = .library
            store.accept(files)
            return
        }
        let text = pasteboard.string(forType: .string)
            ?? (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first?.absoluteString
        guard let text, let route = LinkRoute.detect(text) else { NSSound.beep(); return }
        reveal()
        navigation.open(route)
    }

    func updateIcon(busy: Bool) {
        let image = NSImage(systemSymbolName: busy ? "arrow.down.circle" : "music.note",
                            accessibilityDescription: "Music Drop")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func updateActivity() {
        updateIcon(busy: store.activeCount > 0 || soundCloud.isDownloading || youtube.isDownloading)
    }

    func show(activate: Bool = true) {
        guard let button = statusItem.button else { return }
        if activate { NSApp.activate(ignoringOtherApps: true) }
        guard !popover.isShown else { return }
        // Built on demand, so a hidden popover never re-renders alongside the main window.
        if popover.contentViewController == nil {
            popover.contentSize = NSSize(width: 380, height: 540)
            popover.contentViewController = NSHostingController(rootView: DropPanel(store: store, soundCloud: soundCloud,
                                                                                   youtube: youtube, navigation: navigation))
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if activate { popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil) }
        store.refreshCloud()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else { NSApp.activate(ignoringOtherApps: true); show() }
    }

    @objc func showWindow() {
        if let window = previewWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 540),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Music Drop"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: DropPanel(store: store, soundCloud: soundCloud, youtube: youtube,
                                                               navigation: navigation).padding(.top, 24))
        window.setContentSize(NSSize(width: 380, height: 564))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = window
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if store == nil { pendingURLs.append(contentsOf: urls) }
        else { store.accept(urls); show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.activeCount > 0 || soundCloud.isDownloading || youtube.isDownloading else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Загрузка или импорт ещё идут"
        alert.informativeText = "Лучше дождаться завершения. При выходе результат текущего импорта может остаться неподтверждённым."
        alert.addButton(withTitle: "Продолжить импорт")
        alert.addButton(withTitle: "Всё равно выйти")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        soundCloud.cancelAll()
        youtube.cancelAll()
        store.flushHistory()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
