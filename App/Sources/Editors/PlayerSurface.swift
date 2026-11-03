// Playback for the Trim and Split editors (P27): plays only the chosen range and stops at its end, and seeks
// frame-exactly where the person clicks. Nothing plays until the editor's view enables it on a desktop that plays
// media, so tests, snapshots and measurements (`EditorDesktop.offScreen`) never create a player.
import AVFoundation
import AppKit
import SwiftUI

/// When playback of a range stops, decided apart from the player so it can be tested without playing media.
struct PlaybackStop: Equatable {
    enum Decision: Equatable {
        case keepPlaying
        case stop
        /// Stop when the player crosses this time.
        case armBoundary(Double)
    }

    private(set) var end: Double
    /// False while the seek to the range's start runs: until then the player's time is where it was before.
    private(set) var started = false

    init(end: Double) {
        self.end = end
    }

    /// The seek to the start finished and the player plays.
    mutating func start() -> Decision {
        started = true
        return .armBoundary(end)
    }

    /// The end moved while playing. A boundary observer fires only for a time the player crosses, so an end at or
    /// behind `now` stops at once.
    mutating func retarget(end: Double, now: Double?) -> Decision {
        self.end = end
        guard started else { return .keepPlaying }
        if let now, now >= end { return .stop }
        return .armBoundary(end)
    }

    /// The periodic observer's backstop, should a boundary be missed.
    func tick(_ now: Double) -> Decision {
        started && now >= end ? .stop : .keepPlaying
    }
}

@MainActor
final class TimelinePlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    private(set) var player: AVPlayer?
    /// The time while playing, about 30 times a second.
    var onTime: ((Double) -> Void)?
    /// Playback stopped at the end of the range, at this time.
    var onFinish: ((Double) -> Void)?

    private let url: URL
    private var periodicObserver: Any?
    private var boundaryObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stop: PlaybackStop?
    /// One seek runs at a time; a click during it replaces the one waiting (coalesced, as QuickTime scrubs).
    private var seekRunning = false
    private var pendingSeek: Double?
    /// Bumped by each play and pause, so a play whose seek finishes after a pause doesn't start.
    private var generation = 0

    init(url: URL) {
        self.url = url
    }

    /// Creates the player. Only the editor's view calls it, and only when `editorPlaysMedia` is true.
    func enable() {
        guard player == nil else { return }
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        self.player = player
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                if self.stop?.tick(time.seconds) == .stop {
                    self.finish()
                } else {
                    self.onTime?(time.seconds)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    func play(_ range: ClosedRange<Double>) {
        guard let player else { return }
        generation += 1
        let token = generation
        pendingSeek = nil
        isPlaying = true
        removeBoundary()
        stop = PlaybackStop(end: range.upperBound)
        Task { [weak self] in
            _ = await player.seek(to: Self.time(range.lowerBound), toleranceBefore: .zero, toleranceAfter: .zero)
            guard let self, self.generation == token, self.isPlaying, let decision = self.stop?.start() else { return }
            self.apply(decision)
            player.play()
        }
    }

    /// Where the player is while it plays; nil when paused, when the model's playhead is the time.
    var currentSeconds: Double? {
        guard isPlaying, stop?.started == true, let seconds = player?.currentTime().seconds, seconds.isFinite
        else { return nil }
        return seconds
    }

    func pause() {
        generation += 1
        player?.pause()
        isPlaying = false
        removeBoundary()
        stop = nil
    }

    /// Moves where playback stops (the end grip moved while playing).
    func retarget(end: Double) {
        guard player != nil, isPlaying, let decision = stop?.retarget(end: end, now: currentSeconds) else { return }
        apply(decision)
    }

    /// Shows the frame at `seconds`, exactly (zero tolerance).
    func seek(to seconds: Double) {
        guard let player else { return }
        pendingSeek = seconds
        guard !seekRunning else { return }
        seekRunning = true
        Task { [weak self] in
            while let target = self?.pendingSeek {
                self?.pendingSeek = nil
                _ = await player.seek(to: Self.time(target), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            self?.seekRunning = false
        }
    }

    func tearDown() {
        pause()
        if let periodicObserver { player?.removeTimeObserver(periodicObserver) }
        periodicObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
    }

    private func apply(_ decision: PlaybackStop.Decision) {
        switch decision {
        case .keepPlaying:
            break
        case .stop:
            finish()
        case .armBoundary(let end):
            guard let player else { return }
            removeBoundary()
            boundaryObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: Self.time(end))], queue: .main
            ) { [weak self] in
                MainActor.assumeIsolated { self?.finish() }
            }
        }
    }

    private func finish() {
        guard isPlaying else { return }
        let end = stop?.end ?? player?.currentTime().seconds ?? 0
        pause()
        onFinish?(end)
    }

    private func removeBoundary() {
        if let boundaryObserver { player?.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}

/// The video, aspect-fit. The timeline view puts it over the poster, which shows until the player has a frame.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }

    static func dismantleNSView(_ nsView: PlayerView, coordinator: ()) {
        nsView.playerLayer.player = nil
    }

    final class PlayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        // The timeline's gestures and the header's drag area take the mouse; the picture never does.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
