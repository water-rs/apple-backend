import Foundation

private struct WaterKitAppleMediaCommandFFI {
  var kind: Int32
  var valueSeconds: Double
}

private enum WaterKitAppleMediaResult: Int32 {
  case success = 0
  case initializationFailed = 1
  case updateFailed = 2
  case audioFocusDenied = 3
  case unknown = 4
}

private enum WaterKitAppleMediaCommandKind: Int32 {
  case none = 0
  case play = 1
  case pause = 2
  case playPause = 3
  case stop = 4
  case next = 5
  case previous = 6
  case seek = 7
  case seekForward = 8
  case seekBackward = 9
  case audioFocusGained = 10
  case audioFocusLost = 11
  case audioFocusLostTransient = 12
  case audioFocusLostDuck = 13
  case audioBecomingNoisy = 14
}

@_silgen_name("waterkit_audio_apple_media_session_init")
private func waterkitAudioAppleMediaSessionInit(
  _: UnsafeMutablePointer<Int32>
) -> UnsafeMutableRawPointer?

@_silgen_name("waterkit_audio_apple_media_session_set_metadata")
private func waterkitAudioAppleMediaSessionSetMetadata(
  _: UnsafeMutableRawPointer,
  _: UnsafePointer<CChar>?,
  _: UnsafePointer<CChar>?,
  _: UnsafePointer<CChar>?,
  _: UnsafePointer<CChar>?,
  _: Double
) -> Int32

@_silgen_name("waterkit_audio_apple_media_session_set_playback_state")
private func waterkitAudioAppleMediaSessionSetPlaybackState(
  _: UnsafeMutableRawPointer,
  _: UInt8,
  _: Double,
  _: Double,
  _: Bool,
  _: Bool
) -> Int32

@_silgen_name("waterkit_audio_apple_media_session_request_audio_focus")
private func waterkitAudioAppleMediaSessionRequestAudioFocus(_: UnsafeMutableRawPointer) -> Int32

@_silgen_name("waterkit_audio_apple_media_session_abandon_audio_focus")
private func waterkitAudioAppleMediaSessionAbandonAudioFocus(_: UnsafeMutableRawPointer) -> Int32

@_silgen_name("waterkit_audio_apple_media_session_clear")
private func waterkitAudioAppleMediaSessionClear(_: UnsafeMutableRawPointer) -> Int32

@_silgen_name("waterkit_audio_apple_media_session_wait_command")
private func waterkitAudioAppleMediaSessionWaitCommand(
  _: UnsafeMutableRawPointer
) -> WaterKitAppleMediaCommandFFI

@_silgen_name("waterkit_audio_apple_media_session_destroy")
private func waterkitAudioAppleMediaSessionDestroy(_: UnsafeMutableRawPointer)

struct WuiMediaMetadataSnapshot: Equatable {
  var title: String
  var artist: String
  var album: String
  var artworkURL: String
  var durationSeconds: Double
}

enum WuiMediaPlaybackStatus: UInt8, Equatable {
  case stopped = 0
  case paused = 1
  case playing = 2
}

struct WuiMediaPlaybackSnapshot: Equatable {
  var status: WuiMediaPlaybackStatus
  var positionSeconds: Double
  var rate: Double
  var nextEnabled: Bool
  var previousEnabled: Bool
}

@MainActor
protocol WuiMediaSessionHost: AnyObject {
  var currentMediaMetadataSnapshot: WuiMediaMetadataSnapshot { get }
  var currentMediaPlaybackSnapshot: WuiMediaPlaybackSnapshot { get }

  func mediaSessionPlay()
  func mediaSessionPause()
  func mediaSessionStop()
  func mediaSessionSeek(to seconds: Double)
  func mediaSessionSetDucked(_ ducked: Bool)
  func mediaSessionEmitNextRequested()
  func mediaSessionEmitPreviousRequested()
}

private func withOptionalCString<R>(_ value: String, _ body: (UnsafePointer<CChar>?) -> R) -> R {
  if value.isEmpty {
    return body(nil)
  }

  return value.withCString { pointer in
    body(pointer)
  }
}

private func mediaSessionAssertSuccess(_ rawValue: Int32, context: String) {
  guard let result = WaterKitAppleMediaResult(rawValue: rawValue) else {
    fatalError("waterkit-audio returned unsupported Apple media result \(rawValue) for \(context)")
  }

  switch result {
  case .success:
    return
  case .initializationFailed:
    fatalError("waterkit-audio failed to initialize Apple media session for \(context)")
  case .updateFailed:
    fatalError("waterkit-audio failed to update Apple media session for \(context)")
  case .audioFocusDenied:
    fatalError("waterkit-audio Apple media session audio focus was denied for \(context)")
  case .unknown:
    fatalError("waterkit-audio Apple media session returned an unknown error for \(context)")
  }
}

@MainActor
final class WuiWaterKitMediaSessionBridge {
  private weak var host: (any WuiMediaSessionHost)?
  private let sessionHandle: UnsafeMutableRawPointer
  private let commandQueue = DispatchQueue(label: "dev.waterui.media-session.commands")
  private var lastMetadata: WuiMediaMetadataSnapshot?
  private var lastPlayback: WuiMediaPlaybackSnapshot?
  private var audioSessionActive = false
  private var resumeAfterFocusGain = false

  init(host: any WuiMediaSessionHost) {
    self.host = host
    var initializationResult = WaterKitAppleMediaResult.unknown.rawValue
    guard let sessionHandle = waterkitAudioAppleMediaSessionInit(&initializationResult) else {
      mediaSessionAssertSuccess(initializationResult, context: "media session initialization")
      fatalError("waterkit-audio returned no Apple media session after successful initialization")
    }
    self.sessionHandle = sessionHandle
    mediaSessionAssertSuccess(
      initializationResult,
      context: "media session initialization"
    )
    syncMetadataIfNeeded(force: true)
    syncPlaybackStateIfNeeded(force: true)
    startCommandPump()
  }

