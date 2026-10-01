//! The `applied_filter` leaf: `Metadata<AppliedFilter>` — the
//! `WuiAppliedFilter` port. The hidden content view is captured offscreen
//! through the kit's `ViewCapture`; the semantic filter renders it into an
//! `IOSurface` pair presented through a plain layer-backed output view
//! composited on top.

use std::cell::{Cell, RefCell};
use std::fmt;
use std::rc::{Rc, Weak};
use std::sync::Arc;

use cocoa_ui::PlatformView;
use cocoa_ui::Retained;
use executor_core::spawn_local;
use futures::FutureExt;
use objc2_metal::{MTLDevice as _, MTLTexture as _};
use waterui_backend_core::{AnyView, View};
use waterui_core::Metadata;
use waterui_core::layout::{ProposalSize, Size, StretchAxis, SubView, ViewDimensions};
use waterui_graphics::filter_view::{
    AppliedFilter, EffectContext, EffectFrameClock, EffectInput, EffectOutput, WgslModuleCache,
};
use waterui_graphics::gpu_surface::RedrawHandle;
use waterui_graphics::shared_context::GpuRuntime;
use waterui_graphics::wgpu;

use crate::contract::{Mounted, NativeLeaf, RenderContext};
use crate::dispatch::{Dispatcher, needs_fallback};

#[cfg(target_os = "macos")]
mod platform {
    pub(super) use cocoa_ui::appkit::HostView;
}

#[cfg(target_os = "ios")]
mod platform {
    pub(super) use cocoa_ui::uikit::HostView;
}

use platform::HostView;

type WgpuFormat = wgpu::TextureFormat;

/// The format an Apple host renders a filter into — `attach_host_textures`
/// always takes the extended-range half-float target, exactly as the
/// `CAMetalLayer` path's unconditional `rendererMode: .high` did.
const PRESENTATION_FORMAT: WgpuFormat = WgpuFormat::Rgba16Float;

/// A captured content frame — `WuiAppliedFilterCaptureFrame`.
struct CaptureFrame {
    texture: Retained<objc2::runtime::ProtocolObject<dyn objc2_metal::MTLTexture>>,
    width: u32,
    height: u32,
}

impl fmt::Debug for CaptureFrame {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CaptureFrame")
            .field("width", &self.width)
            .field("height", &self.height)
            .finish_non_exhaustive()
    }
}

/// Marks a value as crossing the GPU-completion → main-queue boundary; the
/// wrapped object is only dereferenced once the work item lands on the main
/// thread, where every receiver was created.
struct Sendable<T>(T);

impl<T> Sendable<T> {
    /// Reads the wrapped value — method access keeps closure captures on the
    /// whole cell, where the `Send`/`Sync` contract lives.
    const fn get(&self) -> &T {
        &self.0
    }
}

// SAFETY: the payload is only touched on the main thread: Metal completion
// handlers and `enqueue` consumers of these values both land there.
#[allow(clippy::non_send_fields_in_send_ty)]
unsafe impl<T> Send for Sendable<T> {}
// SAFETY: `&Sendable<T>` shared with the main queue is only read on it.
#[allow(clippy::non_send_fields_in_send_ty)]
unsafe impl<T> Sync for Sendable<T> {}

type MetalTexture = objc2::runtime::ProtocolObject<dyn objc2_metal::MTLTexture>;
type MetalDevice = objc2::runtime::ProtocolObject<dyn objc2_metal::MTLDevice>;

/// `output_dimensions_for_input`: the resolved output size wins once the
/// filter has answered one; before that the output is the input's size.
const fn output_dimensions_for_input(
    resolved: (u32, u32),
    input_width: u32,
    input_height: u32,
) -> (u32, u32) {
    (
        if resolved.0 == 0 {
            input_width
        } else {
            resolved.0
        },
        if resolved.1 == 0 {
            input_height
        } else {
            resolved.1
        },
    )
}

