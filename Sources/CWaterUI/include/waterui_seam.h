// waterui_seam.h — the Rust/Swift coexistence seam ABI.
//
// Hand-written mirror of `src/seam.rs` in the `waterui-apple` crate, kept
// byte-for-byte with its `repr(C)` declarations: same field order, same
// packing. `waterui_apple_resolve` / `waterui_swift_render` exchange these
// types by value; neither side may re-enter the other on a miss.
//
// The `Waterui*` prefix is deliberate: `Wui*` types belong to the generated
// waterui-ffi header (`waterui.h`), this ABI does not.

#ifndef WATERUI_SEAM_H
#define WATERUI_SEAM_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A `std::any::TypeId` on the wire: FNV-1a-128 of `type_name::<T>()` as a
/// `u128`, passed as its low and high halves.
typedef struct WateruiTypeId {
  uint64_t low;
  uint64_t high;
} WateruiTypeId;

/// `ProposalSize` on the wire: one `f32` per axis, `NaN` when the axis is
/// unspecified.
typedef struct WateruiProposalSize {
  float width;
  float height;
} WateruiProposalSize;

/// `Size` on the wire.
typedef struct WateruiSize {
  float width;
  float height;
} WateruiSize;

/// `Point` on the wire.
typedef struct WateruiPoint {
  float x;
  float y;
} WateruiPoint;

/// `Rect` on the wire.
typedef struct WateruiRect {
  struct WateruiPoint origin;
  struct WateruiSize size;
} WateruiRect;

/// `HorizontalAlignment` on the wire (`repr(u8)`): leading 0, center 1,
/// trailing 2.
typedef uint8_t WateruiHorizontalGuideAlignment;

/// `VerticalAlignment` on the wire (`repr(u8)`): top 0, center 1, bottom 2,
/// first baseline 3, last baseline 4.
typedef uint8_t WateruiVerticalGuideAlignment;

/// `StretchAxis` on the wire (`repr(u8)`): none 0, horizontal 1, vertical 2,
/// both 3, main axis 4, cross axis 5.
typedef uint8_t WateruiStretchAxis;

/// An explicit horizontal guide: an alignment tag and its offset.
typedef struct WateruiHorizontalGuide {
  WateruiHorizontalGuideAlignment alignment;
  float value;
} WateruiHorizontalGuide;

/// An explicit vertical guide: an alignment tag and its offset.
typedef struct WateruiVerticalGuide {
  WateruiVerticalGuideAlignment alignment;
  float value;
} WateruiVerticalGuide;

/// An owned array on the wire: allocation, length, capacity and its free
/// function. The producer allocates however it chooses and must free exactly
/// that allocation when `free` runs. A null `data` array is empty.
typedef struct WateruiOwnedArray {
  void *data;
  uintptr_t len;
  uintptr_t cap;
  void (*free)(void *data, uintptr_t len, uintptr_t cap);
} WateruiOwnedArray;

/// `ViewDimensions` on the wire.
typedef struct WateruiViewDimensions {
  struct WateruiSize size;
  struct WateruiOwnedArray horizontal_guides;
  struct WateruiOwnedArray vertical_guides;
} WateruiViewDimensions;

/// A leaf's layout face: a context pointer and one callback per question
/// the parent asks. The query callbacks are live reads — a leaf whose
/// stretch axis or emptiness changes answers the new value on the next
/// call. `drop` runs once, when the leaf's owner lets go; the view is
/// retained and released separately from `context`.
typedef struct WateruiSubView {
  void *context;
  struct WateruiViewDimensions (*measure)(void *context,
                                          struct WateruiProposalSize proposal);
  void (*place)(void *context, struct WateruiProposalSize proposal);
  WateruiStretchAxis (*stretch_axis)(void *context);
  int32_t (*priority)(void *context);
  bool (*is_empty)(void *context);
  void (*drop)(void *context);
} WateruiSubView;

/// A leaf crossing the seam in either direction, passed by value: `view` is
/// +1 retained and owned by the receiver (`takeRetainedValue` /
/// `Retained::from_raw`), or null for "not claimed" — in which case
/// `subview.drop` is a no-op and `context` is null.
typedef struct WateruiLeaf {
  void *view;
  struct WateruiSubView subview;
} WateruiLeaf;

