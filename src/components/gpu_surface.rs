//! The `gpu_surface` leaf: `Native<GpuSurface>` as a kit surface view
//! presenting host-owned `IOSurface` textures — the Rust port of
//! `WuiGpuSurface`/`WuiGpuSurfaceState`, `WuiSurfacePresentation`,
//! `WuiDisplayLinkDriver`, `WuiRedrawCallback` and `WuiWindowOcclusion`.
//!
//! Frames render into the kit's double-buffered `IOSurface` pair through an
//! imported `MTLTexture`, present once the submission lands, and schedule
//! the next frame from the display-link clock while dirty. Surfaces also
//! implement the kit's [`CapturableSurface`] so an enclosing capture
//! (`view_effect`, `applied_filter`) can draw their content into its target.

use alloc::boxed::Box;
use alloc::rc::{Rc, Weak};
use alloc::sync::Arc;
use core::cell::{Cell, RefCell};
use core::ffi::c_void;
use core::fmt;
use core::num::NonZeroU32;
use core::time::Duration;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Instant;

use cocoa_ui::Retained;
use executor_core::spawn_local;
use futures::FutureExt;
#[allow(unused_imports)]
use objc2_metal::MTLTexture as _;
use waterui_backend_core::Environment;
use waterui_core::layout::{ProposalSize, Size, StretchAxis, SubView, ViewDimensions};
use waterui_graphics::gpu_surface::{GestureState, GpuContext, GpuFrame, GpuSurface, PointerState};
use waterui_graphics::shared_context::GpuRuntime;

use crate::contract::NativeLeaf;
use crate::dispatch::Dispatcher;

#[cfg(target_os = "macos")]
mod platform {
    pub(super) use cocoa_ui::appkit::surface_view::SurfaceView;
}

#[cfg(target_os = "ios")]
mod platform {
    pub(super) use cocoa_ui::uikit::surface_view::SurfaceView;
}

use platform::SurfaceView;

/// The semantic renderer plus the environment it runs `setup` against — the
/// slot asynchronous setup moves the value through.
struct Semantic {
    gpu_surface: GpuSurface,
    env: Environment,
}

/// Everything the leaf owns for one mounted `GpuSurface` — the
/// `WuiGpuSurfaceState` equivalent, plus the presentation resources the
/// Swift side split across its own files.
struct SurfaceState {
    /// The environment's GPU runtime; `context()` follows device rebuilds.
    runtime: GpuRuntime,
    /// Main-thread semantic renderer and environment. Setup temporarily
    /// moves this value into its local future, then returns it to the slot.
    semantic: Rc<RefCell<Option<Semantic>>>,
    /// Becomes true only after the local setup future has completed.
    setup_ready: Rc<Cell<bool>>,
    /// Maximum MSAA sample count requested by the `GpuSurface` API.
    msaa_max_samples: NonZeroU32,
    /// Layout priority, captured when the state is created.
    priority: i32,
    /// The format selected when asynchronous renderer setup starts.
    renderer_format: Cell<Option<waterui_graphics::wgpu::TextureFormat>>,
    /// Physical size the presentation buffers are configured at.
    current_width: Cell<u32>,
    /// Physical size the presentation buffers are configured at.
    current_height: Cell<u32>,
    /// Pointer/cursor snapshot the last interaction delivered.
    pointer_state: Cell<PointerState>,
    /// Gesture snapshot the last interaction delivered.
    gesture_state: Cell<GestureState>,
    /// Animation clock start for frame timing.
    start_time: Cell<Instant>,
    /// Timestamp of the previous render.
    last_frame_time: Cell<Instant>,
    /// Redraw handle for external redraw triggers.
    redraw_handle: waterui_graphics::gpu_surface::RedrawHandle,
    /// Whether the semantic GPU view takes its own input — captured once at
    /// creation, since `wants_input_events` is a registration-time question.
    wants_input_events: bool,
    /// The `SharedGpuContext` generation the renderer was set up under; a
    /// different one means the pipelines died with their device.
    context_generation: Cell<u64>,
    /// The host-owned `IOSurface` presentation buffers.
    buffers: RefCell<Option<cocoa_ui::metal::SurfaceBuffers>>,
    /// Outstanding capture-suppression scopes — the presentation layer is
    /// hidden while nonzero (`beginCaptureSuppression`).
    capture_suppression: Cell<u32>,
    /// Outstanding external-rendering scopes; while nonzero the surface's
    /// redraws go to `external_redraw` and it presents nowhere itself.
    external_count: Cell<u32>,
    /// The redraw target external capture installed.
    external_redraw: RefCell<Option<Rc<dyn Fn()>>>,
    /// The display-link clock driving scheduled frames.
    clock: cocoa_ui::display_link::FrameClock,
    /// Whether a frame is pending completion — the clock is not restarted
    /// until the outstanding submission's present decision is made.
    frame_in_flight: Cell<bool>,
    /// A frame asked for while one could not be drawn — owed, not dropped.
    frame_owed: Cell<bool>,
    /// Whether the frame clock should tick — `keepRedrawing`.
    keep_redrawing: Cell<bool>,
    /// Whether an on-demand `renderFrame` is queued on the main queue.
    redraw_wake_scheduled: Cell<bool>,
    /// The explicit HDR preference `resolved_hdr_preference` produced.
    explicit_range: Option<cocoa_ui::dynamic_range::DynamicRange>,
    /// `rendererDynamicRange`'s latch: wgpu keeps the negotiated format
    /// across attach cycles, so the first answer stands.
    latched_renderer_range: Cell<Option<cocoa_ui::dynamic_range::DynamicRange>>,
    /// The presentation range `applyDynamicRange` was last run with.
    configured_range: Cell<Option<cocoa_ui::dynamic_range::DynamicRange>>,
    /// Whether the presenter and renderer are attached for this window.
    attached: Cell<bool>,
    /// The format the presented surfaces carry — `configureDynamicRange`'s
    /// answer; `capturePixelFormat` reads it.
    presentation_format: Cell<Option<objc2_metal::MTLPixelFormat>>,
    /// The scale the current bounds were last resolved at.
    current_scale: Cell<f64>,
    /// Wakers of tasks waiting on the first presented frame.
    ready_waiters: RefCell<Vec<std::task::Waker>>,
    /// Whether content accessibility republishes after the next frame.
    needs_a11y_refresh: Cell<bool>,
    /// Pinch scale when the current gesture began — the host accumulates.
    pinch_start_scale: Cell<f64>,
    /// The accumulated pinch scale (1.0 = none) — `cumulativeScale`.
    cumulative_scale: Cell<f64>,
    /// The accumulated pan offset in logical points — `gesturePanOffset`.
    pan_offset: Cell<(f64, f64)>,
    /// Window/app observers re-arming presentation edges.
    observers: RefCell<Vec<cocoa_ui::notification::NotificationObserver>>,
    /// The proposal the surface was last measured under.
    last_proposal: Cell<Option<ProposalSize>>,
    /// The last measurement the renderer answered — reused while setup
    /// owns the semantic renderer (`deferredMeasurementInvalidation`).
    last_resolved_size: RefCell<Option<Size>>,
    /// Whether a layout pass measured under a setup-owned renderer.
    deferred_measurement: Cell<bool>,
}

impl core::fmt::Debug for SurfaceState {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("SurfaceState")
            .field("current_width", &self.current_width)
            .field("current_height", &self.current_height)
            .finish_non_exhaustive()
    }
}

