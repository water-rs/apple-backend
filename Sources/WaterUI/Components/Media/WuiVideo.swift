import AVFoundation
import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiVideo: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_video_id() }

  private(set) var stretchAxis: WuiStretchAxis
  private let playback: WuiVideoPlaybackCoordinator
  private let playerLayer: AVPlayerLayer

  init(anyview: OpaquePointer, env: WuiEnvironment) {
    let descriptor: CWaterUI.WuiVideo = waterui_force_as_video(anyview)
    guard descriptor.projection == CWaterUI.WuiVideoProjection_Rectilinear else {
      fatalError(
        "Apple's native AVPlayer realization does not support equirectangular projection; install the WaterKit self-drawn realization for spherical video"
      )
    }
    stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
    playback = WuiVideoPlaybackCoordinator(descriptor.playbackDescriptor, loops: descriptor.loops)

    let playerLayer = AVPlayerLayer(player: playback.player)
    playerLayer.videoGravity = AVLayerVideoGravity.from(descriptor.content_mode)
    self.playerLayer = playerLayer

    super.init(frame: .zero)

    #if canImport(AppKit)
      let hostLayer = CALayer()
      layer = hostLayer
      hostLayer.addSublayer(playerLayer)
    #elseif canImport(UIKit)
      layer.addSublayer(playerLayer)
    #endif

    applyResolvedDynamicRange(to: playerLayer, for: self)
    playback.activate()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    playback.sizeThatFits(proposal)
  }

  #if canImport(UIKit)
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil {
        playback.pauseForDetachment()
      }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      layoutPlayerLayer()
    }
  #elseif canImport(AppKit)
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        playback.pauseForDetachment()
      }
    }

    override func layout() {
      super.layout()
      layoutPlayerLayer()
    }

    nonisolated override var isFlipped: Bool { true }

    override var wantsLayer: Bool {
      get { true }
      set {}
    }
  #endif

  private func layoutPlayerLayer() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.frame = bounds
    CATransaction.commit()
    applyResolvedDynamicRange(to: playerLayer, for: self)
  }
}
