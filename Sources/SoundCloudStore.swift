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
    /// An opened set; while it is shown the normal results are hidden.
    private(set) var collection: SoundCloudCollection?
    var selection: Set<String> = []
    /// Put the set's tracks into a playlist named after it.
    var collectionIntoPlaylist = true
    @ObservationIgnored private var playlistTargets: [String: String] = [:]
    /// What was on screen before a related or artist list opened from it; closing goes back there.
    private struct Screen {
        let collection: SoundCloudCollection?
        let results: [SoundCloudTrack]
        let selection: Set<String>
        let intoPlaylist: Bool
    }
    private var backStack: [Screen] = []
    var canGoBack: Bool { !backStack.isEmpty }
    @ObservationIgnored private var autoAddInput: String?
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

    /// With `autoAdd` a track link is added as soon as it resolves, as the hotkey and URL scheme ask.
    func search(autoAdd: Bool = false) {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        autoAddInput = autoAdd && input.contains("://") ? input : nil
        if isSearching, activeSearchInput == input { return }
        if let request = SoundCloudService.collectionRequest(input) { openCollection(request, input: input); return }
        collection = nil
        backStack = []
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
                    if self.autoAddInput == input, let first = results.first {
                        self.autoAddInput = nil
                        self.add(first)
                    }
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

    /// An artist's latest uploads through the same connection the panel uses; blocks, call it off the main thread.
    func artistCollection(userID: String, name: String, cancellation: SoundCloudCancellation) throws -> SoundCloudCollection {
        try service.collection(.artist(userID: userID, name: name), cancellation: cancellation)
    }

    /// Tracks like this one, as a list to pick from.
    func openRelated(_ track: SoundCloudTrack) {
        openCollection(.related(track), input: nil)
    }

    /// The uploader's other tracks.
    func openArtist(_ track: SoundCloudTrack) {
        guard let id = track.userID else { return }
        openCollection(.artist(userID: id, name: track.artist), input: nil)
    }

    /// A list that was fetched elsewhere, such as new tracks from followed artists.
    func show(_ collection: SoundCloudCollection) {
        backStack = []
        searchToken?.cancel()
        searchToken = nil
        activeSearchInput = nil
        isSearching = false
        didSearch = true
        error = nil
        present(collection)
    }

    private func present(_ collection: SoundCloudCollection) {
        self.collection = collection
        results = collection.tracks
        // A set or likes list is usually wanted whole; artist and related lists are picked from.
        let whole = collection.kind == .set || collection.kind == .likes || collection.kind == .subscriptions
        selection = whole ? Set(collection.tracks.map(\.id)) : []
        collectionIntoPlaylist = collection.kind == .set || collection.kind == .likes
        stopPreviewIfUnlisted()
    }

    /// A typed link starts over; a list opened from a row (no input) can be closed back to that row.
    func openCollection(_ request: SoundCloudCollectionRequest, input: String?) {
        if input != nil { backStack = [] }
        searchToken?.cancel()
        activeSearchInput = input
        let token = SoundCloudCancellation()
        searchToken = token
        error = nil
        isSearching = true
        didSearch = true
        searchQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.service.collection(request, cancellation: token) }
            DispatchQueue.main.async {
                guard self.searchToken === token else { return }
                self.isSearching = false
                switch result {
                case .success(let collection):
                    if input == nil, self.collection != nil || !self.results.isEmpty {
                        self.backStack.append(Screen(collection: self.collection, results: self.results,
                                                     selection: self.selection, intoPlaylist: self.collectionIntoPlaylist))
                        if self.backStack.count > 20 { self.backStack.removeFirst() }
                    }
                    self.present(collection)
                case .failure(let error):
                    if !token.isCancelled { self.error = error.localizedDescription }
                    self.stopPreviewIfUnlisted()
                }
            }
        }
    }

    func closeCollection() {
        searchToken?.cancel()
        isSearching = false
        if let previous = backStack.popLast() {
            collection = previous.collection
            results = previous.results
            selection = previous.selection
            collectionIntoPlaylist = previous.intoPlaylist
        } else {
            collection = nil
            selection = []
            results = []
        }
        stopPreviewIfUnlisted()
    }

    /// Queues every selected track that is not already in the library and returns the ones that are,
    /// so the caller can still put them into the set's playlist.
    @discardableResult
    func addCollection(skipping imported: Set<String>) -> [SoundCloudTrack] {
        guard let collection else { return [] }
        let playlist = collectionIntoPlaylist ? collection.title : nil
        var existing: [SoundCloudTrack] = []
        for track in collection.tracks where selection.contains(track.id) {
            if imported.contains(track.id) { existing.append(track); continue }
            if let playlist { playlistTargets[track.id] = playlist }
            add(track)
        }
        return existing
    }

    /// The playlist a queued track should go into, when it differs from the chosen destination.
    func playlistTarget(for id: String) -> String? {
        playlistTargets.removeValue(forKey: id)
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