impl SurfaceState {
    /// Builds the state inside `Rc::new_cyclic`: the display-link clock's
    /// frame callback needs the `Weak` this construction produces.
    fn new(
        weak: &Weak<Self>,
        runtime: GpuRuntime,
        gpu_surface: GpuSurface,
        env: Environment,
        view: &Retained<SurfaceView>,
        mtm: cocoa_ui::MainThreadMarker,
    ) -> Self {
        let priority = gpu_surface.priority();
        let wants_input_events = gpu_surface.wants_input_events();
        let msaa_max_samples = gpu_surface.msaa_sample_limit();
        let gpu_surface_explicit_range = gpu_surface.resolved_hdr_preference().map(|high| {
            if high {
                cocoa_ui::dynamic_range::DynamicRange::High
            } else {
                cocoa_ui::dynamic_range::DynamicRange::Standard
            }
        });
        let semantic = Semantic { gpu_surface, env };
        let redraw_handle = waterui_graphics::gpu_surface::RedrawHandle::new();
        let now = Instant::now();
        // The display-link clock drives one frame per tick while dirty —
        // WuiDisplayLinkDriver.
        let clock = cocoa_ui::display_link::FrameClock::new(mtm, {
            let weak = weak.clone();
            let view = view.clone();
            move || {
                if let Some(state) = weak.upgrade() {
                    render_frame(&state, &view, false);
                }
            }
        });
        Self {
            runtime,
            semantic: Rc::new(RefCell::new(Some(semantic))),
            setup_ready: Rc::new(Cell::new(false)),
            msaa_max_samples,
            priority,
            renderer_format: Cell::new(None),
            current_width: Cell::new(0),
            current_height: Cell::new(0),
            pointer_state: Cell::new(PointerState::default()),
            gesture_state: Cell::new(GestureState::default()),
            start_time: Cell::new(now),
            last_frame_time: Cell::new(now),
            redraw_handle,
            wants_input_events,
            context_generation: Cell::new(0),
            buffers: RefCell::new(None),
            capture_suppression: Cell::new(0),
            external_count: Cell::new(0),
            external_redraw: RefCell::new(None),
            clock,
            frame_in_flight: Cell::new(false),
            frame_owed: Cell::new(false),
            keep_redrawing: Cell::new(false),
            redraw_wake_scheduled: Cell::new(false),
            explicit_range: gpu_surface_explicit_range,
            latched_renderer_range: Cell::new(None),
            configured_range: Cell::new(None),
            attached: Cell::new(false),
            presentation_format: Cell::new(None),
            current_scale: Cell::new(1.0),
            ready_waiters: RefCell::new(Vec::new()),
            needs_a11y_refresh: Cell::new(true),
            pinch_start_scale: Cell::new(1.0),
            cumulative_scale: Cell::new(1.0),
            pan_offset: Cell::new((0.0, 0.0)),
            observers: RefCell::new(Vec::new()),
            last_proposal: Cell::new(None),
            last_resolved_size: RefCell::new(None),
            deferred_measurement: Cell::new(false),
        }
    }
}

impl Drop for SurfaceState {
    fn drop(&mut self) {
        // Clearing the waker before the state falls out of scope releases
        // the redraw target first — same ordering as the ffi `drop`.
        self.redraw_handle.set_waker(None);
    }
}

/// Runs `f` with the semantic renderer if the setup future has returned it.
fn with_semantic_mut<T>(state: &SurfaceState, f: impl FnOnce(&mut Semantic) -> T) -> Option<T> {
    state.semantic.borrow_mut().as_mut().map(f)
}

/// Starts the asynchronous renderer setup against `format`, exactly once per
/// format — `waterui_gpu_surface_prepare_metal_texture`'s semantics.
fn start_renderer_setup(state: &Rc<SurfaceState>, format: waterui_graphics::wgpu::TextureFormat) {
    if let Some(existing) = state.renderer_format.get() {
        assert_eq!(
            existing, format,
            "GpuSurface target format changed after renderer setup started"
        );
        return;
    }
    state.renderer_format.set(Some(format));
    spawn_renderer_setup(state, format);
}

/// Re-runs renderer setup after the runtime's device was lost and rebuilt.
fn restart_renderer_setup(state: &Rc<SurfaceState>, format: waterui_graphics::wgpu::TextureFormat) {
    // A setup already in flight read the rebuilt context when it started, so
    // it is the recovery; starting another one would panic on the empty slot.
    if state.semantic.borrow().is_none() {
        return;
    }
    state.setup_ready.set(false);
    spawn_renderer_setup(state, format);
}

/// `ensure_current_context`: drops every device-bound resource and restarts
/// setup when the runtime's generation advanced past this surface's — the
/// pipelines died with the old device.
fn ensure_current_context(state: &Rc<SurfaceState>) {
    let gpu = state.runtime.context();
    if gpu.generation() == state.context_generation.get() {
        return;
    }
    state.context_generation.set(gpu.generation());
    if state.renderer_format.get().is_some() {
        restart_renderer_setup(state, state.renderer_format.get().expect("checked"));
    }
}

/// The setup loop: retries on the current context until it completes on a
/// context that is still the runtime's current one.
fn spawn_renderer_setup(state: &Rc<SurfaceState>, format: waterui_graphics::wgpu::TextureFormat) {
    let mut semantic = state
        .semantic
        .borrow_mut()
        .take()
        .expect("GpuSurface semantic renderer is unavailable before setup starts");
    let semantic_slot = Rc::clone(&state.semantic);
    let setup_ready = Rc::clone(&state.setup_ready);
    let runtime = state.runtime.clone();
    let redraw_handle = state.redraw_handle.clone();
    let msaa_max_samples = state.msaa_max_samples;

    spawn_local(async move {
        let Semantic { gpu_surface, env } = &mut semantic;
        loop {
            let gpu = runtime.context();
            let outcome = {
                let ctx = GpuContext::new(
                    &gpu.adapter,
                    &gpu.device,
                    &gpu.queue,
                    format,
                    gpu.shader_cache.as_ref(),
                    gpu.scene_renderer(),
                    msaa_max_samples,
                    redraw_handle.clone(),
                    gpu.device_loss(),
                );
                std::panic::AssertUnwindSafe(gpu_surface.setup(&ctx, env))
                    .catch_unwind()
                    .await
            };
            if let Err(payload) = outcome {
                if gpu.device_lost_reason().is_none() {
                    std::panic::resume_unwind(payload);
                }
                continue;
            }
            if gpu.device_lost_reason().is_none()
                && runtime.context().generation() == gpu.generation()
            {
                break;
            }
        }
        semantic_slot.replace(Some(semantic));
        setup_ready.set(true);
        redraw_handle.request_redraw();
    })
    .detach();
}

/// Advances elapsed/delta frame timing, capping delta at 100ms.
fn advance_frame_timing(state: &SurfaceState) -> (Duration, Duration) {
    let now = Instant::now();
    let elapsed = now.duration_since(state.start_time.get());
    let delta = now
        .duration_since(state.last_frame_time.get())
        .min(Duration::from_millis(100));
    state.last_frame_time.set(now);
    (elapsed, delta)
}

/// The wgpu texture format an `MTLTexture` imports at — the ffi
/// `metal_texture_format`.
fn metal_texture_format(
    texture: &objc2::runtime::ProtocolObject<dyn objc2_metal::MTLTexture>,
) -> waterui_graphics::wgpu::TextureFormat {
    use objc2_metal::{MTLPixelFormat, MTLTexture};
    match texture.pixelFormat() {
        MTLPixelFormat::BGRA8Unorm => waterui_graphics::wgpu::TextureFormat::Bgra8Unorm,
        MTLPixelFormat::BGRA8Unorm_sRGB => waterui_graphics::wgpu::TextureFormat::Bgra8UnormSrgb,
        MTLPixelFormat::RGBA16Float => waterui_graphics::wgpu::TextureFormat::Rgba16Float,
        other => panic!("GpuSurface external Metal texture has unsupported format {other:?}"),
    }
}

