//! The view dispatcher: walks an [`AnyView`] until a registered handler or
//! the Swift fallback claims it.
//!
//! Composition expands first — a view that is not claimed runs `body()` and
//! the walk continues on the result — so handlers always see the type the
//! tree ends on: `Native<C>` for native payloads, `Metadata<M>` /
//! `IgnorableMetadata<M>` for wrappers, or any composer type a handler
//! registers directly. A `Native<C>`/`Metadata<M>` that no handler claims
//! crosses the seam to [`waterui_swift_render`].

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
#[cfg(debug_assertions)]
use alloc::vec::Vec;
use core::any::TypeId;
use core::fmt;

use cocoa_ui::{PlatformView, Retained};
use dispatch2::MainThreadBound;
use waterui_backend_core::{AnyView, Environment, View};

use crate::contract::{NativeLeaf, RenderContext};
use crate::seam;

/// The handler signature every port implements: the erased view downcast to
/// the claimed type, the render context, the leaf it becomes.
pub(crate) type Handler = Box<dyn Fn(AnyView, &RenderContext<'_>) -> NativeLeaf>;

/// The dispatch table. Built once at startup by [`crate::registry`], then
/// immutable: children register through it, it is never written after
/// handlers could run.
pub(crate) struct Dispatcher {
    handlers: BTreeMap<TypeId, Handler>,
    /// The claimed type's name per registered type, for the seam's debug
    /// disjointness check; release builds store none.
    #[cfg(debug_assertions)]
    names: Vec<&'static str>,
}

impl fmt::Debug for Dispatcher {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut output = f.debug_struct("Dispatcher");
        output.field("handlers", &self.handlers.len());
        #[cfg(debug_assertions)]
        output.field("names", &self.names);
        output.finish()
    }
}

impl Dispatcher {
    /// An empty table; [`crate::registry`] fills it.
    pub(crate) fn new() -> Self {
        Self {
            handlers: BTreeMap::new(),
            #[cfg(debug_assertions)]
            names: Vec::new(),
        }
    }

    /// Claims `Native<C>`: a native payload the handler renders into a
    /// platform view.
    ///
    /// The handler receives the payload itself — the wrapper is downcast and
    /// unwrapped for it. Registering `C` here is how a component port owns a
    /// leaf: `TextField`'s `Native<ResolvedTextFieldConfig>`,
    /// `Native<Spacer>`, `Native<FixedContainer>`, and every other
    /// `raw_view!`/`configurable!` payload.
    pub(crate) fn register_native<C: waterui_core::NativeView + 'static>(
        &mut self,
        handler: impl Fn(C, &RenderContext<'_>) -> NativeLeaf + 'static,
    ) {
        let wrapped: Handler = Box::new(move |view, ctx| {
            let native = view
                .downcast::<waterui_backend_core::Native<C>>()
                .unwrap_or_else(|_| {
                    panic!(
                        "dispatcher claimed {} but the erased view was not one",
                        core::any::type_name::<C>()
                    )
                });
            handler(native.into_inner(), ctx)
        });
        self.handlers
            .insert(TypeId::of::<waterui_backend_core::Native<C>>(), wrapped);
        // The name the fallback's registry keys is the erased view's own:
        // `Native<C>`, not `C`.
        #[cfg(debug_assertions)]
        self.names
            .push(core::any::type_name::<waterui_backend_core::Native<C>>());
    }

    /// Claims `T` exactly as it appears in the view tree: a metadata wrapper
    /// (`Metadata<M>`, `IgnorableMetadata<M>`), or a composer the port takes
    /// before `body()` expands it.
    ///
    /// A `register_view` handler typically owns no platform view of its own:
    /// it applies `T`'s effect (an environment overlay, an attribute on the
    /// child's platform view) and returns the leaf its child rendered.
    pub(crate) fn register_view<T: 'static>(
        &mut self,
        handler: impl Fn(T, &RenderContext<'_>) -> NativeLeaf + 'static,
    ) {
        let wrapped: Handler = Box::new(move |view, ctx| {
            let typed = view.downcast::<T>().unwrap_or_else(|_| {
                panic!(
                    "dispatcher claimed {} but the erased view was not one",
                    core::any::type_name::<T>()
                )
            });
            handler(*typed, ctx)
        });
        self.handlers.insert(TypeId::of::<T>(), wrapped);
        #[cfg(debug_assertions)]
        self.names.push(core::any::type_name::<T>());
    }

    /// The handler claiming `type_id`, if any.
    fn handler(&self, type_id: TypeId) -> Option<&Handler> {
        self.handlers.get(&type_id)
    }

