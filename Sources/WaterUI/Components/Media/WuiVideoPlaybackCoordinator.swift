import AVFoundation
import CWaterUI
import Foundation
import OSLog

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

private enum WuiNativeAudioTrackSelection: Equatable {
  case automatic
  case track(Int)

  init(_ selection: CWaterUI.WuiAudioTrackSelection) {
    switch selection.selection_type {
    case WuiAudioTrackSelectionType_Auto:
      self = .automatic
    case WuiAudioTrackSelectionType_Track:
      self = .track(Int(selection.track_index))
    default:
      fatalError(
        "Unsupported WaterUI audio track selection: \(selection.selection_type.rawValue)"
      )
    }
  }
}

private enum WuiNativeVideoTrackSelection: Equatable {
  case automatic
  case track(Int)

  init(_ selection: CWaterUI.WuiVideoTrackSelection) {
    switch selection.selection_type {
    case WuiVideoTrackSelectionType_Auto:
      self = .automatic
    case WuiVideoTrackSelectionType_Track:
      self = .track(Int(selection.track_index))
    default:
      fatalError(
        "Unsupported WaterUI video track selection: \(selection.selection_type.rawValue)"
      )
    }
  }
}

private enum WuiNativePlaybackPhase: Int32 {
  case idle = 0
  case preparing = 1
  case ready = 2
  case playing = 3
  case paused = 4
  case buffering = 5
  case ended = 6
  case failed = 7
}

private enum WuiNativeRepeatMode: Int32 {
  case off = 0
  case one = 1
  case all = 2
}

struct WuiNativePlaybackPolicy {
  let realtime: Bool
  let preferredForwardBufferSeconds: TimeInterval

  init(_ policy: CWaterUI.WuiVideoPlaybackPolicy) {
    realtime = policy.realtime
    preferredForwardBufferSeconds = TimeInterval(policy.vod_start_buffer_ms) / 1_000
    switch policy.power {
    case WuiVideoPlaybackPowerPolicy_PlatformManaged:
      break
    case WuiVideoPlaybackPowerPolicy_RequireAudioOffload:
      fatalError("Apple AVPlayer does not expose a contract that guarantees audio offload")
    case WuiVideoPlaybackPowerPolicy_RequireAudioVideoTunneling:
      fatalError("Apple AVPlayer does not expose an Android-style A/V tunneling contract")
    default:
      fatalError("Unsupported WaterUI playback power policy: \(policy.power.rawValue)")
    }
  }
}

struct WuiVideoPlaybackDescriptor {
  let controller: OpaquePointer?
  let source: OpaquePointer?
  let delivery: OpaquePointer?
  let title: OpaquePointer?
  let artist: OpaquePointer?
  let album: OpaquePointer?
  let artworkURL: OpaquePointer?
  let durationSeconds: OpaquePointer?
  let positionSeconds: OpaquePointer?
  let desiredPlaying: OpaquePointer?
  let seekTargetSeconds: OpaquePointer?
  let seekGeneration: OpaquePointer?
  let stepForwardGeneration: OpaquePointer?
  let stepBackwardGeneration: OpaquePointer?
  let phase: OpaquePointer?
  let repeatMode: OpaquePointer?
  let hasNext: OpaquePointer?
  let hasPrevious: OpaquePointer?
  let volume: OpaquePointer?
  let muted: OpaquePointer?
  let subtitleSelection: OpaquePointer?
  let audioTrackSelection: OpaquePointer?
  let videoTrackSelection: OpaquePointer?
  let trackCatalog: OpaquePointer?
  let liveWindow: OpaquePointer?
  let playbackRate: OpaquePointer?
  let preservePitch: OpaquePointer?
  let onEvent: OpaquePointer?
  let playbackPolicy: WuiNativePlaybackPolicy

  init(_ descriptor: CWaterUI.WuiVideoPlaybackDescriptor) {
    controller = opaquePointer(descriptor.controller)
    source = opaquePointer(descriptor.source)
    delivery = opaquePointer(descriptor.delivery)
    title = opaquePointer(descriptor.title)
    artist = opaquePointer(descriptor.artist)
    album = opaquePointer(descriptor.album)
    artworkURL = opaquePointer(descriptor.artwork_url)
    durationSeconds = opaquePointer(descriptor.duration_seconds)
    positionSeconds = opaquePointer(descriptor.position_seconds)
    desiredPlaying = opaquePointer(descriptor.desired_playing)
    seekTargetSeconds = opaquePointer(descriptor.seek_target_seconds)
    seekGeneration = opaquePointer(descriptor.seek_generation)
    stepForwardGeneration = opaquePointer(descriptor.step_forward_generation)
    stepBackwardGeneration = opaquePointer(descriptor.step_backward_generation)
    phase = opaquePointer(descriptor.phase)
    repeatMode = opaquePointer(descriptor.repeat_mode)
    hasNext = opaquePointer(descriptor.has_next)
    hasPrevious = opaquePointer(descriptor.has_previous)
    volume = opaquePointer(descriptor.volume)
    muted = opaquePointer(descriptor.muted)
    subtitleSelection = opaquePointer(descriptor.subtitle_selection)
    audioTrackSelection = opaquePointer(descriptor.audio_track_selection)
    videoTrackSelection = opaquePointer(descriptor.video_track_selection)
    trackCatalog = opaquePointer(descriptor.track_catalog)
    liveWindow = opaquePointer(descriptor.live_window)
    playbackRate = opaquePointer(descriptor.playback_rate)
    preservePitch = opaquePointer(descriptor.preserve_pitch)
    onEvent = opaquePointer(descriptor.on_event)
    playbackPolicy = WuiNativePlaybackPolicy(descriptor.playback_policy)
  }
}

private struct WuiNativeAudioTrackInfo {
  let label: String
  let language: String?
  let roles: [String]
}

private struct WuiNativeVideoTrackInfo {
  let id: String
  let label: String
  let bandwidth: UInt64?
  let width: UInt32?
  let height: UInt32?
  let codecs: [String]
  let hdr: Bool
}

private struct WuiNativeSubtitleTrackInfo {
  let label: String
  let language: String?
  let roles: [String]
  let forced: Bool
}

