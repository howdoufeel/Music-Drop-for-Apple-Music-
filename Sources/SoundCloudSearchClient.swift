import Foundation

struct SoundCloudAudioSource {
    let url: URL
    let fileExtension: String
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
            var streamURL = URLComponents(url: candidate.url, resolvingAgainstBaseURL: false)!
            streamURL.queryItems = (streamURL.queryItems ?? []).filter { !["client_id", "track_authorization"].contains($0.name) }
                + [URLQueryItem(name: "client_id", value: clientID)]
            if let authorization = root["track_authorization"] as? String {
                streamURL.queryItems?.append(URLQueryItem(name: "track_authorization", value: authorization))
            }
            let (streamData, streamResponse) = try request(streamURL.url!, cancellation: cancellation)
            if streamResponse.statusCode == 429 { throw SoundCloudError.rateLimited }
            guard streamResponse.statusCode == 200,
                  let stream = try JSONSerialization.jsonObject(with: streamData) as? [String: Any],
                  let rawURL = stream["url"] as? String, let url = URL(string: rawURL), Self.isMediaURL(url) else { return nil }
            return SoundCloudAudioSource(url: url, fileExtension: candidate.fileExtension)
        }
        return nil
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
            candidates.append((SoundCloudAudioSource(url: url, fileExtension: ext), score))
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
        return try SoundCloudService.parseTracks(JSONSerialization.data(withJSONObject: ["entries": normalized]))
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
        var partialAssets: [URL] = []
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
        for url in candidates {
            if cancellation.isCancelled { throw SoundCloudError.cancelled }
            guard Date() < deadline else { break }
            let data: Data, response: HTTPURLResponse
            do { (data, response) = try request(url, timeout: 4, range: "bytes=0-65535", cancellation: cancellation) }
            catch { if cancellation.isCancelled { throw SoundCloudError.cancelled }; continue }
            if let value = readID(data) { return save(value) }
            if response.statusCode == 206 { partialAssets.append(url) }
        }
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
