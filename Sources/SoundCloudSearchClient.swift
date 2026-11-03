import Foundation

struct SoundCloudAudioSource {
    let url: URL
    let fileExtension: String
    var isHLS = false
}

/// A stream for listening in the app; `isClip` marks SoundCloud's 30-second preview of a restricted track.
struct SoundCloudPreview: Equatable {
    let url: URL
    let isClip: Bool
}

/// A media playlist reduced to the parts the native downloader can join byte for byte.
struct HLSPlaylist {
    var initSegment: URL?
    var segments: [URL] = []
    var variants: [(url: URL, bandwidth: Int)] = []
}

/// Search uses only listing metadata. Audio extraction is deferred until Add.
final class SoundCloudSearchClient {
    typealias Transport = (URLRequest, SoundCloudCancellation) throws -> (Data, HTTPURLResponse)
    private let session: URLSession
    private let cache: URL
    private let transport: Transport?
    private let credentialLock = NSLock()
    private var publicClientID: String?

    init(cache: URL, clientID: String? = nil, transport: Transport? = nil) {
        self.cache = cache
        self.transport = transport
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 25
        session = URLSession(configuration: configuration)
        publicClientID = clientID
        if publicClientID == nil {
            // Reuse the public website identifier already cached by the download helper.
            for path in ["public-client.json", "soundcloud/client_id.json"] {
                if let data = try? Data(contentsOf: cache.appendingPathComponent(path)),
                   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = root["data"] as? String, Self.isClientID(value) {
                    publicClientID = value
                    break
                }
            }
        }
    }

    func search(_ target: String, cancellation: SoundCloudCancellation) throws -> [SoundCloudTrack] {
        var endpoint = "search/tracks"
        var query: [URLQueryItem]
        if target.hasPrefix("scsearch15:") {
            query = [URLQueryItem(name: "q", value: String(target.dropFirst("scsearch15:".count))),
                     URLQueryItem(name: "limit", value: "15"), URLQueryItem(name: "offset", value: "0")]
        } else {
            guard let url = URL(string: target) else { throw SoundCloudError.message("Не удалось прочитать ссылку.") }
            var canonical = url
            if url.host?.lowercased() == "on.soundcloud.com" {
                let (_, response) = try request(url, method: "HEAD", cancellation: cancellation)
                guard (200..<400).contains(response.statusCode), let resolved = response.url,
                      ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"].contains(resolved.host?.lowercased() ?? ""),
                      !(try SoundCloudService.searchTarget(resolved.absoluteString)).hasPrefix("scsearch") else {
                    throw SoundCloudError.message("Не удалось раскрыть короткую ссылку SoundCloud. Вставь полную ссылку на трек.")
                }
                canonical = resolved
            }
            endpoint = "resolve"
            query = [URLQueryItem(name: "url", value: canonical.absoluteString)]
        }
        for attempt in 0...1 {
            let clientID = try credential(refresh: attempt > 0, cancellation: cancellation)
            var components = URLComponents(string: "https://api-v2.soundcloud.com/" + endpoint)!
            components.queryItems = query + [URLQueryItem(name: "client_id", value: clientID)]
            let (data, response) = try request(components.url!, cancellation: cancellation)
            if [401, 403].contains(response.statusCode), attempt == 0 { continue }
            if response.statusCode == 429 {
                throw SoundCloudError.message("SoundCloud временно ограничил частоту запросов. Подожди немного и повтори поиск.")
            }
            guard response.statusCode == 200 else {
                throw SoundCloudError.message("Поиск SoundCloud недоступен (\(response.statusCode)). Попробуй ещё раз.")
            }
            return try Self.parse(data)
        }
        return []
    }

