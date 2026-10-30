import SwiftUI
import AppKit
import ImageIO

/// Decoded thumbnails; NSCache is thread-safe and evicts under memory pressure.
private let artworkMemory = NSCache<NSURL, NSImage>()

/// Track artwork, downsampled once and kept in memory and on disk, so rows that scroll back
/// into view or reappear after a new search never flash or download again.
actor ArtworkLoader {
    static let shared = ArtworkLoader()
    private var running: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music Drop/Artwork", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 64_000_000, directory: caches)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "i.ytimg.com" || host == "sndcdn.com" || host.hasSuffix(".sndcdn.com")
    }

    nonisolated func cached(_ url: URL) -> NSImage? { artworkMemory.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        if let task = running[url] { return await task.value }
        guard Self.isAllowed(url) else { return nil }
        let session = self.session
        // Detached, so downloads and decoding never hold the actor that hands out cached images.
        let task = Task<NSImage?, Never>.detached(priority: .utility) {
            guard let reply = try? await session.data(from: url),
                  (reply.1 as? HTTPURLResponse)?.statusCode == 200, reply.0.count < 5_000_000 else { return nil }
            return Self.thumbnail(reply.0, maxPixels: 132)
        }
        running[url] = task
        let image = await task.value
        running[url] = nil
        if let image { artworkMemory.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// Starts loading artwork that is about to be shown.
    nonisolated func prefetch(_ urls: [URL]) {
        for url in urls where cached(url) == nil {
            Task(priority: .utility) { _ = await self.image(url) }
        }
    }

    private static func thumbnail(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

struct ArtworkView: View {
    let url: URL?
    let symbol: String
    let tint: Color
    @State private var image: NSImage?

    init(url: URL?, symbol: String, tint: Color) {
        self.url = url
        self.symbol = symbol
        self.tint = tint
        // Cached artwork is shown in the very first frame.
        _image = State(initialValue: url.flatMap { ArtworkLoader.shared.cached($0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tint.opacity(0.08))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await ArtworkLoader.shared.image(url)
        }
    }
}
