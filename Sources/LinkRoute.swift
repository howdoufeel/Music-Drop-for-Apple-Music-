import Foundation

/// Which source a pasted, dropped or typed link belongs to, so any field or drop target can accept it.
enum LinkRoute: Equatable {
    case youTube(String)
    case soundCloud(String)

    /// Only real track links are routed; plain text and other sites return nil.
    static func detect(_ text: String) -> LinkRoute? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2_000, !value.contains("\n") else { return nil }
        if (try? YouTubeService.videoID(value)) != nil { return .youTube(value) }
        if value.contains("://"), (try? SoundCloudService.searchTarget(value)) != nil { return .soundCloud(value) }
        return nil
    }

    /// For a search field: links go to their source, plain words to SoundCloud search.
    static func forInput(_ text: String) -> LinkRoute? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let route = detect(value) { return route }
        return value.contains("://") ? nil : .soundCloud(value)
    }
}
