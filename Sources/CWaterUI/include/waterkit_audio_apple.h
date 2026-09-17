// The Apple host bridge of `waterkit-audio`
// (`waterkit-audio/src/sys/apple/host_bridge.rs`): the C ABI through which a
// Swift host mirrors a player's metadata and playback state into the system
// media session and drains its remote commands.
//
// These are C-convention functions and must be declared to Swift as such.
// `@_silgen_name` binds a symbol with the Swift calling convention, which on
// arm64 does not zero-extend narrow integer arguments and returns a
// {int32, double} aggregate in separate registers; the Rust callee, following
// the Apple arm64 C ABI, assumes both — so a `uint8_t` status arrived with
// stale upper bits and a command's `value_secs` was read from the wrong
// register.

#ifndef WATERKIT_AUDIO_APPLE_H
#define WATERKIT_AUDIO_APPLE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WaterKitAppleMediaSessionHandle WaterKitAppleMediaSessionHandle;

typedef struct WaterKitAppleMediaCommandFFI {
  int32_t kind;
  double value_secs;
} WaterKitAppleMediaCommandFFI;

WaterKitAppleMediaSessionHandle *waterkit_audio_apple_media_session_init(int32_t *result_out);

int32_t waterkit_audio_apple_media_session_set_metadata(
    WaterKitAppleMediaSessionHandle *handle,
    const char *title,
    const char *artist,
    const char *album,
    const char *artwork_url,
    double duration_secs);

int32_t waterkit_audio_apple_media_session_set_playback_state(
    WaterKitAppleMediaSessionHandle *handle,
    uint8_t status,
    double position_secs,
    double rate,
    bool next_enabled,
    bool previous_enabled);

int32_t waterkit_audio_apple_media_session_request_audio_focus(
    WaterKitAppleMediaSessionHandle *handle);

int32_t waterkit_audio_apple_media_session_abandon_audio_focus(
    WaterKitAppleMediaSessionHandle *handle);

int32_t waterkit_audio_apple_media_session_clear(WaterKitAppleMediaSessionHandle *handle);

WaterKitAppleMediaCommandFFI waterkit_audio_apple_media_session_wait_command(
    WaterKitAppleMediaSessionHandle *handle);

void waterkit_audio_apple_media_session_destroy(WaterKitAppleMediaSessionHandle *handle);

#ifdef __cplusplus
}
#endif

#endif  // WATERKIT_AUDIO_APPLE_H
