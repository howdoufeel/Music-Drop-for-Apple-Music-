import Foundation

/// Turns upload titles such as "Artist - Song (Official Video) [4K]" into the title and
/// artist a music library expects. Words that describe the music itself (remix, live,
/// feat.) are kept; only words about the upload are removed.
enum TrackMetadata {
    private static let noise: NSRegularExpression = {
        let label = #"(?:official\s+)?(?:music\s+|lyrics?\s+|audio\s+|hd\s+|4k\s+)?(?:video|audio|visuali[sz]er|lyrics?|clip|mv|m/v)"#
        let quality = "hd|hq|4k|1080p|720p"
        let russian = #"премьера(?:\s+клипа)?|официальн\S*\s+(?:видео|клип)|клип"#
        return try! NSRegularExpression(pattern: #"\s*[\(\[]\s*(?:"# + label + "|" + quality + "|" + russian + #")\s*[\)\]]"#,
                                        options: [.caseInsensitive])
    }()
    private static let separators = [" - ", " – ", " — ", " -- "]

    /// Removes bracketed upload labels and a trailing "| Official Video" style suffix.
    static func cleanTitle(_ title: String) -> String {
        var value = noise.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
        if let bar = value.range(of: " | ", options: .backwards) {
            let tail = value[bar.upperBound...].lowercased()
            if ["official", "video", "audio", "lyric", "клип", "видео"].contains(where: tail.contains) {
                value = String(value[..<bar.lowerBound])
            }
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    /// Channel names that only label the upload, such as "Artist - Topic" or "ArtistVEVO".
    static func cleanChannel(_ channel: String) -> String {
        var value = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Topic", "VEVO", " Official", " - Official"] where value.hasSuffix(suffix) && value.count > suffix.count {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    /// YouTube: music metadata first, then "Artist - Title" in the upload title, then the channel.
    static func youTube(title: String, channel: String, artist: String?, track: String?) -> (title: String, artist: String) {
        if let artist = artist?.nonEmpty, let track = track?.nonEmpty { return (cleanTitle(track), artist) }
        let cleaned = cleanTitle(title)
        if let artist = artist?.nonEmpty { return (stripPrefix(artist, from: cleaned), artist) }
        if channel.hasSuffix(" - Topic") { return (cleaned, cleanChannel(channel)) }
        if let parts = split(cleaned) { return (parts.title, parts.artist) }
        return (cleaned, cleanChannel(channel).nonEmpty ?? "YouTube")
    }

    /// SoundCloud: uploaders are usually the artist themselves, so a dash is split only
    /// when it repeats the known artist; "Song - Extended Mix" stays intact.
    static func soundCloud(title: String, artist: String) -> (title: String, artist: String) {
        (stripPrefix(artist, from: cleanTitle(title)), artist)
    }

    private static func stripPrefix(_ artist: String, from title: String) -> String {
        guard let parts = split(title), parts.artist.caseInsensitiveCompare(artist) == .orderedSame else { return title }
        return parts.title
    }

    private static func split(_ title: String) -> (artist: String, title: String)? {
        for separator in separators {
            guard let range = title.range(of: separator) else { continue }
            let left = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty { return (left, right) }
        }
        return nil
    }

    /// The year from "2024-05-01T…", "20240501" or a plain year.
    static func year(_ value: Any?) -> Int? {
        if let number = value as? Int, (1900...2100).contains(number) { return number }
        if let number = value as? NSNumber, (1900...2100).contains(number.intValue) { return number.intValue }
        guard let text = value as? String, text.count >= 4, let year = Int(text.prefix(4)), (1900...2100).contains(year) else { return nil }
        return year
    }
}

extension String {
    /// Nil for blank strings, so optional chains can fall through to the next candidate.
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