/// The filter host's shared state — `WuiAppliedFilterRenderState` plus the
/// view's frame bookkeeping.
pub struct FilterState {
    /// The host view.
    view: Retained<HostView>,
    /// The output presentation view.
    output_view: Retained<PlatformView>,
    /// The shared Metal device — `metalDevice`.
    device: Retained<MetalDevice>,
    /// The semantic filter; `None` while asynchronous setup owns it —
    /// the ffi state's filter slot.
    filter: Rc<RefCell<Option<AppliedFilter>>>,
    /// The GPU runtime.
    runtime: GpuRuntime,
    /// The redraw handle shared with the semantic filter.
    redraw_handle: RedrawHandle,
    /// The host-owned effect clock — `frame_clock` on the ffi state.
    frame_clock: RefCell<EffectFrameClock>,
    /// Setup ran to completion on the current context — `setup_ready`.
    setup_ready: Rc<Cell<bool>>,
    /// The (input, output) formats setup was launched with — `setup_formats`.
    setup_formats: Cell<Option<(WgpuFormat, WgpuFormat)>>,
    /// The imported capture texture of the live frame — `imported_texture`.
    imported_texture: RefCell<Option<wgpu::Texture>>,
    /// The captured input's pixel format — `imported_format`.
    imported_format: Cell<Option<WgpuFormat>>,
    /// Attach-time sizes — `input_width`/`input_height`,
    /// `output_width`/`output_height`.
    input_size: Cell<(u32, u32)>,
    output_size_px: Cell<(u32, u32)>,
    /// The latest answer from `AppliedFilter::output_size` —
    /// `resolved_output_width`/`resolved_output_height`.
    resolved_output: Cell<(u32, u32)>,
    /// `isAttached`.
    attached: Cell<bool>,
    /// The `IOSurface` presenter on the output layer — `presenter`.
    presenter: RefCell<Option<cocoa_ui::metal::SurfaceBuffers>>,
    /// `captureTexture`.
    capture_texture: RefCell<Option<Retained<MetalTexture>>>,
    /// `framePresentationInFlight`.
    frame_presentation_in_flight: Cell<bool>,
    /// `renderInFlight`.
    render_in_flight: Cell<bool>,
    /// `detachAfterCapture`.
    detach_after_capture: Cell<bool>,
    /// `pendingDynamicRangeMode`.
    pending_dynamic_range: RefCell<Option<cocoa_ui::dynamic_range::DynamicRange>>,
    /// `configuredDynamicRangeMode`.
    configured_range: Cell<Option<cocoa_ui::dynamic_range::DynamicRange>>,
    /// `needsRender`.
    needs_render: Cell<bool>,
    /// `outputRevealed`/`filteredOutputRevealed`.
    output_revealed: Cell<bool>,
    /// `currentScaleFactor`.
    current_scale: Cell<f64>,
    /// `laidOutGeometry`: a layout pass only requests a frame when the
    /// geometry it produced is new — captures provoke layout passes of
    /// their own, so arming the clock on every pass makes nested filters
    /// drive each other forever.
    laid_out_geometry: RefCell<Option<cocoa_ui::Rect>>,
    /// `contentChangedSinceCapture` — a filter is only ready once it has
    /// shown a frame of the content as it actually stands (#521).
    content_changed_since_capture: Cell<bool>,
    /// First-paint waiters — `readyCompletions` in waker form.
    ready_waiters: RefCell<Vec<std::task::Waker>>,
    /// The hidden content leaf — `contentView`.
    mounted: RefCell<Option<Mounted>>,
    /// The `ViewCapture` pipeline — `capturePipeline`.
    capture: Rc<cocoa_ui::capture::ViewCapture>,
    /// The frame clock — `frameDriver`.
    clock: cocoa_ui::display_link::FrameClock,
    /// Window observers — `occlusionObserver`/app-activation watchers.
    observers: RefCell<Vec<cocoa_ui::notification::NotificationObserver>>,
}

impl fmt::Debug for FilterState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FilterState")
            .field("attached", &self.attached)
            .field("setup_ready", &self.setup_ready)
            .finish_non_exhaustive()
    }
}

/// The host bounds in physical pixels.
fn pixel_size(view: &PlatformView, scale: f64) -> (u32, u32) {
    let bounds = cocoa_ui::view::bounds(view);
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let (w, h) = (
        (bounds.size.width * scale).max(0.0) as u32,
        (bounds.size.height * scale).max(0.0) as u32,
    );
    (w, h)
}

/// `outputPixelFormat`: the Metal format the attached filter renders its
/// output in.
fn output_pixel_format(state: &FilterState) -> objc2_metal::MTLPixelFormat {
    let format = state
        .setup_formats
        .get()
        .map_or(PRESENTATION_FORMAT, |(_, output)| output);
    cocoa_ui::metal::wgpu_to_metal_format(format)
}

/// `isPresentationOccluded`.
fn presentation_occluded(view: &PlatformView) -> bool {
    #[cfg(target_os = "macos")]
    {
        cocoa_ui::view::window(view).is_none_or(|window| !cocoa_ui::appkit::is_visible(&window))
    }
    #[cfg(target_os = "ios")]
    {
        let _ = view;
        !cocoa_ui::uikit::application_is_active()
    }
}

/// `canAttachNow`.
fn can_attach_now(view: &PlatformView) -> bool {
    cocoa_ui::view::window(view).is_some() && !presentation_occluded(view)
}

/// `configureDynamicRange`.
fn configure_dynamic_range(state: &FilterState, mode: cocoa_ui::dynamic_range::DynamicRange) {
    assert!(
        !state.attached.get(),
        "AppliedFilter dynamic range cannot change while attached"
    );
    cocoa_ui::dynamic_range::apply_to_view(mode, &state.view);
    if let Some(presenter) = state.presenter.borrow_mut().as_mut() {
        presenter.release();
    }
    state.capture_texture.borrow_mut().take();
    hide_output(state);
    state.configured_range.set(Some(mode));
}

/// `prepareDynamicRange` — parks the change while a frame is in flight.
fn prepare_dynamic_range(state: &FilterState, mode: cocoa_ui::dynamic_range::DynamicRange) -> bool {
    if state.configured_range.get() == Some(mode) {
        state.pending_dynamic_range.borrow_mut().take();
        return true;
    }
    if state.render_in_flight.get() || state.frame_presentation_in_flight.get() {
        *state.pending_dynamic_range.borrow_mut() = Some(mode);
        return false;
    }
    detach_if_needed(state);
    configure_dynamic_range(state, mode);
    true
}

