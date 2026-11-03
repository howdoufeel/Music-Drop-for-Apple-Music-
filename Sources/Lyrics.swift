import Foundation

/// Finds song lyrics on LRCLIB, an open lyrics database that needs no account or key.
/// Only the title, artist, album and length of the track are sent.
enum Lyrics {
    static let enabledKey = "LyricsEnabled"
    static let maximumLength = 30_000
    typealias Fetch = (URL) throws -> Data

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Plain lyrics for the track, or nil when there are none or it is instrumental.
    static func find(title: String, artist: String, album: String?, duration: Double?, fetch: Fetch? = nil) throws -> String? {
        guard let title = title.nonEmpty, let artist = artist.nonEmpty, title.count <= 300, artist.count <= 300 else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let album = album?.nonEmpty, album.count <= 300, album.caseInsensitiveCompare(title) != .orderedSame {
            components.queryItems?.append(URLQueryItem(name: "album_name", value: album))
        }
        guard let url = components.url else { return nil }
        let data = try (fetch ?? download)(url)
        if let found = best(data, duration: duration) { return found }
        // An album name that LRCLIB spells differently should not hide the song.
        guard components.queryItems?.count == 3 else { return nil }
        components.queryItems?.removeLast()
        guard let plain = components.url else { return nil }
        return best(try (fetch ?? download)(plain), duration: duration)
    }

    /// Picks the result closest in length; a match more than five seconds off is a different recording.
    static func best(_ data: Data, duration: Double?) -> String? {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let candidates = items.prefix(50).compactMap { item -> (text: String, distance: Double)? in
            guard item["instrumental"] as? Bool != true, (item["instrumental"] as? NSNumber)?.boolValue != true else { return nil }
            let length = (item["duration"] as? NSNumber)?.doubleValue
            let distance = duration.flatMap { mine in length.map { abs($0 - mine) } } ?? 0
            guard distance <= 5 else { return nil }
            let text = (item["plainLyrics"] as? String).flatMap(clean) ?? (item["syncedLyrics"] as? String).flatMap { clean(unsynced($0)) }
            return text.map { ($0, distance) }
        }
        return candidates.min { $0.distance < $1.distance }?.text
    }

    /// Drops the "[01:23.45]" times from synced lyrics.
    static func unsynced(_ text: String) -> String {
        // "\r\n" is one Character in Swift, so line ends are made plain before splitting.
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.replacingOccurrences(of: #"^(\s*\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\])+\s?"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    /// Normal line breaks, no control characters, no runaway length.
    static func clean(_ text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let scalars = lines.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        let value = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maximumLength else { return nil }
        return value
    }

    private static func download(_ url: URL) throws -> Data {
        try BoundedFetch.with(allowed: { $0.scheme == "https" && $0.host?.lowercased() == "lrclib.net" }) { fetch in
            var request = URLRequest(url: url)
            request.setValue("Music Drop (https://github.com/howdoufeel/Music-Drop-for-Apple-Music-)", forHTTPHeaderField: "User-Agent")
            do {
                return try fetch.data(request, cancellation: SoundCloudCancellation(), maximumBytes: 2_000_000, timeout: 10) { _ in true }.0
            } catch let error as YouTubeHTTPError where error.status == 404 {
                return Data("[]".utf8)
            }
        }
    }
}