/// Renders one frame of the semantic GPU view into a texture it does not
/// own — `render_into_texture`. Nothing is submitted here; the caller
/// decides what the frame is ordered against.
fn render_into_texture(
    state: &SurfaceState,
    texture: &waterui_graphics::wgpu::Texture,
    view: waterui_graphics::wgpu::TextureView,
    format: waterui_graphics::wgpu::TextureFormat,
    width: u32,
    height: u32,
    scale: f64,
) {
    let (elapsed, delta) = advance_frame_timing(state);
    let gpu = state.runtime.context();
    let mut frame = GpuFrame::new(
        &gpu.device,
        &gpu.queue,
        texture,
        view,
        format,
        width,
        height,
        scale,
        state.pointer_state.get(),
        state.gesture_state.get(),
        elapsed,
        delta,
    );
    let _ = state.redraw_handle.take_dirty();
    with_semantic_mut(state, |semantic| {
        semantic.gpu_surface.render(&mut frame);
    });
    if frame.was_redraw_requested() || state.redraw_handle.take_dirty() {
        state.redraw_handle.request_redraw();
    }
}

/// Imports an `MTLTexture` as a wgpu texture and renders a frame into it;
/// returns the submission index the frame lands with — the
/// `render_to_metal_texture` half of the ffi entry point.
fn render_to_metal_texture(
    state: &Rc<SurfaceState>,
    metal_texture: Retained<objc2::runtime::ProtocolObject<dyn objc2_metal::MTLTexture>>,
    width: u32,
    height: u32,
    scale: f64,
) -> waterui_graphics::wgpu::SubmissionIndex {
    ensure_current_context(state);
    let target_format = metal_texture_format(&metal_texture);
    assert_eq!(
        state.renderer_format.get(),
        Some(target_format),
        "GpuSurface render called before preparing this target format"
    );
    assert!(
        state.setup_ready.get(),
        "GpuSurface render called before asynchronous setup completed"
    );

    let gpu = state.runtime.context();
    // SAFETY: `metal_texture` is retained by the caller, and the format and
    // size are read off that same texture.
    let wgpu_texture = unsafe {
        cocoa_ui::metal::import_texture(
            &gpu.device,
            metal_texture,
            target_format,
            width,
            height,
            waterui_graphics::wgpu::TextureUsages::RENDER_ATTACHMENT,
            "GpuSurface Imported Metal Texture",
        )
    };
    let view = wgpu_texture.create_view(&waterui_graphics::wgpu::TextureViewDescriptor {
        label: Some("GpuSurface Metal Frame View"),
        format: Some(target_format),
        ..Default::default()
    });
    render_into_texture(
        state,
        &wgpu_texture,
        view,
        target_format,
        width,
        height,
        scale,
    );
    gpu.queue.submit([])
}

// MARK: - Presentation lifecycle (WuiGpuSurface + WuiSurfacePresentation)

/// The renderer's latched target range — `rendererDynamicRange`.
fn renderer_dynamic_range(
    state: &SurfaceState,
    presentation: cocoa_ui::dynamic_range::DynamicRange,
) -> cocoa_ui::dynamic_range::DynamicRange {
    if let Some(latched) = state.latched_renderer_range.get() {
        return latched;
    }
    let mode = state.explicit_range.unwrap_or(presentation);
    state.latched_renderer_range.set(Some(mode));
    mode
}

/// Applies `presentation` to the view and settles the pixel format the
/// frames are rendered and composited in — `configureDynamicRange`.
fn configure_dynamic_range(
    state: &SurfaceState,
    view: &Retained<SurfaceView>,
    presentation: cocoa_ui::dynamic_range::DynamicRange,
    renderer: cocoa_ui::dynamic_range::DynamicRange,
) {
    if state.configured_range.get() == Some(presentation) {
        return;
    }
    debug_assert!(
        !state.attached.get(),
        "GpuSurface dynamic range cannot change while attached"
    );
    debug_assert!(
        presentation == cocoa_ui::dynamic_range::DynamicRange::Standard
            || renderer == cocoa_ui::dynamic_range::DynamicRange::High,
        "an HDR presentation requires an HDR-capable renderer target"
    );
    cocoa_ui::dynamic_range::apply_to_view(presentation, view.as_platform_view());
    let format = match renderer {
        cocoa_ui::dynamic_range::DynamicRange::High => objc2_metal::MTLPixelFormat::RGBA16Float,
        cocoa_ui::dynamic_range::DynamicRange::Standard => {
            objc2_metal::MTLPixelFormat::BGRA8Unorm_sRGB
        }
    };
    if let Some(buffers) = state.buffers.borrow_mut().as_mut() {
        buffers.release();
    }
    state.presentation_format.set(Some(format));
    state.configured_range.set(Some(presentation));
}

/// Whether this surface's window can put a frame in front of someone —
/// `canPresentNow`.
fn can_present_now(view: &Retained<SurfaceView>) -> bool {
    let Some(window) = cocoa_ui::view::window(view.as_platform_view()) else {
        return false;
    };
    #[cfg(target_os = "macos")]
    {
        if window.isMiniaturized() {
            return false;
        }
        cocoa_ui::appkit::is_visible(&window)
    }
    #[cfg(target_os = "ios")]
    {
        let _ = window;
        cocoa_ui::uikit::application_is_active()
    }
}

/// Whether this view and every ancestor is visible — `hasVisibleAncestry`.
fn has_visible_ancestry(view: &Retained<SurfaceView>) -> bool {
    let mut node = Some(cocoa_ui::view::retain_base(view));
    while let Some(current) = node {
        if cocoa_ui::view::is_hidden(&current) || cocoa_ui::view::alpha(&current) <= 0.0 {
            return false;
        }
        node = cocoa_ui::view::superview(&current);
    }
    true
}

/// Whether the frame clock ticks — `isEffectivelyVisible`: narrower than
/// `can_present_now` on the states that announce when they clear.
fn is_effectively_visible(view: &Retained<SurfaceView>) -> bool {
    let Some(window) = cocoa_ui::view::window(view.as_platform_view()) else {
        return false;
    };
    if !has_visible_ancestry(view) {
        return false;
    }
    #[cfg(target_os = "macos")]
    {
        // A window that is on no display cannot present; the frame clock
        // falls back to the run loop for those, so gating here keeps an
        // offscreen window from rendering frames nobody sees.
        if window.screen().is_none() {
            return false;
        }
        if window.isMiniaturized() {
            return false;
        }
        cocoa_ui::appkit::is_visible(&window)
    }
    #[cfg(target_os = "ios")]
    {
        let _ = window;
        cocoa_ui::uikit::application_is_active()
    }
}

/// Positions the presentation layer and tells Core Animation the frames are
/// already at device-pixel size — `updatePresentationFrame`.
fn update_presentation_frame(state: &SurfaceState, view: &Retained<SurfaceView>) {
    let layer = view.presentation_layer();
    let bounds = view.bounds_size();
    cocoa_ui::core_animation::without_animation(|| {
        cocoa_ui::core_animation::set_frame(
            &layer,
            cocoa_ui::Rect::new(0.0, 0.0, bounds.width, bounds.height),
        );
        cocoa_ui::core_animation::set_contents_scale(&layer, state.current_scale.get());
    });
}

