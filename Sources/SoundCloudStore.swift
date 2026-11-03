import Foundation
import Observation

@Observable final class SoundCloudStore {
    var query = ""
    var results: [SoundCloudTrack] = []
    var isSearching = false
    var didSearch = false
    var error: String?
    var downloadStates: [String: String] = [:]
    var downloadErrors: [String: String] = [:]
    /// Fraction transferred, present only while the current phase has a known size.
    var downloadProgress: [String: Double] = [:]
    /// The track chosen for listening; playback itself belongs to the interface's player.
    private(set) var previewID: String?
    private(set) var previewLoading = false
    private(set) var previewIsClip = false
    var previewErrors: [String: String] = [:]
    private let service: SoundCloudProviding
    private let searchQueue = DispatchQueue(label: "tech.musicdrop.soundcloud.search", qos: .userInitiated, attributes: .concurrent)
    private let downloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "tech.musicdrop.soundcloud.download"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    @ObservationIgnored private var searchToken: SoundCloudCancellation?
    @ObservationIgnored private var activeSearchInput: String?
    @ObservationIgnored private var downloadTokens: [String: SoundCloudCancellation] = [:]
    @ObservationIgnored private var previewToken: SoundCloudCancellation?
    private let preview: Bool
    let directory: URL
    @ObservationIgnored var onReady: ((URL, SoundCloudTrack) -> Void)?
    @ObservationIgnored var onActivity: (() -> Void)?
    /// Receives the stream to play, or nil to stop.
    @ObservationIgnored var onPreview: ((URL?) -> Void)?
    var isDownloading: Bool { !downloadStates.isEmpty }

    init(service: SoundCloudProviding = SoundCloudService(artwork: CoverArt.load), directory: URL? = nil, preview: Bool = false) {
        self.service = service
        self.preview = preview
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music Drop/Downloads/SoundCloud", isDirectory: true)
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
            results = [SoundCloudTrack(id: "preview", title: "A new discovery", artist: "SoundCloud artist",
                                       url: URL(string: "https://soundcloud.com/example/discovery")!, duration: 214)]
            isSearching = false
            return
        }
        searchQueue.async { [weak self] in
            guard let self else { return }
            do {
                let results = try self.service.search(input, cancellation: token)
                DispatchQueue.main.async {
                    guard self.searchToken === token else { return }
                    self.results = results
                    self.isSearching = false
                    self.stopPreviewIfUnlisted()
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.searchToken === token else { return }
                    self.isSearching = false
                    if !token.isCancelled { self.error = error.localizedDescription; self.results = [] }
                    self.stopPreviewIfUnlisted()
                }
            }
        }
    }

    /// Starts listening to a result; any other preview stops first.
    func startPreview(_ track: SoundCloudTrack) {
        guard !preview else { error = "Это предпросмотр интерфейса. Прослушивание отключено."; return }
        stopPreview()
        let token = SoundCloudCancellation()
        previewToken = token
        previewID = track.id
        previewLoading = true
        previewErrors[track.id] = nil
        searchQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.service.previewStream(for: track, cancellation: token) }
            DispatchQueue.main.async {
                guard self.previewToken === token else { return }
                self.previewLoading = false
                switch result {
                case .success(let stream?):
                    self.previewIsClip = stream.isClip
                    self.onPreview?(stream.url)
                case .success(nil):
                    self.clearPreview()
                    self.previewErrors[track.id] = "SoundCloud не даёт прослушать этот трек."
                case .failure(let error):
                    // Still the current request, so this is a real failure rather than a cancellation.
                    self.clearPreview()
                    self.previewErrors[track.id] = error.localizedDescription
                }
            }
        }
    }

    func stopPreview() {
        let active = previewID != nil
        clearPreview()
        if active { onPreview?(nil) }
    }

    /// Called by the player when the stream ends or cannot be played.
    func previewEnded(failed: Bool) {
        if failed, let id = previewID { previewErrors[id] = "Не удалось воспроизвести трек. Попробуй ещё раз." }
        stopPreview()
    }

    private func clearPreview() {
        previewToken?.cancel()
        previewToken = nil
        previewID = nil
        previewLoading = false
        previewIsClip = false
    }

    /// Listening continues through a new search only while its track is still on screen.
    private func stopPreviewIfUnlisted() {
        guard let id = previewID, !results.contains(where: { $0.id == id }) else { return }
        stopPreview()
    }

    /// Called when the SoundCloud tab opens, so the first search does not pay for the connection.
    func prewarm() {
        guard !preview else { return }
        let service = self.service
        searchQueue.async { service.prewarm() }
    }

    func add(_ track: SoundCloudTrack) {
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
                let file = try self.service.download(track, directory: self.directory, cancellation: token, stage: { state in
                    DispatchQueue.main.async {
                        guard self.downloadTokens[track.id] === token else { return }
                        self.downloadStates[track.id] = state
                        self.downloadProgress[track.id] = nil
                    }
                }, progress: { value in
                    DispatchQueue.main.async {
                        guard self.downloadTokens[track.id] === token else { return }
                        // Whole percents are enough; finer steps would only re-render the row.
                        if value >= 1 || value - (self.downloadProgress[track.id] ?? -1) >= 0.01 { self.downloadProgress[track.id] = value }
                    }
                })
                DispatchQueue.main.async {
                    guard self.downloadTokens[track.id] === token else { return }
                    self.downloadTokens[track.id] = nil
                    self.downloadStates[track.id] = nil
                    self.downloadProgress[track.id] = nil
                    if !token.isCancelled { self.onReady?(file, track) }
                    self.onActivity?()
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.downloadTokens[track.id] === token else { return }
                    self.downloadTokens[track.id] = nil
                    self.downloadStates[track.id] = nil
                    self.downloadProgress[track.id] = nil
                    if !token.isCancelled { self.downloadErrors[track.id] = error.localizedDescription }
                    self.onActivity?()
                }
            }
        }
    }

    func cancel(_ track: SoundCloudTrack) {
        downloadTokens[track.id]?.cancel()
        downloadTokens[track.id] = nil
        downloadStates[track.id] = nil
        downloadProgress[track.id] = nil
        downloadErrors[track.id] = nil
        onActivity?()
    }
    func cancelAll() {
        stopPreview()
        searchToken?.cancel()
        for token in downloadTokens.values { token.cancel() }
    }
}