/// `waterui_applied_filter_attach_host_textures` — the capture texture and
/// output format an attached presentation implies, always at the
/// extended-range target.
fn attach_if_needed(state: &Rc<FilterState>, width: u32, height: u32) {
    if state.attached.get() {
        return;
    }
    let output_format = PRESENTATION_FORMAT;
    let gpu = state.runtime.context();
    // `assert_capture_usable_format`: the capture texture and the output
    // share one format, so the check runs at attach, not inside a frame.
    let capture_usages = wgpu::TextureUsages::TEXTURE_BINDING
        | wgpu::TextureUsages::RENDER_ATTACHMENT
        | wgpu::TextureUsages::COPY_DST;
    assert!(
        gpu.adapter
            .get_texture_format_features(output_format)
            .allowed_usages
            .contains(capture_usages),
        "applied_filter attach: output format {output_format:?} cannot be used for capture"
    );
    let (output_width, output_height) =
        output_dimensions_for_input(state.resolved_output.get(), width, height);
    assert!(
        width > 0 && height > 0,
        "AppliedFilter attach: dimensions must be non-zero, got {width}x{height}"
    );
    assert!(
        output_width > 0 && output_height > 0,
        "AppliedFilter attach: output size must be non-zero, got {output_width}x{output_height}"
    );
    if let Some((_, setup_output_format)) = state.setup_formats.get() {
        assert_eq!(
            setup_output_format, output_format,
            "AppliedFilter output format changed after setup"
        );
    }
    state.input_size.set((width, height));
    state.output_size_px.set((output_width, output_height));
    state.attached.set(true);
    let _ = state.redraw_handle.take_dirty();
    if state.setup_ready.get() {
        state.redraw_handle.request_redraw();
    }
    start_setup(state, output_format);
}

/// `detachIfNeeded` — `waterui_applied_filter_detach`.
fn detach_if_needed(state: &FilterState) {
    if !state.attached.get() {
        return;
    }
    state.attached.set(false);
    state.imported_texture.borrow_mut().take();
    state.imported_format.set(None);
    state.capture_texture.borrow_mut().take();
    state.input_size.set((0, 0));
    state.output_size_px.set((0, 0));
    state.resolved_output.set((0, 0));
}

/// `resolve_output_size` — the filter's current output size for `input`,
/// recorded as `resolved_output`.
fn resolve_output_size(state: &FilterState, input_width: u32, input_height: u32) -> (u32, u32) {
    let (output_width, output_height) = state
        .filter
        .borrow()
        .as_ref()
        .expect("AppliedFilter output size requested while asynchronous setup is pending")
        .output_size(input_width, input_height);
    assert!(
        output_width > 0 && output_height > 0,
        "applied_filter resolve_output_size: filter produced invalid output size {output_width}x{output_height} for input {input_width}x{input_height}"
    );
    state.resolved_output.set((output_width, output_height));
    (output_width, output_height)
}

/// `ensureCaptureTexture` — a private-storage render target in the
/// filter's output format, reallocated on size/format change.
fn ensure_capture_texture(state: &FilterState, width: u32, height: u32) -> Retained<MetalTexture> {
    let pixel_format = output_pixel_format(state);
    if let Some(texture) = state.capture_texture.borrow().as_ref()
        && texture.width() == width as usize
        && texture.height() == height as usize
        && texture.pixelFormat() == pixel_format
    {
        return texture.clone();
    }
    // SAFETY: creates a valid descriptor; Metal validates the arguments.
    let descriptor = unsafe {
        objc2_metal::MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
            pixel_format,
            width as usize,
            height as usize,
            false,
        )
    };
    descriptor.setUsage(
        objc2_metal::MTLTextureUsage::ShaderRead | objc2_metal::MTLTextureUsage::RenderTarget,
    );
    descriptor.setStorageMode(objc2_metal::MTLStorageMode::Private);
    let texture = state
        .device
        .newTextureWithDescriptor(&descriptor)
        .expect("Failed to create the AppliedFilter capture texture");
    *state.capture_texture.borrow_mut() = Some(texture.clone());
    texture
}

/// `initializeGpuIfNeeded`.
fn initialize_gpu(state: &Rc<FilterState>) {
    let bounds = cocoa_ui::view::bounds(&state.view);
    if bounds.size.width <= 0.0 || bounds.size.height <= 0.0 {
        return;
    }
    let Some(window) = cocoa_ui::view::window(&state.view) else {
        return;
    };
    let dynamic_range = cocoa_ui::dynamic_range::require_inherited(&state.view);
    if !prepare_dynamic_range(state, dynamic_range) {
        return;
    }
    #[cfg(target_os = "macos")]
    let scale = window.backingScaleFactor();
    #[cfg(target_os = "ios")]
    let scale = window.screen().scale();
    state.current_scale.set(scale);
    update_output_frame(state);

    // Attaching waits for a window that can present: a filter in a covered
    // window never captures anything, so the capture texture is only bought
    // once `schedule_frame_if_needed` could arm the clock (#576).
    if !can_attach_now(&state.view) {
        return;
    }
    let (width, height) = pixel_size(&state.view, scale);
    attach_if_needed(state, width, height);
    let _ = ensure_capture_texture(state, width, height);
}

/// `updateOutputLayerFrame`.
fn update_output_frame(state: &FilterState) {
    let bounds = cocoa_ui::view::bounds(&state.view);
    cocoa_ui::core_animation::without_animation(|| {
        cocoa_ui::view::set_frame(&state.output_view, bounds);
        if let Some(layer) = cocoa_ui::view::layer(&state.output_view) {
            cocoa_ui::core_animation::set_frame(&layer, bounds);
            cocoa_ui::core_animation::set_contents_scale(&layer, state.current_scale.get());
        }
    });
}

/// `scheduleFrameIfNeeded`.
fn schedule_frame_if_needed(state: &Rc<FilterState>) {
    if state.attached.get()
        && state.setup_ready.get()
        && cocoa_ui::view::window(&state.view).is_some()
        && state.needs_render.get()
        && !state.render_in_flight.get()
        && !state.frame_presentation_in_flight.get()
        && !presentation_occluded(&state.view)
    {
        state.clock.start(&state.view);
    } else {
        state.clock.stop();
    }
}

