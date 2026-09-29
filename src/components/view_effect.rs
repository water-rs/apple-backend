//! The `view_effect` leaf: `Native<ViewEffectErased>` — the `WuiViewEffect`
//! port. The hidden content view is captured offscreen through the kit's
//! `ViewCapture`; the effect renders it into an `IOSurface` pair presented
//! through a plain layer-backed output view composited on top.

use std::cell::{Cell, RefCell};
use std::fmt;
use std::rc::{Rc, Weak};
use std::sync::Arc;

use cocoa_ui::PlatformView;
use cocoa_ui::Retained;
use executor_core::spawn_local;
use futures::FutureExt;
use objc2_metal::{MTLDevice as _, MTLTexture as _};
use waterui_core::layout::{ProposalSize, Size, StretchAxis, SubView, ViewDimensions};
use waterui_graphics::shared_context::GpuRuntime;
use waterui_graphics::view_effect::{
    OutputSize, ViewEffectContext, ViewEffectErased, ViewEffectInput, ViewEffectOutput,
};
use waterui_graphics::wgpu;

use crate::contract::{Mounted, NativeLeaf};
use crate::dispatch::Dispatcher;

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

/// A captured content frame — `WuiViewEffectCaptureFrame`.
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

impl<T> Sendable<T> {
    /// Consumes the cell, returning the wrapped value.
    fn into_inner(self) -> T {
        self.0
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

/// The effect host's shared state — `WuiViewEffectRenderState` plus the
/// view's frame bookkeeping.
pub struct EffectState {
    /// The host view.
    view: Retained<HostView>,
    /// The output presentation view.
    output_view: Retained<PlatformView>,
    /// The shared Metal device — `metalDevice`.
    device: Retained<MetalDevice>,
    /// The semantic renderer; `None` while asynchronous setup owns it —
    /// the ffi state's effect slot.
    effect: RefCell<Option<ViewEffectErased>>,
    /// The resolved output-size policy — `output_size`.
    output_size: OutputSize,
    /// The GPU runtime.
    runtime: GpuRuntime,
    /// The redraw handle shared with the semantic renderer.
    redraw_handle: waterui_graphics::gpu_surface::RedrawHandle,
    /// Setup ran to completion on the current context — `setup_ready`.
    setup_ready: Cell<bool>,
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
    /// `pendingSetupFrame`.
    pending_setup_frame: RefCell<Option<CaptureFrame>>,
    /// `outputRevealed`.
    output_revealed: Cell<bool>,
    /// `currentScaleFactor`.
    current_scale: Cell<f64>,
    /// First-paint waiters — `readyCompletions` in waker form.
    ready_waiters: RefCell<Vec<std::task::Waker>>,
    /// The hidden content leaf — `childView`.
    mounted: RefCell<Option<Mounted>>,
    /// The `ViewCapture` pipeline — `capturePipeline`.
    capture: Rc<cocoa_ui::capture::ViewCapture>,
    /// The frame clock — `frameDriver`.
    clock: cocoa_ui::display_link::FrameClock,
    /// Window observers — `occlusionObserver`.
    #[allow(dead_code)]
    observers: RefCell<Vec<cocoa_ui::notification::NotificationObserver>>,
}

impl fmt::Debug for EffectState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EffectState")
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

/// `outputPixelFormat`: the Metal format the attached effect renders its
/// output in.
fn output_pixel_format(state: &EffectState) -> objc2_metal::MTLPixelFormat {
    let format = state
        .setup_formats
        .get()
        .expect("ViewEffect presentation target is detached")
        .1;
    match format {
        WgpuFormat::Bgra8Unorm => objc2_metal::MTLPixelFormat::BGRA8Unorm,
        WgpuFormat::Bgra8UnormSrgb => objc2_metal::MTLPixelFormat::BGRA8Unorm_sRGB,
        WgpuFormat::Rgba16Float => objc2_metal::MTLPixelFormat::RGBA16Float,
        other => panic!("ViewEffect output format {other:?} has no Metal equivalent"),
    }
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
fn configure_dynamic_range(state: &EffectState, mode: cocoa_ui::dynamic_range::DynamicRange) {
    assert!(
        !state.attached.get(),
        "ViewEffect dynamic range cannot change while attached"
    );
    cocoa_ui::dynamic_range::apply_to_view(mode, &state.view);
    if let Some(presenter) = state.presenter.borrow_mut().as_mut() {
        presenter.release();
    }
    state.capture_texture.borrow_mut().take();
    state.pending_setup_frame.borrow_mut().take();
    hide_output(state);
    state.configured_range.set(Some(mode));
}

/// `prepareDynamicRange` — parks the change while a frame is in flight.
fn prepare_dynamic_range(state: &EffectState, mode: cocoa_ui::dynamic_range::DynamicRange) -> bool {
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

/// `attachIfNeeded` — always the half-float target (`prefersHDR: true`, as
/// the `CAMetalLayer` path always rendered extended-range linear).
fn attach_if_needed(state: &EffectState, width: u32, height: u32) {
    if state.attached.get() {
        return;
    }
    let output_format = WgpuFormat::Rgba16Float;
    let (output_width, output_height) = state.output_size.compute(width, height);
    assert!(
        width > 0 && height > 0,
        "ViewEffect attach: dimensions must be non-zero, got {width}x{height}"
    );
    assert!(
        output_width > 0 && output_height > 0,
        "ViewEffect attach: output size must be non-zero, got {output_width}x{output_height}"
    );
    if let Some((_, setup_output_format)) = state.setup_formats.get() {
        assert_eq!(
            setup_output_format, output_format,
            "ViewEffect output format changed after setup"
        );
    }
    state.input_size.set((width, height));
    state.output_size_px.set((output_width, output_height));
    state.attached.set(true);
}

/// `detachIfNeeded`.
fn detach_if_needed(state: &EffectState) {
    if !state.attached.get() {
        return;
    }
    state.attached.set(false);
    state.imported_texture.borrow_mut().take();
    state.imported_format.set(None);
    state.input_size.set((0, 0));
    state.output_size_px.set((0, 0));
}

/// `ensureCaptureTexture` — a private-storage render target in the
/// effect's output format, reallocated on size/format change.
fn ensure_capture_texture(state: &EffectState, width: u32, height: u32) -> Retained<MetalTexture> {
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
        .expect("Failed to create the ViewEffect capture texture");
    *state.capture_texture.borrow_mut() = Some(texture.clone());
    texture
}

/// `initializeGpuIfNeeded`.
fn initialize_gpu(state: &Rc<EffectState>) {
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

    if !can_attach_now(&state.view) {
        return;
    }
    let (width, height) = pixel_size(&state.view, scale);
    attach_if_needed(state, width, height);
    let _ = ensure_capture_texture(state, width, height);
}

/// `updateOutputLayerFrame`.
fn update_output_frame(state: &EffectState) {
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
fn schedule_frame_if_needed(state: &Rc<EffectState>) {
    if state.attached.get()
        && cocoa_ui::view::window(&state.view).is_some()
        && state.needs_render.get()
        && !state.render_in_flight.get()
        && !state.frame_presentation_in_flight.get()
        && state.pending_setup_frame.borrow().is_none()
        && !presentation_occluded(&state.view)
    {
        state.clock.start(&state.view);
    } else {
        state.clock.stop();
    }
}

/// `requestRenderIfNeeded`.
fn request_render(state: &Rc<EffectState>) {
    state.needs_render.set(true);
    schedule_frame_if_needed(state);
}

/// `renderFrame`.
fn render_frame(state: &Rc<EffectState>) {
    if !state.needs_render.get()
        || state.render_in_flight.get()
        || state.frame_presentation_in_flight.get()
        || state.pending_setup_frame.borrow().is_some()
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
                finish_captured_frame(&state, frame.into_inner(), captured);
            }
        }
    });
}

/// `finishCapturedFrame`.
fn finish_captured_frame(state: &Rc<EffectState>, frame: CaptureFrame, captured: bool) {
    state.render_in_flight.set(false);
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
    if !captured {
        schedule_frame_if_needed(state);
        return;
    }
    set_input(state, &frame);
    if !state.setup_ready.get() {
        *state.pending_setup_frame.borrow_mut() = Some(frame);
        return;
    }
    finish_prepared_frame(state, frame);
}

/// `setInput` — `waterui_view_effect_set_input_metal_texture`: import the
/// capture texture and kick asynchronous setup on first use.
fn set_input(state: &Rc<EffectState>, frame: &CaptureFrame) {
    assert!(
        frame.width > 0 && frame.height > 0,
        "ViewEffect input dimensions must be non-zero"
    );
    let (output_width, output_height) = state.output_size.compute(frame.width, frame.height);
    assert!(
        output_width > 0 && output_height > 0,
        "ViewEffect output dimensions must be non-zero"
    );
    state.input_size.set((frame.width, frame.height));
    state.output_size_px.set((output_width, output_height));

    let wgpu_format = match frame.texture.pixelFormat() {
        objc2_metal::MTLPixelFormat::BGRA8Unorm => WgpuFormat::Bgra8Unorm,
        objc2_metal::MTLPixelFormat::BGRA8Unorm_sRGB => WgpuFormat::Bgra8UnormSrgb,
        objc2_metal::MTLPixelFormat::RGBA16Float => WgpuFormat::Rgba16Float,
        other => panic!("ViewEffect import: unsupported Metal format {other:?}"),
    };
    let gpu = state.runtime.context();
    // SAFETY: `frame.texture` is retained in `frame`, which outlives the
    // import; the format and size describe that same texture.
    let wgpu_texture = unsafe {
        cocoa_ui::metal::import_texture(
            &gpu.device,
            frame.texture.clone(),
            wgpu_format,
            frame.width,
            frame.height,
            wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            "ViewEffect Imported Input Texture",
        )
    };
    *state.imported_texture.borrow_mut() = Some(wgpu_texture);
    state.imported_format.set(Some(wgpu_format));

    // `start_view_effect_setup`.
    let output_format = state
        .setup_formats
        .get()
        .map_or(WgpuFormat::Rgba16Float, |(_, output)| output);
    assert!(
        state.attached.get(),
        "ViewEffect setup requires an attached presentation target"
    );
    if let Some((setup_input, setup_output)) = state.setup_formats.get() {
        assert_eq!(
            setup_input, wgpu_format,
            "ViewEffect input format changed after setup"
        );
        assert_eq!(
            setup_output, output_format,
            "ViewEffect output format changed after setup"
        );
        return;
    }
    state.setup_formats.set(Some((wgpu_format, output_format)));
    spawn_setup(state, wgpu_format, output_format);
}

/// `spawn_view_effect_setup`: run `erased.setup` on the UI-local executor,
/// retrying on device loss until it lands on the still-current context.
fn spawn_setup(state: &Rc<EffectState>, input_format: WgpuFormat, output_format: WgpuFormat) {
    let mut effect = state
        .effect
        .borrow_mut()
        .take()
        .expect("ViewEffect semantic renderer is unavailable before setup starts");
    let weak = Sendable(Rc::downgrade(state));
    let runtime = state.runtime.clone();
    let redraw_handle = state.redraw_handle.clone();
    spawn_local(async move {
        loop {
            let gpu = runtime.context();
            let outcome = {
                let ctx = ViewEffectContext {
                    device: &gpu.device,
                    queue: &gpu.queue,
                    input_format,
                    output_format,
                };
                std::panic::AssertUnwindSafe(effect.setup(&ctx))
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
        if let Some(state) = weak.get().upgrade() {
            *state.effect.borrow_mut() = Some(effect);
            state.setup_ready.set(true);
        }
        redraw_handle.request_redraw();
    })
    .detach();
}

/// `finishPreparedFrame` — render into a pending surface and present on
/// its fence.
#[allow(clippy::needless_pass_by_value)]
fn finish_prepared_frame(state: &Rc<EffectState>, frame: CaptureFrame) {
    let (output_width, output_height) = state.output_size.compute(frame.width, frame.height);
    let pixel_format = output_pixel_format(state);
    {
        let mut presenter = state.presenter.borrow_mut();
        presenter
            .as_mut()
            .expect("ViewEffect presenter released while rendering")
            .configure(output_width, output_height, pixel_format);
    }
    let pending = state
        .presenter
        .borrow()
        .as_ref()
        .and_then(cocoa_ui::metal::SurfaceBuffers::next_frame)
        .expect("ViewEffect presenter has no texture to render into");

    // `renderPreparedInput` — `render_to_metal_texture`.
    let gpu = state.runtime.context();
    let input_texture = state
        .imported_texture
        .borrow()
        .clone()
        .expect("ViewEffect input texture was not provided");
    let input_format = state
        .imported_format
        .get()
        .expect("ViewEffect input format was not provided");
    let output_format = state
        .setup_formats
        .get()
        .expect("ViewEffect presentation target is detached")
        .1;
    let input_view = input_texture.create_view(&wgpu::TextureViewDescriptor {
        label: Some("ViewEffect Input View"),
        ..Default::default()
    });
    // SAFETY: `pending.texture` is the retained texture the presenter handed
    // us for this frame; the format and size describe that texture.
    let output_wgpu_texture = unsafe {
        cocoa_ui::metal::import_texture(
            &gpu.device,
            pending.texture.clone(),
            output_format,
            output_width,
            output_height,
            wgpu::TextureUsages::RENDER_ATTACHMENT,
            "ViewEffect Host Presentation Texture",
        )
    };
    let output_view = output_wgpu_texture.create_view(&wgpu::TextureViewDescriptor {
        label: Some("ViewEffect Output View"),
        format: Some(output_format),
        ..Default::default()
    });
    let needs_redraw = {
        let input = ViewEffectInput {
            device: &gpu.device,
            queue: &gpu.queue,
            texture: &input_texture,
            view: input_view,
            format: input_format,
            width: state.input_size.get().0,
            height: state.input_size.get().1,
        };
        let output = ViewEffectOutput {
            device: &gpu.device,
            queue: &gpu.queue,
            texture: &output_wgpu_texture,
            view: output_view,
            format: output_format,
            width: output_width,
            height: output_height,
        };
        let mut effect = state.effect.borrow_mut();
        effect
            .as_mut()
            .expect("ViewEffect ready state is missing its semantic renderer")
            .render(&input, &output)
    };
    drop(input_texture);
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

/// The fence continuation — `present`/`revealOutput`/`completeReady`.
fn finish_presented_frame(
    state: &Rc<EffectState>,
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
        initialize_gpu_owned(state);
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
    complete_ready(state, true);
    schedule_frame_if_needed(state);
}

/// `initializeGpuIfNeeded` where only `&EffectState` is at hand — it needs
/// no upgrade because every caller already holds `Rc`.
fn initialize_gpu_owned(state: &Rc<EffectState>) {
    initialize_gpu(state);
}

/// `revealOutput` / `hideOutput`.
fn reveal_output(state: &EffectState) {
    if state.output_revealed.get() {
        return;
    }
    state.output_revealed.set(true);
    cocoa_ui::view::set_hidden(&state.output_view, false);
}

fn hide_output(state: &EffectState) {
    state.output_revealed.set(false);
    cocoa_ui::view::set_hidden(&state.output_view, true);
}

/// `completeReady` — `result` narrows to the waiters' next poll.
fn complete_ready(state: &EffectState, _result: bool) {
    for waker in state.ready_waiters.borrow_mut().drain(..) {
        waker.wake();
    }
}

/// `handleRendererRedraw`.
fn handle_redraw(state: &Rc<EffectState>) {
    if state.setup_ready.get() && state.pending_setup_frame.borrow().is_some() {
        let frame = state
            .pending_setup_frame
            .borrow_mut()
            .take()
            .expect("checked");
        finish_prepared_frame(state, frame);
    } else {
        request_render(state);
    }
}

/// `handleWindowChange` — leaving the window defers teardown to whichever
/// half of the frame is still in flight.
fn handle_window_change(state: &Rc<EffectState>) {
    if cocoa_ui::view::window(&state.view).is_none() {
        state.clock.stop();
        state.pending_setup_frame.borrow_mut().take();
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
    #[cfg(target_os = "macos")]
    update_window_observers(state);
    initialize_gpu(state);
    request_render(state);
}

/// `WuiWindowOcclusionObserver` — occlusion changes re-run attach+schedule.
#[cfg(target_os = "macos")]
fn update_window_observers(state: &Rc<EffectState>) {
    state.observers.borrow_mut().clear();
    let Some(window) = cocoa_ui::view::window(&state.view) else {
        return;
    };
    let mtm = cocoa_ui::MainThreadMarker::new().expect("main thread");
    let weak = Rc::downgrade(state);
    let observer = cocoa_ui::appkit::watch_occlusion(mtm, &window, move || {
        if let Some(state) = weak.upgrade() {
            initialize_gpu(&state);
            schedule_frame_if_needed(&state);
        }
    });
    state.observers.borrow_mut().push(observer);
}

/// `layoutSubviews`/`layout`: frame the hidden child, refresh geometry,
/// then ensure GPU state and a pending frame.
fn on_layout(state: &Rc<EffectState>) {
    let bounds = cocoa_ui::view::bounds(&state.view);
    if let Some(mounted) = state.mounted.borrow().as_ref() {
        cocoa_ui::view::set_frame(mounted.view(), bounds);
        cocoa_ui::view::invalidate_layout(mounted.view());
        cocoa_ui::view::layout_immediately(mounted.view());
    }
    update_output_frame(state);
    initialize_gpu(state);
    request_render(state);
}

/// The layout face: measurement delegates to the hidden child —
/// `sizeThatFits`/`measure`.
struct EffectSubView {
    state: Rc<EffectState>,
}

impl fmt::Debug for EffectSubView {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EffectSubView").finish_non_exhaustive()
    }
}

impl SubView for EffectSubView {
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

/// Every live effect host view → its state, so a first-paint walk finds
/// unrevealed effects anywhere in the tree.
static EFFECTS: std::sync::Mutex<
    Option<std::collections::HashMap<usize, Sendable<Weak<EffectState>>>>,
> = std::sync::Mutex::new(None);

fn effect_key(view: &PlatformView) -> usize {
    core::ptr::from_ref(view).cast::<u8>() as usize
}

/// `participatesInFirstPaintReady` — an effect whose window cannot present
/// has no first frame to wait for.
fn participates_in_first_paint_ready(state: &EffectState) -> bool {
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
fn request_ready_frame(state: &Rc<EffectState>, waker: std::task::Waker) {
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
    render_frame(state);
}

/// Walks `view`'s subtree calling `f` on every registered effect — the
/// effect half of `collectFirstPaintReadyParticipants`.
pub fn collect_effects(view: &PlatformView, f: &mut impl FnMut(&Rc<EffectState>)) {
    let effects = EFFECTS.lock().expect("view effect registry");
    if let Some(state) = effects
        .as_ref()
        .and_then(|effects| effects.get(&effect_key(view)))
        .and_then(|weak| weak.get().upgrade())
    {
        f(&state);
    }
    drop(effects);
    for subview in cocoa_ui::view::subviews(view) {
        collect_effects(&subview, f);
    }
}

/// The state's own `wait`, used by [`collect_effects`] callers.
pub fn effect_needs_frame(state: &Rc<EffectState>, waker: std::task::Waker) -> bool {
    if !participates_in_first_paint_ready(state) || state.output_revealed.get() {
        return false;
    }
    request_ready_frame(state, waker);
    !state.output_revealed.get()
}

/// Dropping clears the effect's registry entries — `deinit`.
struct EffectGuard {
    view: Retained<PlatformView>,
}

impl fmt::Debug for EffectGuard {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EffectGuard").finish_non_exhaustive()
    }
}

impl Drop for EffectGuard {
    fn drop(&mut self) {
        crate::invalidation::unregister_sink(&self.view);
        if let Some(effects) = EFFECTS.lock().expect("view effect registry").as_mut() {
            effects.remove(&effect_key(&self.view));
        }
    }
}

/// Installs the `view_effect` handler.
#[allow(clippy::too_many_lines)]
pub fn install(dispatcher: &mut Dispatcher) {
    dispatcher.register_native::<ViewEffectErased>(|mut erased, ctx| {
        let mtm = ctx.mtm();
        let runtime = crate::gpu_runtime::runtime(ctx.env());
        let output_size = erased.output_size();
        let redraw_handle = erased.redraw_handle();

        let view = HostView::new(mtm, cocoa_ui::Rect::ZERO);
        #[cfg(target_os = "macos")]
        cocoa_ui::view::ensure_layer_backed(&view);

        // `setupChildView`: the unfiltered child sits underneath and hidden.
        let mounted = ctx.render(erased.take_content()).mount(&view);
        let child_view = cocoa_ui::view::retain_base(mounted.view());
        #[cfg(target_os = "macos")]
        cocoa_ui::view::ensure_layer_backed(&child_view);
        cocoa_ui::view::set_hidden(&child_view, true);

        // `setupOutputView`: a layer-backed sibling drawn last.
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
            EffectState {
                view: view.clone(),
                output_view: output_view.clone(),
                device,
                effect: RefCell::new(Some(erased)),
                output_size,
                runtime,
                redraw_handle,
                setup_ready: Cell::new(false),
                setup_formats: Cell::new(None),
                imported_texture: RefCell::new(None),
                imported_format: Cell::new(None),
                input_size: Cell::new((0, 0)),
                output_size_px: Cell::new((0, 0)),
                attached: Cell::new(false),
                presenter: RefCell::new(Some(presenter)),
                capture_texture: RefCell::new(None),
                frame_presentation_in_flight: Cell::new(false),
                render_in_flight: Cell::new(false),
                detach_after_capture: Cell::new(false),
                pending_dynamic_range: RefCell::new(None),
                configured_range: Cell::new(None),
                needs_render: Cell::new(false),
                pending_setup_frame: RefCell::new(None),
                output_revealed: Cell::new(false),
                current_scale: Cell::new(1.0),
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
                    request_render(&state);
                    crate::invalidation::invalidate_rendered_content(&state.view);
                }
            }
        });
        crate::invalidation::register_sink(&view, sink_callback);
        EFFECTS
            .lock()
            .expect("view effect registry")
            .get_or_insert_with(std::collections::HashMap::new)
            .insert(effect_key(&view), Sendable(Rc::downgrade(&state)));

        let effect_guard = EffectGuard {
            view: cocoa_ui::view::retain_base(&view),
        };
        let mut leaf = NativeLeaf::new(
            &view,
            EffectSubView {
                state: state.clone(),
            },
        );
        leaf.keep(view);
        leaf.keep(state);
        leaf.keep(effect_guard);
        leaf
    });
}
