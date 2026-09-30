//! Window realization — `WuiWindowManager` ported to the kit.
//!
//! macOS: a declared [`Window`] becomes a kit [`cocoa_ui::appkit::Window`]
//! whose title, frame, state, size limits, background and toolbar are all
//! wired two-way — declared signals drive the platform, platform events
//! publish back — and whose content is a dispatched leaf laid out inside a
//! host view. iOS has no multi-window surface: the service is installed so
//! `Window::show` finds it, and it fails exactly as the Swift implementation
//! did.

#[cfg(target_os = "macos")]
use cocoa_ui::geometry::{Rect, Size};
#[cfg(target_os = "macos")]
use waterui_core::layout::{Point as WPoint, Rect as WRect, Size as WSize};

#[cfg(target_os = "macos")]
mod imp {
    use alloc::rc::Rc;
    use alloc::vec::Vec;
    use core::cell::{Cell, RefCell};
    use core::ffi::c_void;

    use super::{into_kit_rect, into_kit_size, into_layout_rect};
    use cocoa_ui::appkit::{HostView, WindowStyle};
    use cocoa_ui::{MainThreadMarker, Retained};
    use waterui::animation::Animation;
    use waterui::reactive::{Signal, SignalExt};
    use waterui::resolve::Resolvable;
    use waterui::theme::color::Background;
    use waterui::window::WindowStyle as WuiStyle;
    use waterui::window::{Window, WindowBackground, WindowState};
    use waterui_backend_core::Environment;

    use crate::contract::KeepAlive;
    use crate::seam::waterui_swift_content_frame;

    /// Installs `view` — the rendered window-toolbar host — as `window`'s
    /// toolbar items: lone-child wrappers are descended and the first
    /// multi-child view's children become the items, as
    /// `WuiWindowToolbar.setWindowContent` answered them.
    fn install_toolbar(
        window: &cocoa_ui::objc2_app_kit::NSWindow,
        view: &cocoa_ui::objc2_app_kit::NSView,
    ) {
        crate::toolbar::install_toolbar_items(window, view);
    }

    /// What an open window owns: the platform object, its host view, and
    /// every subscription and child leaf the window keeps alive. Dropping a
    /// host closes the window and stops the watchers.
    pub struct WindowHost {
        _window: Rc<cocoa_ui::appkit::Window>,
        _host: Retained<HostView>,
        _keepalive: KeepAlive,
    }

    thread_local! {
        /// Every window the manager has opened, by insertion order: the set
        /// the `activeWindows` array tracked. A window removes itself on
        /// close.
        static HOSTS: RefCell<Vec<WindowHost>> = const { RefCell::new(Vec::new()) };
    }

    /// Installs the `WindowManager` service: `window.show(env)` realizes the
    /// declaration on a fresh platform window, deferred to the next main-queue
    /// turn exactly as the Swift `show` dispatch was.
    pub fn install_manager(env: &mut Environment) {
        let inner = env.clone();
        let manager = waterui::window::WindowManager::new(move |window| {
            let inner = inner.clone();
            cocoa_ui::main_queue::enqueue_local(mtm(), move |mtm| {
                track(realize(window, &inner, mtm));
            });
        });
        env.insert(manager);
    }

    /// Keeps `host` — the window the startup path realized — in the open set.
    pub fn track(host: WindowHost) {
        HOSTS.with(|hosts| hosts.borrow_mut().push(host));
    }