private struct WuiNativeLiveWindow: Equatable {
  let seekableStartSeconds: Double
  let seekableEndSeconds: Double
  let liveEdgeSeconds: Double
  let targetPositionSeconds: Double
}

@MainActor
private final class WuiVideoLiveWindowSink {
  private let inner: OpaquePointer
  private var current: WuiNativeLiveWindow?

  init(_ inner: OpaquePointer) {
    self.inner = inner
  }

  @MainActor deinit {
    waterui_drop_video_live_window_binding(inner)
  }

  func replace(_ window: WuiNativeLiveWindow?) {
    guard current != window else { return }
    current = window
    let raw =
      window.map {
        CWaterUI.WuiVideoLiveWindow(
          present: true,
          seekable_start_seconds: $0.seekableStartSeconds,
          seekable_end_seconds: $0.seekableEndSeconds,
          live_edge_seconds: $0.liveEdgeSeconds,
          target_position_seconds: $0.targetPositionSeconds
        )
      }
      ?? CWaterUI.WuiVideoLiveWindow(
        present: false,
        seekable_start_seconds: 0,
        seekable_end_seconds: 0,
        live_edge_seconds: 0,
        target_position_seconds: 0
      )
    waterui_video_live_window_replace(inner, raw)
  }
}

@MainActor
private final class WuiVideoTrackCatalogSink {
  private let inner: OpaquePointer

  init(_ inner: OpaquePointer) {
    self.inner = inner
  }

  @MainActor deinit {
    waterui_drop_video_track_catalog_binding(inner)
  }

  func replaceAudio(_ tracks: [WuiNativeAudioTrackInfo]) {
    let rawTracks = tracks.map { track in
      CWaterUI.WuiVideoAudioTrackInfo(
        label: WuiStr(string: track.label).intoInner(),
        language: WuiStr(string: track.language ?? "").intoInner(),
        roles: Self.rawStrings(track.roles)
      )
    }
    waterui_video_track_catalog_replace_audio(
      inner,
      WuiArray<CWaterUI.WuiVideoAudioTrackInfo>(array: rawTracks)
        .intoVideoAudioTrackInfoArray()
    )
  }

  func replaceVideo(_ tracks: [WuiNativeVideoTrackInfo]) {
    let rawTracks = tracks.map { track in
      CWaterUI.WuiVideoTrackInfo(
        id: WuiStr(string: track.id).intoInner(),
        label: WuiStr(string: track.label).intoInner(),
        bandwidth: track.bandwidth ?? 0,
        width: track.width ?? 0,
        height: track.height ?? 0,
        codecs: Self.rawStrings(track.codecs),
        hdr: track.hdr
      )
    }
    waterui_video_track_catalog_replace_video(
      inner,
      WuiArray<CWaterUI.WuiVideoTrackInfo>(array: rawTracks).intoVideoTrackInfoArray()
    )
  }

  func replaceSubtitles(_ tracks: [WuiNativeSubtitleTrackInfo]) {
    let rawTracks = tracks.map { track in
      CWaterUI.WuiVideoSubtitleTrackInfo(
        label: WuiStr(string: track.label).intoInner(),
        language: WuiStr(string: track.language ?? "").intoInner(),
        roles: Self.rawStrings(track.roles),
        forced: track.forced,
        origin: CWaterUI.WuiVideoSubtitleTrackOrigin_Native
      )
    }
    waterui_video_track_catalog_replace_subtitles(
      inner,
      WuiArray<CWaterUI.WuiVideoSubtitleTrackInfo>(array: rawTracks)
        .intoVideoSubtitleTrackInfoArray()
    )
  }