    /// Resolve only the selected compatible stream; no audio process or artwork probes.
    func audioStream(for track: SoundCloudTrack, cancellation: SoundCloudCancellation) throws -> SoundCloudAudioSource? {
        guard track.id.range(of: "^[0-9]+$", options: .regularExpression) != nil else { return nil }
        if let hint = track.stream {
            // Search results already list the streams; a stale authorization falls back to fresh metadata.
            let clientID = try credential(refresh: false, cancellation: cancellation)
            if let source = try resolveStream(hint.transcoding, fileExtension: hint.fileExtension, isHLS: hint.isHLS,
                                              authorization: hint.authorization, clientID: clientID, cancellation: cancellation) {
                return source
            }
        }
        for attempt in 0...1 {
            let clientID = try credential(refresh: attempt > 0, cancellation: cancellation)
            var metadataURL = URLComponents(string: "https://api-v2.soundcloud.com/tracks/" + track.id)!
            metadataURL.queryItems = [URLQueryItem(name: "client_id", value: clientID)]
            let (data, response) = try request(metadataURL.url!, cancellation: cancellation)
            if response.statusCode == 429 { throw SoundCloudError.rateLimited }
            if [401, 403].contains(response.statusCode), attempt == 0 { continue }
            guard response.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["id"] as? NSNumber)?.stringValue == track.id || root["id"] as? String == track.id,
                  let candidate = Self.nativeCandidate(root) else { return nil }
            return try resolveStream(candidate.url, fileExtension: candidate.fileExtension, isHLS: candidate.isHLS,
                                     authorization: root["track_authorization"] as? String, clientID: clientID, cancellation: cancellation)
        }
        return nil
    }

    /// Listening needs only the signed stream; AVFoundation plays the HLS playlist itself.
    func previewStream(for track: SoundCloudTrack, cancellation: SoundCloudCancellation) throws -> SoundCloudPreview? {
        guard track.id.range(of: "^[0-9]+$", options: .regularExpression) != nil else { return nil }
        if let hint = track.stream {
            let clientID = try credential(refresh: false, cancellation: cancellation)
            if let source = try resolveStream(hint.transcoding, fileExtension: hint.fileExtension, isHLS: hint.isHLS,
                                              authorization: hint.authorization, clientID: clientID, cancellation: cancellation) {
                return SoundCloudPreview(url: source.url, isClip: false)
            }
        }
        for attempt in 0...1 {
            let clientID = try credential(refresh: attempt > 0, cancellation: cancellation)
            var metadataURL = URLComponents(string: "https://api-v2.soundcloud.com/tracks/" + track.id)!
            metadataURL.queryItems = [URLQueryItem(name: "client_id", value: clientID)]
            let (data, response) = try request(metadataURL.url!, cancellation: cancellation)
            if response.statusCode == 429 { throw SoundCloudError.rateLimited }
            if [401, 403].contains(response.statusCode), attempt == 0 { continue }
            guard response.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (root["id"] as? NSNumber)?.stringValue == track.id || root["id"] as? String == track.id,
                  let candidate = Self.previewCandidate(root),
                  let source = try resolveStream(candidate.source.url, fileExtension: candidate.source.fileExtension,
                                                 isHLS: candidate.source.isHLS, authorization: root["track_authorization"] as? String,
                                                 clientID: clientID, cancellation: cancellation) else { return nil }
            return SoundCloudPreview(url: source.url, isClip: candidate.isClip)
        }
        return nil
    }

    /// Unlike downloads, listening accepts a preview clip and tracks with original downloads.
    /// AVFoundation plays AAC and MP3 over HLS or plain HTTPS, but not the encrypted variants.
    static func previewCandidate(_ root: [String: Any]) -> (source: SoundCloudAudioSource, isClip: Bool)? {
        guard root["kind"] as? String == "track", root["policy"] as? String != "BLOCK",
              let media = root["media"] as? [String: Any], let transcodings = media["transcodings"] as? [[String: Any]] else { return nil }
        var best: (source: SoundCloudAudioSource, isClip: Bool, score: Int)?
        for item in transcodings {
            guard let format = item["format"] as? [String: Any], let transport = format["protocol"] as? String,
                  ["hls", "progressive"].contains(transport), let preset = item["preset"] as? String,
                  preset.hasPrefix("aac_") || preset.hasPrefix("mp3_"),
                  let rawURL = item["url"] as? String, let url = URL(string: rawURL), isMediaURL(url),
                  url.host?.lowercased() == "api-v2.soundcloud.com" else { continue }
            let clip = item["snipped"] as? Bool == true
            let aac = preset.hasPrefix("aac_")
            let score = (clip ? 0 : 100) + (aac ? 10 : 0) + (item["quality"] as? String == "hq" ? 5 : 0) + (transport == "hls" ? 1 : 0)
            guard score > best?.score ?? -1 else { continue }
            best = (SoundCloudAudioSource(url: url, fileExtension: aac ? "m4a" : "mp3", isHLS: transport == "hls"), clip, score)
        }
        return best.map { ($0.source, $0.isClip) }
    }

    /// Exchanges a transcoding endpoint for the signed media URL.
    private func resolveStream(_ transcoding: URL, fileExtension: String, isHLS: Bool, authorization: String?, clientID: String,
                               cancellation: SoundCloudCancellation) throws -> SoundCloudAudioSource? {
        var streamURL = URLComponents(url: transcoding, resolvingAgainstBaseURL: false)!
        streamURL.queryItems = (streamURL.queryItems ?? []).filter { !["client_id", "track_authorization"].contains($0.name) }
            + [URLQueryItem(name: "client_id", value: clientID)]
        if let authorization {
            streamURL.queryItems?.append(URLQueryItem(name: "track_authorization", value: authorization))
        }
        let (streamData, streamResponse) = try request(streamURL.url!, cancellation: cancellation)
        if streamResponse.statusCode == 429 { throw SoundCloudError.rateLimited }
        guard streamResponse.statusCode == 200,
              let stream = (try? JSONSerialization.jsonObject(with: streamData)) as? [String: Any],
              let rawURL = stream["url"] as? String, let url = URL(string: rawURL), Self.isMediaURL(url) else { return nil }
        return SoundCloudAudioSource(url: url, fileExtension: fileExtension, isHLS: isHLS)
    }

    /// Opens the connection ahead of the first search and, on a fresh install,
    /// discovers the public identifier before anyone waits for it.
    func prewarm() {
        let token = SoundCloudCancellation()
        credentialLock.lock(); let cached = publicClientID; credentialLock.unlock()
        if cached == nil { _ = try? credential(refresh: false, cancellation: token) }
        _ = try? request(URL(string: "https://api-v2.soundcloud.com/")!, method: "HEAD", timeout: 5, cancellation: token)
    }

    /// SoundCloud serves full tracks as many short HLS segments. Fetching several at once
    /// avoids paying a full round trip per segment, which dominates a sequential download.
    func downloadHLS(_ playlist: URL, to destination: URL, cancellation: SoundCloudCancellation,
                     progress: @escaping (Int, Int) -> Void) throws {
        var parsed = try loadPlaylist(playlist, cancellation: cancellation)
        if parsed.segments.isEmpty, let variant = parsed.variants.max(by: { $0.bandwidth < $1.bandwidth }) {
            parsed = try loadPlaylist(variant.url, cancellation: cancellation)
        }
        guard !parsed.segments.isEmpty else { throw SoundCloudError.message("SoundCloud не отдал сегменты аудио.") }
        let parts = (parsed.initSegment.map { [$0] } ?? []) + parsed.segments
        try ParallelDownload.run(count: parts.count, concurrency: 6, destination: destination, maximumBytes: 200_000_000,
                                 cancellation: cancellation, progress: progress) { index in
            let (data, response) = try self.request(parts[index], timeout: 15, cancellation: cancellation)
            if response.statusCode == 429 { throw SoundCloudError.rateLimited }
            guard [200, 206].contains(response.statusCode), !data.isEmpty else {
                throw SoundCloudError.message("SoundCloud не отдал часть аудио (\(response.statusCode)).")
            }
            return data
        }
    }

    private func loadPlaylist(_ url: URL, cancellation: SoundCloudCancellation) throws -> HLSPlaylist {
        let (data, response) = try request(url, timeout: 10, cancellation: cancellation)
        if response.statusCode == 429 { throw SoundCloudError.rateLimited }
        guard response.statusCode == 200, data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else {
            throw SoundCloudError.message("SoundCloud не отдал список сегментов (\(response.statusCode)).")
        }
        return try Self.parsePlaylist(text, base: response.url ?? url)
    }

    /// Accepts only plain VOD playlists. Encryption, byte ranges and live lists stay with FFmpeg.
    static func parsePlaylist(_ text: String, base: URL) throws -> HLSPlaylist {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else { throw SoundCloudError.message("SoundCloud вернул непонятный список сегментов.") }
        func resolve(_ value: String) throws -> URL {
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL, isMediaURL(url) else {
                throw SoundCloudError.message("SoundCloud указал недопустимый адрес сегмента.")
            }
            return url
        }
        // Attribute lists are KEY=value pairs; quoted values may contain commas.
        func attribute(_ name: String, in list: Substring) -> String? {
            var rest = list
            while let equals = rest.firstIndex(of: "=") {
                let key = rest[..<equals].trimmingCharacters(in: .whitespaces)
                var value = rest[rest.index(after: equals)...]
                if value.hasPrefix("\"") {
                    value = value.dropFirst()
                    guard let close = value.firstIndex(of: "\"") else { return nil }
                    rest = value[value.index(after: close)...]
                    value = value[..<close]
                } else {
                    let end = value.firstIndex(of: ",") ?? value.endIndex
                    rest = value[end...]
                    value = value[..<end]
                }
                if key == name { return String(value) }
                rest = rest.drop { $0 == "," || $0 == " " }
            }
            return nil
        }
        var playlist = HLSPlaylist()
        var pendingBandwidth: Int?
        var ended = false
        for line in lines.dropFirst() {
            if line.hasPrefix("#") {
                let tag = line.split(separator: ":", maxSplits: 1)
                let attributes = tag.count > 1 ? tag[1] : ""
                switch tag[0] {
                case "#EXT-X-KEY":
                    guard attribute("METHOD", in: attributes) == "NONE" else {
                        throw SoundCloudError.message("Зашифрованный поток загружается через FFmpeg.")
                    }
                case "#EXT-X-BYTERANGE":
                    throw SoundCloudError.message("Поток с диапазонами загружается через FFmpeg.")
                case "#EXT-X-MAP":
                    guard attribute("BYTERANGE", in: attributes) == nil, playlist.initSegment == nil,
                          let uri = attribute("URI", in: attributes) else {
                        throw SoundCloudError.message("Поток с диапазонами загружается через FFmpeg.")
                    }
                    playlist.initSegment = try resolve(uri)
                case "#EXT-X-STREAM-INF":
                    pendingBandwidth = attribute("BANDWIDTH", in: attributes).flatMap(Int.init) ?? 0
                case "#EXT-X-ENDLIST":
                    ended = true
                default:
                    break
                }
                continue
            }
            if let bandwidth = pendingBandwidth {
                playlist.variants.append((try resolve(line), bandwidth))
                pendingBandwidth = nil
            } else {
                playlist.segments.append(try resolve(line))
            }
            guard playlist.segments.count + playlist.variants.count <= 10_000 else {
                throw SoundCloudError.message("Слишком длинный список сегментов.")
            }
        }
        guard playlist.segments.isEmpty || ended else {
            throw SoundCloudError.message("Незавершённый поток загружается через FFmpeg.")
        }
        return playlist
    }

    static func isMediaURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["soundcloud.com", "sndcdn.com", "soundcloud.cloud"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    static func nativeCandidate(_ root: [String: Any]) -> SoundCloudAudioSource? {
        guard root["kind"] as? String == "track", root["policy"] as? String != "BLOCK",
              !(root["downloadable"] as? Bool == true && root["has_downloads_left"] as? Bool == true),
              let media = root["media"] as? [String: Any], let transcodings = media["transcodings"] as? [[String: Any]] else { return nil }
        var candidates: [(source: SoundCloudAudioSource, score: Int)] = []
        for item in transcodings {
            guard item["snipped"] as? Bool != true, let format = item["format"] as? [String: Any],
                  let transport = format["protocol"] as? String, ["hls", "progressive"].contains(transport),
                  let preset = item["preset"] as? String else { continue }
            if preset.hasPrefix("abr_") { continue }
            // Preserve the legacy best-format selection for other codecs and original downloads.
            guard preset.hasPrefix("aac_") || preset.hasPrefix("mp3_") else { return nil }
            let mime = format["mime_type"] as? String ?? ""
            let ext: String
            if preset.hasPrefix("aac_"), mime.contains("audio/mp4") || mime.contains("audio/aac") { ext = "m4a" }
            else if preset.hasPrefix("mp3_"), mime.contains("audio/mpeg") { ext = "mp3" }
            else { return nil }
            guard let rawURL = item["url"] as? String, let url = URL(string: rawURL), isMediaURL(url),
                  url.host?.lowercased() == "api-v2.soundcloud.com" else { continue }
            let bitrate = Int(preset.split(separator: "_").last?.replacingOccurrences(of: "k", with: "") ?? "") ?? 0
            let quality = item["quality"] as? String == "hq" ? 5 : (bitrate >= 160 ? 0 : -1)
            let score = (quality + 2) * 1_000_000 + (ext == "m4a" ? 10_000 : 0)
                + min(bitrate, 1_000) * 2 + (transport == "progressive" ? 1 : 0)
            candidates.append((SoundCloudAudioSource(url: url, fileExtension: ext, isHLS: transport == "hls"), score))
        }
        return candidates.max(by: { $0.score < $1.score })?.source
    }

    static func parse(_ data: Data) throws -> [SoundCloudTrack] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SoundCloudError.message("SoundCloud вернул непонятный ответ.")
        }
        let items: [[String: Any]]
        if let collection = root["collection"] as? [[String: Any]] { items = collection }
        else if root["kind"] as? String == "track" { items = [root] }
        else { throw SoundCloudError.message("Вставь ссылку на отдельный трек SoundCloud.") }
        let normalized: [[String: Any]] = items.prefix(15).compactMap { item in
            guard item["kind"] as? String == "track" else { return nil }
            let user = item["user"] as? [String: Any] ?? [:]
            let publisher = item["publisher_metadata"] as? [String: Any] ?? [:]
            var track: [String: Any] = ["id": item["id"] ?? "", "title": item["title"] ?? "",
                                      "webpage_url": item["permalink_url"] ?? "",
                                      "uploader": user["username"] ?? "Автор не указан"]
            if let artist = publisher["artist"] as? String, !artist.isEmpty { track["artist"] = artist }
            if let milliseconds = item["duration"] as? Double { track["duration"] = milliseconds / 1000 }
            track["thumbnail"] = item["artwork_url"] as? String ?? user["avatar_url"] as? String
            return track
        }
        var hints: [String: SoundCloudStreamHint] = [:]
        for item in items.prefix(15) where item["kind"] as? String == "track" {
            let id = (item["id"] as? NSNumber)?.stringValue ?? item["id"] as? String ?? ""
            guard let candidate = nativeCandidate(item) else { continue }
            hints[id] = SoundCloudStreamHint(transcoding: candidate.url, fileExtension: candidate.fileExtension,
                                             isHLS: candidate.isHLS, authorization: item["track_authorization"] as? String)
        }
        return try SoundCloudService.parseTracks(JSONSerialization.data(withJSONObject: ["entries": normalized])).map {
            var track = $0
            track.stream = hints[track.id]
            return track
        }
    }

    private static func isClientID(_ value: String) -> Bool {
        value.range(of: "^[a-zA-Z0-9]{32}$", options: .regularExpression) != nil
    }

    private func credential(refresh: Bool, cancellation: SoundCloudCancellation) throws -> String {
        credentialLock.lock()
        let cached = publicClientID
        credentialLock.unlock()
        if let cached, !refresh { return cached }
        // SoundCloud rotates this public website identifier. Discover it from its
        // own assets instead of shipping a fixed value or requesting an account.
        let (home, response) = try request(URL(string: "https://soundcloud.com/")!, timeout: 5, cancellation: cancellation)
        guard response.statusCode == 200, let html = String(data: home, encoding: .utf8) else {
            throw SoundCloudError.message("Не удалось подключиться к поиску SoundCloud.")
        }
        let regex = try NSRegularExpression(pattern: #"<script[^>]+src=["']([^"']+)["']"#)
        let scripts = regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match -> URL? in
            guard let range = Range(match.range(at: 1), in: html), let url = URL(string: String(html[range])),
                  url.scheme == "https", let host = url.host, host.hasSuffix(".sndcdn.com") else { return nil }
            return url
        }
        let idRegex = try NSRegularExpression(pattern: #"client_id\s*:\s*"([a-zA-Z0-9]{32})""#)
        let deadline = Date().addingTimeInterval(18)
        let candidates = Array(scripts.reversed().prefix(12))
        // The website's configuration is normally at the start of its main
        // asset. A range request avoids downloading megabytes of application JS.
        func readID(_ data: Data) -> String? {
            let text = String(decoding: data, as: UTF8.self)
            guard let match = idRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        func save(_ value: String) -> String {
            credentialLock.lock(); publicClientID = value; credentialLock.unlock()
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: ["data": value]) {
                try? data.write(to: cache.appendingPathComponent("public-client.json"), options: .atomic)
            }
            return value
        }
        // Probe several scripts at once; the first that names the identifier wins.
        final class Probe {
            let lock = NSLock()
            let done = DispatchSemaphore(value: 0)
            var next = 0
            var found: String?
            var partial: [Int] = []
        }
        let probe = Probe()
        let group = DispatchGroup()
        for _ in 0..<min(6, candidates.count) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                while true {
                    probe.lock.lock()
                    guard probe.found == nil, probe.next < candidates.count, !cancellation.isCancelled, Date() < deadline else {
                        probe.lock.unlock(); return
                    }
                    let index = probe.next
                    probe.next += 1
                    probe.lock.unlock()
                    guard let reply = try? self.request(candidates[index], timeout: 4, range: "bytes=0-65535",
                                                        cancellation: cancellation) else { continue }
                    let (data, response) = reply
                    let value = readID(data)
                    probe.lock.lock()
                    if let value, probe.found == nil { probe.found = value; probe.done.signal() }
                    if value == nil, response.statusCode == 206 { probe.partial.append(index) }
                    probe.lock.unlock()
                }
            }
        }
        group.notify(queue: .global()) { probe.done.signal() }
        probe.done.wait()
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        probe.lock.lock()
        let found = probe.found
        let partialAssets = probe.partial.sorted().map { candidates[$0] }
        probe.lock.unlock()
        if let found { return save(found) }
        // If SoundCloud moves the configuration, allow a bounded full-asset fallback.
        for url in partialAssets.prefix(3) {
            if cancellation.isCancelled { throw SoundCloudError.cancelled }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            do {
                let (data, _) = try request(url, timeout: min(6, remaining), cancellation: cancellation)
                if let value = readID(data) { return save(value) }
            } catch { if cancellation.isCancelled { throw SoundCloudError.cancelled } }
        }
        throw SoundCloudError.message("Не удалось обновить подключение к поиску SoundCloud. Попробуй позже.")
    }

    private final class Reply {
        var result: Result<(Data, HTTPURLResponse), Error>?
        let ready = DispatchSemaphore(value: 0)
    }

    private func request(_ url: URL, method: String = "GET", timeout: TimeInterval = 10, range: String? = nil,
                         cancellation: SoundCloudCancellation) throws -> (Data, HTTPURLResponse) {
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        request.setValue("application/json, text/html, */*", forHTTPHeaderField: "Accept")
        if let transport { return try transport(request, cancellation) }
        let reply = Reply()
        let task = session.dataTask(with: request) { data, response, error in
            if let error { reply.result = .failure(error) }
            else if let response = response as? HTTPURLResponse { reply.result = .success((data ?? Data(), response)) }
            else { reply.result = .failure(SoundCloudError.message("Нет ответа от SoundCloud.")) }
            reply.ready.signal()
        }
        cancellation.attach(task)
        task.resume()
        let deadline = Date().addingTimeInterval(timeout + 1)
        while reply.ready.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellation.isCancelled { task.cancel(); throw SoundCloudError.cancelled }
            if Date() >= deadline {
                task.cancel()
                throw SoundCloudError.message("SoundCloud долго не отвечает. Повтори поиск.")
            }
        }
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        do { return try reply.result!.get() }
        catch { throw SoundCloudError.message("Не удалось подключиться к SoundCloud. Проверь соединение и повтори поиск.") }
    }
}
