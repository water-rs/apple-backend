//! The application object and the events of its life.
//!
//! # Safety
//!
//! The `unsafe` here defines the application delegate class and initializes
//! it. The delegate's methods have the signatures `NSApplicationDelegate`
//! declares, `AppKit` sends them on the main thread, and the delegate stays
//! alive for as long as the application runs with it, because
//! [`Application::run`] owns it for that long.

use std::cell::Cell;
use std::fmt;

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
use objc2_app_kit::{NSApplication, NSApplicationActivationPolicy, NSApplicationDelegate};
use objc2_foundation::{NSNotification, NSObject, NSObjectProtocol};

use super::menu::Menu;
use crate::callback::guarded;

/// How the application presents itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ActivationPolicy {
    /// An ordinary application, with a Dock icon, a menu bar and windows.
    Regular,
    /// No Dock icon and no menu bar of its own, but it can show windows and
    /// be activated by clicking one.
    Accessory,
    /// Never activated and never shown: a process that runs headless.
    Prohibited,
}

impl ActivationPolicy {
    const fn native(self) -> NSApplicationActivationPolicy {
        match self {
            Self::Regular => NSApplicationActivationPolicy::Regular,
            Self::Accessory => NSApplicationActivationPolicy::Accessory,
            Self::Prohibited => NSApplicationActivationPolicy::Prohibited,
        }
    }
}

type OnceHandler = Box<dyn FnOnce(MainThreadMarker)>;
type QueryHandler = Box<dyn Fn(MainThreadMarker) -> bool>;

/// What the application does at each point of its life, given to
/// [`Application::run`].
///
/// Every handler is optional; an event without one gets `AppKit`'s default
/// behaviour.
#[derive(Default)]
#[must_use = "handlers do nothing until they are passed to `Application::run`"]
pub struct ApplicationHandlers {
    did_finish_launching: Option<OnceHandler>,
    should_terminate_after_last_window_closed: Option<QueryHandler>,
    will_terminate: Option<OnceHandler>,
}

impl ApplicationHandlers {
    /// Handlers for no event.
    pub fn new() -> Self {
        Self::default()
    }

    /// Runs `handler` once the application has launched and is about to
    /// handle its first event: the place to create the first windows.
    pub fn did_finish_launching(
        mut self,
        handler: impl FnOnce(MainThreadMarker) + 'static,
    ) -> Self {
        self.did_finish_launching = Some(Box::new(handler));
        self
    }

    /// Asks `handler`, when the user closes the last window, whether the
    /// application should quit. Without a handler it keeps running.
    pub fn should_terminate_after_last_window_closed(
        mut self,
        handler: impl Fn(MainThreadMarker) -> bool + 'static,
    ) -> Self {
        self.should_terminate_after_last_window_closed = Some(Box::new(handler));
        self
    }

    /// Runs `handler` once, just before the application quits.
    pub fn will_terminate(mut self, handler: impl FnOnce(MainThreadMarker) + 'static) -> Self {
        self.will_terminate = Some(Box::new(handler));
        self
    }
}

impl fmt::Debug for ApplicationHandlers {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ApplicationHandlers")
            .field("did_finish_launching", &self.did_finish_launching.is_some())
            .field(
                "should_terminate_after_last_window_closed",
                &self.should_terminate_after_last_window_closed.is_some(),
            )
            .field("will_terminate", &self.will_terminate.is_some())
            .finish()
    }
}

/// The process's application object.
#[derive(Debug, Clone)]
pub struct Application {
    app: Retained<NSApplication>,
}

impl Application {
    /// The application object, created on first use.
    #[must_use]
    pub fn shared(mtm: MainThreadMarker) -> Self {
        Self {
            app: NSApplication::sharedApplication(mtm),
        }
    }

    /// Sets how the application presents itself.
    ///
    /// # Panics
    ///
    /// If `AppKit` refuses the policy.
    pub fn set_activation_policy(&self, policy: ActivationPolicy) {
        assert!(
            self.app.setActivationPolicy(policy.native()),
            "AppKit refused the activation policy {policy:?}"
        );
    }

    /// Makes `menu` the menu bar: each of its items is one top-level menu,
    /// and the first is the application menu.
    pub fn set_main_menu(&self, menu: &Menu) {
        self.app.setMainMenu(Some(menu.native()));
    }

    /// Makes `menu` the Services menu, which the system fills with the
    /// services that apply to the current selection.
    pub fn set_services_menu(&self, menu: &Menu) {
        self.app.setServicesMenu(Some(menu.native()));
    }

    /// Makes `menu` the Window menu, which the system extends with an item
    /// for every open window.
    pub fn set_windows_menu(&self, menu: &Menu) {
        self.app.setWindowsMenu(Some(menu.native()));
    }

    /// Runs the application's event loop, calling `handlers` as its events
    /// occur, until the application stops.
    ///
    /// An application that quits exits the process from inside this call;
    /// it returns only when the loop is stopped without quitting.
    pub fn run(&self, handlers: ApplicationHandlers) {
        let delegate = Delegate::new(self.app.mtm(), handlers);
        self.app
            .setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
        self.app.run();
        self.app.setDelegate(None);
    }

    pub(super) fn native(&self) -> &NSApplication {
        &self.app
    }
}

struct DelegateIvars {
    did_finish_launching: Cell<Option<OnceHandler>>,
    should_terminate_after_last_window_closed: Option<QueryHandler>,
    will_terminate: Cell<Option<OnceHandler>>,
}

define_class!(
    // SAFETY: `NSObject` has no subclassing requirements, and the class does
    // not implement `Drop`.
    #[unsafe(super(NSObject))]
    #[name = "WaterUIAppleKitApplicationDelegate"]
    #[thread_kind = MainThreadOnly]
    #[ivars = DelegateIvars]
    struct Delegate;

    // SAFETY: `NSObjectProtocol` asks nothing of an `NSObject` subclass.
    unsafe impl NSObjectProtocol for Delegate {}

    // SAFETY: see the module safety note.
    unsafe impl NSApplicationDelegate for Delegate {
        #[unsafe(method(applicationDidFinishLaunching:))]
        fn application_did_finish_launching(&self, _notification: &NSNotification) {
            guarded("applicationDidFinishLaunching:", || {
                if let Some(handler) = self.ivars().did_finish_launching.take() {
                    handler(self.mtm());
                }
            });
        }

        #[unsafe(method(applicationShouldTerminateAfterLastWindowClosed:))]
        fn application_should_terminate_after_last_window_closed(
            &self,
            _sender: &NSApplication,
        ) -> bool {
            guarded("applicationShouldTerminateAfterLastWindowClosed:", || {
                self.ivars()
                    .should_terminate_after_last_window_closed
                    .as_ref()
                    .is_some_and(|handler| handler(self.mtm()))
            })
        }

        #[unsafe(method(applicationWillTerminate:))]
        fn application_will_terminate(&self, _notification: &NSNotification) {
            guarded("applicationWillTerminate:", || {
                if let Some(handler) = self.ivars().will_terminate.take() {
                    handler(self.mtm());
                }
            });
        }
    }
);

impl Delegate {
    fn new(mtm: MainThreadMarker, handlers: ApplicationHandlers) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(DelegateIvars {
            did_finish_launching: Cell::new(handlers.did_finish_launching),
            should_terminate_after_last_window_closed: handlers
                .should_terminate_after_last_window_closed,
            will_terminate: Cell::new(handlers.will_terminate),
        });
        // SAFETY: `init` is `NSObject`'s designated initializer.
        unsafe { msg_send![super(this), init] }
    }
}
