import Foundation
import Darwin

struct YouTubeTrack: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    var url: URL { URL(string: "https://www.youtube.com/watch?v=" + id)! }
    var duration: Double?
    var fallbackEndpoint: URL?
    var album: String?
    var year: Int?
    var durationLabel: String {
        guard let duration, duration.isFinite, duration >= 0 else { return "" }
        let seconds = Int(min(duration, 864_000))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// M4A keeps YouTube's AAC stream as is; MP3 re-encodes for players that need it.
enum YouTubeAudioFormat: String, CaseIterable, Identifiable {
    case m4a, mp3
    static let defaultsKey = "YouTubeAudioFormat"
    static var stored: YouTubeAudioFormat {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .m4a
    }
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var selector: String { self == .m4a ? "bestaudio[ext=m4a]/bestaudio/best" : "bestaudio/best" }
}

/// When the extractor is slow, the fallback starts alongside it after this delay.
/// Turned off, the fallback is used only after the extractor fails.
enum YouTubeFallbackRace {
    static let defaultsKey = "YouTubeFallbackRace"
    static var storedDelay: TimeInterval? {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool == false ? nil : 5
    }
}

/// Everything one extractor run learns about a video, reused by the download.
struct YouTubeMediaInfo {
    let track: YouTubeTrack
    let json: Data
    let audioURL: URL?
    let headers: [String: String]
    let fileExtension: String?
    let contentLength: Int?
}

protocol YouTubeProviding {
    /// A quick title card before the full check; nil when unavailable.
    func preview(_ input: String, cancellation: SoundCloudCancellation) -> YouTubeTrack?
    func resolve(_ input: String, cancellation: SoundCloudCancellation) throws -> YouTubeTrack
    func download(_ track: YouTubeTrack, directory: URL, cancellation: SoundCloudCancellation,
                  stage: @escaping (String) -> Void) throws -> URL
    /// Like `download`, also reporting the fraction transferred once the size is known.
    func download(_ track: YouTubeTrack, directory: URL, cancellation: SoundCloudCancellation,
                  stage: @escaping (String) -> Void, progress: @escaping (Double) -> Void) throws -> URL
}

extension YouTubeProviding {
    func preview(_ input: String, cancellation: SoundCloudCancellation) -> YouTubeTrack? { nil }
    func download(_ track: YouTubeTrack, directory: URL, cancellation: SoundCloudCancellation,
                  stage: @escaping (String) -> Void, progress: @escaping (Double) -> Void) throws -> URL {
        try download(track, directory: directory, cancellation: cancellation, stage: stage)
    }
}

final class YouTubeService: YouTubeProviding {
    let helper: URL
    let ffmpeg: URL?
    let runtime: URL
    let cache: URL
    private let routeLock = NSLock()
    private var directUnavailableUntil = Date.distantPast
    private var infos: [String: (date: Date, info: YouTubeMediaInfo)] = [:]
    private var extracting: [String: DispatchGroup] = [:]
    private let fallback: YouTubeFallback?
    private let format: () -> YouTubeAudioFormat
    private let transferConfiguration: URLSessionConfiguration?
    private let raceDelay: () -> TimeInterval?
    private let artwork: (([URL], SoundCloudCancellation) -> Data?)?
    /// `artwork` loads cover art for tagging; without it files get no picture.
    init(helper: URL? = nil, ffmpeg: URL? = nil, runtime: URL? = nil, cache: URL? = nil,
         fallback: YouTubeFallback? = YouTubeFallback(), format: @escaping () -> YouTubeAudioFormat = { .stored },
         transferConfiguration: URLSessionConfiguration? = nil,
         raceDelay: @escaping () -> TimeInterval? = { YouTubeFallbackRace.storedDelay },
         artwork: (([URL], SoundCloudCancellation) -> Data?)? = nil) {
        self.artwork = artwork
        self.fallback = fallback
        self.format = format
        self.transferConfiguration = transferConfiguration
        self.raceDelay = raceDelay
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        self.helper = helper ?? FileTools.extractor(in: resources)
        self.ffmpeg = FileTools.ffmpeg(ffmpeg)
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

    /// oEmbed answers with the title and channel in a fraction of an extractor run.
    static func parsePreview(_ data: Data, expectedID: String) throws -> YouTubeTrack {
        guard data.count <= 100_000, let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = item["title"] as? String, !title.isEmpty else {
            throw DropError.message("Не удалось получить название видео YouTube.")
        }
        func clean(_ text: String) -> String {
            String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        }
        let tags = TrackMetadata.youTube(title: clean(title), channel: clean(item["author_name"] as? String ?? ""), artist: nil, track: nil)
        return YouTubeTrack(id: expectedID, title: tags.title, artist: tags.artist)
    }

    static func isGoogleVideo(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".googlevideo.com")
    }

    /// The extractor's JSON already names the selected stream; a plain HTTPS one can be fetched directly.
    static func parseInfo(_ data: Data, expectedID: String) throws -> YouTubeMediaInfo {
        let track = try parseTrack(data, expectedID: expectedID)
        let item = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        var audioURL: URL?
        if item["protocol"] as? String == "https", let raw = item["url"] as? String, let url = URL(string: raw),
           isGoogleVideo(url), url.path == "/videoplayback" {
            audioURL = url
        }
        let allowed: Set<String> = ["m4a", "webm", "mp4", "opus", "ogg", "mp3", "aac"]
        let ext = (item["ext"] as? String)?.lowercased()
        var headers: [String: String] = [:]
        for (key, value) in item["http_headers"] as? [String: String] ?? [:]
        where !["cookie", "authorization"].contains(key.lowercased()) && value.count < 2_000 && !value.contains("\n") {
            headers[key] = value
        }
        let clen = audioURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "clen" }?.value }
        let length = (item["filesize"] as? Int) ?? clen.flatMap(Int.init)
        return YouTubeMediaInfo(track: track, json: data, audioURL: audioURL, headers: headers,
                                fileExtension: ext.flatMap { allowed.contains($0) ? $0 : nil },
                                contentLength: length.flatMap { $0 > 0 ? $0 : nil })
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
        // yt-dlp names the artist and song for music uploads; otherwise the title and channel are read.
        let artist = (item["artist"] as? String) ?? (item["artists"] as? [String])?.joined(separator: ", ") ?? (item["creator"] as? String)
        let tags = TrackMetadata.youTube(title: clean(title), channel: clean((item["channel"] as? String) ?? (item["uploader"] as? String) ?? ""),
                                         artist: artist.map(clean), track: (item["track"] as? String).map(clean))
        return YouTubeTrack(id: expectedID, title: tags.title, artist: tags.artist, duration: item["duration"] as? Double,
                            album: (item["album"] as? String).map(clean)?.nonEmpty,
                            year: TrackMetadata.year(item["release_year"] ?? item["release_date"] ?? item["upload_date"]))
    }

    private var arguments: [String] {
        ["--ignore-config", "--no-plugin-dirs", "--no-playlist", "--no-warnings", "--no-progress",
         "--socket-timeout", "10", "--retries", "1", "--fragment-retries", "2", "--extractor-retries", "1",
         "--cache-dir", cache.path, "--js-runtimes", "deno:" + runtime.path]
    }
    static let ffmpegNeeded = "Для MP3 нужен FFmpeg: установи его командой brew install ffmpeg или выбери M4A в настройках Music Drop."

    private func validateTools(needsEncoder: Bool) throws {
        guard FileManager.default.isExecutableFile(atPath: helper.path), FileManager.default.isExecutableFile(atPath: runtime.path) else {
            throw DropError.message("Компонент YouTube не найден. Переустанови Music Drop из нового DMG.")
        }
        if needsEncoder && ffmpeg == nil { throw DropError.message(Self.ffmpegNeeded) }
    }
    func preview(_ input: String, cancellation: SoundCloudCancellation) -> YouTubeTrack? {
        guard let id = try? Self.videoID(input) else { return nil }
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=" + id),
                                 URLQueryItem(name: "format", value: "json")]
        let request = URLRequest(url: components.url!)
        return try? BoundedFetch.with(allowed: { $0.scheme == "https" && $0.host?.lowercased() == "www.youtube.com" }) { fetch in
            let (data, _) = try fetch.data(request, cancellation: cancellation, maximumBytes: 100_000, timeout: 4) {
                $0.contains("json") || $0.hasPrefix("text/")
            }
            return try Self.parsePreview(data, expectedID: id)
        }
    }

    func resolve(_ input: String, cancellation: SoundCloudCancellation) throws -> YouTubeTrack {
        let id = try Self.videoID(input)
        let format = self.format()
        routeLock.lock(); let directAvailable = Date() >= directUnavailableUntil; routeLock.unlock()
        if directAvailable, let fallback, let delay = raceDelay() {
            return try race(id, format: format, delay: delay, fallback: fallback, cancellation: cancellation)
        }
        if directAvailable || fallback == nil {
            do {
                return try mediaInfo(id, format: format, refresh: false, cancellation: cancellation).info.track
            } catch {
                if cancellation.isCancelled { throw SoundCloudError.cancelled }
                guard fallback != nil else { throw error }
                routeLock.lock(); directUnavailableUntil = Date().addingTimeInterval(900); routeLock.unlock()
            }
        }
        guard let fallback else { throw DropError.message("YouTube сейчас не предоставляет аудио без входа.") }
        return try fallback.resolve(id, cancellation: cancellation, preferAAC: format == .m4a).track
    }

    /// The extractor starts first; if it is still busy after `delay`, the fallback runs alongside
    /// and the first usable answer wins. An extractor failure still switches routes for a while.
    private func race(_ id: String, format: YouTubeAudioFormat, delay: TimeInterval, fallback: YouTubeFallback,
                      cancellation: SoundCloudCancellation) throws -> YouTubeTrack {
        final class Outcome {
            let lock = NSLock()
            let changed = DispatchSemaphore(value: 0)
            var track: YouTubeTrack?
            var directError: Error?, fallbackError: Error?
            var fallbackStarted = false
        }
        let outcome = Outcome()
        let direct = SoundCloudCancellation(), relay = SoundCloudCancellation()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let track = try self.mediaInfo(id, format: format, refresh: false, cancellation: direct).info.track
                outcome.lock.lock(); if outcome.track == nil { outcome.track = track }; outcome.lock.unlock()
            } catch {
                if !direct.isCancelled {
                    self.routeLock.lock(); self.directUnavailableUntil = Date().addingTimeInterval(900); self.routeLock.unlock()
                }
                outcome.lock.lock(); outcome.directError = error; outcome.lock.unlock()
            }
            outcome.changed.signal()
        }
        let started = Date()
        while true {
            if cancellation.isCancelled { direct.cancel(); relay.cancel(); throw SoundCloudError.cancelled }
            outcome.lock.lock()
            if let track = outcome.track {
                outcome.lock.unlock()
                if track.fallbackEndpoint == nil { relay.cancel() } else { direct.cancel() }
                return track
            }
            if outcome.directError != nil, let error = outcome.fallbackError { outcome.lock.unlock(); throw error }
            let shouldStart = !outcome.fallbackStarted && (outcome.directError != nil || Date().timeIntervalSince(started) >= delay)
            if shouldStart { outcome.fallbackStarted = true }
            outcome.lock.unlock()
            if shouldStart {
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let track = try fallback.resolve(id, cancellation: relay, preferAAC: format == .m4a).track
                        outcome.lock.lock(); if outcome.track == nil { outcome.track = track }; outcome.lock.unlock()
                    } catch {
                        outcome.lock.lock(); outcome.fallbackError = error; outcome.lock.unlock()
                    }
                    outcome.changed.signal()
                }
            }
            _ = outcome.changed.wait(timeout: .now() + 0.05)
        }
    }

    /// One extractor run per video: the check and the later download share its result,
    /// and a download started during the check waits for it instead of extracting again.
    private func mediaInfo(_ id: String, format: YouTubeAudioFormat, refresh: Bool,
                           cancellation: SoundCloudCancellation) throws -> (info: YouTubeMediaInfo, cached: Bool) {
        let key = id + "|" + format.rawValue
        let started = Date()
        while true {
            if cancellation.isCancelled { throw SoundCloudError.cancelled }
            routeLock.lock()
            if let entry = infos[key], Date().timeIntervalSince(entry.date) < 1_800, !refresh || entry.date >= started {
                routeLock.unlock()
                return (entry.info, entry.date < started)
            }
            if let running = extracting[key] {
                routeLock.unlock()
                while running.wait(timeout: .now() + 0.1) == .timedOut {
                    if cancellation.isCancelled { throw SoundCloudError.cancelled }
                }
                routeLock.lock()
                let finished = infos[key].map { $0.date >= started } ?? false
                routeLock.unlock()
                // The other run failed; report that instead of starting a second slow attempt.
                guard finished else { throw DropError.message("YouTube не предоставил сведения о видео.") }
                continue
            }
            let group = DispatchGroup()
            group.enter()
            extracting[key] = group
            routeLock.unlock()
            defer {
                routeLock.lock(); extracting[key] = nil; routeLock.unlock()
                group.leave()
            }
            try validateTools(needsEncoder: false)
            let data = try run(helper, arguments: arguments + ["-f", format.selector, "--skip-download", "--dump-single-json",
                                                             "--", "https://www.youtube.com/watch?v=" + id],
                               cancellation: cancellation, timeout: 30)
            let info = try Self.parseInfo(data, expectedID: id)
            routeLock.lock()
            infos = infos.filter { Date().timeIntervalSince($0.value.date) < 1_800 }
            if infos.count >= 30, let oldest = infos.min(by: { $0.value.date < $1.value.date })?.key { infos[oldest] = nil }
            infos[key] = (Date(), info)
            routeLock.unlock()
            return (info, false)
        }
    }

    func download(_ track: YouTubeTrack, directory: URL, cancellation: SoundCloudCancellation,
                  stage: @escaping (String) -> Void) throws -> URL {
        try download(track, directory: directory, cancellation: cancellation, stage: stage, progress: { _ in })
    }

    func download(_ track: YouTubeTrack, directory: URL, cancellation: SoundCloudCancellation,
                  stage: @escaping (String) -> Void, progress: @escaping (Double) -> Void) throws -> URL {
        _ = try Self.videoID(track.url.absoluteString)
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        let format = self.format()
        // M4A from AAC needs only AVFoundation; MP3 always needs the encoder.
        if format == .mp3, ffmpeg == nil { throw DropError.message(Self.ffmpegNeeded) }
        let working = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: working) } }
        // The cover downloads alongside the audio and is ready by the time the file is tagged.
        let cover = artwork.map { load in PendingResult { load(CoverArt.youTubeURLs(track.id), cancellation) } }
        let source: URL
        if let endpoint = track.fallbackEndpoint {
            guard let fallback, endpoint == fallback.endpoint else { throw DropError.message("Неизвестный резервный сервис.") }
            source = try fallback.download(track.id, directory: working, cancellation: cancellation, stage: stage,
                                           preferAAC: format == .m4a)
        } else {
            do {
                try validateTools(needsEncoder: false)
                source = try directSource(track.id, format: format, working: working, cancellation: cancellation,
                                          stage: stage, progress: progress)
            } catch {
                if cancellation.isCancelled { throw SoundCloudError.cancelled }
                guard let fallback else { throw error }
                stage("Пробуем резервную загрузку без входа…")
                source = try fallback.download(track.id, directory: working, cancellation: cancellation, stage: stage,
                                               preferAAC: format == .m4a)
            }
        }
        try FileTools.validate(source, allowedExtensions: ["m4a", "webm", "mp4", "opus", "ogg", "mp3", "aac"])
        // The extractor's metadata is fuller than a quick card's, so it wins when it is known.
        let described = describedTrack(track, format: format)
        let tags = AudioTags(title: described.title, artist: described.artist, album: described.album ?? described.title,
                             comment: track.url.absoluteString, year: described.year, artwork: cover?.value(waiting: 5))
        let prepared = try prepare(source, track: track, format: format, working: working, ffmpeg: ffmpeg, tags: tags,
                                   cancellation: cancellation, stage: stage)
        try FileTools.validate(prepared, allowedExtensions: ["mp3", "m4a"])
        let size = try prepared.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 200_000_000 else { throw DropError.message("Аудио превышает ограничение облачной медиатеки 200 МБ.") }
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        try? FileManager.default.removeItem(at: source)
        success = true
        return prepared
    }

    /// Prefers the stream URL from the earlier check; yt-dlp then reuses the same JSON
    /// instead of contacting YouTube again. A stale cached result is refreshed once.
    private func directSource(_ id: String, format: YouTubeAudioFormat, working: URL, cancellation: SoundCloudCancellation,
                              stage: @escaping (String) -> Void, progress: @escaping (Double) -> Void) throws -> URL {
        var lastError: Error?
        for attempt in 0...1 {
            let (info, cached) = try mediaInfo(id, format: format, refresh: attempt > 0, cancellation: cancellation)
            stage("Скачиваем аудио с YouTube…")
            if info.audioURL != nil, let ext = info.fileExtension {
                let target = working.appendingPathComponent("audio." + ext)
                do {
                    try fetchDirect(info, to: target, cancellation: cancellation, progress: progress)
                    return target
                } catch {
                    if cancellation.isCancelled { throw SoundCloudError.cancelled }
                    try? FileManager.default.removeItem(at: target)
                    lastError = error
                }
            }
            do {
                return try downloadWithInfo(info, format: format, working: working, cancellation: cancellation, progress: progress)
            } catch {
                if cancellation.isCancelled { throw SoundCloudError.cancelled }
                lastError = error
                guard cached else { throw error }
            }
        }
        throw lastError ?? DropError.message("YouTube не вернул аудиофайл.")
    }

    /// Splits a known-size stream into ranges fetched in parallel, each within YouTube's chunk size.
    private func fetchDirect(_ info: YouTubeMediaInfo, to destination: URL, cancellation: SoundCloudCancellation,
                             progress: @escaping (Double) -> Void) throws {
        guard let url = info.audioURL, let total = info.contentLength else {
            throw DropError.message("Размер аудио YouTube неизвестен.")
        }
        guard total <= 200_000_000 else { throw DropError.message("Аудио превышает ограничение 200 МБ.") }
        let ranges = Self.ranges(total: total)
        var reported = 0
        let lock = NSLock()
        try BoundedFetch.with(allowed: Self.isGoogleVideo, configuration: transferConfiguration ?? .ephemeral) { fetch in
            try ParallelDownload.run(count: ranges.count, concurrency: 4, destination: destination, maximumBytes: 200_000_000,
                                     cancellation: cancellation, progress: { done, all in
                lock.lock(); defer { lock.unlock() }
                guard done > reported else { return }
                reported = done
                progress(Double(done) / Double(max(1, all)))
            }) { index in
                let range = ranges[index]
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                for (key, value) in info.headers { request.setValue(value, forHTTPHeaderField: key) }
                request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
                let (data, _) = try fetch.data(request, cancellation: cancellation, maximumBytes: range.count, timeout: 30) {
                    $0.hasPrefix("audio/") || $0.hasPrefix("video/") || $0 == "application/octet-stream"
                }
                guard data.count == range.count else { throw DropError.message("YouTube вернул неполный фрагмент аудио.") }
                return data
            }
        }
    }

    /// Up to four parts for typical tracks, never more than YouTube's 10 MB chunk each.
    static func ranges(total: Int) -> [ClosedRange<Int>] {
        guard total > 0 else { return [] }
        let partSize = min(10_485_760, max(1_048_576, (total + 3) / 4))
        return stride(from: 0, to: total, by: partSize).map { $0...min(total, $0 + partSize) - 1 }
    }

    private func downloadWithInfo(_ info: YouTubeMediaInfo, format: YouTubeAudioFormat, working: URL,
                                  cancellation: SoundCloudCancellation, progress: @escaping (Double) -> Void) throws -> URL {
        let infoFile = working.appendingPathComponent("info.json")
        try info.json.write(to: infoFile)
        defer { try? FileManager.default.removeItem(at: infoFile) }
        let output = try run(helper, arguments: arguments.filter { $0 != "--no-progress" } + ProgressTail.arguments + [
            "--load-info-json", infoFile.path, "-f", format.selector, "--concurrent-fragments", "4", "--max-filesize", "200M",
            "--no-simulate", "--print", "after_move:filepath", "-o", working.appendingPathComponent("audio.%(ext)s").path
        ], cancellation: cancellation, timeout: 900, progress: progress)
        let path = String(data: output, encoding: .utf8)?.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let downloaded = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard downloaded.path.hasPrefix(working.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
            throw DropError.message("YouTube не вернул аудиофайл.")
        }
        return downloaded
    }

    private func describedTrack(_ track: YouTubeTrack, format: YouTubeAudioFormat) -> YouTubeTrack {
        routeLock.lock(); defer { routeLock.unlock() }
        return infos[track.id + "|" + format.rawValue]?.info.track ?? track
    }

    private func prepare(_ source: URL, track: YouTubeTrack, format: YouTubeAudioFormat, working: URL, ffmpeg: URL?, tags: AudioTags,
                         cancellation: SoundCloudCancellation, stage: @escaping (String) -> Void) throws -> URL {
        let cover = tags.coverFile(in: working)
        let preparedDirectory = working.appendingPathComponent("Prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: preparedDirectory, withIntermediateDirectories: true)
        let cleaned = track.title.unicodeScalars.map { "/:\0".unicodeScalars.contains($0) ? "_" : String($0) }.joined()
        var name = ""
        for c in cleaned { if (name + String(c)).utf8.count > 180 { break }; name.append(c) }
        let base = name.isEmpty ? "YouTube" : name
        if format == .mp3 {
            guard let ffmpeg else { throw DropError.message(Self.ffmpegNeeded) }
            stage("Сохраняем MP3…")
            let prepared = preparedDirectory.appendingPathComponent(base + ".mp3")
            _ = try run(ffmpeg, arguments: Self.encodeArguments(source: source, output: prepared, track: track, tags: tags, cover: cover),
                        cancellation: cancellation, timeout: 300)
            return prepared
        }
        let prepared = preparedDirectory.appendingPathComponent(base + ".m4a")
        if ["m4a", "mp4", "aac"].contains(source.pathExtension.lowercased()) {
            stage("Сохраняем M4A без перекодирования…")
            do {
                try AudioRemux.m4a(from: source, to: prepared, tags: tags, cancellation: cancellation)
                return prepared
            } catch {
                if cancellation.isCancelled { throw SoundCloudError.cancelled }
            }
            if let ffmpeg {
                do {
                    _ = try run(ffmpeg, arguments: Self.m4aArguments(source: source, output: prepared, track: track, codec: ["-c:a", "copy"],
                                                                     tags: tags, cover: cover),
                                cancellation: cancellation, timeout: 300)
                    return prepared
                } catch {
                    if cancellation.isCancelled { throw SoundCloudError.cancelled }
                }
            }
        }
        guard let ffmpeg else {
            throw DropError.message("Для этого видео YouTube отдаёт только Opus; чтобы сохранить его в M4A, нужен FFmpeg (brew install ffmpeg).")
        }
        stage("Сохраняем M4A…")
        do {
            // AudioToolbox is Apple's own AAC encoder: fast and transparent at this bitrate.
            _ = try run(ffmpeg, arguments: Self.m4aArguments(source: source, output: prepared, track: track,
                                                             codec: ["-c:a", "aac_at", "-b:a", "256k"], tags: tags, cover: cover),
                        cancellation: cancellation, timeout: 300)
        } catch {
            if cancellation.isCancelled { throw SoundCloudError.cancelled }
            _ = try run(ffmpeg, arguments: Self.m4aArguments(source: source, output: prepared, track: track,
                                                             codec: ["-c:a", "aac", "-b:a", "256k"], tags: tags, cover: cover),
                        cancellation: cancellation, timeout: 300)
        }
        return prepared
    }

    static func tags(for track: YouTubeTrack) -> AudioTags {
        AudioTags(title: track.title, artist: track.artist, album: track.album ?? track.title,
                  comment: track.url.absoluteString, year: track.year)
    }

    static func m4aArguments(source: URL, output: URL, track: YouTubeTrack, codec: [String],
                             tags: AudioTags? = nil, cover: URL? = nil) -> [String] {
        let tagArguments = (tags ?? Self.tags(for: track)).ffmpegArguments(cover: cover)
        var arguments: [String] = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path]
        arguments += tagArguments.inputs
        arguments += ["-map", "0:a:0"] + codec + ["-fs", "200000001"]
        arguments += tagArguments.outputs
        return arguments + [output.path]
    }

    static func encodeArguments(source: URL, output: URL, track: YouTubeTrack, tags: AudioTags? = nil, cover: URL? = nil) -> [String] {
        let tagArguments = (tags ?? Self.tags(for: track)).ffmpegArguments(cover: cover)
        var arguments: [String] = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path]
        arguments += tagArguments.inputs
        arguments += ["-map", "0:a:0", "-c:a", "libmp3lame", "-q:a", "2", "-id3v2_version", "3", "-fs", "200000001"]
        arguments += tagArguments.outputs
        return arguments + [output.path]
    }

    /// Output files avoid deadlocks; arguments never pass through a shell.
    private func run(_ executable: URL, arguments: [String], cancellation: SoundCloudCancellation, timeout: TimeInterval,
                     progress: ((Double) -> Void)? = nil) throws -> Data {
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
        let tail = progress.map { ProgressTail(files: [outputURL, errorURL], report: $0) }
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
            tail?.poll()
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
