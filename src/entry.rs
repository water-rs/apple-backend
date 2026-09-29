//! `waterui_apple_main`'s body — the work `WuiRootContext.init()` did in
//! Swift, in the same order.
//!
//! The staging is dictated by the fallback's environment preparation: its
//! GPU runtime is created asynchronously, so [`crate::seam`] returns through
//! a callback on the main thread, and the platform run loop must already be
//! draining the main queue for the callback to ever run. The launch
//! therefore splits at the seam — everything before it runs synchronously,
//! the rest (theme, locale, windows, `app(env)` itself) runs inside the
//! platform's launch handler, half before the seam call and half in its
//! callback:
//!
//! - `run`: process startup (executors, tracing, the locale listener),
//!   the inspector, the font collection and bundled fonts;
//! - launch handler: the platform application, menus, theme, locale — then
//!   `waterui_swift_prepare_env`;
//! - seam callback: the window manager (installed after the fallback's own
//!   services so `Window::show` resolves to this backend), `app(env)`'s
//!   declared windows, and the `LastWindowPolicy`.

use waterui::app::App;
use waterui_backend_core::Environment;

/// Runs `app` on `env`, which the caller's `configure_environment!` already
/// built — the tail of `waterui_apple_main`. `accessory` selects the macOS
/// activation policy and is unused on iOS.
///
/// Never returns: both platforms end in their run loop.
///
/// # Safety
///
/// Call once, on the platform's main thread, as the process's entry. `env`
/// is lent to the fallback's services for the rest of the process, so the
/// caller's frame must live that long — this function does not return, which
/// is what guarantees it.
pub unsafe fn run(
    app: impl FnOnce(Environment) -> App + 'static,
    env: &mut Environment,
    accessory: bool,
) -> ! {
    let inspector = crate::startup::initialize();
    waterui::inspector::install(env, inspector);
    waterui::text::install_system_font_collection(env);
    crate::fonts::register_bundle_fonts();
    imp::launch(app, env, accessory)
}

#[cfg(target_os = "macos")]
mod imp {
    use alloc::boxed::Box;
    use alloc::rc::Rc;
    use core::any::Any;
    use core::cell::Cell;
    use core::ffi::c_void;

    use cocoa_ui::MainThreadMarker;
    use cocoa_ui::appkit::{
        ActivationPolicy, Application, ApplicationHandlers, ColorSchemeObservation,
    };
    use waterui::app::{App, LastWindowPolicy};
    use waterui_backend_core::Environment;

    use crate::theme::ThemeSignals;

    /// What the seam callback finishes the launch with — everything alive at
    /// launch-handler time that must live for the rest of the process, plus
    /// the user's `app` and the environment it runs under.
    struct Launch {
        app: Option<Box<dyn FnOnce(Environment) -> App>>,
        env: *mut Environment,
        _theme: Rc<ThemeSignals>,
        _appearance: ColorSchemeObservation,
        _locale: Box<dyn Any>,
        quit_on_last: Rc<Cell<bool>>,
    }

    /// The seam callback: the fallback's services are installed, so the
    /// window manager — which must win over the fallback's own —
    /// goes in now, then `app(env)` declares its windows.
    unsafe extern "C" fn prepared(context: *mut c_void) {
        let mtm = MainThreadMarker::new().expect("the seam callback runs on the main thread");
        // SAFETY: `context` is the `Launch` box `prepare_env` was given, and
        // the seam runs this callback exactly once.
        let mut launch = unsafe { Box::from_raw(context.cast::<Launch>()) };
        let app = launch
            .app
            .take()
            .expect("the seam callback must run exactly once");
        // SAFETY: `run` lent `env` for the process and never returned.
        let env = unsafe { &mut *launch.env };
        crate::windows::install_manager(env);
        let parts = app(env.clone()).into_parts();
        launch
            .quit_on_last
            .set(matches!(parts.last_window, LastWindowPolicy::Quit));
        if parts.windows.is_empty() {
            // A zero-window application acts on its policy at launch:
            // `Quit` terminates, `StayResident` keeps the process.
            if matches!(parts.last_window, LastWindowPolicy::Quit) {
                Application::shared(mtm).terminate();
            }
        } else {
            // Content renders under the environment `app` returned: its own
            // installs (`install_chromium`, `.state(..)` chains) landed as
            // overlays on the clone it was handed, which the host env cannot
            // see — `insert` never propagates between clones.
            let mut app_env = parts.env;
            // SAFETY: `prepared` runs on the main thread; `app_env` outlives
            // the call and the install borrows it only.
            unsafe {
                crate::seam::waterui_swift_install_webview(core::ptr::from_mut(&mut app_env));
            }
            for window in parts.windows {
                let host = crate::windows::realize(window, &app_env, mtm);
                crate::windows::track(host);
            }
        }
        // The theme signals, the appearance observation and the locale
        // observer must outlive the process; `app` is already consumed.
        core::mem::forget(launch);
    }

