import Foundation

/// Track artwork for the files Music Drop prepares. It is fetched while the audio
/// downloads, so tagging the file rarely has to wait for it.
enum CoverArt {
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host == "i.ytimg.com" || host == "sndcdn.com" || host.hasSuffix(".sndcdn.com")
    }

    /// SoundCloud lists a 100 px image; the 500 px version sits next to it.
    static func soundCloudURLs(_ artwork: URL?) -> [URL] {
        guard let artwork else { return [] }
        let large = artwork.absoluteString.replacingOccurrences(of: "-large.", with: "-t500x500.")
        return [URL(string: large), artwork].compactMap { $0 }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The full-resolution frame exists for most videos; the smaller one always does.
    static func youTubeURLs(_ id: String) -> [URL] {
        ["maxresdefault", "hqdefault"].compactMap { URL(string: "https://i.ytimg.com/vi/\(id)/\($0).jpg") }
    }

    /// Downloads the first image that answers and turns it into a square JPEG.
    static func load(_ urls: [URL], cancellation: SoundCloudCancellation) -> Data? {
        BoundedFetch.with(allowed: isAllowed) { fetch in
            for url in urls where !cancellation.isCancelled {
                guard let reply = try? fetch.data(URLRequest(url: url), cancellation: cancellation, maximumBytes: 8_000_000,
                                                  timeout: 10, acceptsType: { $0.hasPrefix("image/") }) else { continue }
                if let square = CoverImage.squareJPEG(reply.0) { return square }
            }
            return nil
        }
    }
}

/// Work started now whose result is collected later, waiting at most a bounded time.
final class PendingResult<Value> {
    private let done = DispatchSemaphore(value: 0)
    private var value: Value?

    init(_ work: @escaping () -> Value?) {
        DispatchQueue.global(qos: .utility).async {
            self.value = work()
            self.done.signal()
        }
    }

    func value(waiting seconds: TimeInterval) -> Value? {
        done.wait(timeout: .now() + seconds) == .success ? value : nil
    }
}
