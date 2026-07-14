import AVFoundation
import CWaterUI
import Foundation

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
    default: fatalError("Unsupported WaterUI video aspect ratio: \(aspect.rawValue)")
    }
  }
}

private func opaquePointer<T>(_ pointer: UnsafeMutablePointer<T>?) -> OpaquePointer? {
  pointer.map { OpaquePointer(UnsafeMutableRawPointer($0)) }
}

private func opaquePointer(_ pointer: OpaquePointer?) -> OpaquePointer? {
  pointer
}

private enum WuiNativeSubtitleSelection: Equatable {
  case automatic
  case off
  case track(Int)

  init(_ selection: CWaterUI.WuiSubtitleSelection) {
    switch selection.selection_type {
    case WuiSubtitleSelectionType_Auto:
      self = .automatic
    case WuiSubtitleSelectionType_Off:
      self = .off
    case WuiSubtitleSelectionType_Track:
      self = .track(Int(selection.track_index))
    default:
      fatalError(
        "Unsupported WaterUI subtitle selection: \(selection.selection_type.rawValue)"
      )
    }
  }
}

struct WuiNativePlaybackPolicy {
  let realtime: Bool
  let preferredForwardBufferSeconds: TimeInterval

  init(_ policy: CWaterUI.WuiVideoPlaybackPolicy) {
    realtime = policy.realtime
    preferredForwardBufferSeconds = TimeInterval(policy.vod_start_buffer_ms) / 1_000
  }
}

struct WuiVideoPlaybackDescriptor {
  let source: OpaquePointer?
  let title: OpaquePointer?
  let artist: OpaquePointer?
  let album: OpaquePointer?
  let artworkURL: OpaquePointer?
  let durationSeconds: OpaquePointer?
  let hasNext: OpaquePointer?
  let hasPrevious: OpaquePointer?
  let volume: OpaquePointer?
  let subtitleSelection: OpaquePointer?
  let playbackRate: OpaquePointer?
  let preservePitch: OpaquePointer?
  let onEvent: OpaquePointer?
  let playbackPolicy: WuiNativePlaybackPolicy

  init(_ descriptor: CWaterUI.WuiVideoPlaybackDescriptor) {
    source = opaquePointer(descriptor.source)
    title = opaquePointer(descriptor.title)
    artist = opaquePointer(descriptor.artist)
    album = opaquePointer(descriptor.album)
    artworkURL = opaquePointer(descriptor.artwork_url)
    durationSeconds = opaquePointer(descriptor.duration_seconds)
    hasNext = opaquePointer(descriptor.has_next)
    hasPrevious = opaquePointer(descriptor.has_previous)
    volume = opaquePointer(descriptor.volume)
    subtitleSelection = opaquePointer(descriptor.subtitle_selection)
    playbackRate = opaquePointer(descriptor.playback_rate)
    preservePitch = opaquePointer(descriptor.preserve_pitch)
    onEvent = opaquePointer(descriptor.on_event)
    playbackPolicy = WuiNativePlaybackPolicy(descriptor.playback_policy)
  }
}

extension CWaterUI.WuiVideo {
  var playbackDescriptor: WuiVideoPlaybackDescriptor {
    WuiVideoPlaybackDescriptor(playback)
  }
}

extension CWaterUI.WuiVideoPlayer {
  var playbackDescriptor: WuiVideoPlaybackDescriptor {
    WuiVideoPlaybackDescriptor(playback)
  }
}

@MainActor
private struct WuiVideoPlaybackSignals {
  let source: WuiComputed<WuiStr>
  let title: WuiComputed<WuiStr>
  let artist: WuiComputed<WuiStr>
  let album: WuiComputed<WuiStr>
  let artworkURL: WuiComputed<WuiStr>
  let durationSeconds: WuiComputed<Double>
  let hasNext: WuiBinding<Bool>
  let hasPrevious: WuiBinding<Bool>
  let volume: WuiBinding<Float>
  let subtitleSelection: WuiBinding<CWaterUI.WuiSubtitleSelection>
  let playbackRate: WuiBinding<Float>
  let preservePitch: WuiBinding<Bool>