/// `requestRenderIfNeeded`.
fn request_render(state: &Rc<FilterState>) {
    state.needs_render.set(true);
    schedule_frame_if_needed(state);
}

/// `requestRenderIfGeometryChanged` — only a pass that produced new
/// geometry arms the frame clock; see `laid_out_geometry`.
fn request_render_if_geometry_changed(state: &Rc<FilterState>) {
    let geometry = cocoa_ui::view::bounds(&state.view);
    if state
        .laid_out_geometry
        .borrow()
        .is_some_and(|g| g == geometry)
    {
        schedule_frame_if_needed(state);
        return;
    }
    *state.laid_out_geometry.borrow_mut() = Some(geometry);
    request_render(state);
}

/// `renderFrame` — `resolve_output_size`, then capture into the
/// input-size texture.
fn render_frame(state: &Rc<FilterState>) {
    if !state.setup_ready.get()
        || !state.needs_render.get()
        || state.render_in_flight.get()
        || state.frame_presentation_in_flight.get()
    {
        schedule_frame_if_needed(state);
        return;
    }
    let (width, height) = pixel_size(&state.view, state.current_scale.get());
    if width == 0 || height == 0 {
        return;
    }
    state.needs_render.set(false);
    state.render_in_flight.set(true);
    state.clock.stop();
    // `resolve_output_size` runs before the capture so the presenter pair
    // the frame lands on is sized by the answer.
    let (output_width, output_height) = resolve_output_size(state, width, height);
    state.output_size_px.set((output_width, output_height));
    let frame = CaptureFrame {
        texture: ensure_capture_texture(state, width, height),
        width,
        height,
    };
    let weak = Sendable(Rc::downgrade(state));
    let frame_texture = frame.texture.clone();
    // The capture completion is `Fn` — the frame crosses it inside a slot.
    let frame = std::sync::Mutex::new(Some(Sendable(frame)));
    state.capture.capture(&frame_texture, move |captured| {
        if let Some(state) = weak.get().upgrade() {
            let frame = frame.lock().expect("capture fires once").take();
            if let Some(frame) = frame {
                finish_captured_frame(&state, frame.0, captured);
            }
        }
    });
}

/// `finishCapturedFrame`.
fn finish_captured_frame(state: &Rc<FilterState>, frame: CaptureFrame, captured: bool) {
    if state.detach_after_capture.get() {
        state.render_in_flight.set(false);
        state.detach_after_capture.set(false);
        detach_if_needed(state);
        if let Some(presenter) = state.presenter.borrow_mut().as_mut() {
            presenter.release();
        }
        complete_ready(state, false);
        return;
    }
    if state.pending_dynamic_range.borrow_mut().take().is_some() {
        state.render_in_flight.set(false);
        detach_if_needed(state);
        initialize_gpu(state);
        request_render(state);
        return;
    }
    if !captured {
        state.render_in_flight.set(false);
        schedule_frame_if_needed(state);
        return;
    }
    finish_prepared_frame(state, frame);
}

/// `renderCapturedFrame` — `waterui_applied_filter_render_to_metal_texture`:
/// render the filter into a pending surface and present on its fence.
#[allow(clippy::needless_pass_by_value)]
#[allow(clippy::too_many_lines)]
fn finish_prepared_frame(state: &Rc<FilterState>, frame: CaptureFrame) {
    let (output_width, output_height) = state.output_size_px.get();
    let pixel_format = output_pixel_format(state);
    {
        let mut presenter = state.presenter.borrow_mut();
        presenter
            .as_mut()
            .expect("AppliedFilter presenter released while rendering")
            .configure(output_width, output_height, pixel_format);
    }
    let pending = state
        .presenter
        .borrow()
        .as_ref()
        .and_then(cocoa_ui::metal::SurfaceBuffers::next_frame)
        .expect("AppliedFilter presenter has no texture to render into");

    let gpu = state.runtime.context();
    let input_format = output_pixel_format_wgpu(state);
    let input_texture = {
        let mut imported = state.imported_texture.borrow_mut();
        match imported.as_ref() {
            Some(texture) if texture.width() == frame.width && texture.height() == frame.height => {
                texture.clone()
            }
            _ => {
                // SAFETY: `frame.texture` is retained in `frame`, which
                // outlives the import; the format and size describe that
                // same texture.
                let texture = unsafe {
                    cocoa_ui::metal::import_texture(
                        &gpu.device,
                        frame.texture.clone(),
                        input_format,
                        frame.width,
                        frame.height,
                        wgpu::TextureUsages::RENDER_ATTACHMENT
                            | wgpu::TextureUsages::TEXTURE_BINDING,
                        "AppliedFilter Imported Input Texture",
                    )
                };
                *imported = Some(texture.clone());
                texture
            }
        }
    };
    state.imported_format.set(Some(input_format));
    state.input_size.set((frame.width, frame.height));

    // SAFETY: `pending.texture` is the retained texture the presenter handed
    // us for this frame; the format and size describe that texture.
    let output_wgpu_texture = unsafe {
        cocoa_ui::metal::import_texture(
            &gpu.device,
            pending.texture.clone(),
            PRESENTATION_FORMAT,
            output_width,
            output_height,
            wgpu::TextureUsages::RENDER_ATTACHMENT,
            "AppliedFilter Host Presentation Texture",
        )
    };
    let input_view = input_texture.create_view(&wgpu::TextureViewDescriptor {
        label: Some("AppliedFilter Input View"),
        ..Default::default()
    });
    let output_view = output_wgpu_texture.create_view(&wgpu::TextureViewDescriptor {
        label: Some("AppliedFilter Output View"),
        format: Some(PRESENTATION_FORMAT),
        ..Default::default()
    });
    let timing = state.frame_clock.borrow_mut().tick();
    let needs_redraw = {
        let input = EffectInput {
            device: &gpu.device,
            queue: &gpu.queue,
            texture: &input_texture,
            view: input_view,
            format: input_format,
            width: frame.width,
            height: frame.height,
            timing,
        };
        let output = EffectOutput {
            device: &gpu.device,
            queue: &gpu.queue,
            texture: &output_wgpu_texture,
            view: output_view,
            format: PRESENTATION_FORMAT,
            width: output_width,
            height: output_height,
        };
        state
            .filter
            .borrow_mut()
            .as_mut()
            .expect("AppliedFilter ready state is missing its semantic filter")
            .render(&input, &output)
            .unwrap_or_else(|error| panic!("applied_filter render: {error}"))
    };
    drop(input_texture);
    drop(output_wgpu_texture);
    let submission = gpu.queue.submit([]);

    // `observeGpuCaptureFence`: the frame stays in flight until its fence.
    state.frame_presentation_in_flight.set(true);
    let weak = Sendable(Rc::downgrade(state));
    let pending = Sendable(pending);
    gpu.submission_completion_driver()
        .on_complete(submission, move || {
            let weak = Sendable(weak.get().clone());
            let pending = pending;
            cocoa_ui::main_queue::enqueue(move |_mtm| {
                let Some(state) = weak.get().upgrade() else {
                    return;
                };
                state.frame_presentation_in_flight.set(false);
                finish_presented_frame(&state, pending.get(), needs_redraw);
            });
        });
}

