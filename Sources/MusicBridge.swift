import AppKit

struct MusicResult {
    let id: String
    let title: String
    let cloudStatus: String
    var isFavorite: Bool? = nil
    var favoriteError: String? = nil
}

struct AutomationError: LocalizedError {
    let code: Int
    let detail: String
    var errorDescription: String? {
        switch code {
        case -1743:
            return "Разреши Music Drop управлять «Музыкой»: Системные настройки → Конфиденциальность и безопасность → Автоматизация. Затем повтори импорт."
        case -1712:
            return "«Музыка» не ответила вовремя. Проверь медиатеку перед повторным добавлением: файл мог уже импортироваться."
        default:
            return "«Музыка» не смогла выполнить действие (\(code)): \(detail)"
        }
    }
}

/// All calls run on one serial queue. No automation work blocks the UI thread.
enum MusicBridge {
    /// Launch only when necessary, without taking focus or hiding an already open Music window.
    /// Called on the serial worker, never on the main thread.
    static func ensureRunning() throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else {
            throw DropError.message("Приложение «Музыка» не найдено на этом Mac.")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                launchError = error
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw DropError.message("Не удалось дождаться запуска «Музыки». Импорт ещё не отправлен; попробуй снова.")
        }
        if let launchError { throw launchError }
    }

    static func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw DropError.message("Не удалось подготовить команду для «Музыки».")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            throw AutomationError(code: error[NSAppleScript.errorNumber] as? Int ?? -1,
                                  detail: error[NSAppleScript.errorMessage] as? String ?? "Неизвестная ошибка")
        }
        return result
    }

    static func importSource(path: String) -> String {
        """
        with timeout of 120 seconds
            tell application id "com.apple.Music"
                set addedItems to add (POSIX file \(FileTools.appleScriptLiteral(path)) as alias) to library playlist 1
                if class of addedItems is list then
                    if (count of addedItems) is 0 then error "Music returned no imported track"
                    set addedTrack to item 1 of addedItems
                else
                    set addedTrack to addedItems
                end if
                set favoriteState to false
                set favoriteProblem to ""
                try
                    set favorited of addedTrack to true
                    set favoriteState to favorited of addedTrack
                on error problemText number problemNumber
                    set favoriteProblem to problemText & " (" & (problemNumber as string) & ")"
                end try
                set cloudState to "unknown"
                try
                    set cloudState to cloud status of addedTrack as string
                end try
                return {persistent ID of addedTrack, name of addedTrack, cloudState, favoriteState, favoriteProblem}
            end tell
        end timeout
        """
    }

    static func add(_ url: URL) throws -> MusicResult {
        try ensureRunning()
        let result = try execute(importSource(path: url.path))
        guard result.numberOfItems >= 3,
              let id = result.atIndex(1)?.stringValue, !id.isEmpty else {
            // An import could have succeeded even if its result was unexpected.
            throw AutomationError(code: -1712, detail: "Нет подтверждения импорта")
        }
        let favorite = result.atIndex(4)?.booleanValue ?? false
        let problem = result.atIndex(5)?.stringValue ?? ""
        return MusicResult(id: id, title: result.atIndex(2)?.stringValue ?? url.lastPathComponent,
                           cloudStatus: result.atIndex(3)?.stringValue ?? "unknown", isFavorite: favorite,
                           favoriteError: favorite ? nil : "Трек в медиатеке, но избранное не подтверждено. " + problem)
    }

    static func favoriteSource(id: String) -> String {
        """
        with timeout of 30 seconds
            tell application id "com.apple.Music"
                set foundTracks to (every file track of library playlist 1 whose persistent ID is \(FileTools.appleScriptLiteral(id)))
                if (count of foundTracks) is 0 then error "Трек не найден в медиатеке" number -1728
                set selectedTrack to item 1 of foundTracks
                set favorited of selectedTrack to true
                return favorited of selectedTrack
            end tell
        end timeout
        """
    }

    static func favorite(id: String) throws {
        try ensureRunning()
        guard try execute(favoriteSource(id: id)).booleanValue else {
            throw DropError.message("«Музыка» не подтвердила добавление в избранное. Можно повторить без нового импорта.")
        }
    }

    /// Launches Music and waits until it answers scripts, so an import that follows
    /// does not also pay for the launch.
    static func prepare() throws {
        try ensureRunning()
        _ = try execute("""
        with timeout of 60 seconds
            tell application id "com.apple.Music" to get version
        end timeout
        """)
    }

    static func cloudStatus(id: String) throws -> String {
        // A status read is never urgent; a short timeout keeps a busy Music from holding imports back.
        try execute("""
        with timeout of 4 seconds
            tell application id "com.apple.Music"
                set foundTracks to (every file track of library playlist 1 whose persistent ID is \(FileTools.appleScriptLiteral(id)))
                if (count of foundTracks) is 0 then return "missing"
                return cloud status of item 1 of foundTracks as string
            end tell
        end timeout
        """).stringValue ?? "unknown"
    }

    static func reveal(id: String) throws {
        _ = try execute("""
        tell application id "com.apple.Music"
            set foundTracks to (every file track of library playlist 1 whose persistent ID is \(FileTools.appleScriptLiteral(id)))
            if (count of foundTracks) > 0 then reveal item 1 of foundTracks
            activate
        end tell
        """)
    }
}