/// Geometry + deferred allocation — `initializeGpuIfNeeded`.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn initialize_gpu(state: &Rc<SurfaceState>, view: &Retained<SurfaceView>) {
    let bounds = view.bounds_size();
    if bounds.width <= 0.0 || bounds.height <= 0.0 {
        return;
    }
    let Some(scale) = view.backing_scale() else {
        return;
    };

    let requested = state
        .explicit_range
        .unwrap_or_else(|| cocoa_ui::dynamic_range::require_inherited(view.as_platform_view()));
    let renderer = renderer_dynamic_range(state, requested);
    // An SDR renderer target has no extended range to present, so a surface
    // that latched SDR stays SDR even once its window reaches an HDR display.
    let presentation = if renderer == cocoa_ui::dynamic_range::DynamicRange::Standard {
        cocoa_ui::dynamic_range::DynamicRange::Standard
    } else {
        requested
    };
    if state.configured_range.get() != Some(presentation) {
        detach_if_attached(state);
        configure_dynamic_range(state, view, presentation, renderer);
    }

    state.current_scale.set(scale);
    let width = (bounds.width * scale) as u32;
    let height = (bounds.height * scale) as u32;
    let size_changed = state.current_width.get() != width || state.current_height.get() != height;
    state.current_width.set(width);
    state.current_height.set(height);
    if size_changed {
        state.keep_redrawing.set(true);
    }
    update_presentation_frame(state, view);

    // The surfaces are allocated where a frame could actually be shown:
    // laying out a covered window bought pairs for frames that never came.
    if !can_present_now(view) {
        return;
    }
    if let Some(format) = state.presentation_format.get()
        && let Some(buffers) = state.buffers.borrow_mut().as_mut()
    {
        buffers.configure(width, height, format);
    }
    if state.attached.get() {
        return;
    }
    let Some(first) = state
        .buffers
        .borrow()
        .as_ref()
        .and_then(cocoa_ui::metal::SurfaceBuffers::next_frame)
    else {
        return;
    };
    let format = cocoa_ui::metal::metal_to_wgpu_format(first.texture.pixelFormat())
        .expect("GpuSurface buffers present only supported formats");
    state.attached.set(true);
    start_renderer_setup(state, format);
    render_frame(state, view, true);
}

/// Detaches presenter and renderer for a window or range change.
fn detach_if_attached(state: &SurfaceState) {
    if !state.attached.get() {
        return;
    }
    state.attached.set(false);
    state.setup_ready.set(false);
    if let Some(buffers) = state.buffers.borrow_mut().as_mut() {
        buffers.release();
    }
}

// MARK: - Frame scheduling (WuiDisplayLinkDriver + WuiRedrawCallback)

/// Re-runs `initialize_gpu` once a frame could be shown again, then drives
/// the clock and replays an owed frame — `updateDisplayLinkState`.
fn update_display_link_state(state: &Rc<SurfaceState>, view: &Retained<SurfaceView>) {
    if !state.attached.get() && can_present_now(view) {
        initialize_gpu(state, view);
    }
    let should_tick = state.keep_redrawing.get()
        && state.external_count.get() == 0
        && state.attached.get()
        && is_effectively_visible(view);
    if should_tick {
        state.clock.start(view.as_platform_view());
    } else {
        state.clock.stop();
    }
    // Replay: every reason a frame was deferred ends at this call.
    if state.frame_owed.get()
        && !state.frame_in_flight.get()
        && state.external_count.get() == 0
        && state.attached.get()
        && can_present_now(view)
    {
        state.frame_owed.set(false);
        schedule_on_demand_render(state, view);
    }
}

/// The one-frame-per-tick body — `renderFrame`. `force` draws through the
/// visibility gates for the first frame a window's reveal waits on.
fn render_frame(state: &Rc<SurfaceState>, view: &Retained<SurfaceView>, force: bool) {
    ensure_current_context(state);
    if state.external_count.get() > 0 {
        notify_external_redraw(state);
        return;
    }
    if state.frame_in_flight.get() {
        state.frame_owed.set(true);
        return;
    }
    if !force && !can_present_now(view) {
        state.frame_owed.set(true);
        return;
    }

    let Some(pending) = state
        .buffers
        .borrow()
        .as_ref()
        .and_then(cocoa_ui::metal::SurfaceBuffers::next_frame)
    else {
        // Nothing rendered: nothing to draw, buffers unallocated, or setup
        // still running — the redraw callback wakes us when that changes.
        state.keep_redrawing.set(false);
        update_display_link_state(state, view);
        return;
    };
    if !state.setup_ready.get() {
        state.keep_redrawing.set(false);
        update_display_link_state(state, view);
        return;
    }

    let width = state.current_width.get();
    let height = state.current_height.get();
    let submission = render_to_metal_texture(
        state,
        pending.texture.clone(),
        width,
        height,
        state.current_scale.get(),
    );

    state.frame_in_flight.set(true);
    state.keep_redrawing.set(false);
    publish_content_accessibility(state, view);
    update_display_link_state(state, view);

    let gpu = state.runtime.context();
    let weak = Sendable(Rc::downgrade(state));
    let view = Sendable(view.clone());
    let pending = Sendable(pending);
    gpu.submission_completion_driver()
        .on_complete(submission, move || {
            cocoa_ui::main_queue::enqueue(move |_mtm| {
                let Some(state) = weak.get().upgrade() else {
                    return;
                };
                state.frame_in_flight.set(false);
                let presented = state
                    .buffers
                    .borrow_mut()
                    .as_mut()
                    .is_some_and(|buffers| buffers.present(pending.get()));
                if presented {
                    complete_ready(&state, true);
                } else {
                    // The buffers were replaced while this frame was in flight —
                    // owe it again rather than reveal a hole.
                    state.frame_owed.set(true);
                }
                update_display_link_state(&state, view.get());
            });
        });
}

/// `handleRedrawRequest`: the redraw waker's main-queue body — republishes
/// accessibility, re-measures against the last proposal, then renders.
fn handle_redraw_request(state: &Rc<SurfaceState>, view: &Retained<SurfaceView>) {
    state.needs_a11y_refresh.set(true);
    if take_measurement_invalidation(state) {
        invalidate_layout_hierarchy(view.as_platform_view());
    }
    if state.external_count.get() > 0 {
        notify_external_redraw(state);
    } else {
        schedule_on_demand_render(state, view);
    }
}

/// Queues one `renderFrame` on the main queue — `scheduleOnDemandRender`.
fn schedule_on_demand_render(state: &Rc<SurfaceState>, view: &Retained<SurfaceView>) {
    if state.redraw_wake_scheduled.replace(true) {
        return;
    }
    let weak = Sendable(Rc::downgrade(state));
    let view = Sendable(view.clone());
    cocoa_ui::main_queue::enqueue(move |_mtm| {
        let Some(state) = weak.get().upgrade() else {
            return;
        };
        state.redraw_wake_scheduled.set(false);
        render_frame(&state, view.get(), false);
    });
}

/// Whether the host laid this surface out with a measurement the renderer no
/// longer gives — `takeMeasurementInvalidation`.
fn take_measurement_invalidation(state: &SurfaceState) -> bool {
    let Some(proposal) = state.last_proposal.get() else {
        return false;
    };
    if state.deferred_measurement.get() {
        if !state.setup_ready.get() {
            return false;
        }
        state.deferred_measurement.set(false);
        return true;
    }
    if !state.setup_ready.get() {
        return false;
    }
    let measured = with_semantic_mut(state, |semantic| semantic.gpu_surface.measure(proposal));
    let Some(measured) = measured else {
        return false;
    };
    let changed = state
        .last_resolved_size
        .borrow()
        .is_some_and(|last| last != measured.size);
    if changed {
        *state.last_resolved_size.borrow_mut() = Some(measured.size);
    }
    changed
}