/// The capture texture's wgpu format — the input format setup was launched
/// with, or the presentation format before setup ran.
fn output_pixel_format_wgpu(state: &FilterState) -> WgpuFormat {
    state
        .setup_formats
        .get()
        .map_or(PRESENTATION_FORMAT, |(input, _)| input)
}

/// The fence continuation — `present`/`revealFilteredOutput`/`completeReady`.
fn finish_presented_frame(
    state: &Rc<FilterState>,
    pending: &cocoa_ui::metal::PendingFrame,
    needs_redraw: bool,
) {
    if state.detach_after_capture.get() {
        state.detach_after_capture.set(false);
        detach_if_needed(state);
        if let Some(presenter) = state.presenter.borrow_mut().as_mut() {
            presenter.release();
        }
        complete_ready(state, false);
        return;
    }
    if state.pending_dynamic_range.borrow_mut().take().is_some() {
        detach_if_needed(state);
        initialize_gpu(state);
        request_render(state);
        return;
    }
    if let Some(presenter) = state.presenter.borrow_mut().as_mut() {
        presenter.present(pending);
    }
    reveal_output(state);
    crate::invalidation::invalidate_rendered_content(&state.view);
    state
        .needs_render
        .set(state.needs_render.get() || needs_redraw);
    if state.content_changed_since_capture.get() {
        // What this frame shows is already out of date; readiness waits for
        // the one that captures the change (#521).
        state.needs_render.set(true);
    } else {
        complete_ready(state, true);
    }
    schedule_frame_if_needed(state);
}

/// `revealFilteredOutput` / `hideFilteredOutput`.
fn reveal_output(state: &FilterState) {
    if state.output_revealed.get() {
        return;
    }
    state.output_revealed.set(true);
    cocoa_ui::view::set_hidden(&state.output_view, false);
}

fn hide_output(state: &FilterState) {
    state.output_revealed.set(false);
    cocoa_ui::view::set_hidden(&state.output_view, true);
}

/// `completeReady` — `result` narrows to the waiters' next poll.
fn complete_ready(state: &FilterState, _result: bool) {
    for waker in state.ready_waiters.borrow_mut().drain(..) {
        waker.wake();
    }
}

/// `waterui_applied_filter_setup` — run `filter.setup` on the UI-local
/// executor, retrying on device loss until it lands on the still-current
/// context.
fn start_setup(state: &Rc<FilterState>, output_format: WgpuFormat) {
    let input_format = output_pixel_format_wgpu(state);
    if let Some((setup_input, setup_output)) = state.setup_formats.get() {
        assert_eq!(
            setup_input, input_format,
            "AppliedFilter input format changed after setup"
        );
        assert_eq!(
            setup_output, output_format,
            "AppliedFilter output format changed after setup"
        );
        return;
    }
    state.setup_formats.set(Some((input_format, output_format)));
    spawn_setup(state, input_format, output_format);
}

