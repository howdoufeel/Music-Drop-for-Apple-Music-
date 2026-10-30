import Foundation
import Observation

@Observable final class YouTubeStore {
    var query = ""
    var results: [YouTubeTrack] = []
    var isSearching = false
    var didSearch = false
    var error: String?
    var downloadStates: [String: String] = [:]
    var downloadErrors: [String: String] = [:]
    /// Quick title cards still waiting for the full availability check.
    private(set) var verifying: Set<String> = []
    /// Audio already fetched in the background; Add hands it off at once.
    private(set) var prefetchedIDs: Set<String> = []
    private let service: YouTubeProviding
    private let searchQueue = DispatchQueue(label: "tech.musicdrop.youtube.search", qos: .userInitiated, attributes: .concurrent)
    private let downloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "tech.musicdrop.youtube.download"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    @ObservationIgnored private var searchToken: SoundCloudCancellation?
    @ObservationIgnored private var activeSearchInput: String?
    @ObservationIgnored private var downloadTokens: [String: SoundCloudCancellation] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var prefetched: [String: URL] = [:]
    @ObservationIgnored private var lastStage: [String: String] = [:]
    private let preview: Bool
    private let prefetch: Bool
    let directory: URL
    @ObservationIgnored var onReady: ((URL, YouTubeTrack) -> Void)?
    @ObservationIgnored var onActivity: (() -> Void)?
    /// Lets the app skip background downloads for tracks that are already in the library.
    @ObservationIgnored var shouldPrefetch: ((YouTubeTrack) -> Bool)?
    var isDownloading: Bool { !downloadStates.isEmpty }

    init(service: YouTubeProviding = YouTubeService(), directory: URL? = nil, preview: Bool = false, prefetch: Bool = true) {
        self.service = service
        self.preview = preview
        self.prefetch = prefetch
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
        dropUnverifiedCards()
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
            // The title card appears while the slower extractor confirms the audio is available.
            if let quick = self.service.preview(input, cancellation: token), !token.isCancelled {
                DispatchQueue.main.async {
                    guard self.searchToken === token, self.isSearching,
                          !self.results.contains(where: { $0.id == quick.id }) else { return }
                    self.results.insert(quick, at: 0)
                    self.verifying.insert(quick.id)
                }
            }
            do {
                let track = try self.service.resolve(input, cancellation: token)
                DispatchQueue.main.async {
                    guard self.searchToken === token else { return }
                    self.verifying.remove(track.id)
                    self.results = [track] + self.results.filter { $0.id != track.id }
                    self.isSearching = false
                    self.startPrefetch(track)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.searchToken === token else { return }
                    self.isSearching = false
                    self.dropUnverifiedCards()
                    if !token.isCancelled { self.error = error.localizedDescription }
                }
            }
        }
    }

    /// A card whose check failed or was replaced cannot be downloaded reliably.
    private func dropUnverifiedCards() {
        let stale = verifying.filter { downloadTokens[$0] == nil }
        results.removeAll { stale.contains($0.id) }
        verifying.subtract(stale)
    }

    private func startPrefetch(_ track: YouTubeTrack) {
        guard prefetch, !preview, downloadTokens[track.id] == nil, prefetched[track.id] == nil,
              shouldPrefetch?(track) ?? true else { return }
        start(track)
    }

    func add(_ track: YouTubeTrack) {
        guard !preview else { error = "Это предпросмотр. Добавление в медиатеку отключено."; return }
        if let file = prefetched.removeValue(forKey: track.id) {
            prefetchedIDs.remove(track.id)
            if FileManager.default.fileExists(atPath: file.path) {
                downloadErrors[track.id] = nil
                onReady?(file, track)
                onActivity?()
                return
            }
        }
        guard requested.insert(track.id).inserted else { return }
        downloadErrors[track.id] = nil
        downloadStates[track.id] = lastStage[track.id] ?? "В очереди на загрузку"
        onActivity?()
        if downloadTokens[track.id] == nil { start(track) }
    }

    /// One transfer serves both a background prefetch and a later Add of the same track.
    private func start(_ track: YouTubeTrack) {
        let token = SoundCloudCancellation()
        downloadTokens[track.id] = token
        downloadQueue.addOperation { [weak self] in
            guard let self, !token.isCancelled else { return }
            do {
                let file = try self.service.download(track, directory: self.directory, cancellation: token) { state in
                    DispatchQueue.main.async {
                        guard self.downloadTokens[track.id] === token else { return }
                        self.lastStage[track.id] = state
                        if self.requested.contains(track.id) { self.downloadStates[track.id] = state }
                    }
                }
                DispatchQueue.main.async { self.finish(track, token: token, result: .success(file)) }
            } catch {
                DispatchQueue.main.async { self.finish(track, token: token, result: .failure(error)) }
            }
        }
    }

    private func finish(_ track: YouTubeTrack, token: SoundCloudCancellation, result: Result<URL, Error>) {
        guard downloadTokens[track.id] === token else {
            if case .success(let file) = result { discard(file) }
            return
        }
        downloadTokens[track.id] = nil
        lastStage[track.id] = nil
        let wanted = requested.remove(track.id) != nil
        downloadStates[track.id] = nil
        switch result {
        case .success(let file):
            if token.isCancelled { discard(file) }
            else if wanted { onReady?(file, track) }
            else { prefetched[track.id] = file; prefetchedIDs.insert(track.id) }
        case .failure(let error):
            if wanted, !token.isCancelled { downloadErrors[track.id] = error.localizedDescription }
        }
        onActivity?()
    }

    /// Removes the staging folder of audio that will never be imported.
    private func discard(_ file: URL) {
        let working = file.deletingLastPathComponent().deletingLastPathComponent()
        guard working.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: working)
    }

    func cancel(_ track: YouTubeTrack) {
        downloadTokens[track.id]?.cancel()
        downloadTokens[track.id] = nil
        requested.remove(track.id)
        lastStage[track.id] = nil
        downloadStates[track.id] = nil
        downloadErrors[track.id] = nil
        onActivity?()
    }
    func cancelAll() {
        searchToken?.cancel()
        for token in downloadTokens.values { token.cancel() }
        for file in prefetched.values { discard(file) }
        prefetched.removeAll()
        prefetchedIDs.removeAll()
    }
}