/// Publishes the content's label and value — `publishContentAccessibility`:
/// an application-set value on this very view always wins.
fn publish_content_accessibility(state: &SurfaceState, view: &Retained<SurfaceView>) {
    if !state.needs_a11y_refresh.replace(false) {
        return;
    }
    let Some((label, value)) = with_semantic_mut(state, |semantic| {
        (
            semantic.gpu_surface.accessibility_label(),
            semantic.gpu_surface.accessibility_value(),
        )
    }) else {
        return;
    };
    publish_accessibility(view.as_platform_view(), label.as_deref(), value.as_deref());
}

/// Writes label/value through the platform accessibility channel — the two
/// `publishContentAccessibility*` halves.
fn publish_accessibility(view: &cocoa_ui::PlatformView, label: Option<&str>, value: Option<&str>) {
    #[cfg(target_os = "macos")]
    {
        cocoa_ui::view::set_accessibility_content(view, label, value);
    }
    #[cfg(target_os = "ios")]
    {
        cocoa_ui::view::set_accessibility_content(view, label, value);
    }
}

/// The redraw callback's target — external capture gets the call while it
/// owns rendering, otherwise the main queue drives `handleRedrawRequest`.
fn notify_external_redraw(state: &SurfaceState) {
    if let Some(callback) = state.external_redraw.borrow().as_ref() {
        callback();
    }
}

/// Runs the frame after which `ready` waiters wake — `completeReady`.
fn complete_ready(state: &SurfaceState, _presented: bool) {
    for waker in state.ready_waiters.borrow_mut().drain(..) {
        waker.wake();
    }
}

/// `invalidateLayoutHierarchy`: intrinsic-size invalidation up the whole
/// ancestor chain, then captured-content invalidation.
fn invalidate_layout_hierarchy(view: &cocoa_ui::PlatformView) {
    let mut node = Some(cocoa_ui::view::retain_base(view));
    while let Some(current) = node {
        cocoa_ui::view::invalidate_layout(&current);
        node = cocoa_ui::view::superview(&current);
    }
    crate::invalidation::invalidate_rendered_content(view);
}

// MARK: - Window observers (WuiWindowOcclusion)

/// (Re)arms the occlusion / miniaturization / activation observers for the
/// window `view` now sits in — `updateWindowObservers`.
fn update_window_observers(state: &Rc<SurfaceState>, view: &Retained<SurfaceView>) {
    let mut observers = state.observers.borrow_mut();
    observers.clear();
    let Some(window) = cocoa_ui::view::window(view.as_platform_view()) else {
        return;
    };
    #[cfg(target_os = "ios")]
    let _ = &window;
    let mtm = cocoa_ui::MainThreadMarker::new().expect("main thread");
    let fire = {
        let weak = Rc::downgrade(state);
        let view = view.clone();
        move || {
            if let Some(state) = weak.upgrade() {
                update_display_link_state(&state, &view);
            }
        }
    };
    #[cfg(target_os = "macos")]
    {
        observers.push(cocoa_ui::appkit::watch_occlusion(mtm, &window, {
            let fire = fire.clone();
            move || fire()
        }));
        for notification in [
            // SAFETY: the notification names are system constants.
            unsafe { cocoa_ui::objc2_app_kit::NSWindowDidMiniaturizeNotification },
            // SAFETY: the notification names are system constants.
            unsafe { cocoa_ui::objc2_app_kit::NSWindowDidDeminiaturizeNotification },
            // SAFETY: the notification names are system constants.
            unsafe { cocoa_ui::objc2_app_kit::NSWindowDidChangeScreenNotification },
        ] {
            let name = notification;
            observers.push(cocoa_ui::notification::observe_object(
                mtm,
                &cocoa_ui::notification::NotificationName::framework(name),
                window.as_ref(),
                {
                    let fire = fire.clone();
                    move || fire()
                },
            ));
        }
    }
    #[cfg(target_os = "ios")]
    {
        for notification in [
            // SAFETY: the notification names are system constants.
            unsafe { cocoa_ui::objc2_ui_kit::UIApplicationDidBecomeActiveNotification },
            // SAFETY: the notification names are system constants.
            unsafe { cocoa_ui::objc2_ui_kit::UIApplicationWillResignActiveNotification },
        ] {
            let name = notification;
            observers.push(cocoa_ui::notification::observe(
                mtm,
                &cocoa_ui::notification::NotificationName::framework(name),
                {
                    let fire = fire.clone();
                    move || fire()
                },
            ));
        }
    }
}

// MARK: - Input (WuiGpuSurfaceInput)

/// A logical point in physical pixels — `updatePointerPosition`'s
/// `scaleFactor` multiplication.
#[allow(clippy::cast_possible_truncation)]
fn scaled_point(state: &SurfaceState, x: f64, y: f64) -> waterui_core::layout::Point {
    let scale = state.current_scale.get();
    waterui_core::layout::Point::new((x * scale) as f32, (y * scale) as f32)
}

/// One `PointerInteraction` snapshot plus `scheduleInputRender` — the
/// gesture handlers of `WuiGpuSurface` folded onto the kit's neutral events.
#[allow(clippy::too_many_lines, clippy::cast_possible_truncation)]
fn apply_interaction(
    state: &Rc<SurfaceState>,
    view: &Retained<SurfaceView>,
    interaction: cocoa_ui::input::PointerInteraction,
) {
    match interaction {
        cocoa_ui::input::PointerInteraction::Moved(position) => {
            let mut pointer = state.pointer_state.get();
            pointer.position = position.map(|point| scaled_point(state, point.x, point.y));
            state.pointer_state.set(pointer);
        }
        cocoa_ui::input::PointerInteraction::PrimaryDown {
            position,
            click_count,
        } => {
            let mut pointer = state.pointer_state.get();
            let point = scaled_point(state, position.x, position.y);
            pointer.hit = Some(point);
            state.pointer_state.set(pointer);
            if click_count == 2 {
                let mut gesture = state.gesture_state.get();
                gesture.double_tap = true;
                state.gesture_state.set(gesture);
            }
        }
        cocoa_ui::input::PointerInteraction::PrimaryUp => {
            let mut pointer = state.pointer_state.get();
            pointer.hit = None;
            state.pointer_state.set(pointer);
        }
        cocoa_ui::input::PointerInteraction::Pinch {
            phase,
            magnitude,
            center,
        } => {
            use cocoa_ui::input::GesturePhase;
            let mut gesture = state.gesture_state.get();
            match phase {
                GesturePhase::Began => {
                    state.pinch_start_scale.set(state.cumulative_scale.get());
                    gesture.active = true;
                    gesture.pinch_scale = state.cumulative_scale.get() as f32;
                    gesture.pinch_center = Some(scaled_point(state, center.x, center.y));
                }
                GesturePhase::Changed => {
                    // AppKit's `magnification` is a delta; UIKit's `scale` is
                    // cumulative since `Began` — the kit reports the
                    // platform's raw value.
                    #[cfg(target_os = "macos")]
                    let scale = state.pinch_start_scale.get() * (1.0 + magnitude);
                    #[cfg(target_os = "ios")]
                    let scale = state.pinch_start_scale.get() * magnitude;
                    state.cumulative_scale.set(scale);
                    gesture.active = true;
                    gesture.pinch_scale = scale as f32;
                    gesture.pinch_center = Some(scaled_point(state, center.x, center.y));
                }
                GesturePhase::Ended | GesturePhase::Cancelled => {
                    gesture.active = false;
                    gesture.pinch_scale = state.cumulative_scale.get() as f32;
                    gesture.pinch_center = None;
                }
            }
            state.gesture_state.set(gesture);
        }
        cocoa_ui::input::PointerInteraction::Pan {
            phase,
            offset_x,
            offset_y,
        } => {
            use cocoa_ui::input::EventPhase;
            let mut gesture = state.gesture_state.get();
            match phase {
                EventPhase::Began => {
                    state.pan_offset.set((0.0, 0.0));
                    gesture.active = true;
                }
                EventPhase::Changed => {
                    let offset = (
                        state.pan_offset.get().0 + offset_x,
                        state.pan_offset.get().1 + offset_y,
                    );
                    state.pan_offset.set(offset);
                    gesture.active = true;
                    gesture.pan_offset = scaled_point(state, offset.0, offset.1);
                }
                EventPhase::Ended | EventPhase::Cancelled => {
                    gesture.active = false;
                    gesture.pan_offset =
                        scaled_point(state, state.pan_offset.get().0, state.pan_offset.get().1);
                    state.pan_offset.set((0.0, 0.0));
                }
                // A discrete wheel notch: an immediate began-plus-ended pair.
                EventPhase::None => {
                    gesture.active = true;
                    gesture.pan_offset = scaled_point(state, offset_x, offset_y);
                    state.gesture_state.set(gesture);
                    gesture.active = false;
                }
            }
            state.gesture_state.set(gesture);
        }
        cocoa_ui::input::PointerInteraction::DoubleTap => {
            // The gesture ends by resetting zoom/pan — `handleDoubleTap`.
            state.cumulative_scale.set(1.0);
            state.pan_offset.set((0.0, 0.0));
            let mut gesture = state.gesture_state.get();
            gesture.double_tap = true;
            gesture.active = false;
            gesture.pinch_scale = 1.0;
            gesture.pinch_center = None;
            gesture.pan_offset = waterui_core::layout::Point::new(0.0, 0.0);
            state.gesture_state.set(gesture);
        }
    }
    // Input events arrive faster than the display refreshes — snapshot then
    // coalesce into one frame per refresh.
    if state.external_count.get() > 0 {
        notify_external_redraw(state);
        return;
    }
    state.keep_redrawing.set(true);
    update_display_link_state(state, view);
}