/// Whether `view` — an erased `AnyView` box — is a `Native`/`Metadata`
/// wrapper: the types whose `body()` panics instead of expanding. The Swift
/// resolve walk asks this before calling `waterui_view_body`. Borrows `view`.
bool waterui_apple_needs_fallback(void *view);

/// A `waterui_apple_resolve` answer: `leaf` carries the claimed leaf, or
/// `expanded` carries a `Box<AnyView>` the caller re-walks — the unclaimed
/// `Native` expanded to its `with_fallback` view. Both empty means neither
/// side claims the view.
typedef struct WateruiResolution {
  struct WateruiLeaf leaf;
  void *expanded;
} WateruiResolution;

/// Resolves `view` through the Rust dispatcher. `view` and `env` are
/// `Box<AnyView>` / `Box<Environment>` allocations consumed by this call.
/// The answered leaf's `view` is +1 owned by the caller; `expanded` is a
/// `Box<AnyView>` the caller takes and re-walks, or null.
struct WateruiResolution waterui_apple_resolve(void *view, void *env);

/// Installs `view` — the rendered window-toolbar host — as `window`'s
/// toolbar items: lone-child wrappers are descended and the first
/// multi-child view's children become the toolbar items. Both pointers are
/// borrowed `NSWindow*`/`NSView*`; call on the main thread. macOS only.
void waterui_apple_install_toolbar(void *window, void *view);

/// Installs the shared `GpuRuntime` into `env` asynchronously — the CEF
/// backend's `installGpuRuntime(env:)` and the Rust launcher's pre-seam
/// `gpu_runtime::prepare`. `complete` fires once with `context` when the
/// runtime is in; `drop_context` releases `context` exactly once.
void waterui_apple_install_gpu_runtime(void *env, void *context,
                                       void (*complete)(void *),
                                       void (*drop_context)(void *));

/// The runtime's `MTLDevice` for `env`, retained `+1`-neutral (borrowed):
/// `wuiMetalDevice(environment:)` wraps it.
void *waterui_apple_gpu_metal_device(void *env);

/// Installs the environment's `ViewRenderer` — `renderViewToRGBA`'s Rust
/// port — backing `CustomViewRenderer`. Call on the main thread.
void waterui_apple_install_view_renderer(void *env);

/// Installs the platform `WebViewController` into `env` when the
/// application left the slot empty — the Rust port of
/// `installWebViewController`. Runs on the main thread; `env` is borrowed
/// for the call. Only emitted when the crate's `webview` feature is on.
void waterui_apple_install_webview(void *env);

/// `makeWaterUIGpuSurface`: builds a `gpu_surface` leaf for a CEF-owned
/// `CWaterUI.WuiGpuSurface` and returns its platform view `+1` for
/// `Unmanaged<NSView>.takeRetainedValue()`.
void *waterui_apple_make_gpu_surface_view(void *surface, void *env);

/// Application entry point, emitted by `waterui_apple::export_app!` into the
/// app's Rust crate. `main.swift` calls it with `accessory` = whether the
/// process runs as an macOS accessory (menu-bar-only) app.
void waterui_apple_main(bool accessory);

/// The declared first window as the embed path's `WuiWindowContext` carries
/// it: `title`/`frame`/`state`/`style`/`level`/`attention`/
/// `resize_increments`/`background` are the generated FFI crate's
/// `WuiComputed_*`/`WuiBinding_*` pointers (transparent wrappers the Rust
/// side borrows), `toolbar` an owning `WuiAnyView` transfer or NULL.
typedef struct WateruiRootWindowDecl {
  void *env;
  void *title;
  void *frame;
  void *state;
  void *toolbar;
  void *style;
  void *level;
  void *attention;
  void *resize_increments;
  void *background;
  bool closable;
  bool resizable;
} WateruiRootWindowDecl;

/// Installs the environment's `WindowManager` — the Rust port of
/// `installWindowManager`. Call on the main thread.
void waterui_apple_install_window_manager(void *env);

/// macOS only: binds the app's first declared window to an `NSWindow` the
/// host already created. Returns the binding the host keeps for the window's
/// life, or NULL when `window`/a required field is null or the call is not
/// on the main thread.
void *waterui_apple_bind_root_window(void *ns_window,
                                   WateruiRootWindowDecl decl);

/// Releases a root-window binding; NULL is a no-op.
void waterui_apple_root_window_binding_free(void *binding);

#ifdef __cplusplus
}
#endif

#endif /* WATERUI_SEAM_H */
