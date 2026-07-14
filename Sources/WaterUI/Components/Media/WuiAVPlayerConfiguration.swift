import AVFoundation
import CWaterUI

@MainActor
final class WuiVideoEventEmitter {
    private let action: OpaquePointer
    private let env: WuiEnvironment

    init(action: OpaquePointer, env: WuiEnvironment) {
        self.action = action
        self.env = env
    }

    func emit(
        _ eventType: CWaterUI.WuiVideoEventType,
        errorMessage: String = "",
        bufferedMs: UInt32 = 0,
        avDriftMs: Float = 0,
        droppedVideoFrames: UInt64 = 0,
        pictureInPictureActive: Bool = false,
        playbackActive: Bool = false
    ) {
        let event = CWaterUI.WuiVideoEvent(
            event_type: eventType,
            error_message: WuiStr(string: errorMessage).intoInner(),
            buffered_ms: bufferedMs,
            av_drift_ms: avDriftMs,
            dropped_video_frames: droppedVideoFrames,
            picture_in_picture_active: pictureInPictureActive,
            playback_active: playbackActive
        )
        waterui_call_video_event_action(action, event, env.inner)
    }

    @MainActor deinit {
        waterui_drop_video_event_action(action)
    }
}

@MainActor
final class WuiAVPlayerPlaybackStateObserver {
    private var observation: NSKeyValueObservation?
    private var reportedPlaying: Bool?

    init(player: AVPlayer, eventEmitter: WuiVideoEventEmitter) {
        observation = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self, weak eventEmitter] player, _ in
            DispatchQueue.main.async {
                guard let self, let eventEmitter else { return }
                let playing = player.timeControlStatus == .playing
                guard self.reportedPlaying != playing else { return }
                self.reportedPlaying = playing
                eventEmitter.emit(
                    CWaterUI.WuiVideoEventType_PlaybackStateChanged,
                    playbackActive: playing
                )
            }
        }
    }
}

@MainActor
func applyVideoPlaybackPolicy(
    _ policy: CWaterUI.WuiPlaybackPolicy,
    to player: AVPlayer
) {
    player.automaticallyWaitsToMinimizeStalling = !policy.realtime
}

@MainActor
func applyVideoPlaybackPolicy(
    _ policy: CWaterUI.WuiPlaybackPolicy,
    to item: AVPlayerItem
) {
    item.preferredForwardBufferDuration = policy.realtime
        ? 0
        : Double(policy.vod_start_buffer_ms) / 1_000
}

@MainActor
func applyVideoSubtitleSelection(
    _ selection: Int32,
    to item: AVPlayerItem
) async -> String? {
    let group: AVMediaSelectionGroup?
    do {
        group = try await item.asset.loadMediaSelectionGroup(for: .legible)
    } catch {
        return error.localizedDescription
    }
    guard let group else {
        return selection >= 0
            ? "Subtitle track requested, but the media has no legible tracks"
            : nil
    }

    switch selection {
    case -1:
        item.selectMediaOptionAutomatically(in: group)
    case -2:
        item.select(nil, in: group)
    case 0...:
        let index = Int(selection)
        guard group.options.indices.contains(index) else {
            return "Subtitle track index \(index) is out of range for \(group.options.count) tracks"
        }
        item.select(group.options[index], in: group)
    default:
        fatalError("Unsupported subtitle selection wire value \(selection)")
    }
    return nil
}

@MainActor
final class WuiAVPlayerObservers {
    private var guards: [WatcherGuard] = []

    init(
        source: WuiComputed<WuiStr>,
        title: WuiComputed<WuiStr>,
        artist: WuiComputed<WuiStr>,
        album: WuiComputed<WuiStr>,
        artworkURL: WuiComputed<WuiStr>,
        durationSeconds: WuiComputed<Double>,
        hasNext: WuiBinding<Bool>,
        hasPrevious: WuiBinding<Bool>,
        volume: WuiBinding<Float>,
        playbackRate: WuiBinding<Float>,
        preservePitch: WuiBinding<Bool>,
        subtitleSelection: WuiBinding<Int32>,
        sourceChanged: @escaping (WuiStr) -> Void,
        metadataChanged: @escaping () -> Void,
        playbackChanged: @escaping () -> Void,
        volumeChanged: @escaping (Float) -> Void,
        playbackRateChanged: @escaping (Float) -> Void,
        preservePitchChanged: @escaping (Bool) -> Void,
        subtitleSelectionChanged: @escaping (Int32) -> Void
    ) {
        guards = [
            source.watch { value, _ in sourceChanged(value) },
            title.watch { _, _ in metadataChanged() },
            artist.watch { _, _ in metadataChanged() },
            album.watch { _, _ in metadataChanged() },
            artworkURL.watch { _, _ in metadataChanged() },
            durationSeconds.watch { _, _ in metadataChanged() },
            hasNext.watch { _, _ in playbackChanged() },
            hasPrevious.watch { _, _ in playbackChanged() },
            volume.watch { value, _ in volumeChanged(value) },
            playbackRate.watch { value, _ in playbackRateChanged(value) },
            preservePitch.watch { value, _ in preservePitchChanged(value) },
            subtitleSelection.watch { value, _ in subtitleSelectionChanged(value) },
        ]
    }
}
