import Foundation
import Darwin

struct YouTubeTrack: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    var url: URL { URL(string: "https://www.youtube.com/watch?v=" + id)! }
    var duration: Double?
    var fallbackEndpoint: URL?
    var durationLabel: String {
        guard let duration, duration.isFinite, duration >= 0 else { return "" }
        let seconds = Int(min(duration, 864_000))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

protocol YouTubeProviding {
    func resolve(_ input: String, cancellation: SoundCloudCancellation) throws -> YouTubeTrack
    func download(_ track: YouTubeTrack, directory: URL, cancellation: SoundCloudCancellation,
                  stage: @escaping (String) -> Void) throws -> URL
}

final class YouTubeService: YouTubeProviding {
    let helper: URL
    let ffmpeg: URL?
    let runtime: URL
    let cache: URL
    private let routeLock = NSLock()
    private var directUnavailableUntil = Date.distantPast
    private let fallback: YouTubeFallback?
    init(helper: URL? = nil, ffmpeg: URL? = nil, runtime: URL? = nil, cache: URL? = nil,
         fallback: YouTubeFallback? = YouTubeFallback()) {
        self.fallback = fallback
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        self.helper = helper ?? resources.appendingPathComponent("Helpers/yt-dlp")
        self.ffmpeg = ffmpeg ?? ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        #if arch(arm64)
        let runtimeName = "deno-arm64"
        #else
        let runtimeName = "deno-x86_64"
        #endif
        self.runtime = runtime ?? resources.appendingPathComponent("Helpers/" + runtimeName)
        self.cache = cache ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music Drop/Cache/YouTube")
    }

    static func videoID(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 2_000, !text.contains("\0"), let c = URLComponents(string: text),
              ["https", "http"].contains(c.scheme?.lowercased() ?? ""), c.user == nil, c.password == nil,
              c.port == nil || c.port == 443, let host = c.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"].contains(host) else {
            throw DropError.message("Вставь ссылку на отдельное видео YouTube или YouTube Music.")
        }
        let parts = c.path.split(separator: "/").map(String.init)
        let id: String?
        if host == "youtu.be" || host == "www.youtu.be" { id = parts.count == 1 ? parts[0] : nil }
        else if c.path == "/watch" { id = c.queryItems?.first(where: { $0.name == "v" })?.value }
        else if parts.count == 2, ["shorts", "live", "embed"].contains(parts[0]) { id = parts[1] }
        else { id = nil }
        guard let id, id.count == 11, id.unicodeScalars.allSatisfy({
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "_" || $0 == "-"
        }) else { throw DropError.message("Нужна ссылка на одно видео. Плейлисты и каналы не поддерживаются.") }
        return id
    }

    static func parseTrack(_ data: Data, expectedID: String) throws -> YouTubeTrack {
        guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              item["id"] as? String == expectedID, let title = item["title"] as? String, !title.isEmpty,
              item["_type"] as? String != "playlist" else { throw DropError.message("Не удалось получить сведения о видео YouTube.") }
        guard item["is_live"] as? Bool != true, !["is_live", "is_upcoming", "post_live"].contains(item["live_status"] as? String ?? "") else {
            throw DropError.message("Дождись окончания трансляции и обработки записи на YouTube.")
        }
        func clean(_ text: String) -> String {
            String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        }
        return YouTubeTrack(id: expectedID, title: clean(title),
                            artist: clean((item["artist"] as? String) ?? (item["uploader"] as? String) ?? "YouTube"),
                            duration: item["duration"] as? Double)
    }

    private var arguments: [String] {
        ["--ignore-config", "--no-plugin-dirs", "--no-playlist", "--no-warnings", "--no-progress",
         "--socket-timeout", "10", "--retries", "1", "--fragment-retries", "2", "--extractor-retries", "1",
         "--cache-dir", cache.path, "--js-runtimes", "deno:" + runtime.path]
    }
    private func validateTools(needsEncoder: Bool) throws {
        guard FileManager.default.isExecutableFile(atPath: helper.path), FileManager.default.isExecutableFile(atPath: runtime.path) else {
            throw DropError.message("Компонент YouTube не найден. Переустанови Music Drop из нового DMG.")
        }
        if needsEncoder && ffmpeg == nil { throw DropError.message("Для сохранения MP3 нужен FFmpeg в /opt/homebrew/bin или /usr/local/bin.") }
    }
    func resolve(_ input: String, cancellation: SoundCloudCancellation) throws -> YouTubeTrack {
        let id = try Self.videoID(input)
        routeLock.lock(); let directAvailable = Date() >= directUnavailableUntil; routeLock.unlock()
        if directAvailable || fallback == nil {
            do {
                try validateTools(needsEncoder: false)
                let result = try run(helper, arguments: arguments + ["--skip-download", "--dump-single-json", "--", "https://www.youtube.com/watch?v=" + id], cancellation: cancellation, timeout: 30)
                return try Self.parseTrack(result, expectedID: id)
            } catch {
                if cancellation.isCancelled { throw SoundCloudError.cancelled }
                guard fallback != nil else { throw error }
                routeLock.lock(); directUnavailableUntil = Date().addingTimeInterval(900); routeLock.unlock()
            }
        }
        guard let fallback else { throw DropError.message("YouTube сейчас не предоставляет аудио без входа.") }
        return try fallback.resolve(id, cancellation: cancellation).track
    }

    func download(_ track: YouTubeTrack, directory: URL, cancellation: SoundCloudCancellation,
                  stage: @escaping (String) -> Void) throws -> URL {
        _ = try Self.videoID(track.url.absoluteString)
        guard let ffmpeg else { throw DropError.message("Для сохранения MP3 нужен FFmpeg в /opt/homebrew/bin или /usr/local/bin.") }
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        let working = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: working) } }
        let source: URL
        if let endpoint = track.fallbackEndpoint {
            guard let fallback, endpoint == fallback.endpoint else { throw DropError.message("Неизвестный резервный сервис.") }
            source = try fallback.download(track.id, directory: working, cancellation: cancellation, stage: stage)
        } else {
            do {
                try validateTools(needsEncoder: true)
                stage("Скачиваем аудио с YouTube…")
                let output = try run(helper, arguments: arguments + [
                    "-f", "bestaudio/best", "--concurrent-fragments", "4", "--max-filesize", "200M",
                    "--no-simulate", "--print", "after_move:filepath", "-o", working.appendingPathComponent("audio.%(ext)s").path,
                    "--", track.url.absoluteString
                ], cancellation: cancellation, timeout: 900)
                let path = String(data: output, encoding: .utf8)?.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                let downloaded = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                guard downloaded.path.hasPrefix(working.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
                    throw DropError.message("YouTube не вернул аудиофайл.")
                }
                source = downloaded
            } catch {
                if cancellation.isCancelled { throw SoundCloudError.cancelled }
                guard let fallback else { throw error }
                stage("Пробуем резервную загрузку без входа…")
                source = try fallback.download(track.id, directory: working, cancellation: cancellation, stage: stage)
            }
        }
        try FileTools.validate(source, allowedExtensions: ["m4a", "webm", "mp4", "opus", "ogg", "mp3", "aac"])
        stage("Сохраняем MP3…")
        let preparedDirectory = working.appendingPathComponent("Prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: preparedDirectory, withIntermediateDirectories: true)
        let cleaned = track.title.unicodeScalars.map { "/:\0".unicodeScalars.contains($0) ? "_" : String($0) }.joined()
        var name = ""
        for c in cleaned { if (name + String(c)).utf8.count > 180 { break }; name.append(c) }
        let prepared = preparedDirectory.appendingPathComponent((name.isEmpty ? "YouTube" : name) + ".mp3")
        _ = try run(ffmpeg, arguments: Self.encodeArguments(source: source, output: prepared, track: track), cancellation: cancellation, timeout: 300)
        try FileTools.validate(prepared)
        let size = try prepared.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 200_000_000 else { throw DropError.message("MP3 превышает ограничение облачной медиатеки 200 МБ.") }
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        try? FileManager.default.removeItem(at: source)
        success = true
        return prepared
    }
    static func encodeArguments(source: URL, output: URL, track: YouTubeTrack) -> [String] {
        ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path, "-map", "0:a:0", "-vn",
         "-c:a", "libmp3lame", "-q:a", "2", "-id3v2_version", "3", "-fs", "200000001",
         "-metadata", "title=" + track.title, "-metadata", "artist=" + track.artist,
         "-metadata", "album=YouTube", "-metadata", "comment=" + track.url.absoluteString, output.path]
    }

    /// Output files avoid deadlocks; arguments never pass through a shell.
    private func run(_ executable: URL, arguments: [String], cancellation: SoundCloudCancellation, timeout: TimeInterval) throws -> Data {
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("musicdrop-youtube-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout"), errorURL = directory.appendingPathComponent("stderr")
        fm.createFile(atPath: outputURL.path, contents: nil); fm.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL), error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = output; process.standardError = error; process.standardInput = FileHandle.nullDevice
        try process.run(); cancellation.attach(process)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if cancellation.isCancelled || Date() > deadline {
                process.terminate()
                let limit = Date().addingTimeInterval(2)
                while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if cancellation.isCancelled { throw SoundCloudError.cancelled }
                throw DropError.message("YouTube долго не отвечает. Проверь соединение и повтори.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw DropError.message(Self.errorMessage(detail))
        }
        return try Data(contentsOf: outputURL)
    }
    static func errorMessage(_ detail: String) -> String {
        let lower = detail.lowercased()
        if lower.contains("sign in") || lower.contains("not a bot") || lower.contains("cookies") {
            return "YouTube отклонил анонимную загрузку. Пробуем резервный сервис без входа."
        }
        if lower.contains("private") || lower.contains("unavailable") || lower.contains("not available") || lower.contains("drm") || lower.contains("403") {
            return "YouTube не предоставил доступ к аудио. Видео может быть закрыто, удалено или ограничено для твоего подключения."
        }
        if lower.contains("max-filesize") || lower.contains("larger than") { return "Аудио превышает ограничение 200 МБ." }
        let last = detail.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Не удалось загрузить аудио."
        return "Ошибка YouTube: " + String(last.prefix(500))
    }
}