  init(_ descriptor: WuiVideoPlaybackDescriptor) {
    source = WuiComputed(Self.require(descriptor.source, named: "source"))
    title = WuiComputed(Self.require(descriptor.title, named: "title"))
    artist = WuiComputed(Self.require(descriptor.artist, named: "artist"))
    album = WuiComputed(Self.require(descriptor.album, named: "album"))
    artworkURL = WuiComputed(Self.require(descriptor.artworkURL, named: "artwork_url"))
    durationSeconds = WuiComputed(
      Self.require(descriptor.durationSeconds, named: "duration_seconds"))
    hasNext = WuiBinding(Self.require(descriptor.hasNext, named: "has_next"))
    hasPrevious = WuiBinding(Self.require(descriptor.hasPrevious, named: "has_previous"))
    volume = WuiBinding(Self.require(descriptor.volume, named: "volume"))
    subtitleSelection = WuiBinding(
      Self.require(descriptor.subtitleSelection, named: "subtitle_selection")
    )
    playbackRate = WuiBinding(Self.require(descriptor.playbackRate, named: "playback_rate"))
    preservePitch = WuiBinding(Self.require(descriptor.preservePitch, named: "preserve_pitch"))
  }

  private static func require(_ pointer: OpaquePointer?, named name: StaticString) -> OpaquePointer
  {
    guard let pointer else {
      fatalError("WaterUI video descriptor is missing its \(name) signal")
    }
    return pointer
  }
}

@MainActor
final class WuiVideoPlaybackCoordinator: WuiMediaSessionHost {
  let player = AVPlayer()

  private let signals: WuiVideoPlaybackSignals
  private let loops: Bool
  private let onEvent: OpaquePointer?
  private let playbackPolicy: WuiNativePlaybackPolicy
  private var watchers: [WatcherGuard] = []
  private var itemObservers: [NSKeyValueObservation] = []
  private var playbackStateObserver: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var subtitleSelectionTask: Task<Void, Never>?
  private var currentURL: URL?
  private var requestedSubtitleSelection = WuiNativeSubtitleSelection.automatic
  private var isBuffering = false
  private var requestedVolume: Float = 0.5
  private var requestedPlaybackRate: Float = 1
  private var preservePitch = true
  private var isDucked = false
  private var playbackShouldStartWhenReady = false
  private var reportedPlaying: Bool?
  private var title = ""
  private var artist = ""
  private var album = ""
  private var artworkURL = ""
  private var configuredDurationSeconds = -1.0
  private var mediaSessionBridge: WuiWaterKitMediaSessionBridge?

  init(_ descriptor: WuiVideoPlaybackDescriptor, loops: Bool) {
    signals = WuiVideoPlaybackSignals(descriptor)
    self.loops = loops
    onEvent = descriptor.onEvent
    playbackPolicy = descriptor.playbackPolicy
  }

  func activate() {
    startWatchers()
    startPlaybackStateObservation()
    updatePreservePitch(signals.preservePitch.value)
    updatePlaybackRate(signals.playbackRate.value)
    updateSubtitleSelection(signals.subtitleSelection.value)
    updateSource(signals.source.value)
    updateVolume(signals.volume.value)
    title = signals.title.value.toString()
    artist = signals.artist.value.toString()
    album = signals.album.value.toString()
    artworkURL = signals.artworkURL.value.toString()
    configuredDurationSeconds = signals.durationSeconds.value
    mediaSessionBridge = WuiWaterKitMediaSessionBridge(host: self)
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    CGSize(
      width: proposal.width.map(CGFloat.init) ?? 320,
      height: proposal.height.map(CGFloat.init) ?? 180
    )
  }

  func pauseForDetachment() {
    mediaSessionPause()
  }

  func emitEvent(
    _ eventType: CWaterUI.WuiVideoEventType,
    pictureInPictureActive: Bool = false,
    playbackActive: Bool = false
  ) {
    guard let onEvent else { return }
    let event = CWaterUI.WuiVideoEvent(
      event_type: eventType,
      error_message: nil,
      buffered_ms: 0,
      av_drift_ms: 0,
      dropped_video_frames: 0,
      picture_in_picture_active: pictureInPictureActive,
      playback_active: playbackActive
    )
    waterui_video_event_handler_call(onEvent, event)
  }

