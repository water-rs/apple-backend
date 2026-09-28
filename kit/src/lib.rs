//! A safe Rust API over Apple's user-interface frameworks: `AppKit` on macOS
//! and `UIKit` on iOS.
//!
//! The crate owns the parts of an application that the frameworks insist on
//! running themselves — the application object and its delegate, windows,
//! scenes, the view that hosts your content, and the system notifications
//! around them — and hands each of them to Rust as ordinary values and
//! closures. It knows nothing about any particular UI toolkit: what goes into
//! a window is the caller's business.
//!
//! # Platforms
//!
//! Where the two frameworks model the same thing differently, the crate keeps
//! them apart in twin modules, `appkit` on macOS and `uikit` on iOS, and
//! gives the twins the same names wherever the concept is the same:
//! both have a `HostView`, a `Window`, an
//! `ApplicationHandlers` and a `ColorSchemeObservation`. Only the lifecycle
//! differs in shape, because it differs on the platforms: a macOS application
//! creates its windows when it finishes launching, while an iOS application is
//! handed a window scene for every scene the system connects.
//!
//! What is the same on both platforms lives at the crate root: geometry,
//! notifications, locale, the main queue, font registration, the unified
//! log, the application bundle, and process timing.
//!
//! # Safety model
//!
//! The public API contains no `unsafe` function and no `msg_send!`; every
//! Objective-C contract is discharged inside the crate.
//!
//! * **Main thread.** Types the frameworks only allow on the main thread are
//!   created and used only with a [`MainThreadMarker`], which proves the
//!   calling thread is the main one. Nothing here is `Send` that the frameworks
//!   would not let cross threads.
//! * **Ownership.** Native objects are owned through [`Retained`], objc2's
//!   reference-counted pointer, so a Rust value keeps its object alive and
//!   releasing it is a drop. Closures a native object calls back are owned by
//!   that object and dropped with it; a closure the frameworks may release on
//!   another thread is dropped on the main thread.
//! * **Callbacks never unwind into Objective-C.** Every closure the frameworks
//!   call — a delegate event, a layout pass, an observer, work on the main
//!   queue — runs inside a guard that catches a panic, logs it through
//!   `tracing` at error level, and aborts the process. Unwinding through
//!   Objective-C frames is undefined behaviour, and a panicking callback has
//!   already left the interface in a state nothing can recover, so the
//!   process ends where the failure happened. Built with `panic = "abort"`,
//!   the panic aborts before the guard sees it, which has the same outcome.
//!
//! [`MainThreadMarker`]: objc2::MainThreadMarker
//! [`Retained`]: objc2::rc::Retained

#![cfg(any(target_os = "macos", target_os = "ios"))]

#[cfg(target_os = "macos")]
pub mod appkit;
pub mod bundle;
mod callback;
pub mod color_scheme;
pub mod core_animation;
pub mod fonts;
pub mod geometry;
pub mod locale;
pub mod log;
pub mod main_queue;
pub mod notification;
pub mod process;
#[cfg(target_os = "ios")]
pub mod uikit;

pub use color_scheme::ColorScheme;
pub use geometry::{EdgeInsets, Point, Rect, Size};
pub use objc2::MainThreadMarker;
pub use objc2::rc::Retained;