    /// Realizes `declaration` as a platform window and returns its host. The
    /// window is ordered front at full transparency and revealed when its
    /// content reports ready — the same path the Swift host took, so a GPU
    /// surface never shows before its first frame.
    #[expect(
        clippy::too_many_lines,
        reason = "one sequential realization: order is the point, splitting it obscures the wiring"
    )]
    pub fn realize(declaration: Window, env: &Environment, mtm: MainThreadMarker) -> WindowHost {
        let mut keepalive = KeepAlive::default();

        let style = style_mask(
            declaration.style,
            declaration.closable,
            declaration.resizable,
        );
        // `Window.frame` is the content rect — every other backend treats
        // the binding as content-space (winit `inner_size`, GTK
        // `set_default_size`), and the twin scaffold pins `contentRect`
        // unconditionally.
        let frame = declaration.frame.snapshot();
        let window = Rc::new(cocoa_ui::appkit::Window::new(
            mtm,
            into_kit_rect(frame),
            style,
        ));
        window.set_accepts_mouse_moved_events(true);
        window.set_alpha_value(0.0);

        // Title: declared, or the application name when empty — the
        // resolution `display_title` performs for every backend. The env
        // channel reports nothing for a bundle launched directly, so the
        // bundle's own display name is the fallback — `WuiMain` showed the
        // application name the same way.
        let title = declaration.display_title();
        window.set_title(&display_or_app_title(&title.snapshot()));
        keepalive.watch(&title, {
            let window = window.clone();
            move |context| window.set_title(&display_or_app_title(context.value()))
        });

        // Frame, two-way: declared changes apply to the window (animated
        // when the change carries an `Animation`), platform moves and
        // resizes publish back. The `applying` flag is what stops each side
        // from echoing the other's write.
        let applying_frame = Rc::new(Cell::new(false));
        keepalive.watch(&declaration.frame, {
            let window = window.clone();
            let applying = applying_frame.clone();
            move |context| {
                applying.set(true);
                window.set_content_rect(
                    into_kit_rect(*context.value()),
                    context.metadata().try_get::<Animation>().is_some(),
                );
                applying.set(false);
            }
        });
        let publish_frame = {
            let window = window.clone();
            let frame = declaration.frame.clone();
            let applying = applying_frame;
            move || {
                if !applying.get() {
                    frame.set(into_layout_rect(window.content_rect()));
                }
            }
        };
        window.on_resize({
            let publish = publish_frame.clone();
            move || publish()
        });
        window.on_move(publish_frame);

        // State, two-way the same way.
        let applying_state = Rc::new(Cell::new(false));
        keepalive.watch(&declaration.state, {
            let window = window.clone();
            let applying = applying_state.clone();
            move |context| {
                applying.set(true);
                apply_state(&window, *context.value());
                applying.set(false);
            }
        });
        let publish_state = {
            let state = declaration.state.clone();
            let applying = applying_state;
            move |to: WindowState| {
                if !applying.get() {
                    state.set(to);
                }
            }
        };
        window.on_close({
            let publish = publish_state.clone();
            move || publish(WindowState::Closed)
        });
        window.on_miniaturized({
            let publish = publish_state.clone();
            move || publish(WindowState::Minimized)
        });
        window.on_deminiaturized({
            let publish = publish_state.clone();
            move || publish(WindowState::Normal)
        });
        window.on_entered_fullscreen({
            let publish = publish_state.clone();
            move || publish(WindowState::Fullscreen)
        });
        window.on_exited_fullscreen(move || publish_state(WindowState::Normal));

        // Size limits apply only while declared; an undeclared axis keeps
        // AppKit's defaults.
        if let Some(min_size) = &declaration.min_size {
            window.set_content_min_size(into_kit_size(min_size.snapshot()));
            keepalive.watch(min_size, {
                let window = window.clone();
                move |context| window.set_content_min_size(into_kit_size(*context.value()))
            });
        }
        if let Some(max_size) = &declaration.max_size {
            window.set_content_max_size(into_kit_size(max_size.snapshot()));
            keepalive.watch(max_size, {
                let window = window.clone();
                move |context| window.set_content_max_size(into_kit_size(*context.value()))
            });
        }

        // Background: a declared color resolves through the environment; an
        // opaque window reads the theme's Background slot, exactly as the
        // Swift manager did.
        let background: waterui::reactive::Computed<waterui::graphics::color::ResolvedColor> =
            match &declaration.background {
                WindowBackground::Opaque => Background.resolve(env).computed(),
                WindowBackground::Color(color) => color.resolve(env),
            };
        apply_background(&window, background.snapshot());
        keepalive.watch(&background, {
            let window = window.clone();
            move |context| apply_background(&window, *context.value())
        });

        // Content: the declared tree becomes one leaf whose view fills the
        // host each layout pass, at the safe-area-aware frame the seam
        // answers.
        let content = declaration.build_content();
        let leaf = crate::dispatch::dispatcher(mtm)
            .render(content, env, mtm)
            .expect("window content must render: no handler or fallback claims it");

        let host = HostView::new(mtm, window.content_rect());
        host.add_subview(leaf.view());
        let leaf_view = cocoa_ui::view::retain_base(leaf.view());

        // First-paint marking happens on the leaf the fallback produced.
        crate::first_paint::mark(Retained::as_ptr(&leaf_view).cast::<c_void>().cast_mut());

        host.set_layout_handler(move |host| {
            let host_view: &cocoa_ui::PlatformView = host;
            // SAFETY: the seam borrows the views for the call; `leaf_view`
            // holds the retain for the host's lifetime.
            let frame = unsafe {
                waterui_swift_content_frame(
                    Retained::as_ptr(&leaf_view).cast::<c_void>().cast_mut(),
                    core::ptr::from_ref::<cocoa_ui::PlatformView>(host_view)
                        .cast::<c_void>()
                        .cast_mut(),
                )
            };
            cocoa_ui::view::set_frame(&leaf_view, frame.into_kit());
        });
        window.set_content_view(&host);
        keepalive.keep(leaf);
        keepalive.keep(host.clone());

        // The declared toolbar goes through the window's one `NSToolbar`:
        // each child becomes an `NSToolbarItem`, which is what gives it the
        // system's capsule, spacing and overflow.
        if let Some(toolbar) = declaration.toolbar {
            let toolbar_leaf = crate::dispatch::dispatcher(mtm)
                .render(toolbar, env, mtm)
                .expect("window toolbar must render: no handler or fallback claims it");
            install_toolbar(window.native(), toolbar_leaf.view());
            keepalive.keep(toolbar_leaf);
        }

        // Reveal: adopt the declared state, then fade in once the content
        // reports its first frame — a GPU surface's content may still be
        // empty while the window exists.
        apply_state(&window, declaration.state.snapshot());
        window.make_key_and_order_front();
        // The leaf tree is mounted before the window becomes key, so AppKit's
        // automatic first-responder pick lands on the first editable field;
        // the Swift backend showed its windows before content mounted, so
        // none was ever picked. Clear the pick to match that launch state.
        window.clear_first_responder();
        window.display_if_needed();
        window.fade_in(0.12);

        WindowHost {
            _window: window,
            _host: host,
            _keepalive: keepalive,
        }
    }

    /// The `AppKit` style mask a declared window asks for —
    /// `windowStyleMask`'s table.
    fn style_mask(style: WuiStyle, closable: bool, resizable: bool) -> WindowStyle {
        let mut mask = match style {
            WuiStyle::Titled => WindowStyle::TITLED | WindowStyle::CLOSABLE,
            WuiStyle::Borderless => WindowStyle::empty(),
            WuiStyle::FullSizeContentView => {
                WindowStyle::TITLED | WindowStyle::CLOSABLE | WindowStyle::FULL_SIZE_CONTENT_VIEW
            }
        };
        // Miniaturizable accompanies titled styles, matching the mask the
        // Swift side produced.
        if mask.contains(WindowStyle::TITLED) {
            mask |= WindowStyle::MINIATURIZABLE;
        }
        if resizable {
            mask |= WindowStyle::RESIZABLE;
        }
        if !closable {
            mask -= WindowStyle::CLOSABLE;
        }
        mask
    }

    /// What a bound root window owns while the binding lives: the adopted
    /// window and the watchers talking to it. Dropping the binding stops the
    /// watchers — the platform delegate hooks fire only while the kit window
    /// wrapper lives, which the host guarantees for its own window.
    pub struct RootWindowBinding {
        _window: Rc<cocoa_ui::appkit::Window>,
        _keepalive: Rc<RefCell<Option<KeepAlive>>>,
    }

    /// `WuiRootWindowBinding`'s port: binds the app's first declared window to
    /// an `NSWindow` the host already created — the embed path.
    ///
    /// The frame is the one exception to "the declaration wins": the host's
    /// window already has a position on a real screen, so the real (outer)
    /// frame is published into the binding instead, then the binding drives
    /// the window in both directions — as the Swift binding did, including its
    /// outer-frame convention (unlike `realize`, which treats the binding as
    /// content-space).
    #[expect(clippy::too_many_arguments, reason = "the declared window's surface")]
    pub fn bind_root_window(
        window: Retained<cocoa_ui::objc2_app_kit::NSWindow>,
        env: &Environment,
        title: &waterui::reactive::Computed<waterui::Str>,
        frame: &waterui::reactive::Binding<super::WRect>,
        state: &waterui::reactive::Binding<WindowState>,
        toolbar: Option<waterui::AnyView>,
        style: WuiStyle,
        closable: bool,
        resizable: bool,
        mtm: MainThreadMarker,
    ) -> RootWindowBinding {
        let window = Rc::new(cocoa_ui::appkit::Window::adopt(mtm, window));
        let mut keepalive = KeepAlive::default();

        // Adopt the declared style — the toolbar coordinator owns
        // full-size-content, so a host window already carrying it keeps it.
        let mut mask = style_mask(style, closable, resizable);
        if window
            .style_mask()
            .contains(WindowStyle::FULL_SIZE_CONTENT_VIEW)
        {
            mask |= WindowStyle::FULL_SIZE_CONTENT_VIEW;
        }
        window.set_style_mask(mask);

        // The declared toolbar goes through the window's one `NSToolbar`,
        // exactly as a realized window's does.
        if let Some(toolbar) = toolbar {
            let toolbar_leaf = crate::dispatch::dispatcher(mtm)
                .render(toolbar, env, mtm)
                .expect("window toolbar must render: no handler or fallback claims it");
            install_toolbar(window.native(), toolbar_leaf.view());
            keepalive.keep(toolbar_leaf);
        }

        // An empty title means the host already set the application name —
        // keep it; otherwise the declared title drives the window.
        if !title.snapshot().is_empty() {
            window.set_title(&title.snapshot());
        }
        keepalive.watch(title, {
            let window = window.clone();
            move |context| {
                let declared = context.value();
                if !declared.is_empty() {
                    window.set_title(declared);
                }
            }
        });

        wire_frame(&window, &mut keepalive, frame);
        let keepalive = wire_state(&window, keepalive, state);

        RootWindowBinding {
            _window: window,
            _keepalive: keepalive,
        }
    }

    /// The bound window's frame wiring, outer-frame style: the host's real
    /// frame seeds the binding (adopting never moves the window), declared
    /// changes apply with declared animations, platform moves and resizes
    /// publish back — each direction guarded so the other's write does not
    /// echo.
    fn wire_frame(
        window: &Rc<cocoa_ui::appkit::Window>,
        keepalive: &mut KeepAlive,
        frame: &waterui::reactive::Binding<super::WRect>,
    ) {
        frame.set(into_layout_rect(window.frame()));
        let applying = Rc::new(Cell::new(false));
        keepalive.watch(frame, {
            let window = window.clone();
            let applying = applying.clone();
            move |context| {
                let declared = into_kit_rect(*context.value());
                if window.frame() != declared {
                    applying.set(true);
                    window.set_frame(
                        declared,
                        context.metadata().try_get::<Animation>().is_some(),
                    );
                    applying.set(false);
                }
            }
        });
        let publish = {
            let window = window.clone();
            let frame = frame.clone();
            move || {
                if !applying.get() {
                    frame.set(into_layout_rect(window.frame()));
                }
            }
        };
        window.on_resize({
            let publish = publish.clone();
            move || publish()
        });
        window.on_move(publish);
    }

    /// The bound window's state wiring, the same two-way shape; a user close
    /// publishes `Closed` then drops the watchers — the teardown order
    /// `windowWillClose` enforced. Returns the keepalive behind the
    /// close-clears-it cell.
    fn wire_state(
        window: &Rc<cocoa_ui::appkit::Window>,
        mut keepalive: KeepAlive,
        state: &waterui::reactive::Binding<WindowState>,
    ) -> Rc<RefCell<Option<KeepAlive>>> {
        let applying = Rc::new(Cell::new(false));
        keepalive.watch(state, {
            let window = window.clone();
            let applying = applying.clone();
            move |context| {
                applying.set(true);
                apply_state(&window, *context.value());
                applying.set(false);
            }
        });
        let publish = {
            let state = state.clone();
            move |to: WindowState| {
                if !applying.get() {
                    state.set(to);
                }
            }
        };
        let keepalive = Rc::new(RefCell::new(Some(keepalive)));
        window.on_close({
            let publish = publish.clone();
            let keepalive = keepalive.clone();
            move || {
                publish(WindowState::Closed);
                let _ = keepalive.borrow_mut().take();
            }
        });
        window.on_miniaturized({
            let publish = publish.clone();
            move || publish(WindowState::Minimized)
        });
        window.on_deminiaturized({
            let publish = publish.clone();
            move || publish(WindowState::Normal)
        });
        window.on_entered_fullscreen({
            let publish = publish.clone();
            move || publish(WindowState::Fullscreen)
        });
        window.on_exited_fullscreen(move || publish(WindowState::Normal));
        keepalive
    }

    /// Applies `state` to the platform window — `applyState`'s switch.
    fn apply_state(window: &cocoa_ui::appkit::Window, state: WindowState) {
        match state {
            WindowState::Normal => {
                if window.is_miniaturized() {
                    window.deminiaturize();
                } else if window.is_fullscreen() {
                    window.toggle_fullscreen();
                }
            }
            WindowState::Closed => window.close(),
            WindowState::Minimized => {
                if !window.is_miniaturized() {
                    window.miniaturize();
                }
            }
            WindowState::Fullscreen => {
                if !window.is_fullscreen() {
                    window.toggle_fullscreen();
                }
            }
        }
    }

    /// `applyWindowBackground`'s write: the resolved color, the opacity
    /// answer, and the shadow the window always keeps.
    /// The window title a declaration resolves to: the declared string when
    /// present, otherwise the bundle's display name, then the bundle name,
    /// then the process name — `WaterUIMainMenu.appName`'s order, and what
    /// the Swift host's window showed when the env channel reported nothing.
    fn display_or_app_title(title: &str) -> alloc::string::String {
        if !title.is_empty() {
            return title.into();
        }
        cocoa_ui::bundle::info_string("CFBundleDisplayName")
            .or_else(|| cocoa_ui::bundle::info_string("CFBundleName"))
            .unwrap_or_else(cocoa_ui::process::name)
    }

    fn apply_background(
        window: &cocoa_ui::appkit::Window,
        color: waterui::graphics::color::ResolvedColor,
    ) {
        let srgb = color.to_srgb();
        window.set_background_color(cocoa_ui::Rgba {
            red: f64::from(srgb.red),
            green: f64::from(srgb.green),
            blue: f64::from(srgb.blue),
            alpha: f64::from(color.opacity),
        });
        window.set_opaque(color.opacity >= 1.0);
        window.set_has_shadow(true);
    }

    fn mtm() -> MainThreadMarker {
        MainThreadMarker::new().expect("window realization runs on the main thread")
    }
}