  func emitError(_ message: String) {
    guard let onEvent else { return }
    let event = CWaterUI.WuiVideoEvent(
      event_type: CWaterUI.WuiVideoEventType_Error,
      error_message: WuiStr(string: message).intoRustOwnedPointer(),
      buffered_ms: 0,
      av_drift_ms: 0,
      dropped_video_frames: 0,
      picture_in_picture_active: false,
      playback_active: false
    )
    waterui_video_event_handler_call(onEvent, event)
  }

  private func startWatchers() {
    watchers = [
      signals.source.watch { [weak self] source, _ in
        self?.updateSource(source)
        self?.mediaSessionBridge?.metadataDidChange()
        self?.mediaSessionBridge?.playbackDidChange()
      },
      signals.title.watch { [weak self] title, _ in
        self?.title = title.toString()
        self?.mediaSessionBridge?.metadataDidChange()
      },
      signals.artist.watch { [weak self] artist, _ in
        self?.artist = artist.toString()
        self?.mediaSessionBridge?.metadataDidChange()
      },
      signals.album.watch { [weak self] album, _ in
        self?.album = album.toString()
        self?.mediaSessionBridge?.metadataDidChange()
      },
      signals.artworkURL.watch { [weak self] artworkURL, _ in
        self?.artworkURL = artworkURL.toString()
        self?.mediaSessionBridge?.metadataDidChange()
      },
      signals.durationSeconds.watch { [weak self] durationSeconds, _ in
        self?.configuredDurationSeconds = durationSeconds
        self?.mediaSessionBridge?.metadataDidChange()
      },
      observePlayback(signals.hasNext),
      observePlayback(signals.hasPrevious),
      signals.volume.watch { [weak self] volume, _ in
        self?.updateVolume(volume)
      },
      signals.subtitleSelection.watch { [weak self] selection, _ in
        self?.updateSubtitleSelection(selection)
      },
      signals.playbackRate.watch { [weak self] rate, _ in
        self?.updatePlaybackRate(rate)
      },
      signals.preservePitch.watch { [weak self] preservePitch, _ in
        self?.updatePreservePitch(preservePitch)
      },
    ]
  }

