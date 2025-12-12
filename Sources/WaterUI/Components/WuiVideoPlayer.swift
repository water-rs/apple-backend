// WuiVideoPlayer.swift
// Full-featured video player with native playback controls
//
// # Layout Behavior
// Video player expands to fill available space in both dimensions.
// Maintains aspect ratio using platform-native video player controls.
//
// # Platform Implementation
// - iOS/tvOS: Uses AVPlayerViewController for standard iOS controls
// - macOS: Uses AVPlayerView with inline controls
//
// # Volume Control
// The volume system uses a special encoding:
// - Positive values (> 0): Audible volume level
// - Negative values (< 0): Muted state that preserves the original volume level
// - When unmuting, the absolute value is restored

import AVFoundation
import AVKit
import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension AVLayerVideoGravity {
    static func from(_ aspect: WuiAspectRatio) -> AVLayerVideoGravity {
        switch aspect {
        case WuiAspectRatio_Fit: return .resizeAspect
        case WuiAspectRatio_Fill: return .resizeAspectFill
        case WuiAspectRatio_Stretch: return .resize
        default: return .resizeAspect
        }
    }
}

/// Full-featured video player with native playback controls.
/// Uses AVPlayerViewController (iOS) or AVPlayerView (macOS).
@MainActor
final class WuiVideoPlayer: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_video_player_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let player: AVPlayer
    private let showControls: Bool

    // Platform-specific player views
    #if canImport(AppKit)
    private var playerView: AVPlayerView?
    #elseif canImport(UIKit)
    private var playerViewController: AVPlayerViewController?
    #endif

    private var sourceComputed: WuiComputed<WuiStr>
    private var volumeBinding: WuiBinding<Float>
    private var onEvent: CWaterUI.WuiFn_WuiVideoEvent
    private var sourceWatcher: WatcherGuard?
    private var volumeWatcher: WatcherGuard?
    private var playerItemObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?
    private var currentURL: URL?
    private var isBuffering = false

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiVideoPlayer: CWaterUI.WuiVideoPlayer = waterui_force_as_video_player(anyview)

        let sourceComputed = WuiComputed<WuiStr>(ffiVideoPlayer.source!)
        let volumeBinding = WuiBinding<Float>(ffiVideoPlayer.volume!)
        let aspectRatio = AVLayerVideoGravity.from(ffiVideoPlayer.aspect_ratio)
        let showControls = ffiVideoPlayer.show_controls
        let onEvent = ffiVideoPlayer.on_event

        self.init(stretchAxis: stretchAxis, source: sourceComputed, volume: volumeBinding, aspectRatio: aspectRatio, showControls: showControls, onEvent: onEvent)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, source: WuiComputed<WuiStr>, volume: WuiBinding<Float>, aspectRatio: AVLayerVideoGravity, showControls: Bool, onEvent: CWaterUI.WuiFn_WuiVideoEvent) {
        self.stretchAxis = stretchAxis
        self.sourceComputed = source
        self.volumeBinding = volume
        self.onEvent = onEvent
        self.player = AVPlayer()
        self.showControls = showControls

        super.init(frame: .zero)

        #if canImport(AppKit)
        wantsLayer = true
        if layer == nil {
            layer = CALayer()
        }
        #endif

        configurePlayerView(aspectRatio: aspectRatio)
        updateSource(sourceComputed.value)
        updateVolume(volume.value)
        startWatchers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configurePlayerView(aspectRatio: AVLayerVideoGravity) {
        #if canImport(AppKit)
        // macOS: Use AVPlayerView for native controls
        let pv = AVPlayerView()
        pv.player = player
        pv.controlsStyle = showControls ? .inline : .none
        pv.showsFullScreenToggleButton = showControls
        pv.translatesAutoresizingMaskIntoConstraints = false

        // Set video gravity
        switch aspectRatio {
        case .resizeAspect:
            pv.videoGravity = .resizeAspect
        case .resizeAspectFill:
            pv.videoGravity = .resizeAspectFill
        case .resize:
            pv.videoGravity = .resize
        default:
            pv.videoGravity = .resizeAspect
        }

        addSubview(pv)
        NSLayoutConstraint.activate([
            pv.topAnchor.constraint(equalTo: topAnchor),
            pv.leadingAnchor.constraint(equalTo: leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: trailingAnchor),
            pv.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        self.playerView = pv

        #elseif canImport(UIKit)
        // iOS/tvOS: Use AVPlayerViewController for native controls
        let pvc = AVPlayerViewController()
        pvc.player = player
        pvc.showsPlaybackControls = showControls
        pvc.view.translatesAutoresizingMaskIntoConstraints = true

        // Disable safe area inset adjustments for edge-to-edge video
        pvc.view.insetsLayoutMarginsFromSafeArea = false

        // Set video gravity
        pvc.videoGravity = aspectRatio

        addSubview(pvc.view)
        self.playerViewController = pvc

        // When controls are hidden, make the player transparent to touches
        // so overlaid views (like custom controls) can receive touches
        if !showControls {
            pvc.view.isUserInteractionEnabled = false
        }
        #endif

        setupEndNotification()
    }

    #if canImport(UIKit)
    override func didMoveToWindow() {
        super.didMoveToWindow()

        // AVPlayerViewController requires proper view controller containment for controls to work
        guard let pvc = playerViewController else { return }

        if window != nil {
            // Find the parent view controller and add player as child
            if let parentVC = findParentViewController() {
                if pvc.parent == nil {
                    parentVC.addChild(pvc)
                    pvc.didMove(toParent: parentVC)
                }
            }
        } else {
            // Immediately pause playback when removed from window (e.g., during hot reload)
            // This prevents double sound when the view is being replaced
            player.pause()

            // Remove from parent when leaving window
            if pvc.parent != nil {
                pvc.willMove(toParent: nil)
                pvc.removeFromParent()
            }
        }
    }

    private func findParentViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return nil
    }
    #endif

    private func setupEndNotification() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Video player expands to fill available space (both axes stretch)
        let defaultWidth: CGFloat = 320
        let defaultHeight: CGFloat = 180 // 16:9 aspect ratio

        let width = proposal.width.map { CGFloat($0) } ?? defaultWidth
        let height = proposal.height.map { CGFloat($0) } ?? defaultHeight

        return CGSize(width: width, height: height)
    }

    // MARK: - Layout

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        // AVPlayerViewController's view uses frame-based layout
        playerViewController?.view.frame = bounds
    }
    #elseif canImport(AppKit)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Pause playback when removed from window (e.g., during hot reload)
        // This prevents double sound when the view is being replaced
        if window == nil {
            player.pause()
        }
    }

    override func layout() {
        super.layout()
        // AVPlayerView uses auto-layout constraints set during configuration
    }

    override var isFlipped: Bool { true }

    override var wantsLayer: Bool {
        get { true }
        set { }
    }
    #endif

    // MARK: - Event Handling

    @objc private func playerItemDidReachEnd(_ notification: Notification) {
        guard let playerItem = notification.object as? AVPlayerItem,
              playerItem == player.currentItem
        else { return }

        // Emit ended event
        let event = CWaterUI.WuiVideoEvent(
            event_type: CWaterUI.WuiVideoEventType_Ended,
            error_message: WuiStr(string: "").intoInner()
        )
        onEvent.call(onEvent.data, event)
    }

    private func startWatchers() {
        sourceWatcher = sourceComputed.watch { [weak self] source, _ in
            self?.updateSource(source)
        }

        volumeWatcher = volumeBinding.watch { [weak self] volume, _ in
            self?.updateVolume(volume)
        }
    }

    private func updateSource(_ source: WuiStr) {
        let urlString = source.toString()

        guard let url = URL(string: urlString) else {
            // Emit error event
            let event = CWaterUI.WuiVideoEvent(
                event_type: CWaterUI.WuiVideoEventType_Error,
                error_message: WuiStr(string: "Invalid video URL").intoInner()
            )
            onEvent.call(onEvent.data, event)
            return
        }

        // Avoid reloading if URL hasn't changed
        guard url != currentURL else {
            return
        }
        currentURL = url

        let playerItem = AVPlayerItem(url: url)

        // Observe player item status for events
        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch item.status {
                case .failed:
                    let errorMessage: String
                    if let error = item.error {
                        errorMessage = error.localizedDescription
                    } else {
                        errorMessage = "Failed to load video. Check network access and sandbox permissions."
                    }
                    // Emit error event
                    let event = CWaterUI.WuiVideoEvent(
                        event_type: CWaterUI.WuiVideoEventType_Error,
                        error_message: WuiStr(string: errorMessage).intoInner()
                    )
                    self.onEvent.call(self.onEvent.data, event)
                case .readyToPlay:
                    // Emit ready event
                    let event = CWaterUI.WuiVideoEvent(
                        event_type: CWaterUI.WuiVideoEventType_ReadyToPlay,
                        error_message: WuiStr(string: "").intoInner()
                    )
                    self.onEvent.call(self.onEvent.data, event)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        // Observe buffering state - when buffer is empty
        bufferEmptyObserver = playerItem.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if item.isPlaybackBufferEmpty && !self.isBuffering {
                    self.isBuffering = true
                    let event = CWaterUI.WuiVideoEvent(
                        event_type: CWaterUI.WuiVideoEventType_Buffering,
                        error_message: WuiStr(string: "").intoInner()
                    )
                    self.onEvent.call(self.onEvent.data, event)
                }
            }
        }

        // Observe buffering state - when playback is likely to keep up
        likelyToKeepUpObserver = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if item.isPlaybackLikelyToKeepUp && self.isBuffering {
                    self.isBuffering = false
                    let event = CWaterUI.WuiVideoEvent(
                        event_type: CWaterUI.WuiVideoEventType_BufferingEnded,
                        error_message: WuiStr(string: "").intoInner()
                    )
                    self.onEvent.call(self.onEvent.data, event)
                }
            }
        }

        player.replaceCurrentItem(with: playerItem)

        // Start playing after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.player.play()
        }
    }

    private func updateVolume(_ volume: Float) {
        // Volume encoding: negative = muted (preserves volume level)
        if volume < 0 {
            player.isMuted = true
        } else {
            player.isMuted = false
            player.volume = volume
        }
    }

    @MainActor deinit {
        NotificationCenter.default.removeObserver(self)
        sourceWatcher = nil
        volumeWatcher = nil
        statusObserver?.invalidate()
        bufferEmptyObserver?.invalidate()
        likelyToKeepUpObserver?.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