#[cfg(target_os = "ios")]
mod imp {
    use alloc::collections::vec_deque::VecDeque;
    use alloc::rc::Rc;
    use alloc::vec::Vec;
    use core::cell::RefCell;
    use core::ffi::c_void;

    use cocoa_ui::uikit::{ColorSchemeObservation, HostView, ViewController, WindowScene};
    use cocoa_ui::{MainThreadMarker, Retained};
    use waterui::Resolvable;
    use waterui::Signal;
    use waterui::signal::IntoComputed;
    use waterui::theme::color::Background;
    use waterui::window::{Window, WindowBackground};
    use waterui_backend_core::Environment;

    use crate::contract::KeepAlive;
    use crate::seam::waterui_swift_content_frame;
    use crate::theme::ThemeSignals;

    /// What a connected scene owns: its root controller and every
    /// subscription and leaf the window keeps alive. The platform window
    /// itself is retained by the kit's scene delegate.
    pub struct WindowHost {
        _controller: Retained<ViewController>,
        _keepalive: KeepAlive,
    }

    /// A scene connected before its declaration landed: `UIKit` asks for a
    /// window eagerly at connection, so the platform objects exist already
    /// and the content arrives when [`declare`] runs.
    struct Pending {
        _scene: WindowScene,
        controller: Retained<ViewController>,
        observation: ColorSchemeObservation,
    }