  private func startPlaybackStateObservation() {
    playbackStateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) {
      [weak self] _, _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.playbackStateDidChange()
        }
      }
    }
  }

  private func playbackStateDidChange() {
    let playing = player.timeControlStatus == .playing
    guard reportedPlaying != playing else { return }
    reportedPlaying = playing
    emitEvent(CWaterUI.WuiVideoEventType_PlaybackStateChanged, playbackActive: playing)
    mediaSessionBridge?.playbackDidChange()
  }

  private func observePlayback<T>(_ signal: WuiBinding<T>) -> WatcherGuard {
    signal.watch { [weak self] _, _ in
      self?.mediaSessionBridge?.playbackDidChange()
    }
  }

  private func updateSource(_ source: WuiStr) {
    let urlString = source.toString()
    guard let url = URL(string: urlString) else {
      fatalError("WaterUI video received an invalid URL from Rust: \(urlString)")
    }
    guard url != currentURL else { return }

    currentURL = url
    isBuffering = false
    playbackShouldStartWhenReady = true
    itemObservers.removeAll()

    let playerItem = AVPlayerItem(url: url)
    applyPitchAlgorithm(to: playerItem)
    configurePlaybackPolicy(on: playerItem)
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.playerItemDidReachEnd()
      }
    }

    let statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        self?.statusDidChange(for: item)
      }
    }
    let bufferEmptyObserver = playerItem.observe(
      \.isPlaybackBufferEmpty,
      options: [.new]
    ) { [weak self] item, _ in
      DispatchQueue.main.async {
        self?.bufferStateDidChange(for: item)
      }
    }
    let likelyToKeepUpObserver = playerItem.observe(
      \.isPlaybackLikelyToKeepUp,
      options: [.new]
    ) { [weak self] item, _ in
      DispatchQueue.main.async {
        self?.likelyToKeepUpDidChange(for: item)
      }
    }
    itemObservers = [statusObserver, bufferEmptyObserver, likelyToKeepUpObserver]

    player.replaceCurrentItem(with: playerItem)
    applySubtitleSelection(to: playerItem)
  }

  private func statusDidChange(for item: AVPlayerItem) {
    guard item == player.currentItem else { return }
    switch item.status {
    case .failed:
      subtitleSelectionTask?.cancel()
      let message =
        item.error?.localizedDescription
        ?? "AVPlayerItem failed without an error description"
      emitError(message)
      playbackShouldStartWhenReady = false
      currentURL = nil
      player.replaceCurrentItem(with: nil)
      itemObservers.removeAll()
      if let endObserver {
        NotificationCenter.default.removeObserver(endObserver)
        self.endObserver = nil
      }
      mediaSessionBridge?.playbackDidChange()
    case .readyToPlay:
      emitEvent(CWaterUI.WuiVideoEventType_ReadyToPlay)
      mediaSessionBridge?.metadataDidChange()
      mediaSessionBridge?.playbackDidChange()
      startPlaybackIfReady(for: item)
    case .unknown:
      break
    @unknown default:
      fatalError("Unsupported AVPlayerItem status")
    }
  }

  private func bufferStateDidChange(for item: AVPlayerItem) {
    guard item == player.currentItem else { return }
    if item.isPlaybackBufferEmpty && !isBuffering {
      isBuffering = true
      emitEvent(CWaterUI.WuiVideoEventType_Buffering)
      mediaSessionBridge?.playbackDidChange()
    }
  }

  private func likelyToKeepUpDidChange(for item: AVPlayerItem) {
    guard item == player.currentItem else { return }
    if item.isPlaybackLikelyToKeepUp && isBuffering {
      isBuffering = false
      emitEvent(CWaterUI.WuiVideoEventType_BufferingEnded)
      mediaSessionBridge?.playbackDidChange()
    }
  }

  private func playerItemDidReachEnd() {
    emitEvent(CWaterUI.WuiVideoEventType_Ended)
    if loops {
      player.seek(to: .zero) { [weak self] finished in
        guard finished else { return }
        DispatchQueue.main.async {
          self?.mediaSessionPlay()
        }
      }
    }
    mediaSessionBridge?.playbackDidChange()
    mediaSessionBridge?.metadataDidChange()
  }

  private func updateVolume(_ volume: Float) {
    requestedVolume = volume
    applyEffectiveVolume()
  }

  private func applyEffectiveVolume() {
    let baseVolume = abs(requestedVolume)
    player.isMuted = requestedVolume < 0
    player.volume = isDucked ? baseVolume * 0.2 : baseVolume
  }

  private func updatePlaybackRate(_ rate: Float) {
    precondition(rate.isFinite && rate > 0, "video playback rate must be finite and positive")
    requestedPlaybackRate = rate
    if currentMediaPlaybackSnapshot.status == .playing {
      player.rate = rate
    }
    mediaSessionBridge?.playbackDidChange()
  }

  private func updatePreservePitch(_ enabled: Bool) {
    preservePitch = enabled
    applyPitchAlgorithm(to: player.currentItem)
  }

  private func applyPitchAlgorithm(to item: AVPlayerItem?) {
    item?.audioTimePitchAlgorithm = preservePitch ? .spectral : .varispeed
  }

  private func configurePlaybackPolicy(on item: AVPlayerItem) {
    if playbackPolicy.realtime {
      player.automaticallyWaitsToMinimizeStalling = false
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
      item.preferredForwardBufferDuration = 0
    } else {
      player.automaticallyWaitsToMinimizeStalling = true
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
      item.preferredForwardBufferDuration = playbackPolicy.preferredForwardBufferSeconds
    }
  }

  private func updateSubtitleSelection(_ selection: CWaterUI.WuiSubtitleSelection) {
    requestedSubtitleSelection = WuiNativeSubtitleSelection(selection)
    if let item = player.currentItem {
      applySubtitleSelection(to: item)
    }
  }

  private func applySubtitleSelection(to item: AVPlayerItem) {
    subtitleSelectionTask?.cancel()
    let selection = requestedSubtitleSelection
    subtitleSelectionTask = Task { @MainActor [weak self] in
      do {
        let group = try await item.asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled, let self, item === player.currentItem else { return }
        guard selection == requestedSubtitleSelection else { return }
        guard let group else {
          if case .track(let index) = selection {
            fatalError("Video subtitle track \(index) was selected, but the asset has no subtitles")
          }
          return
        }
        switch selection {
        case .automatic:
          item.selectMediaOptionAutomatically(in: group)
        case .off:
          item.select(nil, in: group)
        case .track(let index):
          guard group.options.indices.contains(index) else {
            fatalError(
              "Video subtitle track \(index) is outside the asset's \(group.options.count) tracks"
            )
          }
          item.select(group.options[index], in: group)
        }
      } catch {
        guard !Task.isCancelled else { return }
        self?.emitError(error.localizedDescription)
      }
    }
  }

  private func startPlaybackIfReady(for item: AVPlayerItem) {
    guard item == player.currentItem, playbackShouldStartWhenReady else { return }
    playbackShouldStartWhenReady = false
    startPlaybackImmediately()
  }

  private func startPlaybackImmediately() {
    player.play()
    player.rate = requestedPlaybackRate
    mediaSessionBridge?.playbackDidChange()
  }

  private func resolvedDurationSeconds() -> Double {
    if configuredDurationSeconds >= 0 {
      return configuredDurationSeconds
    }

    let actualDuration = player.currentItem?.duration.seconds ?? -1
    return actualDuration.isFinite && actualDuration >= 0 ? actualDuration : -1
  }

  var currentMediaMetadataSnapshot: WuiMediaMetadataSnapshot {
    let inferredTitle =
      currentURL.map {
        $0.lastPathComponent.isEmpty ? $0.absoluteString : $0.lastPathComponent
      } ?? ""
    return WuiMediaMetadataSnapshot(
      title: title.isEmpty ? inferredTitle : title,
      artist: artist,
      album: album,
      artworkURL: artworkURL,
      durationSeconds: resolvedDurationSeconds()
    )
  }

  var currentMediaPlaybackSnapshot: WuiMediaPlaybackSnapshot {
    let status: WuiMediaPlaybackStatus
    if player.currentItem == nil {
      status = .stopped
    } else {
      switch player.timeControlStatus {
      case .paused:
        status = .paused
      case .waitingToPlayAtSpecifiedRate, .playing:
        status = .playing
      @unknown default:
        fatalError("Unsupported AVPlayer time control status")
      }
    }

    let currentTime = player.currentTime().seconds
    return WuiMediaPlaybackSnapshot(
      status: status,
      positionSeconds: max(0, currentTime.isFinite ? currentTime : 0),
      rate: status == .playing ? Double(requestedPlaybackRate) : 0,
      nextEnabled: signals.hasNext.value,
      previousEnabled: signals.hasPrevious.value
    )
  }

  func mediaSessionPlay() {
    guard let item = player.currentItem else { return }
    guard item.status == .readyToPlay else {
      playbackShouldStartWhenReady = true
      mediaSessionBridge?.playbackDidChange()
      return
    }
    playbackShouldStartWhenReady = false
    startPlaybackImmediately()
  }

  func mediaSessionPause() {
    playbackShouldStartWhenReady = false
    player.pause()
    mediaSessionBridge?.playbackDidChange()
  }

  func mediaSessionStop() {
    playbackShouldStartWhenReady = false
    player.pause()
    player.seek(to: .zero)
    mediaSessionBridge?.playbackDidChange()
  }

  func mediaSessionSeek(to seconds: Double) {
    player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    mediaSessionBridge?.playbackDidChange()
  }

  func mediaSessionSetDucked(_ ducked: Bool) {
    isDucked = ducked
    applyEffectiveVolume()
  }

  func mediaSessionEmitNextRequested() {
    emitEvent(CWaterUI.WuiVideoEventType_NextRequested)
  }

  func mediaSessionEmitPreviousRequested() {
    emitEvent(CWaterUI.WuiVideoEventType_PreviousRequested)
  }

  @MainActor deinit {
    mediaSessionBridge = nil
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    watchers.removeAll()
    playbackStateObserver = nil
    itemObservers.removeAll()
    subtitleSelectionTask?.cancel()
    player.pause()
    player.replaceCurrentItem(with: nil)
    if let onEvent {
      waterui_drop_video_event_handler(onEvent)
    }
  }
}
