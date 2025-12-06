// WuiVideo.swift
// Raw video view without native controls - uses AVPlayerLayer directly
//
// # Layout Behavior
// Video view expands based on aspect ratio setting.
// Uses AVPlayerLayer for direct video rendering without controls.
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

/// Raw video view that displays video without native controls.
/// Uses AVPlayerLayer directly for video rendering.
@MainActor
final class WuiVideo: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_video_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private let loops: Bool

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
        let ffiVideo: CWaterUI.WuiVideo = waterui_force_as_video(anyview)

        let sourceComputed = WuiComputed<WuiStr>(ffiVideo.source!)
        let volumeBinding = WuiBinding<Float>(ffiVideo.volume!)
        let aspectRatio = AVLayerVideoGravity.from(ffiVideo.aspect_ratio)
        let loops = ffiVideo.loops
        let onEvent = ffiVideo.on_event

        self.init(stretchAxis: stretchAxis, source: sourceComputed, volume: volumeBinding, aspectRatio: aspectRatio, loops: loops, onEvent: onEvent)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, source: WuiComputed<WuiStr>, volume: WuiBinding<Float>, aspectRatio: AVLayerVideoGravity, loops: Bool, onEvent: CWaterUI.WuiFn_WuiVideoEvent) {
        self.stretchAxis = stretchAxis
        self.sourceComputed = source
        self.volumeBinding = volume
        self.loops = loops
        self.onEvent = onEvent
        self.player = AVPlayer()

        // Create player layer
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = aspectRatio
        layer.isHidden = false
        layer.backgroundColor = nil
        self.playerLayer = layer

        super.init(frame: .zero)

        #if canImport(AppKit)
        wantsLayer = true
        if self.layer == nil {
            self.layer = CALayer()
        }
        self.layer?.addSublayer(playerLayer)
        #elseif canImport(UIKit)
        self.layer.addSublayer(playerLayer)
        #endif

        setupEndNotification()
        updateSource(sourceComputed.value)
        updateVolume(volume.value)
        startWatchers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - End Notification

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
        // Video view expands to fill available space
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
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

        // Loop video playback if enabled
        if loops {
            player.seek(to: .zero)
            player.play()
        }
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
