// WuiVideoPlayer.swift
// Video player component with reactive volume control
//
// # Layout Behavior
// Video player expands to fill available space in both dimensions.
// Maintains aspect ratio when possible using AVPlayerLayer/AVPlayerView.
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
    static func from(_ aspect: Int32) -> AVLayerVideoGravity {
        switch aspect {
        case 0: return .resizeAspect      // Fit
        case 1: return .resizeAspectFill  // Fill
        case 2: return .resize            // Stretch
        default: return .resizeAspect
        }
    }
}

@MainActor
final class WuiVideoPlayer: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_video_player_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let player: AVPlayer
    private let showControls: Bool

    // For controls mode (macOS: AVPlayerView, iOS: AVPlayerViewController's view)
    #if canImport(AppKit)
    private var playerView: AVPlayerView?
    #elseif canImport(UIKit)
    private var playerViewController: AVPlayerViewController?
    #endif

    // For no-controls mode (raw AVPlayerLayer)
    private var playerLayer: AVPlayerLayer?

    private var videoComputed: WuiComputed<WuiVideo>
    private var volumeBinding: WuiBinding<Float>
    private var onEvent: CWaterUI.WuiFn_WuiVideoEvent
    private var videoWatcher: WatcherGuard?
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

        let videoComputed = WuiComputed<WuiVideo>(ffiVideoPlayer.video!)
        let volumeBinding = WuiBinding<Float>(ffiVideoPlayer.volume!)
        let aspectRatio = AVLayerVideoGravity.from(ffiVideoPlayer.aspect_ratio)
        let showControls = ffiVideoPlayer.show_controls
        let onEvent = ffiVideoPlayer.on_event

        self.init(stretchAxis: stretchAxis, video: videoComputed, volume: volumeBinding, aspectRatio: aspectRatio, showControls: showControls, onEvent: onEvent)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, video: WuiComputed<WuiVideo>, volume: WuiBinding<Float>, aspectRatio: AVLayerVideoGravity, showControls: Bool, onEvent: CWaterUI.WuiFn_WuiVideoEvent) {
        self.stretchAxis = stretchAxis
        self.videoComputed = video
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

        if showControls {
            configureWithControls(aspectRatio: aspectRatio)
        } else {
            configureWithoutControls(aspectRatio: aspectRatio)
        }

        updateVideo(video.value)
        updateVolume(volume.value)
        startWatchers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configureWithControls(aspectRatio: AVLayerVideoGravity) {
        #if canImport(AppKit)
        // macOS: Use AVPlayerView for native controls
        let pv = AVPlayerView()
        pv.player = player
        pv.controlsStyle = .inline
        pv.showsFullScreenToggleButton = true
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
        pvc.showsPlaybackControls = true
        pvc.view.translatesAutoresizingMaskIntoConstraints = false

        // Set video gravity
        pvc.videoGravity = aspectRatio

        addSubview(pvc.view)
        NSLayoutConstraint.activate([
            pvc.view.topAnchor.constraint(equalTo: topAnchor),
            pvc.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            pvc.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            pvc.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        self.playerViewController = pvc
        #endif

        setupEndNotification()
    }

    private func configureWithoutControls(aspectRatio: AVLayerVideoGravity) {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = aspectRatio
        layer.isHidden = false
        layer.backgroundColor = nil

        #if canImport(UIKit)
        self.layer.addSublayer(layer)
        #elseif canImport(AppKit)
        guard let viewLayer = self.layer else {
            print("❌ VideoPlayer: View layer is nil in configureWithoutControls!")
            return
        }
        viewLayer.addSublayer(layer)
        #endif

        self.playerLayer = layer
        setupEndNotification()
    }

    private func setupEndNotification() {
        // Loop video playback
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
        // When no size is proposed, use a reasonable default
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
        if !showControls {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer?.frame = bounds
            CATransaction.commit()
        }
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
        if !showControls {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer?.frame = bounds
            CATransaction.commit()
        }
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

        // Loop video playback
        player.seek(to: .zero)
        player.play()
    }

    private func startWatchers() {
        videoWatcher = videoComputed.watch { [weak self] video, _ in
            self?.updateVideo(video)
        }

        volumeWatcher = volumeBinding.watch { [weak self] volume, _ in
            self?.updateVolume(volume)
        }
    }

    private func updateVideo(_ video: WuiVideo) {
        let urlStr = WuiStr(video.url)
        let urlString = urlStr.toString()

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
        player.pause()
    }
}
