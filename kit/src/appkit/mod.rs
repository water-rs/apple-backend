//! `AppKit`, the user-interface framework of macOS.
//!
//! A macOS application is one [`Application`] run with
//! [`ApplicationHandlers`]: when it finishes launching, the handler creates
//! [`Window`]s and puts a [`HostView`] in each. The main menu is a [`Menu`] of
//! [`MenuItem`]s whose [`MenuAction`]s travel the responder chain.
//!
//! ```no_run
//! use std::cell::RefCell;
//! use std::rc::Rc;
//!
//! use waterui_apple_kit::appkit::{
//!     Application, ApplicationHandlers, HostView, Window, WindowStyle,
//! };
//! use waterui_apple_kit::{MainThreadMarker, Rect};
//!
//! let mtm = MainThreadMarker::new().expect("main runs on the main thread");
//! let windows = Rc::new(RefCell::new(Vec::new()));
//! let launched = Rc::clone(&windows);
//! Application::shared(mtm).run(
//!     ApplicationHandlers::new()
//!         .did_finish_launching(move |mtm| {
//!             let window = Window::new(mtm, Rect::new(0.0, 0.0, 800.0, 600.0), WindowStyle::all());
//!             window.set_title("Hello");
//!             window.set_content_view(&HostView::new(mtm, window.content_rect()));
//!             window.center();
//!             window.make_key_and_order_front();
//!             launched.borrow_mut().push(window);
//!         })
//!         .should_terminate_after_last_window_closed(|_| true),
//! );
//! ```

mod appearance;
mod application;
mod host_view;
mod menu;
mod window;

pub use appearance::ColorSchemeObservation;
pub use application::{ActivationPolicy, Application, ApplicationHandlers};
pub use host_view::{HitTest, HostView};
pub use menu::{KeyModifiers, Menu, MenuAction, MenuItem};
pub use window::{Window, WindowStyle};
