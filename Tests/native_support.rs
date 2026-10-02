//! Harness-only reach into the embedding contract.
//!
//! Compiled into the crate only behind the non-default
//! `native-test-support` feature and pulled in through
//! `#[path]` in `lib.rs`, so `native` test binaries can assert the
//! private window lifecycle without widening the public API. Each entry
//! takes the harness's real `MainThreadMarker` — the cases build real
//! `NSWindow`s, which only the process's true main thread may.

use cocoa_ui::MainThreadMarker;
use waterui::window::WindowManager;
use waterui_backend_core::Environment;

/// Mounts a leaf the way the embedding's `mount_content` does: onto a
/// real `HostView` whose layout handler delivers the placement proposal
/// and applies the content frame. Without the proposal pass every child
/// keeps a `.zero` frame — a bare `mount` is not enough for laid-out
/// `UIKit` assertions.
#[cfg(target_os = "ios")]
pub fn mount_uikit(
    mtm: MainThreadMarker,
    view: waterui::AnyView,
    env: &Environment,
    frame: cocoa_ui::Rect,
) -> (
    cocoa_ui::Retained<cocoa_ui::uikit::HostView>,
    alloc::rc::Rc<crate::contract::Mounted>,
) {
    let host = cocoa_ui::uikit::HostView::new(mtm, frame);
    let leaf = crate::dispatch::render(view, env);
    let content = alloc::rc::Rc::new(leaf.mount(&host));
    let placed = content.clone();
    host.set_layout_handler(move |host| {
        let frame = crate::native_layout::content_frame(placed.view(), host);
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the layout contract uses f32 points"
        )]
        let proposal = waterui_core::layout::ProposalSize::new(
            Some(frame.size.width as f32),
            Some(frame.size.height as f32),
        );
        crate::proposal::deliver(placed.view(), proposal);
        cocoa_ui::view::set_frame(placed.view(), frame);
    });
    (host, content)
}

#[cfg(target_os = "macos")]
use cocoa_ui::Retained;
#[cfg(target_os = "macos")]
use waterui::Signal;
#[cfg(target_os = "macos")]
use waterui::Str;
#[cfg(target_os = "macos")]
use waterui::color::Color;
#[cfg(target_os = "macos")]
use waterui::reactive::{Binding, Computed, SignalExt, binding};
#[cfg(target_os = "macos")]
use waterui::window::{UserAttention, WindowBackground, WindowLevel, WindowState, WindowStyle};
#[cfg(target_os = "macos")]
use waterui_core::layout::{Point, Rect, Size};

/// `install_services` is the real window-service installer — the same
/// entry the owned embedding runtime runs — and it puts the
/// `WindowManager` into the env, the piece `window.show(env)` resolves.
/// The runtime installs the dispatcher first; the harness does the same.
pub fn manager_installs_into_the_environment(_mtm: MainThreadMarker) {
    let mut env = Environment::new();
    crate::dispatch::install(&mut env);
    crate::embedding::install_services(&mut env);
    assert!(env.get::<WindowManager>().is_some());
}

/// `bind_root_window` adopts a window the host already created: the
/// declared style and title land on it, the real frame publishes into
/// the binding, a declared frame drives the window back, and platform
/// close publishes `Closed`. The window is never ordered in — the whole
/// lifecycle stays offscreen.
#[expect(
    clippy::float_cmp,
    reason = "the binding and the window exchange frame fields bit-exact"
)]
#[cfg(target_os = "macos")]
pub fn bind_root_window_wires_a_live_window(mtm: MainThreadMarker) {
    let window = cocoa_ui::appkit::Window::new(
        mtm,
        cocoa_ui::Rect::new(100.0, 100.0, 640.0, 480.0),
        cocoa_ui::appkit::WindowStyle::TITLED,
    );

    let mut env = Environment::new();
    crate::dispatch::install(&mut env);
    crate::embedding::install_services(&mut env);
    let title: Computed<Str> = binding(Str::from("Bind Root")).computed();
    let frame: Binding<Rect> = binding(Rect::new(Point::new(0.0, 0.0), Size::new(0.0, 0.0)));
    let state: Binding<WindowState> = binding(WindowState::Normal);
    let style: Computed<WindowStyle> = binding(WindowStyle::Titled).computed();
    let level: Computed<WindowLevel> = binding(WindowLevel::Normal).computed();
    let attention: Binding<Option<UserAttention>> = binding(None);
    let background: Computed<WindowBackground> =
        binding(WindowBackground::Color(Color::srgb(255, 255, 255))).computed();

    // `window.native()` is +0; the binding retains it for the
    // declaration's lifetime.
    let native = unsafe {
        Retained::retain(std::ptr::from_ref(window.native()).cast_mut())
            .expect("a live NSWindow retains")
    };
    let binding = crate::windows::bind_root_window(
        native,
        &env,
        &title,
        &frame,
        &state,
        None,
        &style,
        &level,
        &attention,
        None,
        &background,
        true,
        true,
        mtm,
    );

    // The declared style was adopted on top of the kit window's mask.
    let mask = window.style_mask();
    assert!(mask.contains(
        cocoa_ui::appkit::WindowStyle::TITLED
            | cocoa_ui::appkit::WindowStyle::CLOSABLE
            | cocoa_ui::appkit::WindowStyle::MINIATURIZABLE
            | cocoa_ui::appkit::WindowStyle::RESIZABLE
    ));

    // The declared title landed on the window.
    assert_eq!(window.native().title().to_string(), "Bind Root");

    // The window's real frame seeded the frame binding (outer-frame
    // convention — the host's position on screen wins over the declared
    // origin).
    let snapshot = frame.snapshot();
    let current = window.frame();
    assert_eq!(f64::from(snapshot.origin().x), current.origin.x);
    assert_eq!(f64::from(snapshot.origin().y), current.origin.y);
    assert_eq!(f64::from(snapshot.size().width), current.size.width);
    assert_eq!(f64::from(snapshot.size().height), current.size.height);

    // A declared frame write drives the real window.
    frame.set(Rect::new(Point::new(20.0, 30.0), Size::new(320.0, 240.0)));
    let moved = window.frame();
    assert_eq!(moved.origin.x, 20.0);
    assert_eq!(moved.origin.y, 30.0);
    assert_eq!(moved.size.width, 320.0);
    assert_eq!(moved.size.height, 240.0);

    // Platform close publishes `Closed` through the binding — the
    // window's own lifecycle event driving the declared state.
    window.close();
    assert_eq!(state.snapshot(), WindowState::Closed);
    window.close();
    assert_eq!(state.snapshot(), WindowState::Closed);

    // Dropping the binding releases the window's declaration — the
    // owned-ABI replacement for a free function over a raw handle.
    drop(binding);
}