    pub fn launch(
        app: impl FnOnce(Environment) -> App + 'static,
        env: &mut Environment,
        accessory: bool,
    ) -> ! {
        let mtm = MainThreadMarker::new().expect("waterui_apple_main runs on the main thread");
        let application = Application::shared(mtm);
        // Best-effort: AppKit can refuse during early startup; the bundle's
        // Info.plist policy is the fallback.
        let _ = application.set_activation_policy(if accessory {
            ActivationPolicy::Accessory
        } else {
            ActivationPolicy::Regular
        });
        crate::menus::install_default(mtm, &application);

        let theme = Rc::new(crate::theme::install(env, application.color_scheme()));
        let appearance = application.observe_color_scheme({
            let theme = Rc::clone(&theme);
            move |scheme| crate::theme::refresh(&theme, scheme)
        });
        let locale = crate::locale::install(env, mtm);

        // Until `app(env)` reports its policy the answer is `Quit`'s: an
        // application that declares no window terminates at launch, which is
        // the default policy's prescription.
        let quit_on_last = Rc::new(Cell::new(true));
        let launch = Box::new(Launch {
            app: Some(Box::new(app)),
            env: core::ptr::from_mut(env),
            _theme: theme,
            _appearance: appearance,
            _locale: Box::new(locale),
            quit_on_last: Rc::clone(&quit_on_last),
        });

        let handlers = ApplicationHandlers::new()
            .did_finish_launching(move |_| {
                let env_ptr = launch.env;
                // SAFETY: `launch` is consumed by `prepared` exactly once —
                // this handler runs once — and `env` is `run`'s borrow, lent
                // for the process.
                unsafe {
                    crate::seam::waterui_swift_prepare_env(
                        env_ptr,
                        Box::into_raw(launch).cast::<c_void>(),
                        prepared,
                    );
                }
            })
            .should_terminate_after_last_window_closed(move |_| quit_on_last.get());
        application.run(handlers);
        std::process::exit(0);
    }
}

#[cfg(target_os = "ios")]
mod imp {
    use alloc::boxed::Box;
    use alloc::rc::Rc;
    use core::any::Any;
    use core::ffi::c_void;

    use cocoa_ui::MainThreadMarker;
    use cocoa_ui::uikit::{self, ApplicationHandlers};
    use waterui::app::App;
    use waterui_backend_core::Environment;

    use crate::theme::ThemeSignals;

    /// The same hand-off as macOS's `Launch`; the appearance side of the
    /// theme arrives per scene instead, through each controller's trait
    /// observation.
    struct Launch {
        app: Option<Box<dyn FnOnce(Environment) -> App>>,
        env: *mut Environment,
        _theme: Rc<ThemeSignals>,
        _locale: Box<dyn Any>,
    }

    /// The seam callback: `app(env)` declares its windows, and each fills
    /// the scene already waiting for it — or queues for the next connection.
    unsafe extern "C" fn prepared(context: *mut c_void) {
        let mtm = MainThreadMarker::new().expect("the seam callback runs on the main thread");
        // SAFETY: `context` is the `Launch` box `prepare_env` was given, and
        // the seam runs this callback exactly once.
        let mut launch = unsafe { Box::from_raw(context.cast::<Launch>()) };
        let app = launch
            .app
            .take()
            .expect("the seam callback must run exactly once");
        // SAFETY: `run` lent `env` for the process and never returned.
        let env = unsafe { &mut *launch.env };
        crate::windows::install_manager(env);
        let parts = app(env.clone()).into_parts();
        assert!(
            !parts.windows.is_empty(),
            "an iOS application must declare at least one window"
        );
        // Same hand-off as macOS: content renders under the env `app`
        // returned — its installs are invisible to the host env.
        let mut app_env = parts.env;
        // SAFETY: `prepared` runs on the main thread; `app_env` outlives
        // the call and the install borrows it only.
        unsafe {
            crate::seam::waterui_swift_install_webview(core::ptr::from_mut(&mut app_env));
        }
        crate::windows::declare(parts.windows, &app_env, mtm);
        core::mem::forget(launch);
    }

    pub fn launch(
        app: impl FnOnce(Environment) -> App + 'static,
        env: &mut Environment,
        _accessory: bool,
    ) -> ! {
        let mtm = MainThreadMarker::new().expect("waterui_apple_main runs on the main thread");

        let theme = Rc::new(crate::theme::install(
            env,
            cocoa_ui::uikit::current_scheme(),
        ));
        let locale = crate::locale::install(env, mtm);

        let launch = Box::new(Launch {
            app: Some(Box::new(app)),
            env: core::ptr::from_mut(env),
            _theme: Rc::clone(&theme),
            _locale: Box::new(locale),
        });

        // Scenes may connect before the asynchronous preparation finishes:
        // `connect` builds the platform window eagerly and the declaration
        // fills it when `prepared` lands.
        let scene_env = env.clone();
        let handlers = ApplicationHandlers::new(move |scene| {
            crate::windows::connect(scene, Rc::clone(&theme), &scene_env, mtm)
        })
        .did_finish_launching(move |_| {
            let env_ptr = launch.env;
            // SAFETY: `launch` is consumed by `prepared` exactly once, and
            // `env` is `run`'s borrow, lent for the process.
            unsafe {
                crate::seam::waterui_swift_prepare_env(
                    env_ptr,
                    Box::into_raw(launch).cast::<c_void>(),
                    prepared,
                );
            }
        });
        uikit::run(mtm, handlers)
    }
}