  private static func rawStrings(_ values: [String]) -> CWaterUI.WuiArray_WuiStr {
    WuiArray<CWaterUI.WuiStr>(
      array: values.map { WuiStr(string: $0).intoInner() }
    ).intoWuiStrArray()
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
  let delivery: WuiComputed<CWaterUI.WuiVideoDelivery>
  let title: WuiComputed<WuiStr>
  let artist: WuiComputed<WuiStr>
  let album: WuiComputed<WuiStr>
  let artworkURL: WuiComputed<WuiStr>
  let durationSeconds: WuiBinding<Double>
  let positionSeconds: WuiBinding<Double>
  let desiredPlaying: WuiBinding<Bool>
  let seekTargetSeconds: WuiBinding<Double>
  let seekGeneration: WuiBinding<Int32>
  let stepForwardGeneration: WuiBinding<Int32>
  let stepBackwardGeneration: WuiBinding<Int32>
  let phase: WuiBinding<Int32>
  let repeatMode: WuiBinding<Int32>
  let hasNext: WuiBinding<Bool>
  let hasPrevious: WuiBinding<Bool>
  let volume: WuiBinding<Float>
  let muted: WuiBinding<Bool>
  let subtitleSelection: WuiBinding<CWaterUI.WuiSubtitleSelection>
  let audioTrackSelection: WuiBinding<CWaterUI.WuiAudioTrackSelection>
  let videoTrackSelection: WuiBinding<CWaterUI.WuiVideoTrackSelection>
  let playbackRate: WuiBinding<Float>
  let preservePitch: WuiBinding<Bool>

  init(_ descriptor: WuiVideoPlaybackDescriptor) {
    source = WuiComputed(Self.require(descriptor.source, named: "source"))
    delivery = WuiComputed(Self.require(descriptor.delivery, named: "delivery"))
    title = WuiComputed(Self.require(descriptor.title, named: "title"))
    artist = WuiComputed(Self.require(descriptor.artist, named: "artist"))
    album = WuiComputed(Self.require(descriptor.album, named: "album"))
    artworkURL = WuiComputed(Self.require(descriptor.artworkURL, named: "artwork_url"))
    durationSeconds = WuiBinding(
      Self.require(descriptor.durationSeconds, named: "duration_seconds"))
    positionSeconds = WuiBinding(
      Self.require(descriptor.positionSeconds, named: "position_seconds"))
    desiredPlaying = WuiBinding(
      Self.require(descriptor.desiredPlaying, named: "desired_playing"))
    seekTargetSeconds = WuiBinding(
      Self.require(descriptor.seekTargetSeconds, named: "seek_target_seconds"))
    seekGeneration = WuiBinding(
      Self.require(descriptor.seekGeneration, named: "seek_generation"))
    stepForwardGeneration = WuiBinding(
      Self.require(descriptor.stepForwardGeneration, named: "step_forward_generation"))
    stepBackwardGeneration = WuiBinding(
      Self.require(descriptor.stepBackwardGeneration, named: "step_backward_generation"))
    phase = WuiBinding(Self.require(descriptor.phase, named: "phase"))
    repeatMode = WuiBinding(Self.require(descriptor.repeatMode, named: "repeat_mode"))
    hasNext = WuiBinding(Self.require(descriptor.hasNext, named: "has_next"))
    hasPrevious = WuiBinding(Self.require(descriptor.hasPrevious, named: "has_previous"))
    volume = WuiBinding(Self.require(descriptor.volume, named: "volume"))
    muted = WuiBinding(Self.require(descriptor.muted, named: "muted"))
    subtitleSelection = WuiBinding(
      Self.require(descriptor.subtitleSelection, named: "subtitle_selection")
    )
    audioTrackSelection = WuiBinding(
      Self.require(descriptor.audioTrackSelection, named: "audio_track_selection")
    )
    videoTrackSelection = WuiBinding(
      Self.require(descriptor.videoTrackSelection, named: "video_track_selection")
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

private struct WuiNativePlaybackObservability {
  private(set) var sourceSelectedAt = ProcessInfo.processInfo.systemUptime
  private(set) var firstPlaybackAt: TimeInterval?
  private(set) var rebufferStartedAt: TimeInterval?
  private(set) var rebufferCount: UInt64 = 0
  private(set) var rebufferDuration: TimeInterval = 0
  private(set) var lastReportAt: TimeInterval?

  mutating func reset(at now: TimeInterval) {
    sourceSelectedAt = now
    firstPlaybackAt = nil
    rebufferStartedAt = nil
    rebufferCount = 0
    rebufferDuration = 0
    lastReportAt = nil
  }

  mutating func recordFirstPlayback(at now: TimeInterval) {
    if firstPlaybackAt == nil {
      firstPlaybackAt = now
    }
  }

  mutating func recordBuffering(_ buffering: Bool, at now: TimeInterval) {
    if buffering {
      guard firstPlaybackAt != nil, rebufferStartedAt == nil else { return }
      rebufferCount &+= 1
      rebufferStartedAt = now
      return
    }
    guard let startedAt = rebufferStartedAt else { return }
    rebufferDuration += now - startedAt
    rebufferStartedAt = nil
  }

  func shouldReport(at now: TimeInterval) -> Bool {
    guard firstPlaybackAt != nil else { return false }
    return lastReportAt.map { now - $0 >= 1 } ?? true
  }

  mutating func didReport(at now: TimeInterval) {
    lastReportAt = now
  }

  func startupTime() -> TimeInterval {
    guard let firstPlaybackAt else {
      fatalError("Playback metrics require a recorded first playback time")
    }
    return firstPlaybackAt - sourceSelectedAt
  }

  func totalRebufferDuration(at now: TimeInterval) -> TimeInterval {
    guard let rebufferStartedAt else { return rebufferDuration }
    return rebufferDuration + now - rebufferStartedAt
  }
}

@MainActor
final class WuiVideoPlaybackCoordinator: WuiMediaSessionHost {
  let player = AVPlayer()

  private let signals: WuiVideoPlaybackSignals
  private let controller: OpaquePointer
  private let loops: Bool
  private let onEvent: OpaquePointer?
  private let playbackPolicy: WuiNativePlaybackPolicy
  private let trackCatalog: WuiVideoTrackCatalogSink
  private let liveWindow: WuiVideoLiveWindowSink
  private var watchers: [WatcherGuard] = []
  private var itemObservers: [NSKeyValueObservation] = []
  private var playbackStateObserver: NSKeyValueObservation?
  private var externalPlaybackObserver: NSKeyValueObservation?
  private var periodicTimeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var subtitleSelectionTask: Task<Void, Never>?
  private var audioTrackSelectionTask: Task<Void, Never>?
  private var videoTrackSelectionTask: Task<Void, Never>?
  private var trackCatalogTask: Task<Void, Never>?
  private var currentURL: URL?
  private var currentDelivery: CWaterUI.WuiVideoDelivery?
  private var requestedSubtitleSelection = WuiNativeSubtitleSelection.automatic
  private var requestedAudioTrackSelection = WuiNativeAudioTrackSelection.automatic
  private var requestedVideoTrackSelection = WuiNativeVideoTrackSelection.automatic
  private var isBuffering = false
  private var requestedVolume: Float = 0.5
  private var requestedMuted = false
  private var requestedPlaybackRate: Float = 1
  private var preservePitch = true
  private var isDucked = false
  private var playbackShouldStartWhenReady = false
  private var reportedPlaying: Bool?
  private var reportedExternalPlaybackActive: Bool?
  private var title = ""
  private var artist = ""
  private var album = ""
  private var artworkURL = ""
  private var configuredDurationSeconds = 0.0
  private var lastAppliedSeekGeneration: Int32?
  private var lastAppliedStepForwardGeneration: Int32?
  private var lastAppliedStepBackwardGeneration: Int32?
  private var mediaSessionBridge: WuiWaterKitMediaSessionBridge?
  private var observability = WuiNativePlaybackObservability()
  private var lastReportedBufferLevelMs: UInt32?

  init(_ descriptor: WuiVideoPlaybackDescriptor, loops: Bool) {
    signals = WuiVideoPlaybackSignals(descriptor)
    guard let controller = descriptor.controller else {
      fatalError("WaterUI video descriptor is missing its controller")
    }
    self.controller = controller
    guard let trackCatalog = descriptor.trackCatalog else {
      fatalError("WaterUI video descriptor is missing its track catalog")
    }
    self.trackCatalog = WuiVideoTrackCatalogSink(trackCatalog)
    guard let liveWindow = descriptor.liveWindow else {
      fatalError("WaterUI video descriptor is missing its live window")
    }
    self.liveWindow = WuiVideoLiveWindowSink(liveWindow)
    self.loops = loops
    onEvent = descriptor.onEvent
    playbackPolicy = descriptor.playbackPolicy
  }

  func activate() {
    emitEvent(CWaterUI.WuiVideoEventType_PlaybackOutputPathChanged)
    lastAppliedStepForwardGeneration = signals.stepForwardGeneration.value
    lastAppliedStepBackwardGeneration = signals.stepBackwardGeneration.value
    startWatchers()
    startPlaybackStateObservation()
    startExternalPlaybackObservation()
    startTimelineObservation()
    updatePreservePitch(signals.preservePitch.value)
    updatePlaybackRate(signals.playbackRate.value)
    updateSubtitleSelection(signals.subtitleSelection.value)
    updateAudioTrackSelection(signals.audioTrackSelection.value)
    updateVideoTrackSelection(signals.videoTrackSelection.value)
    updateSource(signals.source.value, delivery: signals.delivery.value)
    updateDesiredPlaying(signals.desiredPlaying.value)
    updateVolume(signals.volume.value)
    updateMuted(signals.muted.value)
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
    errorMessage: UnsafeMutablePointer<CWaterUI.WuiStr>? = nil,
    positionMs: UInt64 = 0,
    bufferedMs: UInt32 = 0,
    startupTimeMs: UInt64 = 0,
    droppedVideoFrames: UInt64 = 0,
    rebufferCount: UInt64 = 0,
    rebufferDurationMs: UInt64 = 0,
    observedNetworkThroughputBps: UInt64 = 0,
    pictureInPictureActive: Bool = false,
    externalPlaybackActive: Bool = false,
    playbackActive: Bool = false
  ) {
    guard let onEvent else { return }
    let event = CWaterUI.WuiVideoEvent(
      event_type: eventType,
      error_message: errorMessage,
      position_ms: positionMs,
      buffered_ms: bufferedMs,
      startup_time_ms: startupTimeMs,
      av_drift_available: false,
      av_drift_ms: 0,
      dropped_video_frames: droppedVideoFrames,
      rebuffer_count: rebufferCount,
      rebuffer_duration_ms: rebufferDurationMs,
      observed_network_throughput_bps: observedNetworkThroughputBps,
      picture_in_picture_active: pictureInPictureActive,
      external_playback_active: externalPlaybackActive,
      playback_active: playbackActive,
      playback_output_path: CWaterUI.WuiVideoPlaybackOutputPath_PlatformManaged
    )
    waterui_video_event_handler_call(onEvent, event)
  }

  func emitError(_ message: String) {
    setPhase(.failed)
    emitErrorEvent(message)
  }

  private func emitNonfatalError(_ message: String) {
    emitErrorEvent(message)
  }

  private func emitErrorEvent(_ message: String) {
    guard onEvent != nil else { return }
    emitEvent(
      CWaterUI.WuiVideoEventType_Error,
      errorMessage: WuiStr(string: message).intoRustOwnedPointer()
    )
  }

  private func startWatchers() {
    watchers = [
      signals.source.watch { [weak self] source, _ in
        guard let self else { return }
        self.updateSource(source, delivery: self.signals.delivery.value)
        self.mediaSessionBridge?.metadataDidChange()
        self.mediaSessionBridge?.playbackDidChange()
      },
      signals.delivery.watch { [weak self] delivery, _ in
        guard let self else { return }
        self.updateSource(self.signals.source.value, delivery: delivery)
        self.mediaSessionBridge?.playbackDidChange()
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
      signals.desiredPlaying.watch { [weak self] playing, _ in
        self?.updateDesiredPlaying(playing)
      },
      signals.seekGeneration.watch { [weak self] generation, _ in
        self?.applyRequestedSeek(generation: generation)
      },
      signals.stepForwardGeneration.watch { [weak self] generation, _ in
        self?.applyFrameStep(generation: generation, forward: true)
      },
      signals.stepBackwardGeneration.watch { [weak self] generation, _ in
        self?.applyFrameStep(generation: generation, forward: false)
      },
      observePlayback(signals.repeatMode),
      observePlayback(signals.hasNext),
      observePlayback(signals.hasPrevious),
      signals.volume.watch { [weak self] volume, _ in
        self?.updateVolume(volume)
      },
      signals.muted.watch { [weak self] muted, _ in
        self?.updateMuted(muted)
      },
      signals.subtitleSelection.watch { [weak self] selection, _ in
        self?.updateSubtitleSelection(selection)
      },
      signals.audioTrackSelection.watch { [weak self] selection, _ in
        self?.updateAudioTrackSelection(selection)
      },
      signals.videoTrackSelection.watch { [weak self] selection, _ in
        self?.updateVideoTrackSelection(selection)
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

  private func startExternalPlaybackObservation() {
    externalPlaybackObserver = player.observe(
      \.isExternalPlaybackActive,
      options: [.initial, .new]
    ) { [weak self] player, _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.externalPlaybackDidChange(player.isExternalPlaybackActive)
        }
      }
    }
  }

  private func externalPlaybackDidChange(_ active: Bool) {
    guard reportedExternalPlaybackActive != active else { return }
    reportedExternalPlaybackActive = active
    emitEvent(
      CWaterUI.WuiVideoEventType_ExternalPlaybackChanged,
      externalPlaybackActive: active
    )
  }

  private func startTimelineObservation() {
    periodicTimeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 4),
      queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        self?.synchronizeTimeline(at: time)
      }
    }
  }

  private func playbackStateDidChange() {
    guard player.currentItem != nil else {
      setPhase(.idle)
      return
    }
    let playing: Bool
    switch player.timeControlStatus {
    case .playing:
      playing = true
      let now = ProcessInfo.processInfo.systemUptime
      observability.recordFirstPlayback(at: now)
      finishBuffering(at: now)
      setPhase(.playing)
    case .paused:
      playing = false
      if signals.phase.value != WuiNativePlaybackPhase.ended.rawValue {
        setPhase(.paused)
      }
    case .waitingToPlayAtSpecifiedRate:
      playing = signals.desiredPlaying.value
      beginBuffering(at: ProcessInfo.processInfo.systemUptime)
    @unknown default:
      fatalError("Unsupported AVPlayer time control status")
    }
    if player.timeControlStatus != .waitingToPlayAtSpecifiedRate
      && signals.desiredPlaying.value != playing
    {
      signals.desiredPlaying.set(playing)
    }
    guard reportedPlaying != playing else { return }
    reportedPlaying = playing
    emitEvent(CWaterUI.WuiVideoEventType_PlaybackStateChanged, playbackActive: playing)
    mediaSessionBridge?.playbackDidChange()
  }

  private func setPhase(_ phase: WuiNativePlaybackPhase) {
    if signals.phase.value != phase.rawValue {
      signals.phase.set(phase.rawValue)
    }
  }

  private func repeatMode() -> WuiNativeRepeatMode {
    guard let mode = WuiNativeRepeatMode(rawValue: signals.repeatMode.value) else {
      fatalError("Unsupported WaterUI repeat mode: \(signals.repeatMode.value)")
    }
    return mode
  }

  private func updateDesiredPlaying(_ playing: Bool) {
    guard playing else {
      playbackShouldStartWhenReady = false
      player.pause()
      return
    }
    guard let item = player.currentItem, item.status == .readyToPlay else {
      playbackShouldStartWhenReady = true
      return
    }
    playbackShouldStartWhenReady = false
    startPlaybackImmediately()
  }

  private func synchronizeTimeline(at time: CMTime) {
    let position = time.seconds
    guard position.isFinite && position >= 0 else { return }
    signals.positionSeconds.set(position)

    let actualDuration = player.currentItem?.duration.seconds ?? 0
    let duration =
      actualDuration.isFinite && actualDuration > 0
      ? actualDuration : configuredDurationSeconds
    if duration > 0 {
      if abs(signals.durationSeconds.value - duration) > 0.001 {
        signals.durationSeconds.set(duration)
      }
    }
    synchronizeLiveWindow()
    let bufferedAhead = bufferedDurationAhead(of: position)
    emitBufferLevelIfNeeded(bufferedAhead)
    emitPlaybackMetricsIfNeeded(position: position, bufferedAhead: bufferedAhead)
  }

  private func bufferedDurationAhead(of position: TimeInterval) -> TimeInterval {
    guard let ranges = player.currentItem?.loadedTimeRanges else { return 0 }
    for value in ranges {
      let range = value.timeRangeValue
      let start = range.start.seconds
      let end = CMTimeRangeGetEnd(range).seconds
      if start.isFinite && end.isFinite && position >= start && position <= end {
        return max(0, end - position)
      }
    }
    return 0
  }

  private func emitBufferLevelIfNeeded(_ bufferedAhead: TimeInterval) {
    let bufferedMs = Self.milliseconds32(bufferedAhead)
    guard
      lastReportedBufferLevelMs.map({ $0 > bufferedMs ? $0 - bufferedMs : bufferedMs - $0 })
        .map({ $0 >= 250 }) ?? true
    else { return }
    lastReportedBufferLevelMs = bufferedMs
    emitEvent(
      CWaterUI.WuiVideoEventType_BufferLevel,
      bufferedMs: bufferedMs
    )
  }

  private func emitPlaybackMetricsIfNeeded(
    position: TimeInterval,
    bufferedAhead: TimeInterval
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    guard observability.shouldReport(at: now) else { return }
    let accessLog = player.currentItem?.accessLog()?.events.last
    let droppedFrames = UInt64(max(0, accessLog?.numberOfDroppedVideoFrames ?? 0))
    let accessLogStalls = UInt64(max(0, accessLog?.numberOfStalls ?? 0))
    let observedBitrate = accessLog?.observedBitrate ?? 0
    let throughput =
      observedBitrate.isFinite && observedBitrate > 0 ? UInt64(observedBitrate) : 0
    emitEvent(
      CWaterUI.WuiVideoEventType_PlaybackMetrics,
      positionMs: Self.milliseconds(position),
      bufferedMs: Self.milliseconds32(bufferedAhead),
      startupTimeMs: Self.milliseconds(observability.startupTime()),
      droppedVideoFrames: droppedFrames,
      rebufferCount: max(observability.rebufferCount, accessLogStalls),
      rebufferDurationMs: Self.milliseconds(observability.totalRebufferDuration(at: now)),
      observedNetworkThroughputBps: throughput
    )
    observability.didReport(at: now)
  }

  private static func milliseconds(_ seconds: TimeInterval) -> UInt64 {
    UInt64(max(0, seconds) * 1_000)
  }

  private static func milliseconds32(_ seconds: TimeInterval) -> UInt32 {
    UInt32(min(milliseconds(seconds), UInt64(UInt32.max)))
  }

  private func applyRequestedSeek(generation: Int32) {
    guard lastAppliedSeekGeneration != generation else { return }
    guard player.currentItem != nil else { return }
    let target = clampedSeekTarget(signals.seekTargetSeconds.value)
    lastAppliedSeekGeneration = generation
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
  }

  private func applyFrameStep(generation: Int32, forward: Bool) {
    let previous =
      forward
      ? lastAppliedStepForwardGeneration : lastAppliedStepBackwardGeneration
    if forward {
      lastAppliedStepForwardGeneration = generation
    } else {
      lastAppliedStepBackwardGeneration = generation
    }
    guard let previous else { return }
    let count = UInt32(bitPattern: generation) &- UInt32(bitPattern: previous)
    guard count > 0, let item = player.currentItem else { return }
    guard forward ? item.canStepForward : item.canStepBackward else {
      emitNonfatalError(
        forward
          ? "AVPlayer item cannot step to a later frame"
          : "AVPlayer item cannot step to an earlier frame"
      )
      return
    }
    player.pause()
    let signedCount = forward ? Int(count) : -Int(count)
    item.step(byCount: signedCount)
  }

  private func synchronizeLiveWindow() {
    guard let item = player.currentItem else {
      liveWindow.replace(nil)
      return
    }
    let duration = item.duration.seconds
    guard !duration.isFinite || duration <= 0 else {
      liveWindow.replace(nil)
      return
    }
    let ranges = item.seekableTimeRanges.map(\.timeRangeValue).filter {
      $0.start.seconds.isFinite && $0.duration.seconds.isFinite && $0.duration.seconds >= 0
    }
    guard
      let seekableStart = ranges.map({ $0.start.seconds }).min(),
      let seekableEnd = ranges.map({ $0.end.seconds }).max(),
      seekableStart >= 0,
      seekableEnd >= seekableStart
    else {
      liveWindow.replace(nil)
      return
    }
    let recommendedOffset = item.recommendedTimeOffsetFromLive.seconds
    let targetOffset =
      recommendedOffset.isFinite && recommendedOffset >= 0
      ? recommendedOffset : 0
    liveWindow.replace(
      WuiNativeLiveWindow(
        seekableStartSeconds: seekableStart,
        seekableEndSeconds: seekableEnd,
        liveEdgeSeconds: seekableEnd,
        targetPositionSeconds: max(seekableStart, seekableEnd - targetOffset)
      ))
  }

  private func clampedSeekTarget(_ requested: Double) -> Double {
    precondition(requested.isFinite && requested >= 0, "video seek target must be non-negative")
    if let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue,
      range.start.seconds.isFinite,
      range.end.seconds.isFinite
    {
      return min(range.end.seconds, max(range.start.seconds, requested))
    }
    let duration = resolvedDurationSeconds()
    return duration > 0 ? min(duration, requested) : requested
  }

  private func observePlayback<T>(_ signal: WuiBinding<T>) -> WatcherGuard {
    signal.watch { [weak self] _, _ in
      self?.mediaSessionBridge?.playbackDidChange()
    }
  }

  private func updateSource(
    _ source: WuiStr,
    delivery: CWaterUI.WuiVideoDelivery
  ) {
    let urlString = source.toString()
    guard let url = URL(string: urlString) else {
      fatalError("WaterUI video received an invalid URL from Rust: \(urlString)")
    }
    guard url != currentURL || delivery != currentDelivery else { return }

    currentURL = url
    currentDelivery = delivery
    isBuffering = false
    observability.reset(at: ProcessInfo.processInfo.systemUptime)
    lastReportedBufferLevelMs = nil
    signals.positionSeconds.set(0)
    signals.seekTargetSeconds.set(0)
    liveWindow.replace(nil)
    playbackShouldStartWhenReady = signals.desiredPlaying.value
    setPhase(.preparing)
    itemObservers.removeAll()
    trackCatalogTask?.cancel()
    trackCatalog.replaceAudio([])
    trackCatalog.replaceVideo([])
    trackCatalog.replaceSubtitles([])

    if delivery == CWaterUI.WuiVideoDelivery_Dash {
      playbackShouldStartWhenReady = false
      player.replaceCurrentItem(with: nil)
      emitError(
        "MPEG-DASH is not supported by the Apple AVPlayer realization; select the WaterKit self-drawn video realization"
      )
      mediaSessionBridge?.playbackDidChange()
      return
    }

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
    let seekableRangesObserver = playerItem.observe(
      \.seekableTimeRanges,
      options: [.initial, .new]
    ) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self, item == self.player.currentItem else { return }
        self.synchronizeLiveWindow()
      }
    }
    let recommendedOffsetObserver = playerItem.observe(
      \.recommendedTimeOffsetFromLive,
      options: [.initial, .new]
    ) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self, item == self.player.currentItem else { return }
        self.synchronizeLiveWindow()
      }
    }
    itemObservers = [
      statusObserver,
      bufferEmptyObserver,
      likelyToKeepUpObserver,
      seekableRangesObserver,
      recommendedOffsetObserver,
    ]

