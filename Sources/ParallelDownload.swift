import Foundation

/// Fetches ordered parts of one file concurrently and joins them in order.
/// Each part lands in its own file, so a slow part never holds later ones in memory.
enum ParallelDownload {
    static func run(count: Int, concurrency: Int, destination: URL, maximumBytes: Int,
                    cancellation: SoundCloudCancellation, progress: ((Int, Int) -> Void)? = nil,
                    fetch: @escaping (Int) throws -> Data) throws {
        guard count > 0 else { throw DropError.message("Источник не вернул аудиоданные.") }
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        let fm = FileManager.default
        let parts = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".parts", isDirectory: true)
        try fm.createDirectory(at: parts, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parts) }
        let lock = NSLock()
        var next = 0, finished = 0, bytes = 0
        var failure: Error?
        func fetchOnce(_ index: Int) throws -> Data {
            do { return try fetch(index) }
            catch {
                // One quick retry covers a dropped connection; limits and cancellation stop at once.
                if cancellation.isCancelled { throw SoundCloudError.cancelled }
                if case SoundCloudError.rateLimited = error { throw error }
                if (error as? YouTubeHTTPError)?.status == 429 { throw error }
                return try fetch(index)
            }
        }
        let group = DispatchGroup()
        for _ in 0..<min(max(1, concurrency), count) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                while true {
                    lock.lock()
                    guard failure == nil, next < count, !cancellation.isCancelled else { lock.unlock(); return }
                    let index = next
                    next += 1
                    lock.unlock()
                    do {
                        let data = try fetchOnce(index)
                        lock.lock(); bytes += data.count; let oversized = bytes > maximumBytes; lock.unlock()
                        if oversized { throw DropError.message("Аудио превышает ограничение облачной медиатеки 200 МБ.") }
                        try data.write(to: parts.appendingPathComponent(String(index)))
                        lock.lock(); finished += 1; let done = finished; lock.unlock()
                        progress?(done, count)
                    } catch {
                        lock.lock(); if failure == nil { failure = error }; lock.unlock()
                        return
                    }
                }
            }
        }
        group.wait()
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        if let failure { throw failure }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw DropError.message("Не удалось создать файл загрузки.")
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            for index in 0..<count {
                try output.write(contentsOf: Data(contentsOf: parts.appendingPathComponent(String(index))))
            }
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }
}

/// One anonymous, size-bounded HTTP request. Redirects must stay on allowed hosts,
/// and cookies or account headers are never sent.
final class BoundedFetch: NSObject, URLSessionTaskDelegate {
    private let allowed: (URL) -> Bool
    private var session: URLSession!

    private init(allowed: @escaping (URL) -> Bool, configuration: URLSessionConfiguration) {
        self.allowed = allowed
        super.init()
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// The session retains its delegate, so it lives only for the duration of `body`.
    static func with<T>(allowed: @escaping (URL) -> Bool, configuration: URLSessionConfiguration = .ephemeral,
                        _ body: (BoundedFetch) throws -> T) rethrows -> T {
        let fetch = BoundedFetch(allowed: allowed, configuration: configuration)
        defer { fetch.session.invalidateAndCancel() }
        return try body(fetch)
    }

    private final class Reply {
        var result: Result<(Data, HTTPURLResponse), Error>?
        let ready = DispatchSemaphore(value: 0)
    }

    func data(_ request: URLRequest, cancellation: SoundCloudCancellation, maximumBytes: Int, timeout: TimeInterval = 30,
              acceptsType: (String) -> Bool) throws -> (Data, HTTPURLResponse) {
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        guard let url = request.url, allowed(url) else { throw DropError.message("Источник вернул недопустимый адрес.") }
        var anonymous = request
        anonymous.timeoutInterval = timeout
        anonymous.httpShouldHandleCookies = false
        anonymous.setValue(nil, forHTTPHeaderField: "Cookie")
        anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
        let reply = Reply()
        let task = session.dataTask(with: anonymous) { data, response, error in
            if let error { reply.result = .failure(error) }
            else if let response = response as? HTTPURLResponse { reply.result = .success((data ?? Data(), response)) }
            else { reply.result = .failure(DropError.message("Источник не ответил.")) }
            reply.ready.signal()
        }
        task.resume()
        let deadline = Date().addingTimeInterval(timeout + 1)
        while reply.ready.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellation.isCancelled { task.cancel(); throw SoundCloudError.cancelled }
            if Date() >= deadline { task.cancel(); throw DropError.message("Источник долго не отвечает. Повтори попытку.") }
        }
        if cancellation.isCancelled { throw SoundCloudError.cancelled }
        let (data, response) = try reply.result!.get()
        guard [200, 206].contains(response.statusCode) else { throw YouTubeHTTPError(status: response.statusCode) }
        guard data.count <= maximumBytes else { throw DropError.message("Ответ источника превышает допустимый размер.") }
        guard acceptsType(response.mimeType?.lowercased() ?? "") else { throw DropError.message("Источник вернул страницу вместо аудио.") }
        return (data, response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, allowed(url) else { completionHandler(nil); return }
        var anonymous = request
        anonymous.setValue(nil, forHTTPHeaderField: "Cookie")
        anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
        anonymous.httpShouldHandleCookies = false
        completionHandler(anonymous)
    }
}
