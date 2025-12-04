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

@MainActor
final class WuiVideoPlayer: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_video_player_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private var videoComputed: WuiComputed<WuiVideo>
    private var volumeBinding: WuiBinding<Float>
    private var videoWatcher: WatcherGuard?
    private var volumeWatcher: WatcherGuard?
    private var playerItemObserver: NSKeyValueObservation?
    private var currentURL: URL?

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiVideoPlayer: CWaterUI.WuiVideoPlayer = waterui_force_as_video_player(anyview)

        let videoComputed = WuiComputed<WuiVideo>(ffiVideoPlayer.video!)
        let volumeBinding = WuiBinding<Float>(ffiVideoPlayer.volume!)

        self.init(stretchAxis: stretchAxis, video: videoComputed, volume: volumeBinding)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, video: WuiComputed<WuiVideo>, volume: WuiBinding<Float>) {
        self.stretchAxis = stretchAxis
        self.videoComputed = video
        self.volumeBinding = volume
        self.player = AVPlayer()
        self.playerLayer = AVPlayerLayer(player: player)

        super.init(frame: .zero)

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

    // MARK: - Configuration

    private func configurePlayerLayer() {
        playerLayer.videoGravity = .resizeAspect

        #if canImport(UIKit)
        layer.addSublayer(playerLayer)
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
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
        guard let url = URL(string: urlStr.toString()) else { return }

        // Avoid reloading if URL hasn't changed
        guard url != currentURL else { return }
        currentURL = url

        let playerItem = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: playerItem)
        player.play()
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