/// `spawn_applied_filter_setup`.
fn spawn_setup(state: &Rc<FilterState>, input_format: WgpuFormat, output_format: WgpuFormat) {
    let mut filter = state
        .filter
        .borrow_mut()
        .take()
        .expect("AppliedFilter semantic filter is unavailable before setup starts");
    let filter_slot = Rc::clone(&state.filter);
    let setup_ready = Rc::clone(&state.setup_ready);
    let weak = Sendable(Rc::downgrade(state));
    let runtime = state.runtime.clone();
    let redraw_handle = state.redraw_handle.clone();
    spawn_local(async move {
        // Setup retries until it completes on the context that is still the
        // runtime's current one; a device loss mid-setup leaves corpses that
        // must not be installed, and a panic from inside `wgpu`'s purged
        // storage is loss fallout — not a filter bug — so it retries too.
        loop {
            let gpu = runtime.context();
            let outcome = {
                let shader_cache = WgslModuleCache::new();
                let ctx = EffectContext {
                    device: &gpu.device,
                    queue: &gpu.queue,
                    shader_cache: &shader_cache,
                    input_format,
                    output_format,
                };
                std::panic::AssertUnwindSafe(async {
                    filter
                        .setup(&ctx)
                        .await
                        .unwrap_or_else(|error| panic!("AppliedFilter setup failed: {error}"));
                })
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
        filter_slot.replace(Some(filter));
        setup_ready.set(true);
        if let Some(state) = weak.get().upgrade() {
            schedule_frame_if_needed(&state);
        }
        redraw_handle.request_redraw();
    })
    .detach();
}

/// `handleRendererRedraw` — the semantic redraw wake.
fn handle_redraw(state: &Rc<FilterState>) {
    request_render(state);
}

/// `handleWindowChange` — leaving the window defers teardown to whichever
/// half of the frame is still in flight.
fn handle_window_change(state: &Rc<FilterState>) {
    if cocoa_ui::view::window(&state.view).is_none() {
        state.clock.stop();
        state.needs_render.set(false);
        state.pending_dynamic_range.borrow_mut().take();
        complete_ready(state, false);
        if state.render_in_flight.get() || state.frame_presentation_in_flight.get() {
            state.detach_after_capture.set(true);
        } else {
            detach_if_needed(state);
            if let Some(presenter) = state.presenter.borrow_mut().as_mut() {
                presenter.release();
            }
        }
        return;
    }
    state.detach_after_capture.set(false);
    update_window_observers(state);
    initialize_gpu(state);
    request_render(state);
}

/// `WuiWindowOcclusionObserver` — occlusion/activation changes re-run
/// attach+schedule. On iOS the attach a launch-time `.inactive` state
/// deferred is retaken from `didBecomeActive`; without these observers a
/// filter mounted before activation presents nothing forever.
fn update_window_observers(state: &Rc<FilterState>) {
    let mut observers = state.observers.borrow_mut();
    observers.clear();
    let Some(window) = cocoa_ui::view::window(&state.view) else {
        return;
    };
    #[cfg(target_os = "ios")]
    let _ = &window;
    let mtm = cocoa_ui::MainThreadMarker::new().expect("main thread");
    let fire = {
        let weak = Rc::downgrade(state);
        move || {
            if let Some(state) = weak.upgrade() {
                initialize_gpu(&state);
                schedule_frame_if_needed(&state);
            }
        }
    };
    #[cfg(target_os = "macos")]
    observers.push(cocoa_ui::appkit::watch_occlusion(mtm, &window, move || {
        fire();
    }));
    #[cfg(target_os = "ios")]
    for notification in [
        // SAFETY: the notification names are system constants.
        unsafe { cocoa_ui::objc2_ui_kit::UIApplicationDidBecomeActiveNotification },
        // SAFETY: the notification names are system constants.
        unsafe { cocoa_ui::objc2_ui_kit::UIApplicationWillResignActiveNotification },
    ] {
        observers.push(cocoa_ui::notification::observe(
            mtm,
            &cocoa_ui::notification::NotificationName::framework(notification),
            {
                let fire = fire.clone();
                move || fire()
            },
        ));
    }
}

/// `layoutSubviews`/`layout`: frame the hidden child, refresh geometry,
/// then ensure GPU state and a pending frame.
fn on_layout(state: &Rc<FilterState>) {
    let bounds = cocoa_ui::view::bounds(&state.view);
    if let Some(mounted) = state.mounted.borrow().as_ref() {
        cocoa_ui::view::set_frame(mounted.view(), bounds);
        cocoa_ui::view::layout_immediately(mounted.view());
    }
    update_output_frame(state);
    initialize_gpu(state);
    request_render_if_geometry_changed(state);
}

/// The layout face: measurement delegates to the hidden child —
/// `sizeThatFits`/`measure`/`layoutPriority`/`setPlacementProposal`.
struct FilterSubView {
    state: Rc<FilterState>,
}

impl fmt::Debug for FilterSubView {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FilterSubView").finish_non_exhaustive()
    }
}

impl SubView for FilterSubView {
    fn measure(&self, proposal: ProposalSize) -> ViewDimensions {
        self.state.mounted.borrow().as_ref().map_or_else(
            || ViewDimensions::new(Size::new(0.0, 0.0)),
            |m| m.layout().measure(proposal),
        )
    }

    fn stretch_axis(&self) -> StretchAxis {
        self.state
            .mounted
            .borrow()
            .as_ref()
            .map_or(StretchAxis::None, |m| m.layout().stretch_axis())
    }

    fn priority(&self) -> i32 {
        self.state
            .mounted
            .borrow()
            .as_ref()
            .map_or(0, |m| m.layout().priority())
    }
}

// MARK: - First-paint readiness (WuiFirstPaintReadyParticipant)

/// Every live filter host view → its state, so a first-paint walk finds
/// unrevealed filters anywhere in the tree.
static FILTERS: std::sync::Mutex<
    Option<std::collections::HashMap<usize, Sendable<Weak<FilterState>>>>,
> = std::sync::Mutex::new(None);

fn filter_key(view: &PlatformView) -> usize {
    core::ptr::from_ref(view).cast::<u8>() as usize
}

/// `participatesInFirstPaintReady` — a filter whose window cannot present
/// has no first frame to wait for.
fn participates_in_first_paint_ready(state: &FilterState) -> bool {
    let bounds = cocoa_ui::view::bounds(&state.view);
    cocoa_ui::view::window(&state.view).is_some()
        && !cocoa_ui::view::is_hidden(&state.view)
        && cocoa_ui::view::alpha(&state.view) > 0.01
        && bounds.size.width > 0.5
        && bounds.size.height > 0.5
        && can_attach_now(&state.view)
}

/// `requestReadyFrame` — prepare, then register `waker` against the first
/// presented output.
fn request_ready_frame(state: &Rc<FilterState>, waker: std::task::Waker) {
    if state.output_revealed.get() {
        waker.wake();
        return;
    }
    // `prepareForReady`.
    cocoa_ui::view::layout_immediately(&state.view);
    initialize_gpu(state);
    request_render(state);
    if !state.attached.get() {
        complete_ready(state, false);
        return;
    }
    state.ready_waiters.borrow_mut().push(waker);
    schedule_frame_if_needed(state);
}

/// Walks `view`'s subtree calling `f` on every registered filter — the
/// filter half of `collectFirstPaintReadyParticipants`.
pub fn collect_filters(view: &PlatformView, f: &mut impl FnMut(&Rc<FilterState>)) {
    let filters = FILTERS.lock().expect("applied filter registry");
    if let Some(state) = filters
        .as_ref()
        .and_then(|filters| filters.get(&filter_key(view)))
        .and_then(|weak| weak.get().upgrade())
    {
        f(&state);
    }
    drop(filters);
    for subview in cocoa_ui::view::subviews(view) {
        collect_filters(&subview, f);
    }
}

/// The state's own `wait`, used by [`collect_filters`] callers.
pub fn filter_needs_frame(state: &Rc<FilterState>, waker: std::task::Waker) -> bool {
    if !participates_in_first_paint_ready(state) || state.output_revealed.get() {
        return false;
    }
    request_ready_frame(state, waker);
    !state.output_revealed.get()
}

/// Dropping clears the filter's registrations and shuts the capture and
/// render state down — `deinit`.
struct FilterGuard {
    view: Retained<PlatformView>,
    state: Rc<FilterState>,
}

impl fmt::Debug for FilterGuard {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FilterGuard").finish_non_exhaustive()
    }
}

