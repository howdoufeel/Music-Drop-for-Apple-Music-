import Foundation
import SwiftUI

final class YouTubeStore: ObservableObject {
    @Published var query = ""
    @Published var results: [YouTubeTrack] = []
    @Published var isSearching = false
    @Published var didSearch = false
    @Published var error: String?
    @Published var downloadStates: [String: String] = [:]
    @Published var downloadErrors: [String: String] = [:]
    private let service: YouTubeProviding
    private let searchQueue = DispatchQueue(label: "tech.musicdrop.youtube.search", qos: .userInitiated, attributes: .concurrent)
    private let downloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "tech.musicdrop.youtube.download"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var searchToken: SoundCloudCancellation?
    private var activeSearchInput: String?
    private var downloadTokens: [String: SoundCloudCancellation] = [:]
    private let preview: Bool
    let directory: URL
    var onReady: ((URL, YouTubeTrack) -> Void)?
    var onActivity: (() -> Void)?
    var isDownloading: Bool { !downloadStates.isEmpty }

    init(service: YouTubeProviding = YouTubeService(), directory: URL? = nil, preview: Bool = false) {
        self.service = service
        self.preview = preview
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music Drop/Downloads/YouTube", isDirectory: true)
    }

    func search() {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSearching, activeSearchInput == input { return }
        searchToken?.cancel()
        activeSearchInput = input
        let token = SoundCloudCancellation()
        searchToken = token
        error = nil
        isSearching = true
        didSearch = true
        if preview {
            results = [YouTubeTrack(id: "BaW_jenozKc", title: "YouTube test video", artist: "YouTube", duration: 10)]
            isSearching = false
            return
        }
        searchQueue.async { [weak self] in
            guard let self else { return }
            do {
                let results = [try self.service.resolve(input, cancellation: token)]
                DispatchQueue.main.async {
                    guard self.searchToken === token else { return }
                    self.results = results + self.results.filter { old in !results.contains(where: { $0.id == old.id }) }
                    self.isSearching = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.searchToken === token else { return }
                    self.isSearching = false
                    if !token.isCancelled { self.error = error.localizedDescription }
                }
            }
        }
    }

    func add(_ track: YouTubeTrack) {
        guard !preview else { error = "Это предпросмотр. Добавление в медиатеку отключено."; return }
        guard downloadTokens[track.id] == nil else { return }
        let token = SoundCloudCancellation()
        downloadTokens[track.id] = token
        downloadStates[track.id] = "В очереди на загрузку"
        downloadErrors[track.id] = nil
        onActivity?()
        downloadQueue.addOperation { [weak self] in
            guard let self, !token.isCancelled else { return }
            do {
                let file = try self.service.download(track, directory: self.directory, cancellation: token) { state in
                    DispatchQueue.main.async {
                        if self.downloadTokens[track.id] === token { self.downloadStates[track.id] = state }
                    }
                }
                DispatchQueue.main.async {
                    guard self.downloadTokens[track.id] === token else { return }
                    self.downloadTokens[track.id] = nil
                    self.downloadStates[track.id] = nil
                    if !token.isCancelled { self.onReady?(file, track) }
                    self.onActivity?()
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.downloadTokens[track.id] === token else { return }
                    self.downloadTokens[track.id] = nil
                    self.downloadStates[track.id] = nil
                    if !token.isCancelled { self.downloadErrors[track.id] = error.localizedDescription }
                    self.onActivity?()
                }
            }
        }
    }

    func cancel(_ track: YouTubeTrack) {
        downloadTokens[track.id]?.cancel()
        downloadTokens[track.id] = nil
        downloadStates[track.id] = nil
        downloadErrors[track.id] = nil
        onActivity?()
    }
    func cancelAll() {
        searchToken?.cancel()
        for token in downloadTokens.values { token.cancel() }
    }
}
