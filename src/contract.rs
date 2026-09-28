//! The port contract every component handler compiles against.
//!
//! FROZEN: a component port may rely on exactly these items. Anything it needs
//! beyond them is a kit addition (a change to `cocoa-ui`, never a reactivity
//! type), not a change to this file.
//!
//! The model: the dispatcher walks an [`AnyView`]; each registered handler
//! claims a type and answers a [`NativeLeaf`] — a platform view plus the
//! layout face a container lays out with. A handler that wraps other views
//! renders its children through [`RenderContext::render`], mounts each
//! child's platform view inside its own, and keeps the child leaf — and
//! every watcher guard its reactivity needs — in [`KeepAlive`]. When the
//! leaf drops, the watchers stop and the platform object releases.

use alloc::boxed::Box;
use alloc::vec::Vec;
use core::any::Any;
use core::ffi::c_void;
use core::fmt;
use core::marker::PhantomData;

use waterui::reactive::Signal;
use waterui::reactive::watcher::Context;
use waterui_backend_core::{AnyView, Environment};
use waterui_core::layout::SubView;

#[cfg(target_os = "macos")]
use objc2::rc::Retained;
#[cfg(target_os = "ios")]
use objc2::rc::Retained;
#[cfg(target_os = "macos")]
use objc2_app_kit::NSView;
#[cfg(target_os = "ios")]
use objc2_ui_kit::UIView;

/// What a rendered component owns beyond its platform view.
///
/// Watcher guards, the platform objects they fire against, rendered child
/// leaves, and the environment clones an overlaid subtree resolves through.
/// Order matters: guards are stored before the views they observe, so a drop
/// stops the watchers before the objects they fire on go away.
#[derive(Default)]
pub struct KeepAlive(Vec<Box<dyn Any>>);

impl fmt::Debug for KeepAlive {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("KeepAlive")
            .field("held", &self.0.len())
            .finish()
    }
}

impl KeepAlive {
    /// Keeps `value` alive for the leaf's lifetime.
    pub fn keep(&mut self, value: impl Any) {
        self.0.push(Box::new(value));
    }

    /// Subscribes `watcher` to `signal` for the leaf's lifetime.
    ///
    /// The imperative kit call inside `watcher` is the whole reactivity
    /// story: signals never cross into the kit, so each change arrives here
    /// and is pushed to the platform object imperatively.
    pub fn watch<S: Signal>(&mut self, signal: &S, watcher: impl Fn(Context<S::Output>) + 'static) {
        self.keep(signal.watch(watcher));
    }
}

/// A rendered component: the platform view it owns and the layout face its
/// parent measures with.
///
/// `platform_view` is borrowed — the object is retained inside `keepalive`
/// by construction, so the view is alive for exactly as long as the leaf.
pub struct NativeLeaf {
    platform_view: *mut c_void,
    /// The leaf's layout face: how the parent measures and stretches it.
    pub subview: Box<dyn SubView>,
    keepalive: KeepAlive,
}

impl fmt::Debug for NativeLeaf {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NativeLeaf")
            .field("platform_view", &self.platform_view)
            .finish_non_exhaustive()
    }
}

impl NativeLeaf {
    /// Builds a leaf whose platform view is `view`, retaining it for the
    /// leaf's life.
    #[cfg(target_os = "macos")]
    pub fn new_appkit(view: Retained<NSView>, subview: impl SubView + 'static) -> Self {
        let platform_view = Retained::as_ptr(&view).cast::<c_void>().cast_mut();
        let mut keepalive = KeepAlive::default();
        keepalive.keep(view);
        Self {
            platform_view,
            subview: Box::new(subview),
            keepalive,
        }
    }

    /// Builds a leaf whose platform view is `view`, retaining it for the
    /// leaf's life.
    #[cfg(target_os = "ios")]
    pub fn new_uikit(view: Retained<UIView>, subview: impl SubView + 'static) -> Self {
        let platform_view = Retained::as_ptr(&view).cast::<c_void>().cast_mut();
        let mut keepalive = KeepAlive::default();
        keepalive.keep(view);
        Self {
            platform_view,
            subview: Box::new(subview),
            keepalive,
        }
    }

    /// A leaf whose lifetime is managed externally — the seam owns the
    /// platform object and its release. `platform_view` must outlive the
    /// leaf.
    pub(crate) fn borrowed(platform_view: *mut c_void, subview: impl SubView + 'static) -> Self {
        Self {
            platform_view,
            subview: Box::new(subview),
            keepalive: KeepAlive::default(),
        }
    }

