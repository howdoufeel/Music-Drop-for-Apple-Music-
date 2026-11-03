import AVFoundation
import Observation

/// Plays one SoundCloud stream so a track can be heard before it is added.
/// AVFoundation streams the HLS playlist itself; nothing is written to disk.
@Observable final class PreviewPlayer {
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var progress: Double = 0
    private(set) var duration: Double = 0
    /// Called with `true` when the stream could not be played, `false` when it simply ended.
    @ObservationIgnored var onFinish: ((Bool) -> Void)?
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            self?.tick(time)
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func play(_ url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            self?.finish(failed: false)
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        isBuffering = true
    }

    func toggle() {
        guard player.currentItem != nil else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let clamped = min(1, max(0, fraction))
        progress = clamped
        player.seek(to: CMTime(seconds: duration * clamped, preferredTimescale: 600))
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        isPlaying = false
        isBuffering = false
        progress = 0
        duration = 0
    }

    private func tick(_ time: CMTime) {
        guard let item = player.currentItem else { return }
        if item.status == .failed { finish(failed: true); return }
        let total = item.duration.seconds
        if total.isFinite, total > 0 {
            if duration != total { duration = total }
            let fraction = min(1, max(0, time.seconds / total))
            // Half-percent steps keep the row from re-rendering on every tick.
            if abs(fraction - progress) >= 0.005 { progress = fraction }
        }
        let buffering = isPlaying && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if buffering != isBuffering { isBuffering = buffering }
    }

    private func finish(failed: Bool) {
        stop()
        onFinish?(failed)
    }
}