// MARK: - Capturable (WuiMetalViewCapture's surface half)

/// The registered surface, for `ViewCapture`'s resolver and `view.ready()`.
struct Capturable {
    state: Rc<SurfaceState>,
    view: Retained<SurfaceView>,
}

impl cocoa_ui::capture::CapturableSurface for Capturable {
    fn capture_pixel_format(&self) -> objc2_metal::MTLPixelFormat {
        state_format(&self.state)
    }

    fn content_bounds(&self, relative_to: &cocoa_ui::PlatformView) -> cocoa_ui::Rect {
        self.view.bounds_in(relative_to)
    }

    fn begin_capture_suppression(&self) {
        let count = self.state.capture_suppression.get() + 1;
        self.state.capture_suppression.set(count);
        if count == 1 {
            set_presentation_hidden(&self.view, true);
        }
    }

    fn end_capture_suppression(&self) {
        let count = self.state.capture_suppression.get();
        assert!(
            count > 0,
            "GpuSurface capture suppression scopes are unbalanced"
        );
        self.state.capture_suppression.set(count - 1);
        if count == 1 {
            set_presentation_hidden(&self.view, false);
        }
    }

    fn begin_external_rendering(&self, on_redraw: Rc<dyn Fn()>) {
        if self.state.external_count.get() == 0 {
            *self.state.external_redraw.borrow_mut() = Some(on_redraw);
            self.state.keep_redrawing.set(false);
            self.state.clock.stop();
        }
        self.state
            .external_count
            .set(self.state.external_count.get() + 1);
    }

    fn end_external_rendering(&self, resume: bool) {
        let count = self.state.external_count.get();
        assert!(
            count > 0,
            "GpuSurface external rendering scopes are unbalanced"
        );
        self.state.external_count.set(count - 1);
        if count == 1 {
            *self.state.external_redraw.borrow_mut() = None;
            if resume {
                schedule_on_demand_render(&self.state, &self.view);
            }
        }
    }

    fn prepare_external_render(
        &self,
        texture: &objc2::runtime::ProtocolObject<dyn objc2_metal::MTLTexture>,
    ) -> bool {
        let format = metal_texture_format(texture);
        if self.state.renderer_format.get() != Some(format) {
            assert!(
                self.state.renderer_format.get().is_none(),
                "GpuSurface external capture format changed after renderer setup started"
            );
            state_format_check(&self.state, format);
            start_renderer_setup_rc(&self.state, format);
        }
        self.state.setup_ready.get()
    }

    fn render_prepared_external_texture(
        &self,
        texture: &objc2::runtime::ProtocolObject<dyn objc2_metal::MTLTexture>,
        width: u32,
        height: u32,
        completion: Box<dyn FnOnce() + Send>,
    ) {
        // SAFETY: `texture` is the live texture the capture pipeline retained
        // for this call; `retain` takes our own reference.
        let texture = unsafe {
            Retained::<objc2::runtime::ProtocolObject<dyn objc2_metal::MTLTexture>>::retain(
                std::ptr::from_ref(texture).cast_mut(),
            )
        }
        .expect("GpuSurface external render received a null texture");
        let submission = render_to_metal_texture(
            &self.state,
            texture,
            width,
            height,
            self.state.current_scale.get(),
        );
        let gpu = self.state.runtime.context();
        let weak = Sendable(Rc::downgrade(&self.state));
        gpu.submission_completion_driver()
            .on_complete(submission, move || {
                if weak.get().upgrade().is_some() {
                    complete_ready_static(weak.get());
                }
                completion();
            });
    }
}

const fn state_format(state: &SurfaceState) -> objc2_metal::MTLPixelFormat {
    state
        .presentation_format
        .get()
        .expect("GpuSurface must have a configured dynamic range before external capture")
}

fn state_format_check(state: &SurfaceState, format: waterui_graphics::wgpu::TextureFormat) {
    if let Some(existing) = state.renderer_format.get() {
        assert_eq!(existing, format, "GpuSurface target format changed");
    }
}

fn start_renderer_setup_rc(
    state: &Rc<SurfaceState>,
    format: waterui_graphics::wgpu::TextureFormat,
) {
    start_renderer_setup(state, format);
}

fn complete_ready_static(weak: &Weak<SurfaceState>) {
    if let Some(state) = weak.upgrade() {
        complete_ready(&state, true);
    }
}

/// Shows or hides the presentation layer inside a transaction —
/// `setPresentationHidden`.
fn set_presentation_hidden(view: &Retained<SurfaceView>, hidden: bool) {
    let layer = view.presentation_layer();
    if layer.isHidden() == hidden {
        return;
    }
    cocoa_ui::core_animation::without_animation(|| {
        layer.setHidden(hidden);
    });
}

/// The sendable wrapper for main-thread-only state crossing the redraw
/// waker and completion-driver boundaries.
struct Sendable<T>(T);

impl<T> Sendable<T> {
    /// Reads the wrapped value — method access keeps closure captures on the
    /// whole cell, where the `Send`/`Sync` contract lives.
    const fn get(&self) -> &T {
        &self.0
    }
}

// SAFETY: the wrapped value is only ever produced/consumed on the main
// thread — the drivers park the closure on theirs and fire it back through
// the main queue.
#[allow(clippy::non_send_fields_in_send_ty)]
unsafe impl<T> Send for Sendable<T> {}
// SAFETY: as `Send`.
#[allow(clippy::non_send_fields_in_send_ty)]
unsafe impl<T> Sync for Sendable<T> {}

