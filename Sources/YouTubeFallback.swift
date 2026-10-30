import Foundation

struct YouTubeFallbackInfo {
    let track: YouTubeTrack
    let audioURL: URL
    let fileExtension: String
}

/// Public Invidious API; no browser storage, shared cookies or credentials.
final class YouTubeFallback {
    static let defaultEndpoint = URL(string: "https://yt.chocolatemoo53.com")!
    typealias Transport = (URLRequest, SoundCloudCancellation, Int, URL?) throws -> Data
    let endpoint: URL
    private let transport: Transport
    private let lock = NSLock()
    private var cache: [String: (Date, YouTubeFallbackInfo)] = [:]

    init(endpoint: URL = YouTubeFallback.defaultEndpoint, transport: Transport? = nil) {
        self.endpoint = endpoint
        self.transport = transport ?? { request, cancellation, limit, destination in
            try YouTubeHTTPTransfer.run(request, cancellation: cancellation, maximumBytes: limit,
                                        destination: destination, endpoint: endpoint)
        }
    }
    func resolve(_ id: String, cancellation: SoundCloudCancellation, refresh: Bool = false,
                 preferAAC: Bool = false) throws -> YouTubeFallbackInfo {
        _ = try YouTubeService.videoID("https://youtu.be/" + id)
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        let key = preferAAC ? id + "|aac" : id
        lock.lock(); let old = cache[key]; lock.unlock()
        if !refresh, let old, Date().timeIntervalSince(old.0) < 180 { return old.1 }
        var components = URLComponents(url: endpoint.appendingPathComponent("api/v1/videos/" + id), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "local", value: "true"),
            URLQueryItem(name: "fields", value: "videoId,title,author,lengthSeconds,liveNow,isUpcoming,isPostLiveDvr,paid,premium,adaptiveFormats,error")]
        let data = try transport(Self.request(components.url!), cancellation, 2_000_000, nil)
        let info = try Self.parse(data, expectedID: id, endpoint: endpoint, preferAAC: preferAAC)
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        lock.lock()
        cache = cache.filter { Date().timeIntervalSince($0.value.0) < 180 }
        if cache.count >= 30, let key = cache.min(by: { $0.value.0 < $1.value.0 })?.key { cache[key] = nil }
        cache[key] = (Date(), info); lock.unlock()
        return info
    }
    func download(_ id: String, directory: URL, cancellation: SoundCloudCancellation,
                  stage: @escaping (String) -> Void, preferAAC: Bool = false) throws -> URL {
        for attempt in 0...2 {
            let info = try resolve(id, cancellation: cancellation, refresh: attempt > 0, preferAAC: preferAAC)
            let source = directory.appendingPathComponent("audio." + info.fileExtension)
            do {
                stage("Скачиваем аудио через резервный сервис…")
                _ = try transport(Self.request(info.audioURL), cancellation, 200_000_000, source)
                try FileTools.validate(source, allowedExtensions: ["m4a", "webm"])
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 200_000_000 else { throw DropError.message("Аудио превышает ограничение 200 МБ.") }
                if cancellation.isCancelled { throw SoundCloudError.cancelled }
                return source
            } catch {
                try? FileManager.default.removeItem(at: source)
                if cancellation.isCancelled { throw SoundCloudError.cancelled }
                let network = error as NSError
                let transient = network.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(network.code)
                guard attempt < 2, (error as? YouTubeHTTPError)?.retryable == true || transient else { throw error }
                stage("Соединение прервалось · повторяем загрузку…")
            }
        }
        throw DropError.message("Резервный сервис не предоставил аудио.")
    }
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("MusicDrop/1.5.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, audio/*;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        return request
    }
    static func isAllowedURL(_ url: URL, endpoint: URL, media: Bool) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        if host == endpoint.host?.lowercased() { return true }
        if media && endpoint.host?.lowercased() == "yt.chocolatemoo53.com", host.hasSuffix(".chocolatemoo53.com") { return true }
        return media && host.hasSuffix(".googlevideo.com")
    }
    /// With preferAAC an MP4 audio stream wins, so M4A output needs no re-encoding.
    static func parse(_ data: Data, expectedID: String, endpoint: URL, preferAAC: Bool = false) throws -> YouTubeFallbackInfo {
        guard data.count <= 2_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["videoId"] as? String == expectedID,
              let title = root["title"] as? String, !title.isEmpty else {
            throw DropError.message("Резервный сервис не предоставил сведения о выбранном видео.")
        }
        guard !["liveNow", "isUpcoming", "isPostLiveDvr", "paid", "premium"].contains(where: { root[$0] as? Bool == true }) else {
            throw DropError.message("Для загрузки нужна общедоступная обработанная запись YouTube.")
        }
        let formats = root["adaptiveFormats"] as? [[String: Any]] ?? []
        var candidates: [(URL, String, Int)] = []
        for item in formats {
            let mime = item["type"] as? String ?? ""
            let ext: String
            if mime.hasPrefix("audio/webm"), mime.contains("opus") { ext = "webm" }
            else if mime.hasPrefix("audio/mp4"), mime.contains("mp4a") { ext = "m4a" }
            else { continue }
            guard let raw = item["url"] as? String, let url = URL(string: raw),
                  isAllowedURL(url, endpoint: endpoint, media: true), url.path == "/videoplayback" else { continue }
            let size = (item["clen"] as? String).flatMap(Int.init) ?? (item["clen"] as? Int) ?? 0
            guard size <= 200_000_000 else { continue }
            let bitrate = (item["bitrate"] as? String).flatMap(Int.init) ?? (item["bitrate"] as? Int) ?? 0
            candidates.append((url, ext, min(1_000_000, max(0, bitrate))))
        }
        let aac = candidates.filter { $0.1 == "m4a" }
        guard let best = (preferAAC && !aac.isEmpty ? aac : candidates).max(by: { $0.2 < $1.2 }) else {
            throw DropError.message("Резервный сервис не предоставил доступный аудиопоток.")
        }
        func clean(_ text: String) -> String {
            String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        }
        let track = YouTubeTrack(id: expectedID, title: clean(title), artist: clean(root["author"] as? String ?? "YouTube"),
                                 duration: root["lengthSeconds"] as? Double, fallbackEndpoint: endpoint)
        return YouTubeFallbackInfo(track: track, audioURL: best.0, fileExtension: best.1)
    }
}