    thread_local! {
        /// Every window the process is showing, by connection order.
        static HOSTS: RefCell<Vec<WindowHost>> = const { RefCell::new(Vec::new()) };
        /// Scenes connected ahead of their declaration, in connection order.
        static PENDING: RefCell<VecDeque<Pending>> =
            const { RefCell::new(VecDeque::new()) };
        /// Declarations still waiting on a scene, in declaration order.
        static DECLARED: RefCell<VecDeque<Window>> =
            const { RefCell::new(VecDeque::new()) };
        /// The environment `app` returned, stored once `declare` runs: a
        /// scene connecting afterward realizes its declaration under it,
        /// since the app's own installs are invisible to the launch env.
        static APP_ENV: RefCell<Option<Environment>> = const { RefCell::new(None) };
    }

    /// Installs the `WindowManager` service: `Window::show` resolves the
    /// service, and invoking it on a surface with no multi-window support
    /// fails the way the Swift implementation did.
    pub fn install_manager(env: &mut Environment) {
        env.insert(waterui::window::WindowManager::new(|_| {
            panic!("WaterUI multi-window is unsupported on iOS");
        }));
    }

    /// Connects `scene`: the platform window must exist at connection time,
    /// so it is built eagerly — with an empty root — and the first queued
    /// declaration fills it; with none waiting, the scene queues in
    /// `PENDING` until [`declare`] runs.
    pub fn connect(
        scene: &WindowScene,
        theme: Rc<ThemeSignals>,
        env: &Environment,
        _mtm: MainThreadMarker,
    ) -> cocoa_ui::uikit::Window {
        let mtm = scene.main_thread();
        let window = cocoa_ui::uikit::Window::new(scene);
        let controller = ViewController::new(mtm);
        window.set_root_view_controller(&controller);
        window.make_key_and_visible();

        // The scene's own appearance drives the theme refresh: a scene can
        // carry an overridden trait the application-level collection lacks.
        let observation = controller.observe_color_scheme(move |scheme| {
            crate::theme::refresh(&theme, scheme);
        });

        let pending = Pending {
            _scene: scene.clone(),
            controller,
            observation,
        };
        let declaration = DECLARED.with(|declared| declared.borrow_mut().pop_front());
        if let Some(declaration) = declaration {
            // `declare` ran before this declaration was queued, so the app
            // env exists and carries the app's own installs; the launch
            // env is the fallback only for a path that cannot happen.
            let app_env =
                APP_ENV.with(|app_env| app_env.borrow().clone().unwrap_or_else(|| env.clone()));
            HOSTS.with(|hosts| {
                hosts
                    .borrow_mut()
                    .push(realize(&declaration, pending, &app_env, mtm));
            });
        } else {
            PENDING.with(|pending_scenes| {
                pending_scenes.borrow_mut().push_back(pending);
            });
        }
        window
    }