    player.replaceCurrentItem(with: playerItem)
    refreshTrackCatalog(for: playerItem)
    applySubtitleSelection(to: playerItem)
    applyAudioTrackSelection(to: playerItem)
    applyVideoTrackSelection(to: playerItem)
  }

  private func statusDidChange(for item: AVPlayerItem) {
    guard item == player.currentItem else { return }
    switch item.status {
    case .failed:
      subtitleSelectionTask?.cancel()
      audioTrackSelectionTask?.cancel()
      videoTrackSelectionTask?.cancel()
      trackCatalogTask?.cancel()
      let message =
        item.error?.localizedDescription
        ?? "AVPlayerItem failed without an error description"
      emitError(message)
      playbackShouldStartWhenReady = false
      signals.desiredPlaying.set(false)
      currentURL = nil
      player.replaceCurrentItem(with: nil)
      itemObservers.removeAll()
      if let endObserver {
        NotificationCenter.default.removeObserver(endObserver)
        self.endObserver = nil
      }
      mediaSessionBridge?.playbackDidChange()
    case .readyToPlay:
      let duration = item.duration.seconds
      if duration.isFinite && duration > 0 {
        configuredDurationSeconds = duration
        signals.durationSeconds.set(duration)
      }
      synchronizeLiveWindow()
      applyRequestedSeek(generation: signals.seekGeneration.value)
      setPhase(signals.desiredPlaying.value ? .playing : .ready)
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
    if item.isPlaybackBufferEmpty {
      beginBuffering(at: ProcessInfo.processInfo.systemUptime)
    }
  }

  private func likelyToKeepUpDidChange(for item: AVPlayerItem) {
    guard item == player.currentItem else { return }
    if item.isPlaybackLikelyToKeepUp {
      finishBuffering(at: ProcessInfo.processInfo.systemUptime)
    }
  }

  private func beginBuffering(at now: TimeInterval) {
    guard !isBuffering else { return }
    isBuffering = true
    observability.recordBuffering(true, at: now)
    setPhase(.buffering)
    emitEvent(CWaterUI.WuiVideoEventType_Buffering)
    mediaSessionBridge?.playbackDidChange()
  }

  private func finishBuffering(at now: TimeInterval) {
    guard isBuffering else { return }
    isBuffering = false
    observability.recordBuffering(false, at: now)
    setPhase(signals.desiredPlaying.value ? .playing : .paused)
    emitEvent(CWaterUI.WuiVideoEventType_BufferingEnded)
    mediaSessionBridge?.playbackDidChange()
  }

  private func playerItemDidReachEnd() {
    setPhase(.ended)
    emitEvent(CWaterUI.WuiVideoEventType_Ended)
    if loops || repeatMode() == .one {
      player.seek(to: .zero) { [weak self] finished in
        guard finished else { return }
        DispatchQueue.main.async {
          guard let self else { return }
          self.signals.seekTargetSeconds.set(0)
          self.signals.positionSeconds.set(0)
          if self.signals.desiredPlaying.value {
            self.mediaSessionPlay()
          }
        }
      }
    } else if signals.hasNext.value {
      waterui_video_controller_next(controller)
    } else {
      signals.desiredPlaying.set(false)
    }
    mediaSessionBridge?.playbackDidChange()
    mediaSessionBridge?.metadataDidChange()
  }

  private func updateVolume(_ volume: Float) {
    precondition(
      volume.isFinite && (0...1).contains(volume),
      "video volume must be finite and within 0.0...1.0"
    )
    requestedVolume = volume
    applyEffectiveVolume()
  }

  private func updateMuted(_ muted: Bool) {
    requestedMuted = muted
    applyEffectiveVolume()
  }

  private func applyEffectiveVolume() {
    player.isMuted = requestedMuted
    player.volume = isDucked ? requestedVolume * 0.2 : requestedVolume
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

  private func updateAudioTrackSelection(_ selection: CWaterUI.WuiAudioTrackSelection) {
    requestedAudioTrackSelection = WuiNativeAudioTrackSelection(selection)
    if let item = player.currentItem {
      applyAudioTrackSelection(to: item)
    }
  }

  private func applyAudioTrackSelection(to item: AVPlayerItem) {
    audioTrackSelectionTask?.cancel()
    let selection = requestedAudioTrackSelection
    audioTrackSelectionTask = Task { @MainActor [weak self] in
      do {
        let group = try await item.asset.loadMediaSelectionGroup(for: .audible)
        guard !Task.isCancelled, let self, item === player.currentItem else { return }
        guard selection == requestedAudioTrackSelection else { return }
        guard let group else {
          if case .track(let index) = selection {
            fatalError("Video audio track \(index) was selected, but the asset has no audio")
          }
          return
        }
        switch selection {
        case .automatic:
          item.selectMediaOptionAutomatically(in: group)
        case .track(let index):
          guard group.options.indices.contains(index) else {
            fatalError(
              "Video audio track \(index) is outside the asset's \(group.options.count) tracks"
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

  private func updateVideoTrackSelection(_ selection: CWaterUI.WuiVideoTrackSelection) {
    requestedVideoTrackSelection = WuiNativeVideoTrackSelection(selection)
    if let item = player.currentItem {
      applyVideoTrackSelection(to: item)
    }
  }

  private func applyVideoTrackSelection(to item: AVPlayerItem) {
    videoTrackSelectionTask?.cancel()
    let selection = requestedVideoTrackSelection
    switch selection {
    case .automatic:
      item.preferredPeakBitRate = 0
      item.preferredMaximumResolution = .zero
    case .track(let index):
      videoTrackSelectionTask = Task { @MainActor [weak self] in
        do {
          guard let asset = item.asset as? AVURLAsset else {
            fatalError("Video quality selection requires an AVURLAsset")
          }
          let variants = try await asset.load(.variants)
            .filter { $0.videoAttributes != nil }
            .sorted(by: Self.videoVariantPrecedes)
          guard !Task.isCancelled, let self, item === player.currentItem else { return }
          guard selection == requestedVideoTrackSelection else { return }
          guard variants.indices.contains(index) else {
            fatalError(
              "Video quality track \(index) is outside the asset's \(variants.count) video variants"
            )
          }
          let variant = variants[index]
          let bitRate = Self.declaredBitRate(variant)
          let resolution = variant.videoAttributes?.presentationSize ?? .zero
          guard bitRate > 0 || resolution != .zero else {
            fatalError(
              "Video quality track \(index) declares neither bitrate nor presentation size"
            )
          }
          item.preferredPeakBitRate = max(0, bitRate)
          item.preferredMaximumResolution = resolution
        } catch {
          guard !Task.isCancelled else { return }
          self?.emitError(error.localizedDescription)
        }
      }
    }
  }

  private func refreshTrackCatalog(for item: AVPlayerItem) {
    trackCatalogTask?.cancel()
    trackCatalogTask = Task { @MainActor [weak self] in
      do {
        let audioGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let subtitleGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let variants: [AVAssetVariant]
        if let asset = item.asset as? AVURLAsset {
          variants = try await asset.load(.variants)
            .filter { $0.videoAttributes != nil }
            .sorted(by: Self.videoVariantPrecedes)
        } else {
          variants = []
        }
        guard !Task.isCancelled, let self, item === player.currentItem else { return }

        trackCatalog.replaceAudio(
          audioGroup?.options.map(Self.audioTrackInfo) ?? []
        )
        trackCatalog.replaceVideo(
          variants.enumerated().map(Self.videoTrackInfo)
        )
        trackCatalog.replaceSubtitles(
          subtitleGroup?.options.map(Self.subtitleTrackInfo) ?? []
        )
      } catch {
        guard !Task.isCancelled else { return }
        Logger.waterui.error(
          "Failed to load AVPlayer track catalog: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  private static func audioTrackInfo(_ option: AVMediaSelectionOption)
    -> WuiNativeAudioTrackInfo
  {
    WuiNativeAudioTrackInfo(
      label: option.displayName,
      language: option.extendedLanguageTag,
      roles: mediaRoles(option)
    )
  }

  private static func subtitleTrackInfo(_ option: AVMediaSelectionOption)
    -> WuiNativeSubtitleTrackInfo
  {
    let forced = option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
    return WuiNativeSubtitleTrackInfo(
      label: option.displayName,
      language: option.extendedLanguageTag,
      roles: mediaRoles(option),
      forced: forced
    )
  }

  private static func mediaRoles(_ option: AVMediaSelectionOption) -> [String] {
    var roles: [String] = []
    if option.hasMediaCharacteristic(.describesVideoForAccessibility) {
      roles.append("description")
    }
    if option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) {
      roles.append("caption")
    }
    if option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility) {
      roles.append("sound-description")
    }
    if option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) {
      roles.append("forced-subtitle")
    }
    if option.hasMediaCharacteristic(.isAuxiliaryContent) {
      roles.append("auxiliary")
    }
    return roles
  }

  private static func videoTrackInfo(_ entry: EnumeratedSequence<[AVAssetVariant]>.Element)
    -> WuiNativeVideoTrackInfo
  {
    let (index, variant) = entry
    guard let attributes = variant.videoAttributes else {
      fatalError("Video variant catalog received a variant without video attributes")
    }
    let bitRate = declaredBitRate(variant)
    precondition(
      !bitRate.isFinite || bitRate <= Double(UInt64.max),
      "AVAsset variant bitrate exceeds UInt64"
    )
    let bandwidth = bitRate.isFinite && bitRate > 0 ? UInt64(bitRate.rounded()) : nil
    let size = attributes.presentationSize
    let width = videoDimension(size.width)
    let height = videoDimension(size.height)
    precondition(
      (width == nil) == (height == nil),
      "AVAsset variant dimensions must both be declared or both be absent"
    )
    let codecs = attributes.codecTypes.map(codecIdentifier)
    let label = videoVariantLabel(index: index, bandwidth: bandwidth, width: width, height: height)
    return WuiNativeVideoTrackInfo(
      id: "avasset-variant-\(index)",
      label: label,
      bandwidth: bandwidth,
      width: width,
      height: height,
      codecs: codecs,
      hdr: attributes.videoRange != .sdr
    )
  }

  private static func videoDimension(_ value: CGFloat) -> UInt32? {
    guard value != 0 else { return nil }
    precondition(
      value.isFinite && value > 0 && value <= CGFloat(UInt32.max),
      "AVAsset variant dimension is outside UInt32"
    )
    return UInt32(value.rounded())
  }

  private static func codecIdentifier(_ codec: CMVideoCodecType) -> String {
    let bytes: [UInt8] = [
      UInt8((codec >> 24) & 0xff),
      UInt8((codec >> 16) & 0xff),
      UInt8((codec >> 8) & 0xff),
      UInt8(codec & 0xff),
    ]
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func videoVariantLabel(
    index: Int,
    bandwidth: UInt64?,
    width: UInt32?,
    height: UInt32?
  ) -> String {
    var components: [String] = []
    if let width, let height {
      components.append("\(width)×\(height)")
    }
    if let bandwidth {
      let wholeMegabits = bandwidth / 1_000_000
      let decimalMegabits = (bandwidth % 1_000_000) / 100_000
      components.append("\(wholeMegabits).\(decimalMegabits) Mbps")
    }
    return components.isEmpty ? "Variant \(index + 1)" : components.joined(separator: " · ")
  }

  private static func declaredBitRate(_ variant: AVAssetVariant) -> Double {
    let peak = variant.peakBitRate ?? -1
    return peak > 0 ? peak : variant.averageBitRate ?? -1
  }

  private static func videoVariantPrecedes(_ lhs: AVAssetVariant, _ rhs: AVAssetVariant) -> Bool {
    let lhsBitRate = declaredBitRate(lhs)
    let rhsBitRate = declaredBitRate(rhs)
    if lhsBitRate != rhsBitRate {
      return lhsBitRate < rhsBitRate
    }
    let lhsSize = lhs.videoAttributes?.presentationSize ?? .zero
    let rhsSize = rhs.videoAttributes?.presentationSize ?? .zero
    let lhsPixels = lhsSize.width * lhsSize.height
    let rhsPixels = rhsSize.width * rhsSize.height
    return lhsPixels < rhsPixels
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
    if configuredDurationSeconds > 0 {
      return configuredDurationSeconds
    }

    let actualDuration = player.currentItem?.duration.seconds ?? -1
    return actualDuration.isFinite && actualDuration > 0 ? actualDuration : 0
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
    signals.desiredPlaying.set(true)
  }

  func mediaSessionPause() {
    signals.desiredPlaying.set(false)
  }

  func mediaSessionStop() {
    signals.desiredPlaying.set(false)
    let start = player.currentItem?.seekableTimeRanges.first?.timeRangeValue.start.seconds ?? 0
    signals.seekTargetSeconds.set(start.isFinite ? max(0, start) : 0)
    signals.seekGeneration.set(signals.seekGeneration.value &+ 1)
  }

  func mediaSessionSeek(to seconds: Double) {
    signals.seekTargetSeconds.set(clampedSeekTarget(max(0, seconds)))
    signals.seekGeneration.set(signals.seekGeneration.value &+ 1)
  }

  func mediaSessionSetDucked(_ ducked: Bool) {
    isDucked = ducked
    applyEffectiveVolume()
  }

  func mediaSessionEmitNextRequested() {
    guard signals.hasNext.value else { return }
    waterui_video_controller_next(controller)
    emitEvent(CWaterUI.WuiVideoEventType_NextRequested)
  }

  func mediaSessionEmitPreviousRequested() {
    guard signals.hasPrevious.value else { return }
    waterui_video_controller_previous(controller)
    emitEvent(CWaterUI.WuiVideoEventType_PreviousRequested)
  }

  @MainActor deinit {
    mediaSessionBridge = nil
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    watchers.removeAll()
    playbackStateObserver = nil
    if let periodicTimeObserver {
      player.removeTimeObserver(periodicTimeObserver)
      self.periodicTimeObserver = nil
    }
    itemObservers.removeAll()
    subtitleSelectionTask?.cancel()
    audioTrackSelectionTask?.cancel()
    videoTrackSelectionTask?.cancel()
    trackCatalogTask?.cancel()
    player.pause()
    player.replaceCurrentItem(with: nil)
    waterui_drop_video_controller(controller)
    if let onEvent {
      waterui_drop_video_event_handler(onEvent)
    }
  }
}