    /// Renders `view` under `env` into the platform view it becomes.
    ///
    /// The walk: a registered handler claims the view; otherwise it expands
    /// through `body()`; a `Native<T>`/`Metadata<T>` that no handler claims
    /// crosses to the fallback. Returns `None` only when the fallback itself
    /// declines the view.
    pub(crate) fn render(
        &'static self,
        view: AnyView,
        env: &Environment,
        mtm: cocoa_ui::MainThreadMarker,
    ) -> Option<NativeLeaf> {
        let mut view = view;
        let ctx = RenderContext::new(env, self, mtm);
        loop {
            let type_id = view.type_id();
            if let Some(handler) = self.handler(type_id) {
                return Some(handler(view, &ctx));
            }
            if needs_fallback(&view) {
                #[cfg(debug_assertions)]
                seam::assert_disjoint(mtm);
                // SAFETY: the seam contract hands ownership of both boxes
                // across; the returned leaf is owned by this call.
                let leaf = unsafe {
                    seam::waterui_swift_render(
                        Box::into_raw(Box::new(view)),
                        Box::into_raw(Box::new(env.clone())),
                    )
                };
                if leaf.view.is_null() {
                    return None;
                }
                // SAFETY: a non-null `view` is the +1 reference the seam
                // contract hands this call.
                let view = unsafe { Retained::from_raw(leaf.view.cast::<PlatformView>()) }
                    .expect("a non-null seam view is a retained platform view");
                return Some(NativeLeaf::from_seam(view, leaf.subview));
            }
            view = AnyView::new(view.body(env));
        }
    }

    /// The same walk for a view crossing the seam *from* Swift — the
    /// `waterui_apple_resolve` entry. The fallback already failed to claim
    /// it, so a `Native`/`Metadata` here is a double miss — unless it
    /// expands, which [`SeamResolution::Expand`] reports for the caller to
    /// re-walk.
    pub(crate) fn render_across_seam(
        &'static self,
        view: AnyView,
        env: &Environment,
        mtm: cocoa_ui::MainThreadMarker,
    ) -> SeamResolution {
        let mut view = view;
        let ctx = RenderContext::new(env, self, mtm);
        loop {
            let type_id = view.type_id();
            if let Some(handler) = self.handler(type_id) {
                return SeamResolution::Claimed(handler(view, &ctx));
            }
            if needs_fallback(&view) {
                // A `Native` carrying `with_fallback` still expands through
                // `body()` — the embedded view is its backend-agnostic
                // realization. A bare `Native`/`Metadata` panics, which
                // `catch_unwind` reports as a miss.
                let expanded = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    AnyView::new(view.body(env))
                }));
                return expanded.map_or(SeamResolution::Miss, SeamResolution::Expand);
            }
            view = AnyView::new(view.body(env));
        }
    }
}

/// The outcome of rendering a view that crossed the seam from Swift.
pub(crate) enum SeamResolution {
    /// A registered handler claimed the view; mount the leaf.
    Claimed(NativeLeaf),
    /// The view was an unclaimed `Native` that expands to its embedded
    /// `with_fallback` view — the caller re-walks the expansion.
    Expand(AnyView),
    /// Neither side claims the view and it cannot expand.
    Miss,
}

/// Whether the erased view is a wrapper whose `body()` must not run — a
/// `Native<T>` or a `Metadata<T>` — meaning it crosses the seam (or, across
/// the seam already, is a miss).
///
/// The check matches `type_name` prefixes, which is not a stable format:
/// the test below pins the ones in use.
pub(crate) fn needs_fallback(view: &AnyView) -> bool {
    let name = view.name();
    name.starts_with("waterui_core::components::native::Native<")
        || name.starts_with("waterui_core::components::metadata::Metadata<")
}

/// The process-wide dispatcher, built once by [`crate::registry`]; only
/// reachable on the main thread.
pub(crate) fn dispatcher(mtm: cocoa_ui::MainThreadMarker) -> &'static Dispatcher {
    static DISPATCHER: std::sync::OnceLock<MainThreadBound<Dispatcher>> =
        std::sync::OnceLock::new();
    DISPATCHER
        .get_or_init(|| {
            let mut dispatcher = Dispatcher::new();
            crate::registry::install(&mut dispatcher);
            MainThreadBound::new(dispatcher, mtm)
        })
        .get(mtm)
}

/// The type names this dispatcher claims — the seam's disjointness check
/// compares them against the fallback's table.
#[cfg(debug_assertions)]
pub(crate) fn claimed_type_names(
    mtm: cocoa_ui::MainThreadMarker,
) -> impl Iterator<Item = &'static str> {
    dispatcher(mtm).names.iter().copied()
}

/// Renders a view crossing the seam *from* Swift — the body of
/// [`crate::seam::waterui_apple_resolve`]. Runs on the main thread: that is a
/// caller requirement of the seam contract.
pub(crate) fn render_across_seam(view: AnyView, env: &Environment) -> SeamResolution {
    let mtm = cocoa_ui::MainThreadMarker::new().expect("seam renders run on the main thread");
    dispatcher(mtm).render_across_seam(view, env, mtm)
}

#[cfg(test)]
mod tests {
    use waterui_core::metadata::MetadataKey;
    use waterui_core::{Metadata, Native, NativeView};

    struct TestNative;
    impl NativeView for TestNative {}
    struct TestKey;
    impl MetadataKey for TestKey {}

    /// `needs_fallback` pattern-matches `type_name` output; if `Native` or
    /// `Metadata` move, every unclaimed wrapper would run a panicking
    /// `body()` — this pins the module paths the prefixes assume.
    #[test]
    fn type_name_prefixes_hold() {
        assert!(
            core::any::type_name::<Native<TestNative>>()
                .starts_with("waterui_core::components::native::Native<"),
            "Native's type_name moved; update needs_fallback"
        );
        assert!(
            core::any::type_name::<Metadata<TestKey>>()
                .starts_with("waterui_core::components::metadata::Metadata<"),
            "Metadata's type_name moved; update needs_fallback"
        );
    }
}
