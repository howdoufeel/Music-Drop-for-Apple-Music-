import Foundation

/// Which source a pasted, dropped or typed link belongs to, so any field or drop target can accept it.
enum LinkRoute: Equatable {
    case youTube(String)
    case soundCloud(String)

    /// Track, set and playlist links are routed; plain text and other sites return nil.
    static func detect(_ text: String) -> LinkRoute? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2_000, !value.contains("\n") else { return nil }
        if (try? YouTubeService.videoID(value)) != nil || YouTubeService.isPlaylistLink(value) { return .youTube(value) }
        if value.contains("://"), (try? SoundCloudService.searchTarget(value)) != nil || SoundCloudService.collectionTarget(value) != nil {
            return .soundCloud(value)
        }
        return nil
    }

    /// `musicdrop://add?url=<link>` adds a track at once; `musicdrop://open?url=<link>` only opens it.
    /// Bookmarklets, launchers and Shortcuts reach Music Drop this way.
    static func scheme(_ url: URL) -> (route: LinkRoute, add: Bool)? {
        guard url.scheme?.lowercased() == "musicdrop", let action = url.host?.lowercased(), ["add", "open"].contains(action),
              let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let route = detect(link) else { return nil }
        return (route, action == "add")
    }

    /// For a search field: links go to their source, plain words to SoundCloud search.
    static func forInput(_ text: String) -> LinkRoute? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let route = detect(value) { return route }
        return value.contains("://") ? nil : .soundCloud(value)
    }
}
