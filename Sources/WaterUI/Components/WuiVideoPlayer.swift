// WuiVideoPlayer.swift
// Video player component with reactive volume control
//
// # Layout Behavior
// Video player expands to fill available space in both dimensions.
// Maintains aspect ratio when possible using AVPlayerLayer.
//
// # Volume Control
// The volume system uses a special encoding:
// - Positive values (> 0): Audible volume level
// - Negative values (< 0): Muted state that preserves the original volume level
// - When unmuting, the absolute value is restored

import AVFoundation
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
    private let playerLayer: AVPlayerLayer
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
        self.playerLayer = AVPlayerLayer(player: player)

        #if canImport(UIKit)
        if showControls {
            // iOS/tvOS can show native controls via AVPlayerViewController
            // For now, just note the preference
        }
        #elseif canImport(AppKit)
        // macOS AVPlayerLayer doesn't have built-in controls
        // Would need AVPlayerView for controls
        #endif

        super.init(frame: .zero)

        // CRITICAL: Ensure view is layer-backed on macOS BEFORE configuring player layer
        #if canImport(UIKit)
        // UIView is always layer-backed
        #elseif canImport(AppKit)
        wantsLayer = true
        // Force layer creation
        if layer == nil {
            layer = CALayer()
        }
        #endif

        // Set aspect ratio mode
        playerLayer.videoGravity = aspectRatio

        configurePlayerLayer()

        updateVideo(video.value)
        updateVolume(volume.value)
        startWatchers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Video player expands to fill available space (both axes stretch)
        // When no size is proposed, use a reasonable default
        let defaultWidth: CGFloat = 320
        let defaultHeight: CGFloat = 180 // 16:9 aspect ratio

        let width = proposal.width.map { CGFloat($0) } ?? defaultWidth
        let height = proposal.height.map { CGFloat($0) } ?? defaultHeight

        let size = CGSize(width: width, height: height)
        print("📹 VideoPlayer: sizeThatFits called - proposal: \(proposal), returning: \(size)")
        return size
    }

    // MARK: - Layout

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        print("📹 VideoPlayer: layoutSubviews - bounds = \(bounds)")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
        print("📹 VideoPlayer: layout - bounds = \(bounds), frame = \(frame)")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override var isFlipped: Bool { true }

    override var wantsLayer: Bool {
        get { true }
        set { }
    }
    #endif

    // MARK: - Configuration

    private func configurePlayerLayer() {
        // videoGravity is set in init based on aspect_ratio parameter
        playerLayer.isHidden = false  // Ensure player layer is visible by default

        // No background color - let video fill the space naturally
        playerLayer.backgroundColor = nil

        #if canImport(UIKit)
        layer.addSublayer(playerLayer)
        #elseif canImport(AppKit)
        // Layer should already be created in init - force unwrap to catch issues early
        guard let viewLayer = layer else {
            print("❌ VideoPlayer: View layer is nil in configurePlayerLayer!")
            return
        }
        viewLayer.addSublayer(playerLayer)
        print("📹 VideoPlayer: Added playerLayer to view layer. PlayerLayer frame: \(playerLayer.frame)")
        #endif

        // Loop video playback
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }

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
        print("📹 VideoPlayer: Attempting to load video from URL: \(urlString)")

        guard let url = URL(string: urlString) else {
            print("❌ VideoPlayer: Invalid URL format")
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
            print("📹 VideoPlayer: URL unchanged, skipping reload")
            return
        }
        currentURL = url

        // Don't hide error yet - wait until video is ready to play
        print("📹 VideoPlayer: Creating AVPlayerItem for URL: \(url)")
        let playerItem = AVPlayerItem(url: url)

        // Observe player item status for events
        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                print("📹 VideoPlayer: Status changed to \(item.status.rawValue)")
                switch item.status {
                case .failed:
                    print("❌ VideoPlayer: Failed to load video")
                    let errorMessage: String
                    if let error = item.error {
                        print("❌ VideoPlayer error: \(error)")
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
                    print("✅ VideoPlayer: Ready to play")
                    // Emit ready event
                    let event = CWaterUI.WuiVideoEvent(
                        event_type: CWaterUI.WuiVideoEventType_ReadyToPlay,
                        error_message: WuiStr(string: "").intoInner()
                    )
                    self.onEvent.call(self.onEvent.data, event)
                case .unknown:
                    print("⚠️ VideoPlayer: Status unknown")
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
                    print("📹 VideoPlayer: Buffering started")
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
                    print("📹 VideoPlayer: Buffering ended")
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

        // Ensure player starts playing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.player.play()
            print("📹 VideoPlayer: Play called - rate: \(self?.player.rate ?? 0)")
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