    /// Delivers the application's declared windows — `AppParts::windows` — to
    /// the scenes waiting on them, or queues them for future connections.
    /// `env` is the env `app` returned; it is stored so `connect` realizes
    /// declarations queued ahead of its scene under the same env.
    pub fn declare(windows: Vec<Window>, env: &Environment, mtm: MainThreadMarker) {
        APP_ENV.with(|app_env| {
            *app_env.borrow_mut() = Some(env.clone());
        });
        for declaration in windows {
            let pending = PENDING.with(|pending_scenes| pending_scenes.borrow_mut().pop_front());
            if let Some(pending) = pending {
                HOSTS.with(|hosts| {
                    hosts
                        .borrow_mut()
                        .push(realize(&declaration, pending, env, mtm));
                });
            } else {
                DECLARED.with(|declared| declared.borrow_mut().push_back(declaration));
            }
        }
    }

    /// Fills a connected scene's window with `declaration`'s content: the
    /// tree becomes one leaf laid out inside the controller's host view, at
    /// the safe-area-aware frame the seam answers.
    fn realize(
        declaration: &Window,
        pending: Pending,
        env: &Environment,
        mtm: MainThreadMarker,
    ) -> WindowHost {
        let mut keepalive = KeepAlive::default();
        let host = Retained::from(pending.controller.host_view());

        // Background: a declared color resolves through the environment; an
        // opaque window reads the theme's Background slot, exactly as the
        // Swift controller painted `view.backgroundColor`.
        let background: waterui::reactive::Computed<waterui::graphics::color::ResolvedColor> =
            match &declaration.background {
                WindowBackground::Opaque => Background.resolve(env).into_computed(),
                WindowBackground::Color(color) => color.resolve(env),
            };
        apply_background(&host, &background.snapshot());
        keepalive.watch(&background, {
            let host = host.clone();
            move |context| apply_background(&host, context.value())
        });

        let content = declaration.build_content();
        let leaf = crate::dispatch::dispatcher(mtm)
            .render(content, env, mtm)
            .expect("window content must render: no handler or fallback claims it");
        // The declared root can be a controller's root view — a tab bar or
        // navigation stack. Without real containment `UIKit` never delivers
        // `viewWillLayoutSubviews` or the appearance callbacks to it, so
        // chrome that integrates in them (a `UISearchController`'s bar)
        // collapses.
        if let Some(child) = cocoa_ui::uikit::view_controller::owning_controller(leaf.view())
            && cocoa_ui::objc2::rc::Retained::as_ptr(&child)
                != cocoa_ui::objc2::rc::Retained::as_ptr(&pending.controller).cast()
        {
            cocoa_ui::uikit::view_controller::add_child(&pending.controller, &child);
            host.add_subview(leaf.view());
            cocoa_ui::uikit::view_controller::did_move_to_parent(&child);
        } else {
            host.add_subview(leaf.view());
        }
        let leaf_view = cocoa_ui::view::retain_base(leaf.view());

        crate::first_paint::mark(Retained::as_ptr(&leaf_view).cast::<c_void>().cast_mut());

        host.set_layout_handler(move |host| {
            let host_view: &cocoa_ui::PlatformView = host;
            // SAFETY: the seam borrows the views for the call; `leaf_view`
            // holds the retain for the host's lifetime.
            let frame = unsafe {
                waterui_swift_content_frame(
                    Retained::as_ptr(&leaf_view).cast::<c_void>().cast_mut(),
                    core::ptr::from_ref::<cocoa_ui::PlatformView>(host_view)
                        .cast::<c_void>()
                        .cast_mut(),
                )
            };
            cocoa_ui::view::set_frame(&leaf_view, frame.into_kit());
        });
        keepalive.keep(leaf);
        keepalive.keep(pending.observation);

        WindowHost {
            _controller: pending.controller,
            _keepalive: keepalive,
        }
    }