/// The platform's input overlay view.
#[cfg(target_os = "macos")]
fn platform_input_view(
    mtm: cocoa_ui::MainThreadMarker,
) -> Retained<cocoa_ui::appkit::input_view::InputView> {
    cocoa_ui::appkit::input_view::InputView::new(mtm)
}

/// The platform's input overlay view.
#[cfg(target_os = "ios")]
fn platform_input_view(
    mtm: cocoa_ui::MainThreadMarker,
) -> Retained<cocoa_ui::uikit::input_view::InputView> {
    cocoa_ui::uikit::input_view::InputView::new(mtm)
}

/// The leaf-side registry `ViewCapture`'s resolver reads — surface views by
/// their platform address.
static REGISTRY: Mutex<Option<HashMap<usize, Sendable<Weak<Capturable>>>>> = Mutex::new(None);

/// Looks up the capturable surface `view` presents — `as? WuiGpuSurface`.
pub fn resolve_capturable(
    view: &cocoa_ui::PlatformView,
) -> Option<Rc<dyn cocoa_ui::capture::CapturableSurface>> {
    let key = std::ptr::from_ref(view).cast::<()>() as usize;
    let capturable = REGISTRY
        .lock()
        .expect("gpu surface registry")
        .as_ref()
        .and_then(|registry| registry.get(&key))
        .and_then(|weak| weak.get().upgrade())?;
    Some(capturable)
}

/// The resolver closure `ViewCapture::new` takes.
pub fn capturable_resolver()
-> impl Fn(&cocoa_ui::PlatformView) -> Option<Rc<dyn cocoa_ui::capture::CapturableSurface>> {
    resolve_capturable
}

/// Dropping unregisters the surface — `deinit`/`shutdown` on the Swift side.
struct RegistryGuard {
    view: Retained<cocoa_ui::PlatformView>,
}

impl fmt::Debug for RegistryGuard {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RegistryGuard").finish_non_exhaustive()
    }
}

impl Drop for RegistryGuard {
    fn drop(&mut self) {
        unregister_capturable(&self.view);
    }
}

/// Unregisters `view`'s surface — `deinit`/`shutdown` on the Swift side.
fn unregister_capturable(view: &cocoa_ui::PlatformView) {
    let key = std::ptr::from_ref(view).cast::<()>() as usize;
    if let Some(registry) = REGISTRY.lock().expect("gpu surface registry").as_mut() {
        registry.remove(&key);
    }
}

/// Waits until every mounted GPU surface inside `view`'s subtree has
/// presented a frame — `WuiAnyView.ready()`.
#[allow(clippy::future_not_send)]
pub async fn wait_for_first_frames(view: &cocoa_ui::PlatformView) {
    core::future::poll_fn(|cx| {
        let mut pending = false;
        collect_unpresented(view, &mut |capturable| {
            if !capturable.buffers_presented() {
                capturable.register_waiter(cx.waker().clone());
                pending = true;
            }
        });
        #[cfg(feature = "view_effect")]
        crate::components::view_effect::collect_effects(view, &mut |state| {
            if crate::components::view_effect::effect_needs_frame(state, cx.waker().clone()) {
                pending = true;
            }
        });
        if pending {
            core::task::Poll::Pending
        } else {
            core::task::Poll::Ready(())
        }
    })
    .await;
}

impl Capturable {
    fn buffers_presented(&self) -> bool {
        self.state
            .buffers
            .borrow()
            .as_ref()
            .is_some_and(cocoa_ui::metal::SurfaceBuffers::has_presented_frame)
    }

    /// Registers `waker` if this surface has not presented yet.
    fn register_waiter(&self, waker: std::task::Waker) {
        if !self.buffers_presented() {
            self.state.ready_waiters.borrow_mut().push(waker);
        }
    }
}

/// Walks `view`'s subtree calling `f` on every registered surface.
fn collect_unpresented(view: &cocoa_ui::PlatformView, f: &mut impl FnMut(&Rc<Capturable>)) {
    let key = std::ptr::from_ref(view).cast::<()>() as usize;
    let registry = REGISTRY.lock().expect("gpu surface registry");
    if let Some(capturable) = registry
        .as_ref()
        .and_then(|registry| registry.get(&key))
        .and_then(|weak| weak.get().upgrade())
    {
        f(&capturable);
    }
    drop(registry);
    for subview in cocoa_ui::view::subviews(view) {
        collect_unpresented(&subview, f);
    }
}

// MARK: - SubView (WuiGraphicsPrimitiveSizing)

/// The leaf's layout: the semantic renderer measures under the proposal it
/// was last given, reusing the stale box while setup owns the renderer.
struct SurfaceSubView {
    state: Rc<SurfaceState>,
}

impl SubView for SurfaceSubView {
    fn measure(&self, proposal: ProposalSize) -> ViewDimensions {
        self.state.last_proposal.set(Some(proposal));
        let measured = with_semantic_mut(&self.state, |semantic| {
            semantic.gpu_surface.measure(proposal)
        });
        if let Some(dimensions) = measured {
            *self.state.last_resolved_size.borrow_mut() = Some(dimensions.size);
            dimensions
        } else {
            // `GpuView::setup` owns the semantic renderer until ready;
            // answer with the last real measurement and invalidate when
            // setup returns ownership.
            self.state.deferred_measurement.set(true);
            ViewDimensions::new(self.state.last_resolved_size.borrow().unwrap_or_default())
        }
    }

    fn stretch_axis(&self) -> StretchAxis {
        StretchAxis::Both
    }

    fn priority(&self) -> i32 {
        self.state.priority
    }
}

// MARK: - Install

/// Installs the `gpu_surface` handler.
pub fn install(dispatcher: &mut Dispatcher) {
    dispatcher.register_native::<GpuSurface>(build_surface);
}

