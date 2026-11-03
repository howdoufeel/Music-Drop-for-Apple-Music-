import Foundation
import AppKit

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
    checks += 1
    print("PASS: \(message)")
}
func settle(_ store: ImportStore) {
    let limit = Date().addingTimeInterval(10)
    while store.activeCount > 0, Date() < limit {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    expect(store.activeCount == 0, "background queue completes")
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("musicdrop-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let source = root.appendingPathComponent("Трек \"один\".mp3")
try Data("abc".utf8).write(to: source)
expect(try! FileTools.digest(source) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "streaming SHA256 matches known vector")

var imports = 0
var injectedFailure: AutomationError?
var favoriteCalls = 0
var favoriteFailure: AutomationError?
var favoriteOnImport = true
var cloudRequests = 0
var cloudProblem: Error?
var reportedCloudStatus = "uploaded"
var services = ImportServices()
services.playable = { _ in true }
services.add = { url in
    imports += 1
    if let failure = injectedFailure { throw failure }
    expect(FileManager.default.fileExists(atPath: url.path), "Music receives a durable existing file")
    return MusicResult(id: "00000000000000A1", title: "Трек один", cloudStatus: reportedCloudStatus,
                       isFavorite: favoriteOnImport, favoriteError: favoriteOnImport ? nil : "Избранное не подтверждено")
}
services.favorite = { id in
    favoriteCalls += 1
    expect(!id.isEmpty, "favorite mutation uses persistent Music ID")
    if let favoriteFailure { throw favoriteFailure }
}
services.updateCloudLibrary = {
    cloudRequests += 1
    if let cloudProblem { throw cloudProblem }
}
let stateDirectory = root.appendingPathComponent("State")
let store = ImportStore(directory: stateDirectory, services: services, startTimer: false)
store.accept([source])
settle(store)
expect(imports == 1 && store.entries[0].stage == .imported, "import stores confirmed track receipt")
expect(store.entries[0].trackID == "00000000000000A1", "persistent Music ID retained")
expect(store.entries[0].cloudStatus == "uploaded", "cloud result retained separately")
expect(store.entries[0].isFavorite == true, "confirmed favorite is saved with imported track")
expect(cloudRequests == 1 && store.entries[0].cloudUpdateRequestedAt != nil,
       "successful import explicitly requests cloud update and stores request receipt")
expect(store.entries[0].cloudUpdateError == nil, "accepted cloud request has no request error")
let retained = URL(fileURLWithPath: store.entries[0].managedPath!)
try FileManager.default.removeItem(at: source)
expect(FileManager.default.fileExists(atPath: retained.path), "deleting source does not remove imported audio")
expect(retained.lastPathComponent == source.lastPathComponent, "original filename survives for untagged tracks")

let renamed = root.appendingPathComponent("renamed.MP3")
try Data("abc".utf8).write(to: renamed)
store.accept([renamed])
settle(store)
expect(imports == 1 && store.entries.count == 1, "same bytes under different filename do not reimport")
expect(store.notice?.contains("уже добавлен") == true, "duplicate provides a clear result")
expect(favoriteCalls == 1, "dropping an existing MP3 reasserts favorite without another import")

let second = root.appendingPathComponent("second.mp3")
try Data("different".utf8).write(to: second)
injectedFailure = AutomationError(code: -1743, detail: "denied")
store.accept([second])
settle(store)
let failed = store.entries.first { $0.stage == .failed }!
expect(failed.error?.contains("Автоматизация") == true, "automation denial explains recovery")
injectedFailure = nil
try FileManager.default.removeItem(at: second)
store.retry(failed)
settle(store)
expect(store.entries.first { $0.id == failed.id }?.stage == .imported, "retry uses preserved file after original is removed")

let third = root.appendingPathComponent("third.mp3")
try Data("uncertain".utf8).write(to: third)
injectedFailure = AutomationError(code: -1712, detail: "timeout")
store.accept([third])
settle(store)
expect(store.entries[0].stage == .needsReview, "timeout never claims failure or retries blindly")
let previousImports = imports
store.accept([third])
settle(store)
expect(imports == previousImports, "uncertain result blocks automatic duplicate import")

let restored = ImportStore(directory: stateDirectory, services: services, startTimer: false)
expect(restored.entries.count == store.entries.count, "history survives restart")
expect(restored.entries.contains { $0.stage == .needsReview }, "uncertain result survives restart")

let empty = root.appendingPathComponent("empty.mp3")
try Data().write(to: empty)
store.accept([empty])
settle(store)
expect(store.entries[0].stage == .failed && imports == previousImports, "empty MP3 rejected before contacting Music")

let corruptDirectory = root.appendingPathComponent("Corrupt")
try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
try Data("broken".utf8).write(to: corruptDirectory.appendingPathComponent("history.json"))
let corrupt = ImportStore(directory: corruptDirectory, services: services, startTimer: false)
expect(corrupt.entries.isEmpty && corrupt.notice != nil, "corrupt history is reported")
expect(try! FileManager.default.contentsOfDirectory(atPath: corruptDirectory.path).contains { $0.hasPrefix("history-unreadable-") }, "unreadable history is backed up")

// Compile the real automation command without executing an import.
let script = NSAppleScript(source: MusicBridge.importSource(path: "/tmp/Трек \"quote\" \\ slash.mp3"))!
var scriptError: NSDictionary?
expect(script.compileAndReturnError(&scriptError), "real import AppleScript compiles with quoted Unicode paths: \(String(describing: scriptError))")
let favoriteScript = NSAppleScript(source: MusicBridge.favoriteSource(id: "00000000000000A1"))!
expect(favoriteScript.compileAndReturnError(&scriptError), "favorite-only AppleScript compiles without executing")
expect(!CloudState.isReady("unknown") && CloudState.isReady("matched"), "cloud status does not claim unconfirmed upload")

// Exercise the production AVFoundation validator on a generated silent MP3.
// Only the final Music action is substituted, so no personal library is touched.
if CommandLine.arguments.count > 1 {
    var actualServices = ImportServices()
    var actualImports = 0
    actualServices.add = { url in
        actualImports += 1
        return MusicResult(id: "TEST-VALID", title: "Silence", cloudStatus: "unknown", isFavorite: true)
    }
    actualServices.updateCloudLibrary = {}
    let validationStore = ImportStore(directory: root.appendingPathComponent("AVValidation"), services: actualServices, startTimer: false)
    validationStore.accept([URL(fileURLWithPath: CommandLine.arguments[1])])
    settle(validationStore)
    expect(validationStore.entries[0].stage == .imported && actualImports == 1, "production AVFoundation validator accepts real MP3")
    let invalid = root.appendingPathComponent("not-audio.mp3")
    try Data("This is not an audio file".utf8).write(to: invalid)
    validationStore.accept([invalid])
    settle(validationStore)
    expect(validationStore.entries[0].stage == .failed && actualImports == 1, "production AVFoundation validator rejects fake MP3 before import")
}

injectedFailure = nil
favoriteOnImport = false
let partial = root.appendingPathComponent("partial-favorite.mp3")
try Data("favorite-partial".utf8).write(to: partial)
store.accept([partial])
settle(store)
let partialEntry = store.entries[0]
expect(partialEntry.stage == .imported && partialEntry.trackID != nil, "failed favorite retains successful import receipt")
expect(partialEntry.isFavorite == false && partialEntry.favoriteError != nil, "failed favorite is not displayed as success")
let importCountBeforeFavoriteRetry = imports
favoriteFailure = AutomationError(code: -1743, detail: "denied")
store.markFavorite(partialEntry)
settle(store)
expect(store.entries[0].stage == .imported && store.entries[0].favoriteError?.contains("Автоматизация") == true,
       "favorite permission denial preserves library success and explains recovery")
favoriteFailure = nil
let beforeFavoriteCalls = favoriteCalls
store.markFavorite(store.entries[0])
store.markFavorite(store.entries[0])
settle(store)
expect(favoriteCalls == beforeFavoriteCalls + 1, "concurrent favorite retries are coalesced")
expect(imports == importCountBeforeFavoriteRetry, "retrying favorite never imports another track")
expect(store.entries[0].isFavorite == true && store.entries[0].favoriteError == nil, "favorite retry confirms star and clears its error")
let favoriteRestored = ImportStore(directory: stateDirectory, services: services, startTimer: false)
expect(favoriteRestored.entries[0].isFavorite == true, "favorite result survives restart")

// Version 1.0 history has no favorite keys; preserve it without claiming a star.
let legacyDirectory = root.appendingPathComponent("Legacy")
try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode([store.entries[0]])) as! [[String: Any]]
legacyJSON[0].removeValue(forKey: "isFavorite")
legacyJSON[0].removeValue(forKey: "favoriteError")
try JSONSerialization.data(withJSONObject: legacyJSON).write(to: legacyDirectory.appendingPathComponent("history.json"))
let legacyStore = ImportStore(directory: legacyDirectory, services: services, startTimer: false)
expect(legacyStore.entries.count == 1 && legacyStore.entries[0].isFavorite == nil,
       "version 1.0 history migrates without data loss or invented favorite state")

// Failure to request cloud sync never turns a successful import into a failed one.
cloudProblem = CloudUpdateError.accessibilityRequired
reportedCloudStatus = "not uploaded"
favoriteOnImport = true
let cloudFailureFile = root.appendingPathComponent("cloud-permission.mp3")
try Data("needs-cloud-permission".utf8).write(to: cloudFailureFile)
store.accept([cloudFailureFile])
settle(store)
let cloudFailed = store.entries[0]
expect(cloudFailed.stage == .imported && cloudFailed.isFavorite == true,
       "cloud permission denial retains library and favorite success")
expect(cloudFailed.cloudUpdateRequestedAt == nil && store.needsCloudPermission,
       "permission denial is not recorded as a successful cloud request")
let beforeCloudRetryImports = imports
cloudProblem = nil
store.requestCloudUpdate(for: [cloudFailed.id])
settle(store)
expect(imports == beforeCloudRetryImports && store.entries[0].cloudUpdateError == nil,
       "cloud-only retry does not reimport or duplicate the track")
expect(store.entries[0].cloudUpdateRequestedAt != nil && !CloudState.isReady(store.entries[0].cloudStatus),
       "accepted cloud request is distinct from confirmed uploaded status")

let beforeBatchRequests = cloudRequests
let batch = try (0..<3).map { index -> URL in
    let url = root.appendingPathComponent("batch-\(index).mp3")
    try Data("batch-payload-\(index)".utf8).write(to: url)
    return url
}
store.accept(batch)
settle(store)
expect(cloudRequests == beforeBatchRequests + 1, "multiple queued imports coalesce into one cloud update")
expect(store.entries.prefix(3).allSatisfy { $0.cloudUpdateRequestedAt != nil },
       "every track in a batch receives its cloud request receipt")
expect(FileManager.default.fileExists(atPath: batch[0].path), "a user's own MP3 is copied, never moved")

// A slow menu request runs beside imports instead of in front of them.
do {
    let cloudGate = DispatchSemaphore(value: 0)
    let startedLock = NSLock()
    var slowCloudStarted = false
    var slowServices = services
    slowServices.updateCloudLibrary = {
        startedLock.lock(); slowCloudStarted = true; startedLock.unlock()
        _ = cloudGate.wait(timeout: .now() + 5)
    }
    let slowStore = ImportStore(directory: root.appendingPathComponent("SlowCloud"), services: slowServices, startTimer: false)
    let firstSlow = root.appendingPathComponent("slow-first.mp3"), secondSlow = root.appendingPathComponent("slow-second.mp3")
    try Data("slow-first".utf8).write(to: firstSlow); try Data("slow-second".utf8).write(to: secondSlow)
    slowStore.accept([firstSlow])
    let slowDeadline = Date().addingTimeInterval(3)
    func cloudStarted() -> Bool { startedLock.lock(); defer { startedLock.unlock() }; return slowCloudStarted }
    while !cloudStarted(), Date() < slowDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    slowStore.accept([secondSlow])
    while slowStore.entries.first?.stage != .imported, Date() < slowDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(slowStore.entries.count == 2 && slowStore.entries[0].stage == .imported && slowStore.cloudUpdateInProgress,
           "a slow cloud request does not hold back the next import")
    cloudGate.signal(); cloudGate.signal()
    settle(slowStore)
}

// Music Drop's own finished downloads move into the library folder and leave no staging behind.
do {
    let moveRoot = root.appendingPathComponent("MoveState")
    let staging = moveRoot.appendingPathComponent("Downloads/YouTube/\(UUID().uuidString)/Prepared", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let downloaded = staging.appendingPathComponent("Скачанный трек.m4a")
    try Data("downloaded-audio".utf8).write(to: downloaded)
    let moveStore = ImportStore(directory: moveRoot, services: services, startTimer: false)
    let movedTrack = YouTubeTrack(id: "MoveTrack01", title: "Скачанный трек", artist: "Artist")
    moveStore.acceptYouTube(downloaded, track: movedTrack)
    settle(moveStore)
    let managed = moveStore.entries[0].managedPath.map { URL(fileURLWithPath: $0) }
    expect(moveStore.entries[0].stage == .imported && managed.map { FileManager.default.fileExists(atPath: $0.path) } == true
           && (try? Data(contentsOf: managed!)) == Data("downloaded-audio".utf8),
           "a finished M4A download is imported from the library folder with its bytes intact")
    expect(!FileManager.default.fileExists(atPath: downloaded.path)
           && !FileManager.default.fileExists(atPath: staging.deletingLastPathComponent().path)
           && FileManager.default.fileExists(atPath: moveRoot.appendingPathComponent("Downloads/YouTube").path),
           "the download is moved rather than copied and its empty staging folder is removed")
    expect(moveStore.entry(youTubeID: movedTrack.id)?.id == moveStore.entries[0].id && moveStore.entry(soundCloudID: movedTrack.id) == nil,
           "source indexes find the imported entry without scanning the history")
}

// The real scheduler is driven by a clock and fake Music replies, without personal-library writes.
func settleCloud(_ store: ImportStore) {
    let limit = Date().addingTimeInterval(5)
    while (store.activeCount > 0 || store.refreshInProgress), Date() < limit {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    expect(store.activeCount == 0 && !store.refreshInProgress, "cloud scheduler finishes its current work without waiting on a retry timer")
}
var cloudNow = Date(timeIntervalSince1970: 1_800_000_000)
var cloudBusy = true
var cloudPermission = true
var cloudMusicRunning = true
var autoCloudCalls = 0
var autoImports = 0
var autoStatuses: [String: String] = [:]
var autoServices = ImportServices()
autoServices.playable = { _ in true }
autoServices.add = { _ in
    autoImports += 1
    let id = "AUTO-\(autoImports)"
    autoStatuses[id] = "unknown"
    return MusicResult(id: id, title: id, cloudStatus: "unknown", isFavorite: true)
}
autoServices.updateCloudLibrary = {
    autoCloudCalls += 1
    if !cloudPermission { throw CloudUpdateError.accessibilityRequired }
    if cloudBusy { throw CloudUpdateError.commandDisabled }
}
autoServices.cloudStatus = { autoStatuses[$0] ?? "missing" }
autoServices.cloudAccessGranted = { cloudPermission }
autoServices.musicIsRunning = { cloudMusicRunning }
let autoDirectory = root.appendingPathComponent("AutoCloud")
let autoStore = ImportStore(directory: autoDirectory, services: autoServices, startTimer: false, now: { cloudNow })
autoStore.accept(batch)
settleCloud(autoStore)
expect(autoCloudCalls == 1 && autoStore.cloudWaitingCount == 3,
       "busy Music preserves a whole imported batch in the automatic cloud queue")
expect(autoStore.entries.allSatisfy { $0.cloudRetryAt == cloudNow.addingTimeInterval(15) && $0.cloudUpdateRequestedAt == nil },
       "a busy command schedules a delayed retry without inventing a successful request")
expect(autoStore.entries.allSatisfy { $0.cloudRetryMessage?.contains("автоматически") == true },
       "waiting rows explain that the request will retry automatically")
cloudNow = cloudNow.addingTimeInterval(10)
autoStore.cloudSyncTick(); settleCloud(autoStore)
expect(autoCloudCalls == 1, "status checks do not press the menu before the retry is due")
cloudBusy = false
cloudNow = cloudNow.addingTimeInterval(6)
autoStore.cloudSyncTick(); settleCloud(autoStore)
expect(autoCloudCalls == 2 && autoImports == 3 && autoStore.entries.allSatisfy { $0.cloudUpdateError == nil && $0.cloudUpdateRequestedAt == cloudNow },
       "Music becoming available automatically retries once for the batch without importing again")
expect(autoStore.cloudWaitingCount == 3 && autoStore.entries.allSatisfy { $0.cloudRetryAt! > cloudNow },
       "accepted command remains monitored until actual cloud readiness is confirmed")

cloudBusy = true
let laterCloudFile = root.appendingPathComponent("later-cloud.mp3")
try Data("later-cloud-payload".utf8).write(to: laterCloudFile)
autoStore.accept([laterCloudFile]); settleCloud(autoStore)
expect(autoCloudCalls == 3 && autoStore.cloudWaitingCount == 4,
       "tracks added during another cloud update stay queued after the disabled command")
cloudNow = cloudNow.addingTimeInterval(16); cloudBusy = false
autoStore.cloudSyncTick(); settleCloud(autoStore)
expect(autoCloudCalls == 4 && autoImports == 4 && autoStore.entries.allSatisfy { $0.cloudUpdateRequestedAt == cloudNow },
       "a follow-up request covers both newly added and earlier waiting tracks")

autoStatuses["AUTO-1"] = "uploaded"; autoStatuses["AUTO-2"] = "matched"; autoStatuses["AUTO-4"] = "uploaded"
autoStore.cloudSyncTick(); settleCloud(autoStore)
expect(autoStore.cloudWaitingCount == 1 && autoStore.entries.filter { CloudState.isReady($0.cloudStatus) }.allSatisfy { $0.cloudRetryAt == nil && $0.cloudSyncPending == false },
       "uploaded and matched tracks leave the retry queue while the remaining upload stays monitored")
let readyReceipts = autoStore.entries.filter { CloudState.isReady($0.cloudStatus) }.map(\.cloudUpdateRequestedAt)
cloudNow = cloudNow.addingTimeInterval(301)
autoStore.cloudSyncTick(); settleCloud(autoStore)
expect(autoCloudCalls == 5 && readyReceipts == autoStore.entries.filter { CloudState.isReady($0.cloudStatus) }.map(\.cloudUpdateRequestedAt),
       "a successful but still unfinished upload gets a follow-up without rewriting completed receipts")
let acceptedReceipt = autoStore.entries.first { $0.trackID == "AUTO-3" }!.cloudUpdateRequestedAt
cloudNow = cloudNow.addingTimeInterval(301); cloudBusy = true
autoStore.cloudSyncTick(); settleCloud(autoStore)
expect(autoCloudCalls == 6 && autoStore.entries.first { $0.trackID == "AUTO-3" }!.cloudUpdateRequestedAt == acceptedReceipt,
       "a later busy response preserves the previous successful request receipt")
expect(CloudState.retryDelay(attempt: 100, commandAccepted: false) == 300 && CloudState.retryDelay(attempt: 100, commandAccepted: true) == 300,
       "retry backoff stays capped at five minutes for long cloud waits")

cloudPermission = false; cloudBusy = false
let permissionAutoFile = root.appendingPathComponent("permission-auto.mp3")
try Data("permission-auto-payload".utf8).write(to: permissionAutoFile)
autoStore.accept([permissionAutoFile]); settleCloud(autoStore)
cloudNow = cloudNow.addingTimeInterval(301)
autoStore.cloudSyncTick(); settleCloud(autoStore)
// Another track can receive one refusal; once marked permission-blocked it must stop.
let blockedAutoCalls = autoCloudCalls
cloudNow = cloudNow.addingTimeInterval(301)
autoStore.cloudSyncTick(); settleCloud(autoStore)
expect(autoCloudCalls == blockedAutoCalls && autoStore.entries.filter { $0.cloudSyncPending == true }.allSatisfy { $0.cloudPermissionBlocked == true },
       "missing Accessibility access pauses automatic menu attempts without prompting repeatedly")
cloudPermission = true
autoStore.cloudSyncTick(); settleCloud(autoStore)
expect(autoCloudCalls == blockedAutoCalls + 1 && autoImports == 5 && autoStore.entries.filter { $0.cloudSyncPending == true }.allSatisfy { $0.cloudPermissionBlocked == false },
       "granting permission resumes the waiting queue automatically without another import or button press")

let restoredAutoStore = ImportStore(directory: autoDirectory, services: autoServices, startTimer: false, now: { cloudNow })
expect(restoredAutoStore.cloudWaitingCount == 2 && restoredAutoStore.entries.filter { $0.cloudSyncPending == true }.allSatisfy { $0.cloudRetryAt != nil },
       "pending uploads and retry times survive a restart")
cloudMusicRunning = false; cloudNow = cloudNow.addingTimeInterval(301)
let beforeClosedMusicCalls = autoCloudCalls
restoredAutoStore.cloudSyncTick(); settleCloud(restoredAutoStore)
expect(autoCloudCalls == beforeClosedMusicCalls, "automatic retries pause while the user has quit Music")
cloudMusicRunning = true
restoredAutoStore.cloudSyncTick(); settleCloud(restoredAutoStore)
expect(autoCloudCalls == beforeClosedMusicCalls + 1 && autoImports == 5, "reopening Music resumes the persisted queue")
autoStatuses["AUTO-3"] = "missing"; autoStatuses["AUTO-5"] = "ineligible"
restoredAutoStore.cloudSyncTick(); settleCloud(restoredAutoStore)
expect(restoredAutoStore.cloudWaitingCount == 0, "missing and ineligible tracks stop automatic cloud requests")
let completedAutoCalls = autoCloudCalls
cloudNow = cloudNow.addingTimeInterval(301)
restoredAutoStore.cloudSyncTick(); settleCloud(restoredAutoStore)
expect(autoCloudCalls == completedAutoCalls, "a resolved queue does not keep refreshing the library")

let manyDirectory = root.appendingPathComponent("ManyCloud")
try FileManager.default.createDirectory(at: manyDirectory, withIntermediateDirectories: true)
let manyEntries = (0..<25).map { ImportEntry(sourcePath: "", title: "Pending \($0)", stage: .imported, trackID: "MANY-\($0)", cloudStatus: "unknown") }
try JSONEncoder().encode(manyEntries).write(to: manyDirectory.appendingPathComponent("history.json"))
var manyServices = autoServices
manyServices.cloudStatus = { _ in "uploaded" }
let manyStore = ImportStore(directory: manyDirectory, services: manyServices, startTimer: false, now: { cloudNow })
expect(manyStore.cloudWaitingCount == 25, "older unfinished entries migrate into the automatic cloud queue")
manyStore.cloudSyncTick(); settleCloud(manyStore)
manyStore.cloudSyncTick(); settleCloud(manyStore)
expect(manyStore.cloudWaitingCount == 0 && manyStore.entries.allSatisfy { CloudState.isReady($0.cloudStatus) },
       "rotating bounded status polls eventually cover batches larger than twenty tracks")

// Exercise the production timer itself, not just explicit calls to its tick function.
do {
    var timerNow = cloudNow
    var timerCalls = 0
    var timerServices = autoServices
    timerServices.add = { _ in MusicResult(id: "TIMER-1", title: "Timer", cloudStatus: "unknown", isFavorite: true) }
    timerServices.cloudStatus = { _ in "unknown" }
    timerServices.updateCloudLibrary = {
        timerCalls += 1
        if timerCalls == 1 { throw CloudUpdateError.commandDisabled }
    }
    let timedStore = ImportStore(directory: root.appendingPathComponent("TimerCloud"), services: timerServices,
                                 startTimer: true, now: { timerNow })
    timedStore.accept([batch[0]]); settleCloud(timedStore)
    expect(timerCalls == 1 && timedStore.cloudWaitingCount == 1, "production timer fixture begins with a busy command")
    timerNow = timerNow.addingTimeInterval(16)
    let timerDeadline = Date().addingTimeInterval(12)
    while timerCalls < 2 && Date() < timerDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    settleCloud(timedStore)
    expect(timerCalls == 2 && timedStore.entries[0].cloudUpdateRequestedAt == timerNow,
           "the actual ten-second timer retries a due cloud request with no user action")
}

// Exercise the real menu selection policy with a simulated Accessibility tree.
final class MenuNode {
    let id: String?
    let title: String
    let role: String
    var enabled: Bool
    var children: [MenuNode]
    init(_ title: String, id: String? = nil, role: String = "AXMenuItem", enabled: Bool = true, children: [MenuNode] = []) {
        self.title = title; self.id = id; self.role = role; self.enabled = enabled; self.children = children
    }
}
final class MenuFixture: CloudMenuAccess {
    var isTrusted = true
    var root: MenuNode
    var pressed: [MenuNode] = []
    var menuReads = 0
    var acceptsPress = true
    init(_ root: MenuNode) { self.root = root }
    func menuBar() throws -> MenuNode { menuReads += 1; return root }
    func children(of element: MenuNode) -> [MenuNode] { element.children }
    func identifier(of element: MenuNode) -> String? { element.id }
    func title(of element: MenuNode) -> String? { element.title }
    func role(of element: MenuNode) -> String? { element.role }
    func isEnabled(_ element: MenuNode) -> Bool { element.enabled }
    func press(_ element: MenuNode) -> Bool { pressed.append(element); return acceptsPress }
}
let target = MenuNode("別の言語", id: CloudMenuRequest.commandID)
let decoy = MenuNode("Update Genius", id: "kUpdateGeniusCommand")
let menu = MenuFixture(MenuNode("", role: "AXMenuBar", children: [MenuNode("File", children: [decoy, target])]))
try CloudMenuRequest.perform(using: menu)
expect(menu.pressed.count == 1 && menu.pressed[0] === target,
       "menu request selects only Apple's cloud command identifier regardless of language")
menu.pressed = []; menu.isTrusted = false; menu.menuReads = 0
do { try CloudMenuRequest.perform(using: menu); fatalError("expected permission error") }
catch { expect(menu.pressed.isEmpty && menu.menuReads == 0, "missing Accessibility permission never reads or presses Music menus") }
menu.isTrusted = true; target.enabled = false
do { try CloudMenuRequest.perform(using: menu); fatalError("expected disabled error") }
catch { expect(menu.pressed.isEmpty, "disabled cloud command is not pressed or claimed as successful") }
target.enabled = true; menu.acceptsPress = false
do { try CloudMenuRequest.perform(using: menu); fatalError("expected action error") }
catch { expect(menu.pressed.count == 1, "failed menu action is reported without repeated clicks") }
let fallback = MenuNode("Обновить облачную медиатеку")
let oldMenu = MenuFixture(MenuNode("", role: "AXMenuBar", children: [decoy, fallback]))
try CloudMenuRequest.perform(using: oldMenu)
expect(oldMenu.pressed.count == 1 && oldMenu.pressed[0] === fallback, "older Russian menus use the verified title fallback")

// The privacy identity belongs to a pinned component, independent of the main application's signature.
let bridgeID = UUID()
let bridgeRequest = CloudBridgeRequest(version:1,id:bridgeID,command:.update)
let bridgeData = try JSONEncoder().encode(bridgeRequest)
expect(CloudBridgeRequest.decode(bridgeData,expectedID:bridgeID)?.command == .update,
       "cloud helper accepts its fixed, versioned update command")
expect(CloudBridgeRequest.decode(bridgeData,expectedID:UUID()) == nil,
       "cloud helper rejects a request whose nonce does not match its filename")
let futureBridgeRequest = try JSONEncoder().encode(CloudBridgeRequest(version:2,id:bridgeID,command:.update))
expect(CloudBridgeRequest.decode(futureBridgeRequest,expectedID:bridgeID) == nil,
       "cloud helper rejects an unsupported protocol version")
let genericCommand = try JSONSerialization.data(withJSONObject:["version":1,"id":bridgeID.uuidString,"command":"executeShell","script":"ignored"])
expect(CloudBridgeRequest.decode(genericCommand,expectedID:bridgeID) == nil,
       "cloud helper cannot accept arbitrary scripts or generic computer-control commands")
expect(CloudBridgeRequest.decode(Data(repeating:0,count:4096),expectedID:bridgeID) == nil,
       "oversized helper requests are rejected")
let bridgeReplyData = try JSONEncoder().encode(CloudBridgeReply(version:1,id:bridgeID,trusted:true,error:nil))
let bridgeReply = try CloudBridgeClient.decodeReply(bridgeReplyData,expectedID:bridgeID)
expect(bridgeReply.trusted && bridgeReply.error == nil, "cloud reply confirms the component's own access state")
do { _ = try CloudBridgeClient.decodeReply(bridgeReplyData,expectedID:UUID()); fatalError("Wrong reply nonce accepted") }
catch { expect(true,"a stale reply cannot satisfy another cloud request") }

if CommandLine.arguments.count > 2 {
    let template = URL(fileURLWithPath:CommandLine.arguments[2])
    let digest = try FileTools.digest(template.appendingPathComponent("Contents/MacOS/MusicDropCloud"))
    let destination = root.appendingPathComponent("StableComponent/Music Drop Cloud.app")
    let firstInstall = try CloudBridgeClient.installHelper(source:template,destination:destination,digest:digest)
    expect(CloudBridgeClient.validHelper(firstInstall,digest:digest), "the installed component matches its pinned binary hash and strict signature")
    let executable = firstInstall.appendingPathComponent("Contents/MacOS/MusicDropCloud")
    let originalInode = try FileManager.default.attributesOfItem(atPath:executable.path)[.systemFileNumber] as! NSNumber
    let originalDate = try FileManager.default.attributesOfItem(atPath:executable.path)[.modificationDate] as! Date
    _ = try CloudBridgeClient.installHelper(source:root.appendingPathComponent("NewMainAppWithoutHelper"),destination:destination,digest:digest)
    let repeatedAttributes = try FileManager.default.attributesOfItem(atPath:executable.path)
    expect(repeatedAttributes[.systemFileNumber] as? NSNumber == originalInode && repeatedAttributes[.modificationDate] as? Date == originalDate,
           "a main-app update leaves the permission holder's bytes and filesystem identity untouched")
    expect(!CloudBridgeClient.validHelper(firstInstall,digest:String(repeating:"0",count:64)), "an unexpected executable identity is rejected")
    let altered = root.appendingPathComponent("AlteredComponent.app")
    try FileManager.default.copyItem(at:template,to:altered)
    let alteredInfo = altered.appendingPathComponent("Contents/Info.plist")
    var info = try PropertyListSerialization.propertyList(from:Data(contentsOf:alteredInfo),format:nil) as! [String:Any]
    info["CFBundleName"] = "Changed"
    try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:alteredInfo)
    expect(!CloudBridgeClient.validHelper(altered,digest:digest), "altering sealed helper metadata is rejected even when the executable hash matches")
    do {
        _ = try CloudBridgeClient.installHelper(source:altered,destination:root.appendingPathComponent("Rejected.app"),digest:digest)
        fatalError("Altered helper installed")
    } catch { expect(true,"installation refuses a component with an invalid signature") }
    let writer = try FileHandle(forWritingTo:executable);try writer.seekToEnd();try writer.write(contentsOf:Data([0]));try writer.close()
    _ = try CloudBridgeClient.installHelper(source:template,destination:destination,digest:digest)
    expect(CloudBridgeClient.validHelper(destination,digest:digest), "a damaged installed component is repaired from the verified pinned copy")
    let backups = try FileManager.default.contentsOfDirectory(at:destination.deletingLastPathComponent(),includingPropertiesForKeys:nil)
    expect(backups.contains { $0.lastPathComponent.hasPrefix("Previous-") }, "component repair preserves the earlier file for recovery")
}

let permissionMigrationDirectory = root.appendingPathComponent("PermissionMigration")
try FileManager.default.createDirectory(at:permissionMigrationDirectory,withIntermediateDirectories:true)
let stalePermissionEntry = ImportEntry(sourcePath:"",title:"Waiting",stage:.imported,trackID:"UNCHANGED-ID",cloudStatus:"unknown",isFavorite:true,
                                       cloudUpdateError:"Универсальный доступ для Music Drop",cloudSyncPending:true,cloudPermissionBlocked:true)
try JSONEncoder().encode([stalePermissionEntry]).write(to:permissionMigrationDirectory.appendingPathComponent("history.json"))
let permissionMigrationStore = ImportStore(directory:permissionMigrationDirectory,services:services,startTimer:false)
expect(permissionMigrationStore.entries[0].cloudUpdateError?.contains("Music Drop Cloud") == true && permissionMigrationStore.entries[0].trackID == "UNCHANGED-ID" && permissionMigrationStore.entries[0].isFavorite == true,
       "old permission messages migrate to the stable component without reimporting or losing the favorite flag")
for terminalStatus in ["uploaded","removed","missing"] {
    let terminalDirectory = root.appendingPathComponent("OldPermission-"+terminalStatus)
    try FileManager.default.createDirectory(at:terminalDirectory,withIntermediateDirectories:true)
    var terminalEntry = stalePermissionEntry
    terminalEntry.cloudStatus = terminalStatus
    terminalEntry.cloudSyncPending = false
    try JSONEncoder().encode([terminalEntry]).write(to:terminalDirectory.appendingPathComponent("history.json"))
    let terminalStore = ImportStore(directory:terminalDirectory,services:services,startTimer:false)
    expect(terminalStore.entries[0].cloudUpdateError == nil && !terminalStore.needsCloudPermission,
           "obsolete permission warnings are removed for a track with cloud status \(terminalStatus)")
}

// SoundCloud parsing and input handling require no account or network.
expect(try! SoundCloudService.searchTarget("  тёмный принц  ") == "scsearch15:тёмный принц", "SoundCloud search preserves Unicode as a single query")
expect(try! SoundCloudService.searchTarget("https://on.soundcloud.com/WmpY5rIlwBvwNEFUZm").hasPrefix("https://on.soundcloud.com/"),
       "SoundCloud short track links are accepted")
for rejected in ["https://soundcloud.com.evil.test/artist/song", "file:///tmp/music.mp3", "https://soundcloud.com/artist/sets/album", "query\0invalid"] {
    do { _ = try SoundCloudService.searchTarget(rejected); fatalError("Unexpected accepted input") }
    catch { expect(true, "unsupported or malformed SoundCloud input is rejected") }
}
let scFixture: [String: Any] = ["entries": [
    ["id":"101", "title":"Песня\0 первая", "uploader":"Автор", "webpage_url":"https://soundcloud.com/artist/song", "duration":122],
    NSNull(),
    ["id":"101", "title":"Duplicate", "webpage_url":"https://soundcloud.com/artist/song"],
    ["id":"102", "title":"External", "webpage_url":"https://example.com/audio"],
    ["id":103, "title":"Вторая", "artists":["Исполнитель"], "webpage_url":"https://soundcloud.com/artist/second"]
]]
let parsedSC = try SoundCloudService.parseTracks(JSONSerialization.data(withJSONObject: scFixture))
expect(parsedSC.count == 2, "SoundCloud parser ignores nulls, duplicates and external track URLs")
expect(!parsedSC[0].title.contains("\0") && parsedSC[0].artist == "Автор" && parsedSC[0].durationLabel == "2:02",
       "SoundCloud metadata is sanitized and duration is formatted")
expect(parsedSC[1].id == "103" && parsedSC[1].artist == "Исполнитель", "numeric SoundCloud IDs and artist arrays are supported")

// Native search must fetch a listing once, without invoking the helper or probing artwork.
let nativeTrack: [String: Any] = ["id":1920315524, "kind":"track", "title":"Трек", "duration":111171,
    "permalink_url":"https://soundcloud.com/artist/song", "artwork_url":"https://i1.sndcdn.com/art-large.jpg",
    "publisher_metadata":["artist":"Исполнитель"], "user":["username":"Автор"]]
let nativeListing = try JSONSerialization.data(withJSONObject: ["collection":[nativeTrack]])
var nativeRequests: [URLRequest] = []
let nativeCache = root.appendingPathComponent("NativeSearch")
let nativeClient = SoundCloudSearchClient(cache: nativeCache, clientID: String(repeating: "a", count: 32)) { request, _ in
    nativeRequests.append(request)
    return (nativeListing, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}
var searchNow = Date()
let nativeService = SoundCloudService(helper: root.appendingPathComponent("missing-helper"), cache: nativeCache,
                                     searchClient: nativeClient, now: { searchNow })
let nativeResults = try nativeService.search("тёмный принц & song", cancellation: SoundCloudCancellation())
expect(nativeRequests.count == 1 && nativeRequests[0].url?.path == "/search/tracks",
       "native search needs one listing request and works without the audio helper")
let nativeQuery = URLComponents(url: nativeRequests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
expect(nativeQuery.first { $0.name == "q" }?.value == "тёмный принц & song" && nativeQuery.first { $0.name == "limit" }?.value == "15",
       "native query encodes Unicode and separators while preserving 15 results")
expect(nativeResults[0].durationLabel == "1:51" && nativeResults[0].artist == "Исполнитель" && nativeResults[0].artwork != nil,
       "native metadata preserves artist, milliseconds and artwork without extra requests")
_ = try nativeService.search("  тёмный принц & song  ", cancellation: SoundCloudCancellation())
expect(nativeRequests.count == 1, "repeated trimmed query is served from the five-minute cache")
searchNow = searchNow.addingTimeInterval(301)
_ = try nativeService.search("тёмный принц & song", cancellation: SoundCloudCancellation())
expect(nativeRequests.count == 2, "expired listing cache refreshes over the network")
let cancelledSearch = SoundCloudCancellation(); cancelledSearch.cancel()
do { _ = try nativeService.search("тёмный принц & song", cancellation: cancelledSearch); fatalError("Cancelled search returned") }
catch { expect(nativeRequests.count == 2, "cancelled search never returns cached results or starts a request") }

var linkRequests: [URLRequest] = []
let linkClient = SoundCloudSearchClient(cache: nativeCache, clientID: String(repeating: "a", count: 32)) { request, _ in
    linkRequests.append(request)
    let isHead = request.httpMethod == "HEAD"
    return (isHead ? Data() : try JSONSerialization.data(withJSONObject: nativeTrack),
            HTTPURLResponse(url: isHead ? URL(string:"https://soundcloud.com/artist/song")! : request.url!,
                            statusCode: 200, httpVersion: nil, headerFields: nil)!)
}
let linkResults = try linkClient.search("https://on.soundcloud.com/short", cancellation: SoundCloudCancellation())
expect(linkRequests.count == 2 && linkRequests[0].httpMethod == "HEAD" && linkRequests[1].url?.path == "/resolve" && linkResults.count == 1,
       "short links resolve through a redirect and a single metadata request without audio extraction")

var refreshRequests: [URLRequest] = []
let renewedID = String(repeating: "b", count: 32)
let refreshClient = SoundCloudSearchClient(cache: root.appendingPathComponent("RenewedSearch"), clientID: String(repeating: "a", count: 32)) { request, _ in
    refreshRequests.append(request)
    let url = request.url!
    let data: Data
    let code: Int
    if url.path == "/search/tracks" {
        code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_id" }?.value == renewedID ? 200 : 401
        data = nativeListing
    } else if url.host == "soundcloud.com" {
        code = 200; data = Data("<script src=\"https://a-v2.sndcdn.com/assets/app.js\"></script>".utf8)
    } else { code = 200; data = Data("client_id:\"\(renewedID)\"".utf8) }
    return (data, HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
}
let refreshedResults = try refreshClient.search("scsearch15:query", cancellation: SoundCloudCancellation())
expect(refreshedResults.count == 1 && refreshRequests.count == 4,
       "an expired public website ID refreshes from SoundCloud assets and retries once")
expect(refreshRequests[2].value(forHTTPHeaderField: "Range") == "bytes=0-65535",
       "initial setup reads the small configuration prefix instead of a multi-megabyte website asset")
expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("RenewedSearch/public-client.json").path),
       "renewed website identifier persists for fast subsequent launches")

let probeLock = NSLock()
var probeActive = 0, probePeak = 0
let probeClient = SoundCloudSearchClient(cache: root.appendingPathComponent("ProbeSearch"), clientID: String(repeating: "a", count: 32)) { request, _ in
    let url = request.url!
    if url.path == "/search/tracks" {
        let renewed = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_id" }?.value == renewedID
        return (nativeListing, HTTPURLResponse(url: url, statusCode: renewed ? 200 : 401, httpVersion: nil, headerFields: nil)!)
    }
    if url.host == "soundcloud.com" {
        let page = (0..<6).map { "<script src=\"https://a-v2.sndcdn.com/assets/\($0).js\"></script>" }.joined()
        return (Data(page.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    probeLock.lock(); probeActive += 1; probePeak = max(probePeak, probeActive); probeLock.unlock()
    Thread.sleep(forTimeInterval: 0.2)
    probeLock.lock(); probeActive -= 1; probeLock.unlock()
    let body = url.lastPathComponent == "1.js" ? "client_id:\"\(renewedID)\"" : "var unrelated = 1"
    return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: nil)!)
}
let probeStarted = Date()
expect((try! probeClient.search("scsearch15:query", cancellation: SoundCloudCancellation())).count == 1 && probePeak > 1
       && Date().timeIntervalSince(probeStarted) < 1, "a rotated website identifier is found by probing several scripts at once")

var limitedRequests = 0
let limitedClient = SoundCloudSearchClient(cache: nativeCache, clientID: String(repeating: "a", count: 32)) { request, _ in
    limitedRequests += 1
    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
}
do { _ = try limitedClient.search("scsearch15:query", cancellation: SoundCloudCancellation()); fatalError("Rate limit ignored") }
catch { expect(limitedRequests == 1 && error.localizedDescription.contains("частоту"), "rate limits report immediately without retry storms") }

// Fast audio resolution avoids launching the standalone Python extractor.
func transcoding(_ preset: String, quality: String = "sq", transport: String = "hls", snipped: Bool = false) -> [String: Any] {
    ["preset":preset, "quality":quality, "snipped":snipped,
     "url":"https://api-v2.soundcloud.com/media/\(preset)/stream",
     "format":["protocol":transport,"mime_type":preset.hasPrefix("aac") ? "audio/mp4; codecs=\"mp4a.40.2\"" : "audio/mpeg"]]
}
var audioMetadata = nativeTrack
audioMetadata["policy"] = "ALLOW"
audioMetadata["downloadable"] = false
audioMetadata["track_authorization"] = "public-stream-token"
audioMetadata["media"] = ["transcodings":[transcoding("aac_96k", quality:"lq"), transcoding("aac_160k")]]
expect(SoundCloudSearchClient.nativeCandidate(audioMetadata)?.url.path.contains("aac_160k") == true,
       "direct audio picks the full 160 kbps stream over the low-quality variant")
var specialMetadata = audioMetadata
specialMetadata["media"] = ["transcodings":[transcoding("aac_160k"),transcoding("aac_256k", quality:"hq")]]
expect(SoundCloudSearchClient.nativeCandidate(specialMetadata)?.url.path.contains("aac_256k") == true,
       "a public high-quality variant stays preferred")
specialMetadata["downloadable"] = true; specialMetadata["has_downloads_left"] = true
expect(SoundCloudSearchClient.nativeCandidate(specialMetadata) == nil, "original downloads keep the legacy best-format path")
specialMetadata = audioMetadata; specialMetadata["policy"] = "BLOCK"
expect(SoundCloudSearchClient.nativeCandidate(specialMetadata) == nil, "blocked tracks never enter the direct audio path")
specialMetadata = audioMetadata; specialMetadata["media"] = ["transcodings":[transcoding("aac_160k",snipped:true)]]
expect(SoundCloudSearchClient.nativeCandidate(specialMetadata) == nil, "preview-only metadata is not treated as a full direct download")
specialMetadata["media"] = ["transcodings":[transcoding("aac_256k",transport:"ctr-hls")]]
expect(SoundCloudSearchClient.nativeCandidate(specialMetadata) == nil, "protected transport is not selected by the direct downloader")
specialMetadata["media"] = ["transcodings":[transcoding("opus_160k"),transcoding("aac_160k")]]
expect(SoundCloudSearchClient.nativeCandidate(specialMetadata) == nil, "other codecs retain the existing format-selection fallback")
for badMediaURL in ["file:///tmp/secret", "http://cf-media.sndcdn.com/audio", "https://sndcdn.com.evil.test/audio", "https://user:password@cf-media.sndcdn.com/audio"] {
    expect(!SoundCloudSearchClient.isMediaURL(URL(string:badMediaURL)!), "direct audio rejects local, insecure or unrelated destinations")
}
let mediaURL = URL(string:"https://playback.media-streaming.soundcloud.cloud/test/playlist.m3u8")!
var audioRequests: [URLRequest] = []
let audioClient = SoundCloudSearchClient(cache: nativeCache, clientID: String(repeating:"a",count:32)) { request, _ in
    audioRequests.append(request)
    let body = request.url!.path.hasPrefix("/tracks/") ? audioMetadata : ["url":mediaURL.absoluteString]
    return (try JSONSerialization.data(withJSONObject:body), HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
}
let resolvedAudio = try audioClient.audioStream(for:nativeResults[0],cancellation:SoundCloudCancellation())
expect(audioRequests.count == 2 && resolvedAudio?.url == mediaURL && resolvedAudio?.fileExtension == "m4a",
       "direct audio needs only track metadata and the selected stream endpoint")
let audioQuery = URLComponents(url:audioRequests[1].url!,resolvingAgainstBaseURL:false)!.queryItems!
expect(audioQuery.first { $0.name == "track_authorization" }?.value == "public-stream-token",
       "direct audio forwards the track authorization provided by SoundCloud")
let hintedListing = try JSONSerialization.data(withJSONObject: ["collection": [audioMetadata]])
let hintedTrack = try SoundCloudSearchClient.parse(hintedListing)[0]
expect(hintedTrack.stream?.isHLS == true && hintedTrack.stream?.authorization == "public-stream-token" && hintedTrack.stream?.fileExtension == "m4a",
       "search results keep their stream list and authorization")
audioRequests = []
let hintedAudio = try audioClient.audioStream(for: hintedTrack, cancellation: SoundCloudCancellation())
expect(audioRequests.count == 1 && hintedAudio?.url == mediaURL && !audioRequests[0].url!.path.hasPrefix("/tracks/"),
       "Add skips the metadata request when the search result already lists the stream")
var staleRequests: [URLRequest] = []
let staleClient = SoundCloudSearchClient(cache: nativeCache, clientID: String(repeating:"a",count:32)) { request, _ in
    staleRequests.append(request)
    let url = request.url!
    if url.path.hasPrefix("/tracks/") {
        return (try JSONSerialization.data(withJSONObject: audioMetadata), HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
    let fresh = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.value == "public-stream-token" } == true && staleRequests.count > 1
    return (try JSONSerialization.data(withJSONObject: ["url": mediaURL.absoluteString]),
            HTTPURLResponse(url:url,statusCode:fresh ? 200 : 401,httpVersion:nil,headerFields:nil)!)
}
let staleAudio = try staleClient.audioStream(for: hintedTrack, cancellation: SoundCloudCancellation())
expect(staleAudio?.url == mediaURL && staleRequests.count == 3 && staleRequests[1].url!.path.hasPrefix("/tracks/"),
       "an expired search authorization falls back to fresh track metadata")

// Listening: any playable stream will do, including SoundCloud's 30-second clip.
var clipMetadata = audioMetadata
clipMetadata["media"] = ["transcodings":[transcoding("aac_160k", snipped:true), transcoding("mp3_1_0", transport:"progressive", snipped:true)]]
expect(SoundCloudSearchClient.nativeCandidate(clipMetadata) == nil && SoundCloudSearchClient.previewCandidate(clipMetadata)?.isClip == true
       && SoundCloudSearchClient.previewCandidate(clipMetadata)?.source.url.path.contains("aac_160k") == true,
       "a preview-only track can still be heard as a clip, preferring AAC")
var mixedPreview = audioMetadata
mixedPreview["media"] = ["transcodings":[transcoding("aac_160k", snipped:true), transcoding("mp3_1_0", transport:"progressive")]]
expect(SoundCloudSearchClient.previewCandidate(mixedPreview)?.isClip == false && SoundCloudSearchClient.previewCandidate(mixedPreview)?.source.isHLS == false,
       "the full track is preferred over a clip even in another format")
var originalPreview = audioMetadata
originalPreview["downloadable"] = true; originalPreview["has_downloads_left"] = true
expect(SoundCloudSearchClient.previewCandidate(originalPreview) != nil, "tracks with an original download can still be heard")
var protectedPreview = audioMetadata
protectedPreview["media"] = ["transcodings":[transcoding("aac_256k", transport:"ctr-hls"), transcoding("opus_64k")]]
expect(SoundCloudSearchClient.previewCandidate(protectedPreview) == nil, "encrypted and Opus-only streams are not offered for listening")
audioRequests = []
let hintedPreview = try audioClient.previewStream(for: hintedTrack, cancellation: SoundCloudCancellation())
expect(hintedPreview == SoundCloudPreview(url: mediaURL, isClip: false) && audioRequests.count == 1,
       "listening to a search result needs one request for the signed stream")
audioRequests = []
let metadataPreview = try audioClient.previewStream(for: nativeResults[0], cancellation: SoundCloudCancellation())
expect(metadataPreview?.url == mediaURL && audioRequests.count == 2 && audioRequests[0].url!.path.hasPrefix("/tracks/"),
       "without a stream list the preview asks for track metadata first")
let beforeAudioRateLimit = limitedRequests
do { _ = try limitedClient.audioStream(for:nativeResults[0],cancellation:SoundCloudCancellation()); fatalError("Audio rate limit ignored") }
catch SoundCloudError.rateLimited {
    expect(limitedRequests == beforeAudioRateLimit + 1, "audio rate limits stop immediately without resolving more stream variants")
}
let nativeArguments = SoundCloudService.nativeDownloadArguments(stream:resolvedAudio!,track:nativeResults[0],output:root.appendingPathComponent("prepared.m4a"))
expect(nativeArguments.contains("copy") && !nativeArguments.contains("aac") && nativeArguments.contains("https,tls,tcp"),
       "the direct transfer preserves encoded audio and limits FFmpeg to HTTPS transport")
expect(resolvedAudio?.isHLS == true, "HLS transcodings are marked for the parallel segment downloader")

// Native HLS: a plain VOD playlist is fetched several segments at a time and joined in order.
let hlsBase = URL(string:"https://playback.media-streaming.soundcloud.cloud/track/aac_160k/playlist.m3u8")!
let hlsText = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-KEY:METHOD=NONE\n" + (0..<12).map { "#EXTINF:10.0,\nsegment-\($0).m4s" }.joined(separator:"\n") + "\n#EXT-X-ENDLIST\n"
let hlsPlaylist = try SoundCloudSearchClient.parsePlaylist(hlsText, base: hlsBase)
expect(hlsPlaylist.initSegment?.lastPathComponent == "init.mp4" && hlsPlaylist.segments.count == 12 && hlsPlaylist.segments[3].path.hasSuffix("/segment-3.m4s"),
       "an HLS media playlist resolves its init and relative segment URLs")
for rejected in ["#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\nsegment.ts\n#EXT-X-ENDLIST",
                 "#EXTM3U\n#EXT-X-BYTERANGE:100@0\nsegment.ts\n#EXT-X-ENDLIST",
                 "#EXTM3U\nsegment.ts",
                 "#EXTM3U\nhttps://example.com/segment.ts\n#EXT-X-ENDLIST",
                 "not a playlist"] {
    do { _ = try SoundCloudSearchClient.parsePlaylist(rejected, base: hlsBase); fatalError("Unsupported playlist accepted") }
    catch { expect(true, "encrypted, ranged, live, foreign or malformed playlists stay with FFmpeg") }
}
let masterPlaylist = try SoundCloudSearchClient.parsePlaylist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=96000\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=160000\nhigh.m3u8\n", base: hlsBase)
expect(masterPlaylist.segments.isEmpty && masterPlaylist.variants.map(\.bandwidth) == [96000, 160000], "a master playlist exposes its variants")
let hlsLock = NSLock()
var hlsActive = 0, hlsPeak = 0, hlsFailedOnce = false
let hlsClient = SoundCloudSearchClient(cache: nativeCache, clientID: String(repeating:"a",count:32)) { request, _ in
    let url = request.url!
    if url.lastPathComponent == "playlist.m3u8" {
        return (Data(hlsText.utf8), HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
    hlsLock.lock(); hlsActive += 1; hlsPeak = max(hlsPeak, hlsActive)
    let retry = url.lastPathComponent == "segment-5.m4s" && !hlsFailedOnce
    if retry { hlsFailedOnce = true }
    hlsLock.unlock()
    Thread.sleep(forTimeInterval: Double.random(in: 0.01...0.05))
    hlsLock.lock(); hlsActive -= 1; hlsLock.unlock()
    if retry { throw SoundCloudError.message("dropped") }
    return (Data((url.lastPathComponent + ";").utf8), HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
}
let joinedHLS = root.appendingPathComponent("joined.hls")
var hlsProgress: [Int] = []
try hlsClient.downloadHLS(hlsBase, to: joinedHLS, cancellation: SoundCloudCancellation()) { done, _ in hlsLock.lock(); hlsProgress.append(done); hlsLock.unlock() }
let expectedHLS = (["init.mp4"] + (0..<12).map { "segment-\($0).m4s" }).map { $0 + ";" }.joined()
expect(String(data: try! Data(contentsOf: joinedHLS), encoding: .utf8) == expectedHLS, "segments are joined in playlist order even when they finish out of order")
expect(hlsPeak > 1 && hlsPeak <= 6, "several HLS segments download at the same time, within the concurrency limit")
expect(hlsFailedOnce && hlsProgress.count == 13, "a dropped segment is retried once and progress covers every part")
let cancelledHLS = SoundCloudCancellation(); cancelledHLS.cancel()
do { try hlsClient.downloadHLS(hlsBase, to: root.appendingPathComponent("cancelled.hls"), cancellation: cancelledHLS) { _, _ in }; fatalError("Cancelled HLS finished") }
catch { expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.hls").path), "a cancelled HLS download leaves no partial file") }
do {
    try ParallelDownload.run(count: 4, concurrency: 2, destination: root.appendingPathComponent("oversized.parts"), maximumBytes: 10,
                             cancellation: SoundCloudCancellation()) { _ in Data(repeating: 1, count: 6) }
    fatalError("Oversized parallel download accepted")
} catch { expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("oversized.parts").path), "the parallel downloader enforces the size limit across parts") }

// The service joins native HLS locally and only rewraps it; no remote input reaches FFmpeg.
let remuxLog = root.appendingPathComponent("remux-arguments")
let remuxScript = root.appendingPathComponent("remux-encoder")
try "#!/bin/sh\n/usr/bin/printf '%s\\n' \"$@\" >> '\(remuxLog.path)'\nwhile [ $# -gt 0 ]; do\n if [ \"$1\" = -i ]; then input=\"$2\"; fi\n output=\"$1\"; shift\ndone\ncase \"$input\" in https:*) exit 1;; esac\n/bin/cp \"$input\" \"$output\"\n".write(to: remuxScript, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remuxScript.path)
var hlsMetadata = audioMetadata
hlsMetadata["media"] = ["transcodings":[transcoding("aac_160k")]]
let hlsServiceClient = SoundCloudSearchClient(cache: nativeCache, clientID: String(repeating:"a",count:32)) { request, cancellation in
    let url = request.url!
    if url.path.hasPrefix("/tracks/") {
        return (try JSONSerialization.data(withJSONObject: hlsMetadata), HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
    if url.host == "api-v2.soundcloud.com" {
        return (try JSONSerialization.data(withJSONObject: ["url": hlsBase.absoluteString]), HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
    if url.lastPathComponent == "playlist.m3u8" {
        return (Data(hlsText.utf8), HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
    return (Data((url.lastPathComponent + ";").utf8), HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
}
let hlsService = SoundCloudService(helper: root.appendingPathComponent("no-helper"), ffmpeg: remuxScript, cache: nativeCache, searchClient: hlsServiceClient)
var hlsFractions: [Double] = []
let hlsFile = try hlsService.download(nativeResults[0], directory: root.appendingPathComponent("HLSAudio"), cancellation: SoundCloudCancellation(),
                                      stage: { _ in }, progress: { value in hlsLock.lock(); hlsFractions.append(value); hlsLock.unlock() })
let remuxArguments = try String(contentsOf: remuxLog, encoding: .utf8)
expect(String(data: try! Data(contentsOf: hlsFile), encoding: .utf8) == expectedHLS && hlsFile.pathExtension == "m4a",
       "a SoundCloud HLS track arrives as one M4A built from its parallel segments")
expect(remuxArguments.contains("file") && !remuxArguments.contains("https,tls,tcp") && remuxArguments.contains("copy"),
       "FFmpeg only rewraps the local joined file without network access or re-encoding")
expect(hlsFractions.last == 1 && zip(hlsFractions, hlsFractions.dropFirst()).allSatisfy { $0 < $1 }, "native HLS reports steadily rising download progress")
expect((try! FileManager.default.contentsOfDirectory(atPath: hlsFile.deletingLastPathComponent().deletingLastPathComponent().path)) == ["Prepared"],
       "the joined segment file is removed once the M4A is ready")

if CommandLine.arguments.count > 1 {
    let fixtureAudio = URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("silence.m4a")
    func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'" }
    func executableScript(_ name: String, _ text: String) throws -> URL {
        let path = root.appendingPathComponent(name)
        try text.write(to:path,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:path.path)
        return path
    }
    let copyEncoder = try executableScript("copy-encoder", "#!/bin/sh\nfor argument do output=\"$argument\"; done\n/bin/cp \(shellQuote(fixtureAudio.path)) \"$output\"\n")
    let directService = SoundCloudService(helper:root.appendingPathComponent("no-helper"),ffmpeg:copyEncoder,cache:nativeCache,searchClient:audioClient)
    let directFile = try directService.download(nativeResults[0],directory:root.appendingPathComponent("DirectAudio"),cancellation:SoundCloudCancellation(),stage:{ _ in })
    expect(FileManager.default.fileExists(atPath:directFile.path) && directFile.pathExtension == "m4a",
           "the direct route completes without an installed legacy helper")
    let fallbackMarker = root.appendingPathComponent("fallback-used")
    let fallbackHelper = try executableScript("fallback-helper", "#!/bin/sh\nfor argument do\n if [ \"$next\" = yes ]; then pattern=\"$argument\"; next=no; fi\n if [ \"$argument\" = -o ]; then next=yes; fi\ndone\noutput=\"${pattern%.*}.m4a\"\n/bin/cp \(shellQuote(fixtureAudio.path)) \"$output\"\n/usr/bin/touch \(shellQuote(fallbackMarker.path))\n/usr/bin/printf '%s\\n' \"$output\"\n")
    let failRemoteEncoder = try executableScript("fallback-encoder", "#!/bin/sh\nfor argument do\n case \"$argument\" in https:*) exit 1;; esac\n output=\"$argument\"\ndone\n/bin/cp \(shellQuote(fixtureAudio.path)) \"$output\"\n")
    let fallbackService = SoundCloudService(helper:fallbackHelper,ffmpeg:failRemoteEncoder,cache:nativeCache,searchClient:audioClient)
    let fallbackFile = try fallbackService.download(nativeResults[0],directory:root.appendingPathComponent("FallbackAudio"),cancellation:SoundCloudCancellation(),stage:{ _ in })
    expect(FileManager.default.fileExists(atPath:fallbackMarker.path) && FileManager.default.fileExists(atPath:fallbackFile.path),
           "a failed direct transfer falls back to the existing helper and local preparation")
    let rateService = SoundCloudService(helper:fallbackHelper,ffmpeg:copyEncoder,cache:nativeCache,searchClient:limitedClient)
    do { _ = try rateService.download(nativeResults[0],directory:root.appendingPathComponent("RateAudio"),cancellation:SoundCloudCancellation(),stage:{ _ in }); fatalError("Rate limit started fallback") }
    catch SoundCloudError.rateLimited { expect(true, "the service does not launch the fallback after a SoundCloud rate limit") }
    let cancelledAudio = SoundCloudCancellation(); cancelledAudio.cancel()
    let beforeCancelledAudioRequests = audioRequests.count
    let cancelledDirectory = root.appendingPathComponent("CancelledAudio")
    do { _ = try directService.download(nativeResults[0],directory:cancelledDirectory,cancellation:cancelledAudio,stage:{ _ in }); fatalError("Cancelled download returned") }
    catch {
        let cancelledFiles = try FileManager.default.contentsOfDirectory(atPath:cancelledDirectory.path)
        expect(audioRequests.count == beforeCancelledAudioRequests && cancelledFiles.isEmpty,
               "cancelled direct downloads make no requests and clean their staging folder")
    }
    let runningMarker = root.appendingPathComponent("running-encoder")
    let blockingEncoder = try executableScript("blocking-encoder", "#!/bin/sh\n/usr/bin/printf '%s' \"$$\" > \(shellQuote(runningMarker.path))\nexec /bin/sleep 30\n")
    let blockingService = SoundCloudService(helper:root.appendingPathComponent("no-helper"),ffmpeg:blockingEncoder,cache:nativeCache,searchClient:audioClient)
    let runningCancellation = SoundCloudCancellation()
    let cancellationFinished = DispatchSemaphore(value:0)
    var cancelledWhileRunning = false
    DispatchQueue.global().async {
        do { _ = try blockingService.download(nativeResults[0],directory:root.appendingPathComponent("RunningAudio"),cancellation:runningCancellation,stage:{ _ in }) }
        catch SoundCloudError.cancelled { cancelledWhileRunning = true }
        catch { }
        cancellationFinished.signal()
    }
    let runningDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath:runningMarker.path) && Date() < runningDeadline { Thread.sleep(forTimeInterval:0.02) }
    expect(FileManager.default.fileExists(atPath:runningMarker.path), "the direct transfer process has started before cancellation is tested")
    runningCancellation.cancel()
    expect(cancellationFinished.wait(timeout:.now()+3) == .success && cancelledWhileRunning,
           "cancelling an active direct transfer stops its process without launching the slow fallback")
}

func waitUI(_ predicate: () -> Bool) {
    let limit = Date().addingTimeInterval(4)
    while !predicate(), Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(predicate(), "SoundCloud background operation completes")
}
final class SoundCloudFixture: SoundCloudProviding {
    private var downloadCount = 0
    var downloads: Int { searches.lock(); defer { searches.unlock() }; return downloadCount }
    let searches = NSLock()
    let oldSearchFinished = DispatchSemaphore(value: 0)
    var searchCalls = 0
    func search(_ input: String, cancellation: SoundCloudCancellation) throws -> [SoundCloudTrack] {
        searches.lock(); searchCalls += 1; searches.unlock()
        if input == "old" { Thread.sleep(forTimeInterval: 0.5); oldSearchFinished.signal() }
        return [SoundCloudTrack(id: input, title: input, artist: "Artist", url: URL(string:"https://soundcloud.com/artist/\(input)")!)]
    }
    func download(_ track: SoundCloudTrack, directory: URL, cancellation: SoundCloudCancellation,
                  stage: @escaping (String) -> Void) throws -> URL {
        searches.lock(); downloadCount += 1; searches.unlock()
        stage("Скачиваем…")
        for _ in 0..<10 {
            if cancellation.isCancelled { throw SoundCloudError.cancelled }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return directory.appendingPathComponent(track.id + ".m4a")
    }
}
let scProvider = SoundCloudFixture()
let scModel = SoundCloudStore(service: scProvider, directory: root.appendingPathComponent("SoundCloudDownloads"))
scModel.query = "old"; scModel.search()
Thread.sleep(forTimeInterval: 0.02)
let newSearchStarted = Date()
scModel.query = "new"; scModel.search()
scModel.search()
waitUI { !scModel.isSearching }
expect(Date().timeIntervalSince(newSearchStarted) < 0.3, "a new search does not wait for the cancelled slow request")
scProvider.searches.lock(); let searchCallCount = scProvider.searchCalls; scProvider.searches.unlock()
expect(searchCallCount == 2, "repeated search presses coalesce while the same query is active")
expect(scProvider.oldSearchFinished.wait(timeout: .now() + 2) == .success, "cancelled slow fixture eventually returns")
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
expect(scModel.results.first?.id == "new" && scProvider.downloads == 0,
       "a stale SoundCloud search never replaces the newest results or starts a download")
var preparedTracks: [String] = []
scModel.onReady = { _, track in preparedTracks.append(track.id) }
let scTrack = scModel.results[0]
scModel.add(scTrack); scModel.add(scTrack)
waitUI { !scModel.isDownloading }
expect(scProvider.downloads == 1 && preparedTracks == [scTrack.id], "repeated Add clicks create one download and one import handoff")
let queuedTrack = SoundCloudTrack(id: "queued", title: "Queued", artist: "Artist", url: URL(string:"https://soundcloud.com/artist/queued")!)
scModel.add(scTrack); scModel.add(queuedTrack); scModel.cancel(queuedTrack)
expect(scModel.downloadStates[queuedTrack.id] == nil, "cancelling a queued SoundCloud track clears its progress immediately")
waitUI { !scModel.isDownloading }
expect(!preparedTracks.contains(queuedTrack.id), "cancelled SoundCloud downloads never reach Apple Music")

final class ParallelDownloadFixture: SoundCloudProviding {
    let lock = NSLock()
    let release = DispatchSemaphore(value:0)
    var active = 0
    var maximum = 0
    var started: Set<String> = []
    func snapshot() -> (Int, Set<String>) { lock.lock(); defer { lock.unlock() }; return (maximum,started) }
    func search(_ input: String,cancellation:SoundCloudCancellation) throws -> [SoundCloudTrack] { [] }
    func download(_ track: SoundCloudTrack,directory:URL,cancellation:SoundCloudCancellation,stage:@escaping(String)->Void) throws -> URL {
        lock.lock(); active += 1; maximum = max(maximum,active); started.insert(track.id); lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        while release.wait(timeout:.now()+0.02) == .timedOut {
            if cancellation.isCancelled { throw SoundCloudError.cancelled }
        }
        return directory.appendingPathComponent(track.id+".m4a")
    }
}
final class PreviewFixture: SoundCloudProviding {
    let lock = NSLock()
    var calls: [String] = []
    func search(_ input: String, cancellation: SoundCloudCancellation) throws -> [SoundCloudTrack] {
        [SoundCloudTrack(id: input, title: input, artist: "Artist", url: URL(string: "https://soundcloud.com/artist/\(input)")!)]
    }
    func download(_ track: SoundCloudTrack, directory: URL, cancellation: SoundCloudCancellation, stage: @escaping (String) -> Void) throws -> URL {
        directory.appendingPathComponent(track.id + ".m4a")
    }
    func previewStream(for track: SoundCloudTrack, cancellation: SoundCloudCancellation) throws -> SoundCloudPreview? {
        lock.lock(); calls.append(track.id); lock.unlock()
        if track.id == "slow" { Thread.sleep(forTimeInterval: 0.3) }
        if track.id == "broken" { throw SoundCloudError.message("Нет связи") }
        if track.id == "silent" { return nil }
        return SoundCloudPreview(url: URL(string: "https://playback.media-streaming.soundcloud.cloud/\(track.id)/playlist.m3u8")!, isClip: track.id == "clip")
    }
}
let previewProvider = PreviewFixture()
let previewModel = SoundCloudStore(service: previewProvider, directory: root.appendingPathComponent("PreviewModel"))
var played: [URL?] = []
previewModel.onPreview = { played.append($0) }
func previewTrack(_ id: String) -> SoundCloudTrack {
    SoundCloudTrack(id: id, title: id, artist: "Artist", url: URL(string: "https://soundcloud.com/artist/\(id)")!)
}
previewModel.startPreview(previewTrack("first"))
expect(previewModel.previewID == "first" && previewModel.previewLoading, "starting a preview marks the track as loading at once")
waitUI { !previewModel.previewLoading }
expect(played == [URL(string: "https://playback.media-streaming.soundcloud.cloud/first/playlist.m3u8")!] && previewModel.previewID == "first",
       "the resolved stream is handed to the player")
previewModel.startPreview(previewTrack("slow"))
previewModel.startPreview(previewTrack("clip"))
waitUI { !previewModel.previewLoading }
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
expect(played[1] == nil && !played.contains { $0?.path.contains("/slow/") == true } && played.last??.path.contains("/clip/") == true
       && previewModel.previewID == "clip" && previewModel.previewIsClip,
       "switching tracks stops the previous one and a slower earlier answer never starts playing")
previewModel.previewEnded(failed: false)
expect(previewModel.previewID == nil && played.last == .some(nil) && previewModel.previewErrors.isEmpty, "a finished stream clears the preview without an error")
for (id, expected) in [("broken", "Нет связи"), ("silent", "SoundCloud не даёт прослушать этот трек.")] {
    previewModel.startPreview(previewTrack(id))
    waitUI { !previewModel.previewLoading }
    expect(previewModel.previewID == nil && previewModel.previewErrors[id] == expected, "a track that cannot be heard explains why")
}
previewModel.startPreview(previewTrack("first"))
waitUI { !previewModel.previewLoading }
previewModel.previewEnded(failed: true)
expect(previewModel.previewErrors["first"] != nil && previewModel.previewID == nil, "a stream the player cannot open is reported on its row")
previewModel.query = "listed"; previewModel.search()
waitUI { !previewModel.isSearching }
previewModel.startPreview(previewModel.results[0])
waitUI { !previewModel.previewLoading }
let callsBeforeSearch = played.count
previewModel.query = "listed"; previewModel.search()
waitUI { !previewModel.isSearching }
expect(previewModel.previewID == "listed" && played.count == callsBeforeSearch, "a new search keeps playing a track that is still in the results")
previewModel.query = "other"; previewModel.search()
waitUI { !previewModel.isSearching }
expect(previewModel.previewID == nil && played.last == .some(nil), "listening stops when its track leaves the results")

let parallelProvider = ParallelDownloadFixture()
let parallelStore = SoundCloudStore(service:parallelProvider,directory:root.appendingPathComponent("ParallelAudio"))
let parallelTracks = (0..<3).map { SoundCloudTrack(id:"parallel-\($0)",title:"Parallel \($0)",artist:"Artist",url:URL(string:"https://soundcloud.com/artist/track-\($0)")!) }
for track in parallelTracks { parallelStore.add(track) }
waitUI { parallelProvider.snapshot().1.count == 2 }
expect(parallelProvider.snapshot().0 == 2, "two downloads can run together while a third remains queued")
parallelStore.cancel(parallelTracks[2])
parallelProvider.release.signal(); parallelProvider.release.signal()
waitUI { !parallelStore.isDownloading }
expect(parallelProvider.snapshot().1.count == 2, "cancelling the third queued download prevents it from reaching the provider")

if CommandLine.arguments.count > 1 {
    let m4a = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("silence.m4a")
    var scImports = 0
    var scServices = services
    scServices.playable = ImportServices().playable
    scServices.add = { _ in
        scImports += 1
        return MusicResult(id: "SC-101", title: "Песня", cloudStatus: "not uploaded", isFavorite: true)
    }
    let scImportStore = ImportStore(directory: root.appendingPathComponent("SCImport"), services: scServices, startTimer: false)
    scImportStore.acceptSoundCloud(m4a, track: parsedSC[0])
    settle(scImportStore)
    expect(scImports == 1 && scImportStore.entries[0].stage == .imported && scImportStore.entries[0].soundCloudID == "101",
           "SoundCloud M4A enters the existing favorite and explicit-cloud-update import pipeline")
    scImportStore.acceptSoundCloud(m4a, track: parsedSC[0])
    settle(scImportStore)
    expect(scImports == 1, "the same SoundCloud track ID never creates another import")
    let scRestored = ImportStore(directory: root.appendingPathComponent("SCImport"), services: scServices, startTimer: false)
    expect(scRestored.entries[0].soundCloudURL == parsedSC[0].url && scRestored.entries[0].soundCloudID == "101",
           "SoundCloud origin and duplicate protection survive restart")
}
let ytID = "BaW_jenozKc"
for link in ["https://youtu.be/\(ytID)?si=abc", "https://www.youtube.com/watch?v=\(ytID)&list=PLtest&index=2", "https://music.youtube.com/watch?v=\(ytID)", "https://m.youtube.com/shorts/\(ytID)", "https://youtube.com/live/\(ytID)", "https://youtube.com/embed/\(ytID)"] {
    expect(try! YouTubeService.videoID(link) == ytID, "YouTube link normalizes to one video, discarding playlist and tracking parameters")
}
for link in ["file:///tmp/audio.mp3", "https://youtube.com.evil.test/watch?v=\(ytID)", "https://youtube.com@evil.test/watch?v=\(ytID)", "https://youtube.com/playlist?list=PL123", "https://youtube.com/@channel", "--exec touch /tmp/no", "https://youtu.be/abc", "https://youtube.com:8443/watch?v=\(ytID)", "https://youtu.be/abcdefghij%00"] {
    do { _ = try YouTubeService.videoID(link); fatalError("Invalid YouTube link accepted") }
    catch { expect(true, "invalid, non-video and external URLs cannot reach the YouTube downloader") }
}
let ytJSON = Data(#"{"id":"BaW_jenozKc","title":"Трек / один","artist":"Автор","duration":10.5,"live_status":"not_live"}"#.utf8)
let ytTrack = try YouTubeService.parseTrack(ytJSON, expectedID: ytID)
expect(ytTrack.artist == "Автор" && ytTrack.durationLabel == "0:10", "YouTube metadata preserves title, artist and duration")
for invalid in [#"{"id":"wrong","title":"Wrong"}"#, #"{"id":"BaW_jenozKc","title":"Live","is_live":true}"#, #"{"id":"BaW_jenozKc","title":"Soon","live_status":"is_upcoming"}"#] {
    do { _ = try YouTubeService.parseTrack(Data(invalid.utf8), expectedID: ytID); fatalError("Invalid metadata accepted") }
    catch { expect(true, "wrong-video metadata and unfinished live broadcasts are rejected") }
}
expect(YouTubeService.errorMessage("Sign in to confirm you're not a bot").contains("анонимную"), "YouTube authentication errors explain the restriction")
expect(YouTubeService.errorMessage("Video unavailable: private").contains("закрыто"), "private videos return an actionable error")
let ytArgs = YouTubeService.encodeArguments(source: URL(fileURLWithPath:"/tmp/in.webm"), output:URL(fileURLWithPath:"/tmp/out.mp3"), track:ytTrack)
expect(ytArgs.contains("libmp3lame") && ytArgs.contains("title=" + ytTrack.title) && ytArgs.contains("artist=" + ytTrack.artist), "MP3 mode encodes with LAME and writes track metadata")

expect(YouTubeService.ranges(total: 4096) == [0...4095], "a small YouTube stream is fetched in one range")
let middleRanges = YouTubeService.ranges(total: 5_000_000)
expect(middleRanges.count == 4 && middleRanges.first?.lowerBound == 0 && middleRanges.last?.upperBound == 4_999_999
       && zip(middleRanges, middleRanges.dropFirst()).allSatisfy { $0.upperBound + 1 == $1.lowerBound },
       "a typical track splits into four contiguous ranges fetched in parallel")
expect(YouTubeService.ranges(total: 100_000_000).allSatisfy { $0.count <= 10_485_760 }, "no range exceeds YouTube's 10 MB chunk size")

final class GoogleVideoFixture: URLProtocol {
    static var payload = Data()
    static let lock = NSLock()
    static var ranges: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".googlevideo.com") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let header = request.value(forHTTPHeaderField: "Range") ?? ""
        Self.lock.lock(); Self.ranges.append(header); Self.lock.unlock()
        let bounds = header.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
        let slice = bounds.count == 2 ? Self.payload.subdata(in: bounds[0]..<min(Self.payload.count, bounds[1] + 1)) : Self.payload
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "audio/mp4"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: slice)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

if CommandLine.arguments.count > 1 {
    func quoteYT(_ value: String) -> String { "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'" }
    func scriptYT(_ name:String, _ text:String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to:url,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:url.path)
        return url
    }
    let fixtureYT = URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("silence.m4a")
    let argsLog = root.appendingPathComponent("yt-arguments")
    let helperYT = try scriptYT("youtube-fixture", "#!/bin/sh\n/usr/bin/printf '%s\\n' \"$@\" >> \(quoteYT(argsLog.path))\nfor arg do\n if [ \"$arg\" = --dump-single-json ]; then /usr/bin/printf '%s\\n' \(quoteYT(String(data:ytJSON,encoding:.utf8)!)); exit 0; fi\n if [ \"$next\" = yes ]; then pattern=\"$arg\"; next=no; fi\n if [ \"$arg\" = -o ]; then next=yes; fi\ndone\noutput=\"${pattern%.*}.m4a\"\n/bin/cp \(quoteYT(fixtureYT.path)) \"$output\"\n/usr/bin/printf '%s\\n' \"$output\"\n")
    let ffmpegYT = URL(fileURLWithPath:"/opt/homebrew/bin/ffmpeg")
    let ytService = YouTubeService(helper:helperYT,ffmpeg:ffmpegYT,runtime:URL(fileURLWithPath:"/usr/bin/true"),cache:root.appendingPathComponent("YTCache"),fallback:nil,format:{ .mp3 })
    expect(try! ytService.resolve("https://youtu.be/"+ytID,cancellation:SoundCloudCancellation()) == ytTrack, "YouTube metadata is resolved through the validated canonical URL")
    let ytDirectory = root.appendingPathComponent("YTDownload")
    let ytFile = try ytService.download(ytTrack,directory:ytDirectory,cancellation:SoundCloudCancellation(),stage:{ _ in })
    expect(ytFile.pathExtension == "mp3" && !ytFile.lastPathComponent.contains("/"), "YouTube download produces a safely named MP3")
    expect(try! ImportServices().playable(ytFile), "the actual encoded MP3 is playable by AVFoundation")
    let loggedYT = try String(contentsOf:argsLog,encoding:.utf8)
    expect(loggedYT.contains("--no-playlist") && loggedYT.contains("--ignore-config") && loggedYT.contains("--no-plugin-dirs") && loggedYT.contains("--js-runtimes"), "YouTube helper disables external config and plugins and uses the explicit bundled runtime")
    let loggedLines = loggedYT.split(separator:"\n")
    expect(loggedLines.filter { $0 == "--dump-single-json" }.count == 1 && loggedLines.filter { $0 == "--load-info-json" }.count == 1,
           "the link check and the download share one extractor run")
    let m4aService = YouTubeService(helper:helperYT,ffmpeg:ffmpegYT,runtime:URL(fileURLWithPath:"/usr/bin/true"),cache:root.appendingPathComponent("YTCacheM4A"),fallback:nil,format:{ .m4a })
    let m4aFile = try m4aService.download(ytTrack,directory:root.appendingPathComponent("YTDownloadM4A"),cancellation:SoundCloudCancellation(),stage:{ _ in })
    expect(m4aFile.pathExtension == "m4a" && (try! ImportServices().playable(m4aFile)), "M4A mode keeps YouTube's AAC audio in a playable M4A file")
    let m4aLog = try String(contentsOf:argsLog,encoding:.utf8).split(separator:"\n")
    expect(m4aLog.contains("bestaudio[ext=m4a]/bestaudio/best"), "M4A mode asks the extractor for the AAC stream first")
    // With a direct stream in the extractor's JSON, the audio comes straight from Google's servers.
    GoogleVideoFixture.payload = try Data(contentsOf: fixtureYT)
    let directLog = root.appendingPathComponent("yt-direct-arguments")
    var directJSON = try JSONSerialization.jsonObject(with: ytJSON) as! [String: Any]
    directJSON["protocol"] = "https"; directJSON["ext"] = "m4a"; directJSON["http_headers"] = ["User-Agent": "Fixture"]
    directJSON["url"] = "https://rr1---sn-test.googlevideo.com/videoplayback?itag=140&clen=\(GoogleVideoFixture.payload.count)"
    let directJSONText = String(data: try JSONSerialization.data(withJSONObject: directJSON), encoding: .utf8)!
    let directHelper = try scriptYT("youtube-direct", "#!/bin/sh\n/usr/bin/printf '%s\\n' \"$@\" >> \(quoteYT(directLog.path))\nfor arg do\n if [ \"$arg\" = --dump-single-json ]; then /usr/bin/printf '%s\\n' \(quoteYT(directJSONText)); exit 0; fi\ndone\nexit 1\n")
    let directConfig = URLSessionConfiguration.ephemeral; directConfig.protocolClasses = [GoogleVideoFixture.self]
    let directService = YouTubeService(helper:directHelper,ffmpeg:ffmpegYT,runtime:URL(fileURLWithPath:"/usr/bin/true"),cache:root.appendingPathComponent("YTDirect"),fallback:nil,format:{ .m4a },transferConfiguration:directConfig)
    _ = try directService.resolve("https://youtu.be/"+ytID,cancellation:SoundCloudCancellation())
    var directFractions: [Double] = []
    let directFileYT = try directService.download(ytTrack,directory:root.appendingPathComponent("YTDirectDownload"),cancellation:SoundCloudCancellation(),
                                                  stage:{ _ in },progress:{ directFractions.append($0) })
    let directArguments = try String(contentsOf: directLog, encoding: .utf8).split(separator: "\n")
    expect(directFileYT.pathExtension == "m4a" && (try! ImportServices().playable(directFileYT)) && GoogleVideoFixture.ranges.allSatisfy { $0.hasPrefix("bytes=0-") },
           "the direct YouTube stream is fetched by byte range and saved as playable M4A")
    expect(directArguments.filter { $0 == "--dump-single-json" }.count == 1 && !directArguments.contains("--load-info-json"),
           "with a direct stream yt-dlp runs only once, for the link check")
    expect(directFractions.last == 1, "the direct YouTube transfer reports its progress")
    expect(m4aLog.contains("--progress-template"), "yt-dlp downloads report machine-readable progress")
    var ytImports = 0, ytCloudRequests = 0
    var ytServices = services
    ytServices.playable = ImportServices().playable
    ytServices.add = { _ in ytImports += 1; return MusicResult(id:"YT-101",title:ytTrack.title,cloudStatus:"not uploaded",isFavorite:true) }
    ytServices.updateCloudLibrary = { ytCloudRequests += 1 }
    let ytState = root.appendingPathComponent("YTState")
    let ytImportsStore = ImportStore(directory:ytState,services:ytServices,startTimer:false)
    ytImportsStore.acceptYouTube(ytFile,track:ytTrack)
    ytImportsStore.acceptYouTube(ytFile,track:ytTrack)
    settle(ytImportsStore)
    expect(ytImports == 1 && ytImportsStore.entries.count == 1 && ytImportsStore.entries[0].isFavorite == true && ytCloudRequests == 1, "YouTube MP3 goes through favorite and cloud import exactly once even when handed off twice")
    let restoredYT = ImportStore(directory:ytState,services:ytServices,startTimer:false)
    expect(restoredYT.entries[0].youtubeID == ytID && restoredYT.entries[0].youtubeURL == ytTrack.url, "YouTube identity and duplicate protection survive restart")
    let cancelledYT = SoundCloudCancellation(); cancelledYT.cancel()
    do { _ = try ytService.download(ytTrack,directory:root.appendingPathComponent("YTCancelled"),cancellation:cancelledYT,stage:{_ in}); fatalError("Cancelled download accepted") }
    catch SoundCloudError.cancelled { expect(true, "cancelled YouTube downloads never start a transfer or an import") }
    let badYT = try scriptYT("youtube-invalid-output", "#!/bin/sh\n/usr/bin/printf '%s\\n' /tmp/outside.mp3\n")
    let badServiceYT = YouTubeService(helper:badYT,ffmpeg:ffmpegYT,runtime:URL(fileURLWithPath:"/usr/bin/true"),fallback:nil)
    let badDirYT = root.appendingPathComponent("YTBad")
    do { _ = try badServiceYT.download(ytTrack,directory:badDirYT,cancellation:SoundCloudCancellation(),stage:{_ in}); fatalError("Escaped path accepted") }
    catch { expect((try! FileManager.default.contentsOfDirectory(atPath:badDirYT.path)).isEmpty, "invalid downloader output is rejected and partial YouTube downloads are cleaned") }
}

final class YouTubeFixture: YouTubeProviding {
    let lock = NSLock()
    var downloads = 0
    func resolve(_ input:String,cancellation:SoundCloudCancellation) throws -> YouTubeTrack {
        if input == "failure" { throw DropError.message("Unavailable") }
        if input == "old" { Thread.sleep(forTimeInterval:0.3) }
        return YouTubeTrack(id: input == "old" ? "abcdefghijk" : "BaW_jenozKc",title:input,artist:"Artist")
    }
    func download(_ track:YouTubeTrack,directory:URL,cancellation:SoundCloudCancellation,stage:@escaping(String)->Void) throws -> URL {
        lock.lock(); downloads += 1; lock.unlock()
        for _ in 0..<20 { if cancellation.isCancelled { throw SoundCloudError.cancelled }; Thread.sleep(forTimeInterval:0.01) }
        let file = directory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Prepared").appendingPathComponent(track.id+".m4a")
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("audio".utf8).write(to:file)
        return file
    }
    var downloadCount: Int { lock.lock(); defer { lock.unlock() }; return downloads }
}
let ytProvider = YouTubeFixture()
let ytModel = YouTubeStore(service:ytProvider,directory:root.appendingPathComponent("YTModel"),prefetch:false)
ytModel.query = "old"; ytModel.search(); ytModel.query = "new"; ytModel.search()
waitUI { !ytModel.isSearching }
RunLoop.main.run(until:Date().addingTimeInterval(0.35))
expect(ytModel.results.first?.title == "new", "stale YouTube resolution cannot replace the latest result")
var ytReady = 0
ytModel.onReady = { _,_ in ytReady += 1 }
ytModel.add(ytModel.results[0]); ytModel.add(ytModel.results[0]); ytModel.cancel(ytModel.results[0])
waitUI { !ytModel.isDownloading }
RunLoop.main.run(until:Date().addingTimeInterval(0.3))
expect(ytReady == 0, "cancelled YouTube UI operations never hand audio to Apple Music")
ytModel.add(ytModel.results[0]); ytModel.add(ytModel.results[0])
waitUI { !ytModel.isDownloading }
expect(ytReady == 1, "repeated YouTube Add presses produce one import handoff")
ytModel.query = "failure"; ytModel.search()
waitUI { !ytModel.isSearching }
expect(ytModel.error != nil && ytModel.results.first?.id == ytID, "a failed next YouTube link preserves existing track cards and download controls")

final class QuickYouTubeFixture: YouTubeProviding {
    let inner = YouTubeFixture()
    func preview(_ input:String,cancellation:SoundCloudCancellation) -> YouTubeTrack? {
        input == "broken" ? YouTubeTrack(id:"zzzzzzzzzzz",title:"Quick broken",artist:"Artist") : YouTubeTrack(id:"BaW_jenozKc",title:"Quick",artist:"Artist")
    }
    func resolve(_ input:String,cancellation:SoundCloudCancellation) throws -> YouTubeTrack {
        Thread.sleep(forTimeInterval:0.2)
        if input == "broken" { throw DropError.message("Unavailable") }
        return YouTubeTrack(id:"BaW_jenozKc",title:"Full",artist:"Artist",duration:10)
    }
    func download(_ track:YouTubeTrack,directory:URL,cancellation:SoundCloudCancellation,stage:@escaping(String)->Void) throws -> URL {
        try inner.download(track,directory:directory,cancellation:cancellation,stage:stage)
    }
}
let quickProvider = QuickYouTubeFixture()
let prefetchModel = YouTubeStore(service:quickProvider,directory:root.appendingPathComponent("YTPrefetch"))
var prefetchReady: [URL] = []
prefetchModel.onReady = { file,_ in prefetchReady.append(file) }
prefetchModel.query = "quick"; prefetchModel.search()
waitUI { prefetchModel.results.first?.title == "Quick" }
expect(prefetchModel.isSearching && prefetchModel.verifying.contains(ytID), "a quick title card appears before the full link check finishes")
waitUI { prefetchModel.prefetchedIDs.contains(ytID) }
expect(prefetchModel.results.first?.title == "Full" && prefetchReady.isEmpty && !prefetchModel.isDownloading,
       "a checked link prefetches audio in the background without importing it")
prefetchModel.add(prefetchModel.results[0])
expect(prefetchReady.count == 1 && quickProvider.inner.downloadCount == 1 && FileManager.default.fileExists(atPath:prefetchReady[0].path),
       "Add hands prefetched audio over at once without a second download")
prefetchModel.query = "broken"; prefetchModel.search()
waitUI { !prefetchModel.isSearching }
expect(prefetchModel.error != nil && !prefetchModel.results.contains { $0.id == "zzzzzzzzzzz" } && prefetchModel.results.first?.id == ytID,
       "a quick card whose full check fails is removed while earlier cards stay")
let unusedModel = YouTubeStore(service:QuickYouTubeFixture(),directory:root.appendingPathComponent("YTUnused"))
unusedModel.query = "quick"; unusedModel.search()
waitUI { unusedModel.prefetchedIDs.contains(ytID) }
unusedModel.cancelAll()
expect(((try? FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("YTUnused").path)) ?? []).isEmpty,
       "prefetched audio that was never added is deleted when the app quits")

let ytInfoJSON = Data(#"{"id":"BaW_jenozKc","title":"Info","uploader":"Channel","protocol":"https","ext":"m4a","url":"https://rr3---sn-test.googlevideo.com/videoplayback?itag=140&clen=4096","http_headers":{"User-Agent":"Test","Cookie":"secret"}}"#.utf8)
let ytInfo = try YouTubeService.parseInfo(ytInfoJSON, expectedID: ytID)
expect(ytInfo.audioURL?.host == "rr3---sn-test.googlevideo.com" && ytInfo.contentLength == 4096 && ytInfo.fileExtension == "m4a",
       "the extractor's JSON yields a direct stream with its exact size")
expect(ytInfo.headers["User-Agent"] == "Test" && ytInfo.headers["Cookie"] == nil, "direct YouTube requests reuse the extractor's headers but never cookies")
for foreign in ["https://googlevideo.com.evil.test/videoplayback", "http://rr3---sn-test.googlevideo.com/videoplayback", "https://rr3---sn-test.googlevideo.com/other"] {
    let json = String(data: ytInfoJSON, encoding: .utf8)!.replacingOccurrences(of: "https://rr3---sn-test.googlevideo.com/videoplayback?itag=140&clen=4096", with: foreign)
    expect(try! YouTubeService.parseInfo(Data(json.utf8), expectedID: ytID).audioURL == nil, "only Google's HTTPS media endpoint is fetched directly")
}
let ytPreview = try YouTubeService.parsePreview(Data(#"{"title":"Быстрое\u0000 название","author_name":"Канал"}"#.utf8), expectedID: ytID)
expect(ytPreview.id == ytID && ytPreview.artist == "Канал" && !ytPreview.title.contains("\0"), "the quick title card is sanitized and bound to the requested video")
expect(YouTubeService.m4aArguments(source:URL(fileURLWithPath:"/tmp/in.m4a"),output:URL(fileURLWithPath:"/tmp/out.m4a"),track:ytTrack,codec:["-c:a","copy"]).contains("copy"),
       "AAC input is rewrapped rather than re-encoded")

let relayEndpoint = URL(string:"https://relay.example")!
func relayJSON(_ id:String = "BaW_jenozKc", url:String = "https://relay.example/videoplayback?itag=140", extra:[String:Any] = [:]) throws -> Data {
    var root:[String:Any] = ["videoId":id,"title":"Relay track","author":"Relay artist","lengthSeconds":196,
        "adaptiveFormats":[["type":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":"130000","url":url,"clen":"1000"]]]
    for (key,value) in extra { root[key] = value }
    return try JSONSerialization.data(withJSONObject:root)
}
let relayInfo = try YouTubeFallback.parse(relayJSON(),expectedID:ytID,endpoint:relayEndpoint)
expect(relayInfo.track.fallbackEndpoint == relayEndpoint && relayInfo.track.artist == "Relay artist" && relayInfo.fileExtension == "m4a", "anonymous fallback preserves video identity, origin and audio metadata")
for bad in ["http://relay.example/videoplayback", "file:///tmp/audio", "https://relay.example.evil.test/videoplayback", "https://127.0.0.1/videoplayback", "https://user:password@relay.example/videoplayback", "https://relay.example:8443/videoplayback", "https://relay.example/not-a-stream"] {
    do { _ = try YouTubeFallback.parse(relayJSON(url:bad),expectedID:ytID,endpoint:relayEndpoint);fatalError("Invalid relay stream") }
    catch { expect(true,"fallback rejects external, local, credential-bearing and non-HTTPS stream URLs") }
}
for extra:[String:Any] in [["videoId":"wrong"],["paid":true],["premium":true],["liveNow":true],["isUpcoming":true],["isPostLiveDvr":true]] {
    do { _ = try YouTubeFallback.parse(relayJSON(extra:extra),expectedID:ytID,endpoint:relayEndpoint);fatalError("Restricted relay content") }
    catch { expect(true,"fallback cannot substitute a different video or import paid and unfinished content") }
}
expect(YouTubeFallback.isAllowedURL(URL(string:"https://rr1.googlevideo.com/videoplayback")!,endpoint:relayEndpoint,media:true) && !YouTubeFallback.isAllowedURL(URL(string:"https://rr1.googlevideo.com/api/v1/videos/test")!,endpoint:relayEndpoint,media:false), "only audio transfers may redirect to Google's media hosts")
expect(YouTubeFallback.isAllowedURL(URL(string:"https://yt-comp2.chocolatemoo53.com/videoplayback")!,endpoint:YouTubeFallback.defaultEndpoint,media:true), "the known fallback media server is permitted for audio redirects")
expect(!YouTubeFallback.isAllowedURL(URL(string:"https://chocolatemoo53.com.evil.test/videoplayback")!,endpoint:YouTubeFallback.defaultEndpoint,media:true), "a lookalike fallback media host is rejected")
let mixedFormats: [[String: Any]] = [["type":"audio/webm; codecs=\"opus\"","bitrate":"160000","url":"https://relay.example/videoplayback?itag=251","clen":"1000"],
                                     ["type":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":"130000","url":"https://relay.example/videoplayback?itag=140","clen":"1000"]]
expect(try! YouTubeFallback.parse(relayJSON(extra:["adaptiveFormats":mixedFormats]),expectedID:ytID,endpoint:relayEndpoint).fileExtension == "webm"
       && YouTubeFallback.parse(relayJSON(extra:["adaptiveFormats":mixedFormats]),expectedID:ytID,endpoint:relayEndpoint,preferAAC:true).fileExtension == "m4a",
       "M4A mode takes the fallback's AAC stream even when Opus has a higher bitrate")
let relayRequest = YouTubeFallback.request(relayEndpoint)
expect(!relayRequest.httpShouldHandleCookies && relayRequest.value(forHTTPHeaderField:"Cookie") == nil && relayRequest.value(forHTTPHeaderField:"Authorization") == nil, "fallback requests do not include browser cookies or account authorization")

if CommandLine.arguments.count > 1 {
    let fallbackFixture = URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("silence.m4a")
    var relayMetadataCalls = 0, relayDownloads = 0
    let client = YouTubeFallback(endpoint:relayEndpoint,transport:{ request,token,limit,destination in
        expect(request.url?.host == "relay.example" && request.value(forHTTPHeaderField:"Cookie") == nil, "only the selected video is requested anonymously from the configured fallback")
        if let destination { relayDownloads += 1;try FileManager.default.copyItem(at:fallbackFixture,to:destination);return Data() }
        relayMetadataCalls += 1
        expect(request.url?.query?.contains("local=true") == true && limit == 2_000_000,"fallback requests proxied streams and bounds metadata size")
        return try relayJSON(request.url!.lastPathComponent)
    })
    let first = try client.resolve(ytID,cancellation:SoundCloudCancellation())
    _ = try client.resolve(ytID,cancellation:SoundCloudCancellation())
    expect(relayMetadataCalls == 1,"fallback metadata and signed stream URLs are cached briefly without a second network request")
    let service = YouTubeService(helper:URL(fileURLWithPath:"/usr/bin/false"),ffmpeg:URL(fileURLWithPath:"/opt/homebrew/bin/ffmpeg"),runtime:URL(fileURLWithPath:"/usr/bin/true"),fallback:client,format:{ .mp3 })
    let fallbackTrack = try service.resolve("https://youtu.be/"+ytID,cancellation:SoundCloudCancellation())
    expect(fallbackTrack == first.track,"a failed anonymous YouTube extractor automatically resolves through the fallback")
    let fallbackFile = try service.download(fallbackTrack,directory:root.appendingPathComponent("RelayDownloads"),cancellation:SoundCloudCancellation(),stage:{ _ in })
    expect(relayDownloads == 1 && fallbackFile.pathExtension == "mp3" && (try! ImportServices().playable(fallbackFile)),"fallback audio becomes a real playable MP3 through the same encoding path")
    let m4aFallbackService = YouTubeService(helper:URL(fileURLWithPath:"/usr/bin/false"),ffmpeg:URL(fileURLWithPath:"/opt/homebrew/bin/ffmpeg"),runtime:URL(fileURLWithPath:"/usr/bin/true"),fallback:client,format:{ .m4a })
    let m4aFallbackFile = try m4aFallbackService.download(fallbackTrack,directory:root.appendingPathComponent("RelayDownloadsM4A"),cancellation:SoundCloudCancellation(),stage:{ _ in })
    expect(m4aFallbackFile.pathExtension == "m4a" && (try! ImportServices().playable(m4aFallbackFile)),"fallback AAC audio is rewrapped as M4A without re-encoding")
    // A slow extractor is overtaken by the fallback; a quick one answers alone.
    func relayScript(_ name: String, _ body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
    let quotedJSON = String(data: ytJSON, encoding: .utf8)!.replacingOccurrences(of: "'", with: "'\\''")
    let slowExtractor = try relayScript("youtube-slow", "/bin/sleep 3\n/usr/bin/printf '%s\\n' '\(quotedJSON)'\n")
    let quickExtractor = try relayScript("youtube-quick", "/usr/bin/printf '%s\\n' '\(quotedJSON)'\n")
    let racing = YouTubeService(helper:slowExtractor,ffmpeg:URL(fileURLWithPath:"/opt/homebrew/bin/ffmpeg"),runtime:URL(fileURLWithPath:"/usr/bin/true"),cache:root.appendingPathComponent("YTRace"),fallback:client,format:{ .mp3 },raceDelay:{ 0.2 })
    let raceStarted = Date()
    let raced = try racing.resolve("https://youtu.be/"+ytID,cancellation:SoundCloudCancellation())
    expect(raced.fallbackEndpoint == relayEndpoint && Date().timeIntervalSince(raceStarted) < 2, "a slow extractor is overtaken by the fallback after a short delay")
    let quickService = YouTubeService(helper:quickExtractor,ffmpeg:URL(fileURLWithPath:"/opt/homebrew/bin/ffmpeg"),runtime:URL(fileURLWithPath:"/usr/bin/true"),cache:root.appendingPathComponent("YTQuick"),fallback:client,format:{ .mp3 },raceDelay:{ 2 })
    expect(try! quickService.resolve("https://youtu.be/"+ytID,cancellation:SoundCloudCancellation()) == ytTrack, "a quick extractor wins the race without the fallback")
    var refreshCalls = 0, streamCalls = 0
    let refreshing = YouTubeFallback(endpoint:relayEndpoint,transport:{ request,token,limit,destination in
        if let destination {
            streamCalls += 1
            if streamCalls == 1 { throw YouTubeHTTPError(status:403) }
            try FileManager.default.copyItem(at:fallbackFixture,to:destination);return Data()
        }
        refreshCalls += 1
        return try relayJSON(url:"https://relay.example/videoplayback?signature=\(refreshCalls)")
    })
    let refreshingDir = root.appendingPathComponent("RelayRefresh");try FileManager.default.createDirectory(at:refreshingDir,withIntermediateDirectories:true)
    _ = try refreshing.download(ytID,directory:refreshingDir,cancellation:SoundCloudCancellation(),stage:{ _ in })
    expect(refreshCalls == 2 && streamCalls == 2,"an expired media URL is refreshed once and retried without another Music import")
    var transientStreams = 0
    let transientClient = YouTubeFallback(endpoint:relayEndpoint,transport:{ request,token,limit,destination in
        if let destination {
            transientStreams += 1
            if transientStreams == 1 { throw NSError(domain:NSURLErrorDomain,code:NSURLErrorNetworkConnectionLost) }
            try FileManager.default.copyItem(at:fallbackFixture,to:destination);return Data()
        }
        return try relayJSON()
    })
    let transientDir = root.appendingPathComponent("RelayTransient");try FileManager.default.createDirectory(at:transientDir,withIntermediateDirectories:true)
    _ = try transientClient.download(ytID,directory:transientDir,cancellation:SoundCloudCancellation(),stage:{ _ in })
    expect(transientStreams == 2,"a dropped anonymous media connection is retried automatically")
    var deniedStreams = 0
    let deniedClient = YouTubeFallback(endpoint:relayEndpoint,transport:{ request,token,limit,destination in
        if destination != nil { deniedStreams += 1;throw YouTubeHTTPError(status:403) }
        return try relayJSON()
    })
    let deniedDir = root.appendingPathComponent("RelayDenied");try FileManager.default.createDirectory(at:deniedDir,withIntermediateDirectories:true)
    do { _ = try deniedClient.download(ytID,directory:deniedDir,cancellation:SoundCloudCancellation(),stage:{ _ in });fatalError("Endless relay retries") }
    catch { expect(deniedStreams == 3 && (try! FileManager.default.contentsOfDirectory(atPath:deniedDir.path)).isEmpty,"fallback retries stay bounded and leave no incomplete audio for import") }
    let cancelledRelay = SoundCloudCancellation();cancelledRelay.cancel()
    let beforeCancel = relayMetadataCalls
    do { _ = try client.resolve("abcdefghijk",cancellation:cancelledRelay);fatalError("Cancelled fallback resolved") }
    catch SoundCloudError.cancelled { expect(relayMetadataCalls == beforeCancel,"cancelled fallback requests never contact the remote service") }
}

final class YouTubeHTTPFixture: URLProtocol {
    static var seenCookie = false
    static var payload = Data("small audio data".utf8)
    static var status = 200
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seenCookie = request.value(forHTTPHeaderField:"Cookie") != nil || request.value(forHTTPHeaderField:"Authorization") != nil
        let response = HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"audio/mp4"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
let httpFixtureConfig = URLSessionConfiguration.ephemeral;httpFixtureConfig.protocolClasses = [YouTubeHTTPFixture.self]
var credentialRequest = YouTubeFallback.request(URL(string:"https://relay.example/videoplayback")!)
credentialRequest.setValue("test-cookie",forHTTPHeaderField:"Cookie");credentialRequest.setValue("test-auth",forHTTPHeaderField:"Authorization")
let transferred = root.appendingPathComponent("streamed.m4a")
_ = try YouTubeHTTPTransfer.run(credentialRequest,cancellation:SoundCloudCancellation(),maximumBytes:100,destination:transferred,endpoint:relayEndpoint,configuration:httpFixtureConfig)
expect(!YouTubeHTTPFixture.seenCookie && (try! Data(contentsOf:transferred)) == YouTubeHTTPFixture.payload,"the real streaming transport strips credentials and writes the audio directly to disk")
let oversized = root.appendingPathComponent("oversized.m4a")
do { _ = try YouTubeHTTPTransfer.run(credentialRequest,cancellation:SoundCloudCancellation(),maximumBytes:4,destination:oversized,endpoint:relayEndpoint,configuration:httpFixtureConfig);fatalError("Oversized response accepted") }
catch { expect(!FileManager.default.fileExists(atPath:oversized.path),"streaming limits are enforced even without Content-Length and partial files are removed") }
YouTubeHTTPFixture.status = 429
let limitedFile = root.appendingPathComponent("limited.m4a")
do { _ = try YouTubeHTTPTransfer.run(credentialRequest,cancellation:SoundCloudCancellation(),maximumBytes:100,destination:limitedFile,endpoint:relayEndpoint,configuration:httpFixtureConfig);fatalError("Rate limit accepted") }
catch { expect((error as? YouTubeHTTPError)?.status == 429 && !FileManager.default.fileExists(atPath:limitedFile.path),"rate limits stop the transfer and never save an error page as audio") }

// Links from any field, paste or drop go to the source they belong to.
expect(LinkRoute.detect("https://youtu.be/\(ytID)?si=share") == .youTube("https://youtu.be/\(ytID)?si=share")
       && LinkRoute.detect(" https://soundcloud.com/artist/song ") == .soundCloud("https://soundcloud.com/artist/song")
       && LinkRoute.detect("https://on.soundcloud.com/abc") == .soundCloud("https://on.soundcloud.com/abc"),
       "YouTube and SoundCloud track links are routed to their own tabs")
expect(LinkRoute.detect("тёмный принц") == nil && LinkRoute.forInput("тёмный принц") == .soundCloud("тёмный принц"),
       "plain words are not treated as links but a search field sends them to SoundCloud")
expect(LinkRoute.detect("https://example.com/song") == nil && LinkRoute.forInput("https://youtube.com/playlist?list=PL1") == nil
       && LinkRoute.detect("https://soundcloud.com/artist/sets/album") == nil,
       "foreign sites, playlists and albums are never routed")

let progressLog = root.appendingPathComponent("progress.log")
try Data("[download] noise\nMDPROGRESS 50 200\nMDPROGRESS 10 NA\nMDPROGRESS 100 2".utf8).write(to: progressLog)
var tailed: [Double] = []
let tail = ProgressTail(files: [progressLog, root.appendingPathComponent("missing.log")]) { tailed.append($0) }
tail.poll()
let appender = try FileHandle(forWritingTo: progressLog); try appender.seekToEnd(); try appender.write(contentsOf: Data("00\n".utf8)); try appender.close()
tail.poll(); tail.poll()
expect(tailed == [0.25, 0.5], "yt-dlp progress is read from complete new lines only, ignoring unknown totals")

print("\(checks) checks passed. No personal Music library was modified.")