    /// `applyWindowBackground`'s write on `UIKit`: the resolved color as the
    /// host view's `backgroundColor`, matching the Swift controller.
    fn apply_background(host: &HostView, color: &waterui::graphics::color::ResolvedColor) {
        let rgba = cocoa_ui::uikit::colors::extended_linear(
            f64::from(color.red),
            f64::from(color.green),
            f64::from(color.blue),
            f64::from(color.opacity),
            f64::from(color.headroom),
        );
        cocoa_ui::view::set_background_color(host, Some(&rgba));
    }
}

pub use imp::install_manager;
#[cfg(target_os = "macos")]
pub use imp::{RootWindowBinding, bind_root_window, realize, track};
#[cfg(target_os = "ios")]
pub use imp::{connect, declare};

/// A waterui layout rect, as the kit sees it.
#[cfg(target_os = "macos")]
fn into_kit_rect(rect: WRect) -> Rect {
    Rect {
        origin: cocoa_ui::geometry::Point {
            x: f64::from(rect.origin().x),
            y: f64::from(rect.origin().y),
        },
        size: Size {
            width: f64::from(rect.size().width),
            height: f64::from(rect.size().height),
        },
    }
}

/// A kit rect, in the layout engine's units.
#[cfg(target_os = "macos")]
#[expect(
    clippy::cast_possible_truncation,
    reason = "the layout contract is f32; window geometry always fits"
)]
const fn into_layout_rect(rect: Rect) -> WRect {
    WRect::new(
        WPoint::new(rect.origin.x as f32, rect.origin.y as f32),
        WSize::new(rect.size.width as f32, rect.size.height as f32),
    )
}

/// A waterui size, as the kit sees it.
#[cfg(target_os = "macos")]
fn into_kit_size(size: WSize) -> Size {
    Size {
        width: f64::from(size.width),
        height: f64::from(size.height),
    }
}