  func metadataDidChange() {
    syncMetadataIfNeeded(force: false)
  }

  func playbackDidChange() {
    syncPlaybackStateIfNeeded(force: false)
  }

  private func startCommandPump() {
    let handleAddress = UInt(bitPattern: sessionHandle)
    commandQueue.async { [weak self] in
      let handle = UnsafeMutableRawPointer(bitPattern: handleAddress)!
      while true {
        let command = waterkitAudioAppleMediaSessionWaitCommand(handle)
        guard let kind = WaterKitAppleMediaCommandKind(rawValue: command.kind) else {
          fatalError("waterkit-audio returned unsupported Apple media command \(command.kind)")
        }
        if kind == .none {
          return
        }
        Task { @MainActor [weak self] in
          self?.handleCommand(kind, valueSeconds: command.valueSeconds)
        }
      }
    }
  }

  private func syncMetadataIfNeeded(force: Bool) {
    guard let host else { return }

    let metadata = host.currentMediaMetadataSnapshot
    if !force && metadata == lastMetadata {
      return
    }

    withOptionalCString(metadata.title) { title in
      withOptionalCString(metadata.artist) { artist in
        withOptionalCString(metadata.album) { album in
          withOptionalCString(metadata.artworkURL) { artworkURL in
            mediaSessionAssertSuccess(
              waterkitAudioAppleMediaSessionSetMetadata(
                sessionHandle,
                title,
                artist,
                album,
                artworkURL,
                metadata.durationSeconds
              ),
              context: "metadata sync"
            )
          }
        }
      }
    }

    lastMetadata = metadata
  }

  private func syncPlaybackStateIfNeeded(force: Bool) {
    guard let host else { return }

    let snapshot = host.currentMediaPlaybackSnapshot
    let shouldHoldAudioSession = snapshot.status != .stopped

    if shouldHoldAudioSession && !audioSessionActive {
      mediaSessionAssertSuccess(
        waterkitAudioAppleMediaSessionRequestAudioFocus(sessionHandle),
        context: "audio session activation"
      )
      audioSessionActive = true
    } else if !shouldHoldAudioSession && audioSessionActive {
      mediaSessionAssertSuccess(
        waterkitAudioAppleMediaSessionAbandonAudioFocus(sessionHandle),
        context: "audio session deactivation"
      )
      audioSessionActive = false
    }

    if !force && snapshot == lastPlayback {
      return
    }

    mediaSessionAssertSuccess(
      waterkitAudioAppleMediaSessionSetPlaybackState(
        sessionHandle,
        snapshot.status.rawValue,
        snapshot.positionSeconds,
        snapshot.rate,
        snapshot.nextEnabled,
        snapshot.previousEnabled
      ),
      context: "playback state sync"
    )
    lastPlayback = snapshot
  }

  private func handleCommand(
    _ command: WaterKitAppleMediaCommandKind,
    valueSeconds: Double
  ) {
    guard let host else { return }

    switch command {
    case .none:
      return
    case .play:
      host.mediaSessionPlay()
    case .pause:
      host.mediaSessionPause()
    case .playPause:
      if host.currentMediaPlaybackSnapshot.status == .playing {
        host.mediaSessionPause()
      } else {
        host.mediaSessionPlay()
      }
    case .stop:
      resumeAfterFocusGain = false
      host.mediaSessionSetDucked(false)
      host.mediaSessionStop()
    case .next:
      if host.currentMediaPlaybackSnapshot.nextEnabled {
        host.mediaSessionEmitNextRequested()
      }
    case .previous:
      if host.currentMediaPlaybackSnapshot.previousEnabled {
        host.mediaSessionEmitPreviousRequested()
      }
    case .seek:
      host.mediaSessionSeek(to: valueSeconds)
    case .seekForward:
      host.mediaSessionSeek(
        to: host.currentMediaPlaybackSnapshot.positionSeconds + valueSeconds
      )
    case .seekBackward:
      host.mediaSessionSeek(
        to: max(0, host.currentMediaPlaybackSnapshot.positionSeconds - valueSeconds)
      )
    case .audioFocusGained:
      host.mediaSessionSetDucked(false)
      if resumeAfterFocusGain {
        resumeAfterFocusGain = false
        host.mediaSessionPlay()
      }
    case .audioFocusLost:
      resumeAfterFocusGain = false
      host.mediaSessionSetDucked(false)
      host.mediaSessionPause()
    case .audioFocusLostTransient:
      resumeAfterFocusGain = host.currentMediaPlaybackSnapshot.status == .playing
      host.mediaSessionPause()
    case .audioFocusLostDuck:
      host.mediaSessionSetDucked(true)
    case .audioBecomingNoisy:
      resumeAfterFocusGain = false
      host.mediaSessionPause()
    }

    syncPlaybackStateIfNeeded(force: true)
  }

  @MainActor deinit {
    if audioSessionActive {
      mediaSessionAssertSuccess(
        waterkitAudioAppleMediaSessionAbandonAudioFocus(sessionHandle),
        context: "audio session deactivation"
      )
    }
    mediaSessionAssertSuccess(
      waterkitAudioAppleMediaSessionClear(sessionHandle),
      context: "media session teardown"
    )
    let handleAddress = UInt(bitPattern: sessionHandle)
    commandQueue.async {
      let handle = UnsafeMutableRawPointer(bitPattern: handleAddress)!
      waterkitAudioAppleMediaSessionDestroy(handle)
    }
  }
}