struct YouTubeHTTPError: LocalizedError {
    let status: Int
    var retryable: Bool { [403, 404, 410].contains(status) }
    var errorDescription: String? {
        if status == 429 { return "Резервный сервис временно ограничил запросы. Подожди немного и повтори." }
        return "Резервный сервис недоступен (\(status)). Попробуй позже."
    }
}

/// The delegate streams audio straight to disk, bounds responses and validates redirects.
final class YouTubeHTTPTransfer: NSObject, URLSessionDataDelegate {
    private let maximumBytes: Int
    private let endpoint: URL
    private let destination: URL?
    private let semaphore = DispatchSemaphore(value: 0)
    private var bytes = 0
    private var data = Data()
    private var file: FileHandle?
    private var failure: Error?
    private var receivedResponse = false

    init(maximumBytes: Int, destination: URL?, endpoint: URL) {
        self.maximumBytes = maximumBytes; self.destination = destination; self.endpoint = endpoint
    }
    static func run(_ request: URLRequest, cancellation: SoundCloudCancellation, maximumBytes: Int,
                    destination: URL?, endpoint: URL, configuration: URLSessionConfiguration? = nil) throws -> Data {
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        guard let url = request.url, YouTubeFallback.isAllowedURL(url, endpoint: endpoint, media: destination != nil) else {
            throw DropError.message("Резервный сервис вернул недопустимый адрес.")
        }
        let delegate = YouTubeHTTPTransfer(maximumBytes: maximumBytes, destination: destination, endpoint: endpoint)
        if let destination {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw DropError.message("Не удалось создать файл загрузки.") }
            delegate.file = try FileHandle(forWritingTo: destination)
        }
        var success = false
        defer {
            try? delegate.file?.close()
            if !success, let destination { try? FileManager.default.removeItem(at: destination) }
        }
        let config = configuration ?? .ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = destination == nil ? 20 : 60; config.timeoutIntervalForResource = destination == nil ? 30 : 600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var anonymous = request
        anonymous.timeoutInterval = destination == nil ? 20 : 60
        anonymous.setValue(nil, forHTTPHeaderField: "Cookie"); anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
        anonymous.httpShouldHandleCookies = false
        let task = session.dataTask(with: anonymous)
        task.resume(); cancellation.attach(task)
        let deadline = Date().addingTimeInterval(destination == nil ? 35 : 610)
        while delegate.semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            if cancellation.isCancelled { task.cancel() }
            if Date() > deadline {
                task.cancel()
                _ = delegate.semaphore.wait(timeout: .now() + 5)
                throw DropError.message("Резервный сервис долго не отвечает. Попробуй позже.")
            }
        }
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        if let failure = delegate.failure { throw failure }
        guard delegate.receivedResponse, delegate.bytes > 0 else { throw DropError.message("Резервный сервис вернул пустой файл.") }
        success = true
        return delegate.data
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard failure == nil else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            failure = YouTubeHTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= maximumBytes else {
            failure = DropError.message("Ответ сервиса превышает допустимый размер.")
            completionHandler(.cancel); return
        }
        let mime = response.mimeType?.lowercased() ?? ""
        if destination != nil, !mime.hasPrefix("audio/"), !["video/webm", "video/mp4", "application/octet-stream"].contains(mime) {
            failure = DropError.message("Сервис вернул страницу вместо аудио.")
            completionHandler(.cancel); return
        }
        receivedResponse = true; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive incoming: Data) {
        guard failure == nil else { return }
        bytes += incoming.count
        guard bytes <= maximumBytes else {
            failure = DropError.message("Загрузка превышает допустимый размер."); dataTask.cancel(); return
        }
        do { if let file { try file.write(contentsOf: incoming) } else { data.append(incoming) } }
        catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil { failure = error }
        semaphore.signal()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, YouTubeFallback.isAllowedURL(url, endpoint: endpoint, media: destination != nil) else {
            failure = DropError.message("Сервис перенаправил загрузку на недопустимый адрес.")
            completionHandler(nil); return
        }
        var anonymous = request
        anonymous.setValue(nil, forHTTPHeaderField: "Cookie"); anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
        anonymous.httpShouldHandleCookies = false
        completionHandler(anonymous)
    }
}
