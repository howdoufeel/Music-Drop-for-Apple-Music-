import Foundation
import Darwin

struct SoundCloudTrack: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let url: URL
    var duration: Double?
    var artwork: URL?

    var durationLabel: String {
        guard let duration, duration.isFinite, duration >= 0 else { return "" }
        let seconds = Int(min(duration, 864_000))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

enum SoundCloudError: LocalizedError {
    case message(String), cancelled, rateLimited
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .cancelled: return "Отменено"
        case .rateLimited: return "SoundCloud временно ограничил частоту загрузок. Подожди немного и повтори."
        }
    }
}

final class SoundCloudCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var task: URLSessionTask?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attach(_ process: Process) {
        lock.lock(); self.process = process; let stop = cancelled; lock.unlock()
        if stop, process.isRunning { process.terminate() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let process = process; let task = task; lock.unlock()
        task?.cancel()
        if let process, process.isRunning { process.terminate() }
    }
    func attach(_ task: URLSessionTask) {
        lock.lock(); self.task = task; let stop = cancelled; lock.unlock()
        if stop { task.cancel() }
    }
}

protocol SoundCloudProviding {
    func search(_ input: String, cancellation: SoundCloudCancellation) throws -> [SoundCloudTrack]
    func download(_ track: SoundCloudTrack, directory: URL, cancellation: SoundCloudCancellation,
                  stage: @escaping (String) -> Void) throws -> URL
}

final class SoundCloudService: SoundCloudProviding {
    let helper: URL
    let ffmpeg: URL?
    let cache: URL
    private let searchClient: SoundCloudSearchClient
    private let resultLock = NSLock()
    private var searchResults: [String: (date: Date, tracks: [SoundCloudTrack])] = [:]
    private let now: () -> Date

    init(helper: URL? = nil, ffmpeg: URL? = nil, cache: URL? = nil,
         searchClient: SoundCloudSearchClient? = nil, now: @escaping () -> Date = Date.init) {
        self.helper = helper ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("Helpers/yt-dlp")
        self.ffmpeg = ffmpeg ?? ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        self.cache = cache ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music Drop/Cache/SoundCloud", isDirectory: true)
        self.searchClient = searchClient ?? SoundCloudSearchClient(cache: self.cache)
        self.now = now
    }

