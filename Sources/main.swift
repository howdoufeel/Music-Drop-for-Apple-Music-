import AppKit
import SwiftUI

final class StatusDropTarget: NSView {
    var onClick: (() -> Void)?
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
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
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        onEnter?()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onExit?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !urls(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        guard !files.isEmpty else { return false }
        onDrop?(files)
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
        youtube.onReady = { [weak self] file, track in self?.store.acceptYouTube(file, track: track) }
        youtube.onActivity = { [weak self] in self?.updateActivity() }
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
            button.addSubview(target)
        }
        store.onActivity = { [weak self] _ in self?.updateActivity() }
        popover.contentSize = NSSize(width: 380, height: 540)
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: DropPanel(store: store, soundCloud: soundCloud, youtube: youtube))
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
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Music Drop")
        let openWindow = NSMenuItem(title: "Открыть Music Drop", action: #selector(showWindow), keyEquivalent: "0")
        openWindow.target = self
        applicationMenu.addItem(openWindow)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Завершить Music Drop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApp.mainMenu = menu
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
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if activate { popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil) }
        store.refreshCloud()
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
        window.contentView = NSHostingView(rootView: DropPanel(store: store, soundCloud: soundCloud, youtube: youtube).padding(.top, 24))
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
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
