import Foundation
import Observation

/// A followed SoundCloud artist. Tracks they had when followed count as seen, so only
/// later uploads are offered.
struct ArtistSubscription: Codable, Equatable, Identifiable {
    let userID: String
    var name: String
    var artwork: URL?
    var seen: [String]
    var lastChecked: Date?
    var id: String { userID }
}

/// The part of a found track that survives a restart; stream hints expire and are fetched again.
private struct StoredTrack: Codable {
    let id: String
    let title: String
    let artist: String
    let url: URL
    var duration: Double?
    var artwork: URL?
    var userID: String?

    init(_ track: SoundCloudTrack) {
        id = track.id; title = track.title; artist = track.artist; url = track.url
        duration = track.duration; artwork = track.artwork; userID = track.userID
    }

    var track: SoundCloudTrack {
        SoundCloudTrack(id: id, title: title, artist: artist, url: url, duration: duration, artwork: artwork, userID: userID)
    }
}

/// Follows artists and collects their new uploads. Checks run in the background a few times a day.
@Observable final class SubscriptionStore {
    typealias Fetch = (_ userID: String, _ name: String, _ cancellation: SoundCloudCancellation) throws -> SoundCloudCollection
    static let defaultsKey = "ArtistSubscriptions"
    static let freshKey = "ArtistSubscriptionsFresh"
    static let lastCheckKey = "ArtistSubscriptionsLastCheck"
    static let seenLimit = 1_000
    private static let service = SoundCloudService()

    private(set) var subscriptions: [ArtistSubscription]
    /// New uploads not yet dismissed, newest check first.
    private(set) var fresh: [SoundCloudTrack]
    private(set) var checking = false
    private(set) var lastError: String?
    @ObservationIgnored var onNew: (([SoundCloudTrack]) -> Void)?
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let queue = DispatchQueue(label: "tech.musicdrop.subscriptions", qos: .utility)

    init(fetch: Fetch? = nil, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.fetch = fetch ?? { id, name, token in
            try SubscriptionStore.service.collection(.artist(userID: id, name: name), cancellation: token)
        }
        self.defaults = defaults
        self.now = now
        let decoder = JSONDecoder()
        subscriptions = defaults.data(forKey: Self.defaultsKey).flatMap { try? decoder.decode([ArtistSubscription].self, from: $0) } ?? []
        fresh = (defaults.data(forKey: Self.freshKey).flatMap { try? decoder.decode([StoredTrack].self, from: $0) } ?? []).map(\.track)
    }

    func isFollowing(_ userID: String?) -> Bool {
        guard let userID else { return false }
        return subscriptions.contains { $0.userID == userID }
    }

    /// Follows the artist of an opened artist list; what it shows now is already known.
    func follow(_ collection: SoundCloudCollection) {
        guard collection.kind == .artist, let userID = collection.userID, !isFollowing(userID) else { return }
        subscriptions.append(ArtistSubscription(userID: userID, name: collection.artist, artwork: collection.artwork,
                                                seen: collection.tracks.map(\.id), lastChecked: now()))
        subscriptions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    func unfollow(_ userID: String) {
        subscriptions.removeAll { $0.userID == userID }
        fresh.removeAll { $0.userID == userID }
        persist()
    }

    /// The new uploads as a list to add from.
    var freshCollection: SoundCloudCollection? {
        guard let first = fresh.first else { return nil }
        return SoundCloudCollection(title: "Новое от подписок", artist: Set(fresh.map(\.artist)).sorted().joined(separator: ", "),
                                    url: first.url, artwork: first.artwork, tracks: fresh, kind: .subscriptions)
    }

    func clearFresh() {
        fresh = []
        persist()
    }

    func checkIfDue(interval: TimeInterval = 6 * 3_600) {
        guard !subscriptions.isEmpty else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard now().timeIntervalSince(last) >= interval else { return }
        check()
    }

    /// Looks at each artist's latest uploads; one artist failing does not stop the others.
    func check(completion: (() -> Void)? = nil) {
        guard !checking, !subscriptions.isEmpty else { completion?(); return }
        checking = true
        lastError = nil
        defaults.set(now(), forKey: Self.lastCheckKey)
        let snapshot = subscriptions
        queue.async { [weak self] in
            guard let self else { return }
            var found: [String: [SoundCloudTrack]] = [:]
            var failures = 0
            for subscription in snapshot {
                do {
                    let list = try self.fetch(subscription.userID, subscription.name, SoundCloudCancellation())
                    found[subscription.userID] = list.tracks
                } catch {
                    failures += 1
                }
            }
            DispatchQueue.main.async {
                self.checking = false
                var new: [SoundCloudTrack] = []
                for index in self.subscriptions.indices {
                    let subscription = self.subscriptions[index]
                    guard let tracks = found[subscription.userID] else { continue }
                    let seen = Set(subscription.seen)
                    new += tracks.filter { !seen.contains($0.id) }
                    self.subscriptions[index].seen = Array((tracks.map(\.id) + subscription.seen.filter { id in !tracks.contains { $0.id == id } })
                        .prefix(Self.seenLimit))
                    self.subscriptions[index].lastChecked = self.now()
                    if let artwork = tracks.first?.artwork, subscription.artwork == nil { self.subscriptions[index].artwork = artwork }
                }
                let known = Set(self.fresh.map(\.id))
                new = new.filter { !known.contains($0.id) }
                self.fresh = new + self.fresh
                if failures > 0 { self.lastError = failures == snapshot.count ? "SoundCloud не ответил. Проверим позже." : "Не удалось проверить авторов: \(failures)." }
                self.persist()
                if !new.isEmpty { self.onNew?(new) }
                completion?()
            }
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(subscriptions) { defaults.set(data, forKey: Self.defaultsKey) }
        if let data = try? encoder.encode(fresh.prefix(200).map(StoredTrack.init)) { defaults.set(data, forKey: Self.freshKey) }
    }
}