impl Drop for FilterGuard {
    fn drop(&mut self) {
        crate::invalidation::unregister_sink(&self.view);
        if let Some(filters) = FILTERS.lock().expect("applied filter registry").as_mut() {
            filters.remove(&filter_key(&self.view));
        }
        self.state.clock.stop();
        self.state.capture.shutdown();
        detach_if_needed(&self.state);
    }
}

/// `fuseEnclosedFilters` — folds the filters this one directly encloses
/// into `filter`, returning the view the fused filter captures.
///
/// The resolve walk expands `body()` on everything the seam would have
/// handed to the composer layer; when it lands on another
/// `Metadata<AppliedFilter>` the pair collapses into one filter through
/// [`AppliedFilter::chained`] — one capture, one presentation target and
/// one submission instead of two (#521).
fn fuse_enclosed_filters(
    metadata: Metadata<AppliedFilter>,
    ctx: &RenderContext<'_>,
) -> (AnyView, AppliedFilter) {
    let mut filter = metadata.value;
    let mut content = metadata.content;
    loop {
        while !needs_fallback(&content) {
            content = AnyView::new(content.body(ctx.env()));
        }
        match content.downcast::<Metadata<AppliedFilter>>() {
            Ok(inner) => {
                let inner = *inner;
                filter = AppliedFilter::chained(inner.value, filter);
                content = inner.content;
            }
            Err(content) => return (content, filter),
        }
    }
}

