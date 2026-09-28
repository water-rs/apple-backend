//! `waterui-apple` — the `WaterUI` backend for Apple platforms.
//!
//! This crate owns the application's root on macOS and iOS: the executors,
//! the `Environment`, the system locale, the GPU runtime hand-off, the
//! services the rendered tree needs, the theme installs, font registration,
//! and the realization of the app's windows and (on macOS) menu bar — the
//! work `WuiRootContext` performs today in Swift. Views are dispatched in
//! Rust through [`dispatch`]; components this crate does not yet own cross
//! the [`seam`] to the Swift fallback, which renders them through the same
//! package as before.
//!
//! The generated application crate calls `export_app!`, which emits the
//! `waterui_apple_main` entry point. `main.swift` in the Xcode target is a
//! one-line call into it.
//!
//! # Safety
//!
//! The `unsafe` in this crate serves the seam: views, environments and
//! leaves cross the boundary as opaque pointers whose ownership rules the
//! declarations in [`seam`] spell out. Everything on the Rust side of the
//! boundary is ordinary safe Rust, and the platform side goes through
//! `cocoa-ui`, which is safe.

extern crate alloc;

pub mod contract;
pub mod dispatch;
pub mod seam;

pub(crate) mod components;
pub(crate) mod registry;