    /// Only SoundCloud search terms or individual track links are accepted.
    /// The string is passed as one Process argument, never as shell code.
    static func searchTarget(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw SoundCloudError.message("Введи название трека, автора или ссылку SoundCloud.") }
        guard value.count <= 2_000 else { throw SoundCloudError.message("Слишком длинный поисковый запрос.") }
        guard !value.contains("\0") else { throw SoundCloudError.message("Поисковый запрос содержит неподдерживаемый символ.") }
        if value.contains("://") {
            guard var components = URLComponents(string: value),
                  ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host?.lowercased(),
                  ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com", "on.soundcloud.com"].contains(host),
                  components.user == nil, components.password == nil,
                  components.port == nil || components.port == 443 else {
                throw SoundCloudError.message("Поддерживаются только ссылки SoundCloud на отдельные треки.")
            }
            let path = components.path.split(separator: "/")
            if path.first == "search", let query = components.queryItems?.first(where: { $0.name == "q" })?.value,
               !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !query.contains("\0") {
                return "scsearch15:" + query
            }
            guard !path.isEmpty, !path.contains("sets"), host == "on.soundcloud.com" || path.count >= 2 else {
                throw SoundCloudError.message("Вставь ссылку на отдельный трек или введи его название.")
            }
            components.scheme = "https"
            guard let url = components.url else { throw SoundCloudError.message("Не удалось прочитать ссылку.") }
            return url.absoluteString
        }
        return "scsearch15:" + value
    }

    static func parseTracks(_ data: Data) throws -> [SoundCloudTrack] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SoundCloudError.message("SoundCloud вернул непонятный ответ. Попробуй ещё раз.")
        }
        let entries = (root["entries"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [root]
        var seen: Set<String> = []
        return entries.compactMap { item in
            let id = (item["id"] as? String) ?? (item["id"] as? NSNumber)?.stringValue ?? ""
            let rawURL = (item["webpage_url"] as? String) ?? (item["url"] as? String) ?? ""
            guard !id.isEmpty, !seen.contains(id), let url = URL(string: rawURL),
                  ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com", "on.soundcloud.com"].contains(url.host?.lowercased() ?? ""),
                  url.scheme == "https" || url.scheme == "http",
                  let title = item["title"] as? String, !title.isEmpty else { return nil }
            seen.insert(id)
            let artist = (item["artist"] as? String) ?? (item["artists"] as? [String])?.first
                ?? (item["uploader"] as? String) ?? "Автор не указан"
            var artwork: URL?
            if let value = item["thumbnail"] as? String, let imageURL = URL(string: value), imageURL.scheme == "https",
               let host = imageURL.host, host == "sndcdn.com" || host.hasSuffix(".sndcdn.com") {
                artwork = imageURL
            }
            func cleaned(_ text: String, maximum: Int) -> String {
                String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
                    .joined().trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximum))
            }
            return SoundCloudTrack(id: id, title: cleaned(title, maximum: 400), artist: cleaned(artist, maximum: 300),
                                   url: url, duration: item["duration"] as? Double, artwork: artwork)
        }
    }

    private var commonArguments: [String] {
        ["--ignore-config", "--no-plugin-dirs", "--no-playlist", "--no-warnings", "--no-progress",
         "--socket-timeout", "15", "--retries", "1", "--extractor-retries", "1", "--cache-dir", cache.path]
    }

    func search(_ input: String, cancellation: SoundCloudCancellation) throws -> [SoundCloudTrack] {
        let target = try Self.searchTarget(input)
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        resultLock.lock()
        let cached = searchResults[target]
        resultLock.unlock()
        if let cached, now().timeIntervalSince(cached.date) < 300 { return cached.tracks }
        let tracks = try searchClient.search(target, cancellation: cancellation)
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        resultLock.lock()
        searchResults = searchResults.filter { now().timeIntervalSince($0.value.date) < 300 }
        if searchResults.count >= 30, let oldest = searchResults.min(by: { $0.value.date < $1.value.date })?.key {
            searchResults[oldest] = nil
        }
        searchResults[target] = (now(), tracks)
        resultLock.unlock()
        return tracks
    }

    func download(_ track: SoundCloudTrack, directory: URL, cancellation: SoundCloudCancellation,
                  stage: @escaping (String) -> Void) throws -> URL {
        guard let ffmpeg else {
            throw SoundCloudError.message("Не найден FFmpeg для подготовки аудио. На этом Mac нужен FFmpeg в /opt/homebrew/bin или /usr/local/bin.")
        }
        let target = try Self.searchTarget(track.url.absoluteString)
        guard !target.hasPrefix("scsearch") else { throw SoundCloudError.message("Выбери конкретный трек из результатов.") }
        let working = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: working) } }
        stage("Получаем аудио с SoundCloud…")
        do {
            if let stream = try searchClient.audioStream(for: track, cancellation: cancellation) {
                let prepared = try preparedURL(for: track, working: working, fileExtension: stream.fileExtension)
                stage("Скачиваем с SoundCloud…")
                _ = try run(ffmpeg, arguments: Self.nativeDownloadArguments(stream: stream, track: track, output: prepared),
                            cancellation: cancellation, timeout: 900)
                try validatePrepared(prepared)
                if cancellation.isCancelled { throw SoundCloudError.cancelled }
                success = true
                return prepared
            }
        } catch SoundCloudError.rateLimited {
            throw SoundCloudError.rateLimited
        } catch {
            if cancellation.isCancelled { throw SoundCloudError.cancelled }
            // Keep the proven extractor for unsupported stream layouts or a failed direct transfer.
            try? FileManager.default.removeItem(at: working.appendingPathComponent("Prepared"))
        }
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw SoundCloudError.message("Компонент загрузки SoundCloud не найден. Переустанови Music Drop из нового DMG.")
        }
        stage("Скачиваем с SoundCloud…")
        let output = try run(helper, arguments: commonArguments + [
            "--concurrent-fragments", "4",
            "--no-simulate", "--max-filesize", "200M", "--extract-audio", "--audio-format", "best", "--ffmpeg-location", ffmpeg.path,
            "--print", "after_move:filepath", "-o", working.appendingPathComponent("audio.%(ext)s").path,
            "--", target
        ], cancellation: cancellation, timeout: 900)
        let lastLine = String(data: output, encoding: .utf8)?.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let audio = URL(fileURLWithPath: lastLine).standardizedFileURL
        guard audio.path.hasPrefix(working.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: audio.path) else {
            throw SoundCloudError.message("SoundCloud не отдал аудиофайл для этого трека.")
        }
        stage("Готовим аудио для «Музыки»…")
        let ext = audio.pathExtension.lowercased()
        let outputExt = ext == "mp3" ? "mp3" : "m4a"
        let prepared = try preparedURL(for: track, working: working, fileExtension: outputExt)
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", audio.path, "-map", "0:a:0", "-vn"]
        if ["mp3", "m4a", "aac"].contains(ext) { arguments += ["-c:a", "copy"] }
        else if ["wav", "flac", "aif", "aiff"].contains(ext) { arguments += ["-c:a", "alac"] }
        else { arguments += ["-c:a", "aac", "-b:a", "192k"] }
        arguments += ["-metadata", "title=" + track.title, "-metadata", "artist=" + track.artist,
                      "-metadata", "album=SoundCloud", "-metadata", "comment=" + track.url.absoluteString, prepared.path]
        _ = try run(ffmpeg, arguments: arguments, cancellation: cancellation, timeout: 300)
        try validatePrepared(prepared)
        try? FileManager.default.removeItem(at: audio)
        success = true
        return prepared
    }

    static func nativeDownloadArguments(stream: SoundCloudAudioSource, track: SoundCloudTrack, output: URL) -> [String] {
        ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-rw_timeout", "15000000",
         "-protocol_whitelist", "https,tls,tcp", "-i", stream.url.absoluteString,
         "-map", "0:a:0", "-vn", "-c:a", "copy", "-fs", "200000001",
         "-metadata", "title=" + track.title, "-metadata", "artist=" + track.artist,
         "-metadata", "album=SoundCloud", "-metadata", "comment=" + track.url.absoluteString, output.path]
    }

    private func preparedURL(for track: SoundCloudTrack, working: URL, fileExtension: String) throws -> URL {
        let cleanedTitle = track.title.unicodeScalars.map { "/:\0".unicodeScalars.contains($0) ? "_" : String($0) }.joined()
        var safeTitle = ""
        for character in cleanedTitle {
            let candidate = safeTitle + String(character)
            if candidate.utf8.count > 180 { break }
            safeTitle = candidate
        }
        let preparedDirectory = working.appendingPathComponent("Prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: preparedDirectory, withIntermediateDirectories: true)
        return preparedDirectory.appendingPathComponent((safeTitle.isEmpty ? "SoundCloud" : safeTitle) + "." + fileExtension)
    }

    private func validatePrepared(_ prepared: URL) throws {
        let size = try prepared.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 200_000_000 else {
            throw SoundCloudError.message("Аудиофайл пуст или превышает ограничение облачной медиатеки 200 МБ.")
        }
    }

    /// Files for stdout/stderr prevent pipe-buffer deadlocks on large JSON results.
    private func run(_ executable: URL, arguments: [String], cancellation: SoundCloudCancellation,
                     timeout: TimeInterval) throws -> Data {
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("musicdrop-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("output")
        let errorURL = temporary.appendingPathComponent("error")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        try process.run()
        cancellation.attach(process)
        let deadline = Date().addingTimeInterval(timeout)
        func stop() {
            if process.isRunning { process.terminate() }
            let limit = Date().addingTimeInterval(2)
            while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        while process.isRunning {
            if cancellation.isCancelled { stop(); throw SoundCloudError.cancelled }
            if Date() > deadline {
                stop()
                throw SoundCloudError.message("SoundCloud долго не отвечает. Проверь соединение и попробуй снова.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            let lower = detail.lowercased()
            if lower.contains("drm") || lower.contains("not available") || lower.contains("private") || lower.contains("403") {
                throw SoundCloudError.message("SoundCloud не предоставил доступ к этому треку. Он может быть закрыт, ограничен или недоступен для твоего подключения.")
            }
            let summary = detail.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Неизвестная ошибка"
            throw SoundCloudError.message(String(summary.prefix(600)))
        }
        return try Data(contentsOf: outputURL)
    }
}