/// Installs the `applied_filter` handler.
#[allow(clippy::too_many_lines)]
pub fn install(dispatcher: &mut Dispatcher) {
    dispatcher.register_view::<Metadata<AppliedFilter>>(|metadata, ctx| {
        let mtm = ctx.mtm();
        let runtime = crate::gpu_runtime::runtime(ctx.env());
        let (content, mut filter) = fuse_enclosed_filters(metadata, ctx);
        let redraw_handle = filter.redraw_handle();

        let view = HostView::new(mtm, cocoa_ui::Rect::ZERO);
        #[cfg(target_os = "macos")]
        cocoa_ui::view::ensure_layer_backed(&view);

        // `setupContentView`/`hideUnfilteredContent`: the unfiltered child
        // sits underneath and hidden — hidden as a *view*, because
        // `cacheDisplay` walks the view tree and ignores a hidden backing
        // layer.
        let mounted = ctx.render(content).mount(&view);
        crate::primary_content::forward(&view, mounted.view());
        let child_view = cocoa_ui::view::retain_base(mounted.view());
        #[cfg(target_os = "macos")]
        cocoa_ui::view::ensure_layer_backed(&child_view);
        cocoa_ui::view::set_hidden(&child_view, true);

        // `setupOutputView`: a layer-backed sibling drawn last, its plain
        // `CALayer` presenting `IOSurface` contents every capture path can
        // read (#519).
        let output_view = cocoa_ui::PlatformView::new(mtm);
        #[cfg(target_os = "macos")]
        cocoa_ui::view::ensure_layer_backed(&output_view);
        cocoa_ui::view::set_hidden(&output_view, true);
        if let Some(layer) = cocoa_ui::view::layer(&output_view) {
            layer.setOpaque(false);
            cocoa_ui::core_animation::set_contents_gravity_resize(&layer);
            cocoa_ui::core_animation::set_background_clear(&layer);
        }
        if let Some(host_layer) = cocoa_ui::view::layer(&view) {
            cocoa_ui::core_animation::set_background_clear(&host_layer);
        }
        cocoa_ui::view::add_subview(&view, &output_view);
        let output_layer =
            cocoa_ui::view::layer(&output_view).expect("output view is layer-backed");

        let gpu = runtime.context();
        // SAFETY: `raw_device` is the `MTLDevice` the runtime created and
        // still owns; `retain` takes our own reference on it.
        let device = unsafe {
            Retained::<MetalDevice>::retain(
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

        let state = Rc::new_cyclic(|weak| {
            let weak = weak.clone();
            let clock = cocoa_ui::display_link::FrameClock::new(mtm, move || {
                if let Some(state) = weak.upgrade() {
                    render_frame(&state);
                }
            });
            let capture = Rc::new(cocoa_ui::capture::ViewCapture::new(
                mtm,
                cocoa_ui::view::retain_base(&child_view),
                crate::components::gpu_surface::capturable_resolver(),
            ));
            let presenter = cocoa_ui::metal::SurfaceBuffers::new(device.clone(), output_layer);
            FilterState {
                view: view.clone(),
                output_view: output_view.clone(),
                device,
                filter: Rc::new(RefCell::new(Some(filter))),
                runtime,
                redraw_handle,
                frame_clock: RefCell::new(EffectFrameClock::new()),
                setup_ready: Rc::new(Cell::new(false)),
                setup_formats: Cell::new(None),
                imported_texture: RefCell::new(None),
                imported_format: Cell::new(None),
                input_size: Cell::new((0, 0)),
                output_size_px: Cell::new((0, 0)),
                resolved_output: Cell::new((0, 0)),
                attached: Cell::new(false),
                presenter: RefCell::new(Some(presenter)),
                capture_texture: RefCell::new(None),
                frame_presentation_in_flight: Cell::new(false),
                render_in_flight: Cell::new(false),
                detach_after_capture: Cell::new(false),
                pending_dynamic_range: RefCell::new(None),
                configured_range: Cell::new(None),
                needs_render: Cell::new(false),
                output_revealed: Cell::new(false),
                current_scale: Cell::new(1.0),
                laid_out_geometry: RefCell::new(None),
                content_changed_since_capture: Cell::new(false),
                ready_waiters: RefCell::new(Vec::new()),
                mounted: RefCell::new(Some(mounted)),
                capture,
                clock,
                observers: RefCell::new(Vec::new()),
            }
        });

        // `capturePipeline.onRedraw`.
        {
            let weak = Rc::downgrade(&state);
            state.capture.set_on_redraw(move || {
                if let Some(state) = weak.upgrade() {
                    request_render(&state);
                }
            });
        }
        // `installRedrawCallback` — the semantic redraw handle.
        {
            let weak = Sendable(Rc::downgrade(&state));
            state.redraw_handle.set_waker(Some(Arc::new(move || {
                let weak = Sendable(weak.get().clone());
                cocoa_ui::main_queue::enqueue(move |_mtm| {
                    if let Some(state) = weak.get().upgrade() {
                        handle_redraw(&state);
                    }
                });
            })));
        }

        {
            let state = state.clone();
            view.set_layout_handler(move |_| on_layout(&state));
        }
        {
            let state = state.clone();
            view.set_window_handler(move |_| handle_window_change(&state));
        }
        #[cfg(target_os = "macos")]
        {
            let state = state.clone();
            view.set_backing_changed_handler(move |_| {
                if cocoa_ui::view::window(&state.view).is_none() {
                    return;
                }
                initialize_gpu(&state);
                request_render(&state);
            });
        }
        #[cfg(target_os = "ios")]
        {
            // `registerForTraitChanges(UITraitDisplayScale)` — the kit
            // surfaces scale changes through layout/window transitions.
        }

        // `WuiRenderedContentInvalidationSink` — an invalidated descendant
        // redraws the capture and invalidates upward.
        let sink_callback: Rc<dyn Fn()> = Rc::new({
            let weak = Rc::downgrade(&state);
            move || {
                if let Some(state) = weak.upgrade() {
                    state.content_changed_since_capture.set(true);
                    request_render(&state);
                    crate::invalidation::invalidate_rendered_content(&state.view);
                }
            }
        });
        crate::invalidation::register_sink(&view, sink_callback);
        FILTERS
            .lock()
            .expect("applied filter registry")
            .get_or_insert_with(std::collections::HashMap::new)
            .insert(filter_key(&view), Sendable(Rc::downgrade(&state)));

        let filter_guard = FilterGuard {
            view: cocoa_ui::view::retain_base(&view),
            state: state.clone(),
        };
        let mut leaf = NativeLeaf::new(
            &view,
            FilterSubView {
                state: state.clone(),
            },
        );
        leaf.keep(view);
        leaf.keep(state);
        leaf.keep(filter_guard);
        leaf
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `output_dimensions_for_input` mirrors the ffi state's resolution: the
    /// filter's answer wins once it has given one, and before that the
    /// output is the input's size.
    #[test]
    fn unresolved_output_is_input() {
        assert_eq!(output_dimensions_for_input((0, 0), 320, 200), (320, 200));
    }

    #[test]
    fn resolved_output_wins() {
        assert_eq!(
            output_dimensions_for_input((640, 400), 320, 200),
            (640, 400)
        );
        // A blur grows one axis and leaves the other; zero on one axis is
        // "unresolved", not a size.
        assert_eq!(output_dimensions_for_input((640, 0), 320, 200), (640, 200));
    }

    /// The presentation format is the extended-range half-float target the
    /// `CAMetalLayer` path always rendered in, and it maps to Metal.
    #[test]
    fn presentation_format_maps_to_metal() {
        assert_eq!(PRESENTATION_FORMAT, WgpuFormat::Rgba16Float);
        assert_eq!(
            cocoa_ui::metal::wgpu_to_metal_format(PRESENTATION_FORMAT),
            objc2_metal::MTLPixelFormat::RGBA16Float
        );
    }
}