/// The leaf construction shared by the dispatcher and the CEF seam entry
/// point — `makeWaterUIGpuSurface`.
#[allow(clippy::too_many_lines)]
fn build_surface(gpu_surface: GpuSurface, ctx: &crate::contract::RenderContext<'_>) -> NativeLeaf {
    {
        let mtm = ctx.mtm();
        let view = SurfaceView::new(mtm);
        let runtime = crate::gpu_runtime::runtime(ctx.env());
        let state = Rc::new_cyclic(|weak| {
            SurfaceState::new(weak, runtime, gpu_surface, ctx.env().clone(), &view, mtm)
        });

        // The presentation buffers bind to the shared Metal device and the
        // view's presentation layer.
        let gpu = state.runtime.context();
        // SAFETY: the context's device is this runtime's; `raw_device` is the
        // same `MTLDevice` it was made from.
        // SAFETY: `raw_device` is the `MTLDevice` the runtime created and
        // still owns; `retain` takes our own reference on it.
        let device = unsafe {
            Retained::<objc2::runtime::ProtocolObject<dyn objc2_metal::MTLDevice>>::retain(
                Retained::as_ptr(
                    gpu.device
                        .as_hal::<wgpu_hal::api::Metal>()
                        .expect("the Apple runtime's device is Metal")
                        .raw_device(),
                )
                .cast_mut(),
            )
            .expect("the Metal device is non-null")
        };
        *state.buffers.borrow_mut() = Some(cocoa_ui::metal::SurfaceBuffers::new(
            device,
            view.presentation_layer(),
        ));

        // The redraw waker: external capture intercepts while it owns
        // rendering; otherwise the request is handled on the main queue.
        let weak = Sendable(Rc::downgrade(&state));
        let redraw_view = Sendable(view.clone());
        state.redraw_handle.set_waker(Some(Arc::new(move || {
            let weak = Sendable(weak.get().clone());
            let view = Sendable(redraw_view.get().clone());
            cocoa_ui::main_queue::enqueue(move |_mtm| {
                if let Some(state) = weak.get().upgrade() {
                    handle_redraw_request(&state, view.get());
                }
            });
        })));

        // Registry: captures resolve surfaces by their platform view.
        let capturable = Rc::new(Capturable {
            state: state.clone(),
            view: view.clone(),
        });
        let key = std::ptr::from_ref(view.as_platform_view()).cast::<()>() as usize;
        REGISTRY
            .lock()
            .expect("gpu surface registry")
            .get_or_insert_with(HashMap::new)
            .insert(key, Sendable(Rc::downgrade(&capturable)));

        let subview_state = state.clone();
        view.set_layout_handler({
            let state = state.clone();
            let view = view.clone();
            move || {
                initialize_gpu(&state, &view);
                update_display_link_state(&state, &view);
            }
        });
        view.set_window_changed_handler({
            let state = state.clone();
            let view = view.clone();
            move || {
                let Some(window) = cocoa_ui::view::window(view.as_platform_view()) else {
                    detach_if_attached(&state);
                    complete_ready(&state, false);
                    state.keep_redrawing.set(false);
                    state.clock.stop();
                    state.observers.borrow_mut().clear();
                    return;
                };
                if let Some(scale) = view.backing_scale() {
                    state.current_scale.set(scale);
                }
                let _ = window;
                update_presentation_frame(&state, &view);
                update_window_observers(&state, &view);
                update_display_link_state(&state, &view);
            }
        });
        #[cfg(target_os = "macos")]
        {
            view.set_visibility_changed_handler({
                let state = state.clone();
                let view = view.clone();
                move || update_display_link_state(&state, &view)
            });
            view.set_backing_changed_handler({
                let state = state.clone();
                let view = view.clone();
                move || {
                    if cocoa_ui::view::window(view.as_platform_view()).is_none() {
                        return;
                    }
                    if let Some(scale) = view.backing_scale() {
                        state.current_scale.set(scale);
                    }
                    initialize_gpu(&state, &view);
                    update_display_link_state(&state, &view);
                }
            });
        }
        #[cfg(target_os = "ios")]
        {
            view.set_visibility_changed_handler({
                let state = state.clone();
                let view = view.clone();
                move || update_display_link_state(&state, &view)
            });
            view.set_backing_changed_handler({
                let state = state.clone();
                let view = view.clone();
                move || {
                    initialize_gpu(&state, &view);
                    update_display_link_state(&state, &view);
                }
            });
        }
        let input_view = install_input(&view, &state);

        let registry_guard = RegistryGuard {
            view: cocoa_ui::view::retain_base(view.as_platform_view()),
        };
        let mut leaf = NativeLeaf::new(
            &view,
            SurfaceSubView {
                state: subview_state,
            },
        );
        leaf.keep(view);
        leaf.keep(capturable);
        leaf.keep(registry_guard);
        if let Some(input) = input_view {
            leaf.keep(input);
        }
        leaf
    }
}

/// The pointer/gesture half of surface input: `PointerInteraction` events
/// updating the frame snapshot.
fn install_pointer_input(
    view: &Retained<SurfaceView>,
    on_interaction: impl Fn(cocoa_ui::input::PointerInteraction) + 'static,
) {
    view.set_interaction_handler(on_interaction);
}

/// The input responder overlay `wants_input_events` installs — the kit's
/// `InputView` forwarding `SurfaceEvent`s translated for the semantic view,
/// plus the pointer/gesture snapshot channel.
fn install_input(
    view: &Retained<SurfaceView>,
    state: &Rc<SurfaceState>,
) -> Option<Retained<cocoa_ui::PlatformView>> {
    install_pointer_input(view, {
        let state = state.clone();
        let view = view.clone();
        move |interaction| apply_interaction(&state, &view, interaction)
    });
    if !state.wants_input_events {
        return None;
    }
    let mtm = cocoa_ui::MainThreadMarker::new().expect("main thread");
    let input = platform_input_view(mtm);
    let weak = Rc::downgrade(state);
    let host = view.clone();
    input.set_event_handler(move |event| {
        let Some(state) = weak.upgrade() else {
            return;
        };
        let event = crate::gpu_input::translate(&event);
        with_semantic_mut(&state, |semantic| {
            semantic.gpu_surface.input(&event);
        });
        // The event's frame request rides the same coalescing as pointer input.
        if state.external_count.get() > 0 {
            notify_external_redraw(&state);
        } else {
            state.keep_redrawing.set(true);
            update_display_link_state(&state, &host);
        }
    });
    input.set_caret_provider({
        let state = state.clone();
        move || {
            with_semantic_mut(&state, |semantic| {
                semantic.gpu_surface.ime_caret().map(|rect| {
                    cocoa_ui::Rect::new(
                        rect.origin().x,
                        rect.origin().y,
                        rect.size().width,
                        rect.size().height,
                    )
                })
            })
            .flatten()
        }
    });
    // The responder fills the surface and sits on top of it.
    cocoa_ui::view::add_subview(view.as_platform_view(), input.as_ref());
    Some(Retained::into_super(input))
}

// MARK: - CEF seam (`makeWaterUIGpuSurface`)

/// The `CWaterUI.WuiGpuSurface` layout `CefSurfaceView` hands over — the
/// ffi crate's `repr(C)` struct (`ffi::WuiGpuSurface`).
#[repr(C)]
pub struct WuiGpuSurfaceFfi {
    /// Boxed semantic `GpuSurface`, consumed by this call.
    pub surface: *mut c_void,
    /// Whether a picture-in-picture host id is present.
    pub has_picture_in_picture_host_id: bool,
    /// The picture-in-picture host id when present.
    pub picture_in_picture_host_id: u64,
}

/// `makeWaterUIGpuSurface`: builds a `gpu_surface` leaf for a CEF-owned
/// surface and returns its platform view retained `+1` for
/// `Unmanaged<NSView>.takeRetainedValue()`.
///
/// The leaf's keepalive is leaked for the view's process lifetime: the
/// returned view outlives the leaf only while it stays in the hierarchy —
/// CEF surfaces live for the session, matching the Swift side's retention.
///
/// # Safety
/// `surface` must point at a valid `CWaterUI.WuiGpuSurface` whose `surface`
/// field holds a `Box<GpuSurface>`; `env` must be a valid `Environment`
/// pointer; called on the main thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn waterui_apple_make_gpu_surface_view(
    surface: *mut WuiGpuSurfaceFfi,
    env: *mut Environment,
) -> *mut c_void {
    let mtm = cocoa_ui::MainThreadMarker::new().expect("main thread");
    // SAFETY: the caller hands ownership of the boxed semantic surface.
    let ffi = unsafe { &mut *surface };
    // SAFETY: the boxed surface is live and uniquely owned per the contract.
    let gpu_surface = unsafe { *Box::<GpuSurface>::from_raw(ffi.surface.cast::<GpuSurface>()) };
    ffi.surface = std::ptr::null_mut();
    // SAFETY: `env` is the application's environment, valid for the process.
    let env = unsafe { &*env };
    let ctx = crate::contract::RenderContext::new(env, crate::dispatch::dispatcher(mtm), mtm);
    let leaf = build_surface(gpu_surface, &ctx);
    let (view, layout, keepalive) = leaf.into_parts();
    core::mem::forget(layout);
    core::mem::forget(keepalive);
    Retained::into_raw(view).cast::<c_void>()
}
