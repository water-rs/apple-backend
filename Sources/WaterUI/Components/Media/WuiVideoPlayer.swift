import AVFoundation
import AVKit
import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

#if canImport(AppKit)
  private final class WuiVideoPlayerPictureInPictureDelegateProxy: NSObject,
    AVPlayerViewPictureInPictureDelegate
  {
    private let owner: Unmanaged<WuiVideoPlayer>

    init(owner: WuiVideoPlayer) {
      self.owner = Unmanaged.passUnretained(owner)
    }

    func playerViewDidStartPicture(inPicture playerView: AVPlayerView) {
      let owner = owner.takeUnretainedValue()
      MainActor.assumeIsolated {
        owner.emitPictureInPictureChanged(true)
      }
    }

    func playerViewDidStopPicture(inPicture playerView: AVPlayerView) {
      let owner = owner.takeUnretainedValue()
      MainActor.assumeIsolated {
        owner.emitPictureInPictureChanged(false)
      }
    }

    func playerView(
      _ playerView: AVPlayerView,
      failedToStartPictureInPictureWithError error: Error
    ) {
      let owner = owner.takeUnretainedValue()
      MainActor.assumeIsolated {
        owner.emitPlaybackError(error)
      }
    }
  }
#endif

#if canImport(UIKit)
  private final class WuiVideoPlayerViewControllerDelegateProxy: NSObject,
    AVPlayerViewControllerDelegate
  {
    private let owner: Unmanaged<WuiVideoPlayer>

    init(owner: WuiVideoPlayer) {
      self.owner = Unmanaged.passUnretained(owner)
    }

    func playerViewControllerDidStartPictureInPicture(
      _ playerViewController: AVPlayerViewController
    ) {
      let owner = owner.takeUnretainedValue()
      MainActor.assumeIsolated {
        owner.emitPictureInPictureChanged(true)
      }
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController)
    {
      let owner = owner.takeUnretainedValue()
      MainActor.assumeIsolated {
        owner.emitPictureInPictureChanged(false)
      }
    }

    func playerViewController(
      _ playerViewController: AVPlayerViewController,
      failedToStartPictureInPictureWithError error: Error
    ) {
      let owner = owner.takeUnretainedValue()
      MainActor.assumeIsolated {
        owner.emitPlaybackError(error)
      }
    }
  }
#endif

@MainActor
final class WuiVideoPlayer: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_video_player_id() }

  private(set) var stretchAxis: WuiStretchAxis
  private let playback: WuiVideoPlaybackCoordinator
  private let showControls: Bool
  private var reportedPictureInPictureActive: Bool?

  #if canImport(AppKit)
    private let playerView: AVPlayerView
    private var pictureInPictureDelegateProxy: WuiVideoPlayerPictureInPictureDelegateProxy?
  #elseif canImport(UIKit)
    private let playerViewController: AVPlayerViewController
    private var playerViewControllerDelegateProxy: WuiVideoPlayerViewControllerDelegateProxy?
  #endif

  init(anyview: OpaquePointer, env: WuiEnvironment) {
    let descriptor: CWaterUI.WuiVideoPlayer = waterui_force_as_video_player(anyview)
    guard descriptor.projection == CWaterUI.WuiVideoProjection_Rectilinear else {
      fatalError(
        "Apple's native AVPlayer realization does not support equirectangular projection; install the WaterKit self-drawn realization for spherical video"
      )
    }
    stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
    playback = WuiVideoPlaybackCoordinator(descriptor.playbackDescriptor, loops: false)
    showControls = descriptor.show_controls

    #if canImport(AppKit)
      playerView = AVPlayerView()
    #elseif canImport(UIKit)
      playerViewController = AVPlayerViewController()
    #endif

    super.init(frame: .zero)
    configurePlayerView(gravity: AVLayerVideoGravity.from(descriptor.content_mode))
    playback.activate()
    emitPictureInPictureChanged(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configurePlayerView(gravity: AVLayerVideoGravity) {
    #if canImport(AppKit)
      playerView.player = playback.player
      playerView.controlsStyle = showControls ? .inline : .none
      playerView.showsFullScreenToggleButton = showControls
      playerView.allowsPictureInPicturePlayback = true
      playerView.videoGravity = gravity
      playerView.translatesAutoresizingMaskIntoConstraints = false
      playerView.wantsLayer = true

      let delegateProxy = WuiVideoPlayerPictureInPictureDelegateProxy(owner: self)
      playerView.pictureInPictureDelegate = delegateProxy
      pictureInPictureDelegateProxy = delegateProxy

      addSubview(playerView)
      NSLayoutConstraint.activate([
        playerView.topAnchor.constraint(equalTo: topAnchor),
        playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
        playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
        playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
      guard let layer = playerView.layer else {
        fatalError("AVPlayerView did not create its requested backing layer")
      }
      applyResolvedDynamicRange(to: layer, for: self)
    #elseif canImport(UIKit)
      playerViewController.player = playback.player
      playerViewController.showsPlaybackControls = showControls
      playerViewController.allowsPictureInPicturePlayback = true
      playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
      playerViewController.videoGravity = gravity
      playerViewController.view.translatesAutoresizingMaskIntoConstraints = true
      playerViewController.view.insetsLayoutMarginsFromSafeArea = false
      playerViewController.view.isUserInteractionEnabled = showControls

      let delegateProxy = WuiVideoPlayerViewControllerDelegateProxy(owner: self)
      playerViewController.delegate = delegateProxy
      playerViewControllerDelegateProxy = delegateProxy

      addSubview(playerViewController.view)
      applyResolvedDynamicRange(to: playerViewController.view.layer, for: self)
    #endif
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    playback.sizeThatFits(proposal)
  }

  #if canImport(UIKit)
    override func didMoveToWindow() {
      super.didMoveToWindow()

      if window != nil, playerViewController.parent == nil {
        guard let parent = findParentViewController() else {
          fatalError("WaterUI video player was attached outside a UIViewController hierarchy")
        }
        parent.addChild(playerViewController)
        playerViewController.didMove(toParent: parent)
      } else if window == nil {
        playback.pauseForDetachment()
        if playerViewController.parent != nil {
          playerViewController.willMove(toParent: nil)
          playerViewController.removeFromParent()
        }
      }
    }

    private func findParentViewController() -> UIViewController? {
      var responder: UIResponder? = self
      while let next = responder?.next {
        if let viewController = next as? UIViewController {
          return viewController
        }
        responder = next
      }
      return nil
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      playerViewController.view.frame = bounds
      applyResolvedDynamicRange(to: playerViewController.view.layer, for: self)
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
      guard let layer = playerView.layer else {
        fatalError("AVPlayerView lost its backing layer")
      }
      applyResolvedDynamicRange(to: layer, for: self)
    }

    nonisolated override var isFlipped: Bool { true }

    override var wantsLayer: Bool {
      get { true }
      set {}
    }
  #endif

  fileprivate func emitPictureInPictureChanged(_ active: Bool) {
    guard reportedPictureInPictureActive != active else { return }
    reportedPictureInPictureActive = active
    playback.emitEvent(
      CWaterUI.WuiVideoEventType_PictureInPictureChanged,
      pictureInPictureActive: active
    )
  }

  fileprivate func emitPlaybackError(_ error: Error) {
    playback.emitError(error.localizedDescription)
  }
}