    /// The platform view, as `AppKit` sees it.
    ///
    /// Borrowed from the leaf: mount it, lay it out, read it — the leaf
    /// releases it.
    #[cfg(target_os = "macos")]
    #[must_use]
    pub fn nsview(&self) -> &NSView {
        // SAFETY: `platform_view` is a live `NSView` for the leaf's lifetime —
        // either retained in `keepalive` or guaranteed by `borrowed`'s caller.
        unsafe { &*self.platform_view.cast::<NSView>() }
    }

    /// The platform view, as `UIKit` sees it.
    ///
    /// Borrowed from the leaf: mount it, lay it out, read it — the leaf
    /// releases it.
    #[cfg(target_os = "ios")]
    #[must_use]
    pub fn uiview(&self) -> &UIView {
        // SAFETY: `platform_view` is a live `UIView` for the leaf's lifetime —
        // either retained in `keepalive` or guaranteed by `borrowed`'s caller.
        unsafe { &*self.platform_view.cast::<UIView>() }
    }

    /// The erased platform view pointer, for seams and window mounts.
    #[must_use]
    pub const fn platform_view(&self) -> *mut c_void {
        self.platform_view
    }

    /// Keeps `value` — a watcher guard, a rendered child leaf, an
    /// environment clone — alive for this leaf's life.
    pub fn keep(&mut self, value: impl Any) {
        self.keepalive.keep(value);
    }

    /// Subscribes `watcher` to `signal` for this leaf's life.
    pub fn watch<S: Signal>(&mut self, signal: &S, watcher: impl Fn(Context<S::Output>) + 'static) {
        self.keepalive.watch(signal, watcher);
    }

    /// Splits the leaf for a host that manages the parts separately — a
    /// window that mounts the view, measures through the subview, and drops
    /// the rest with its own resources.
    ///
    /// Used by the window host; unused until the host lands.
    #[expect(dead_code, reason = "the window host lands with entry::run")]
    pub(crate) fn into_parts(self) -> (*mut c_void, Box<dyn SubView>, KeepAlive) {
        (self.platform_view, self.subview, self.keepalive)
    }
}

/// What a handler sees when it renders: the environment this subtree
/// resolves against and the dispatcher it renders children through.
///
/// Handlers run on the platform main thread; [`RenderContext::mtm`] proves
/// it to kit constructors that ask for one.
pub struct RenderContext<'a> {
    env: &'a Environment,
    dispatcher: &'a crate::dispatch::Dispatcher,
    mtm: cocoa_ui::MainThreadMarker,
    _marker: PhantomData<&'a ()>,
}

impl fmt::Debug for RenderContext<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RenderContext").finish_non_exhaustive()
    }
}

impl<'a> RenderContext<'a> {
    pub(crate) const fn new(
        env: &'a Environment,
        dispatcher: &'a crate::dispatch::Dispatcher,
        mtm: cocoa_ui::MainThreadMarker,
    ) -> Self {
        Self {
            env,
            dispatcher,
            mtm,
            _marker: PhantomData,
        }
    }

    /// The environment this subtree resolves against.
    #[must_use]
    pub const fn env(&self) -> &'a Environment {
        self.env
    }

    /// Proof of the main thread, for kit calls that require one.
    #[must_use]
    pub const fn mtm(&self) -> cocoa_ui::MainThreadMarker {
        self.mtm
    }

    /// Renders `view` into a leaf: registered handlers claim it, composers
    /// expand through `body()`, and anything the backend does not own yet
    /// crosses to the fallback.
    ///
    /// # Panics
    ///
    /// When the fallback also declines the view — the same contract
    /// `WuiAnyView` enforced with a fatal error.
    #[must_use]
    pub fn render(&self, view: impl Into<AnyView>) -> NativeLeaf {
        self.try_render(view)
            .expect("no handler and no fallback claim this view")
    }

    /// Renders `view`, answering `None` when nothing claims it.
    #[must_use]
    pub fn try_render(&self, view: impl Into<AnyView>) -> Option<NativeLeaf> {
        self.dispatcher.render(view.into(), self.env, self.mtm)
    }

    /// Renders `view` under a different environment.
    ///
    /// Metadata handlers overlay the environment for their subtree:
    /// `let mut env = ctx.env().clone(); env.insert(..); ctx.render_in(&env, content)`
    /// — and keep the clone in the leaf's [`KeepAlive`] when the subtree's
    /// signals may resolve through it after the handler returns.
    ///
    /// # Panics
    ///
    /// Same contract as [`RenderContext::render`]: when nothing claims the
    /// view.
    #[must_use]
    pub fn render_in(&self, env: &Environment, view: impl Into<AnyView>) -> NativeLeaf {
        self.dispatcher
            .render(view.into(), env, self.mtm)
            .expect("no handler and no fallback claim this view")
    }
}
