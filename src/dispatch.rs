//! The view dispatcher: walks an [`AnyView`] until a registered handler or
//! the Swift fallback claims it.
//!
//! Composition expands first — a view that is not claimed runs `body()` and
//! the walk continues on the result — so handlers always see the type the
//! tree ends on: `Native<C>` for native payloads, `Metadata<M>` /
//! `IgnorableMetadata<M>` for wrappers, or any composer type a handler
//! registers directly. A `Native<C>`/`Metadata<M>` nobody claims crosses the
//! seam to [`waterui_swift_render`].

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use core::any::TypeId;

use waterui_backend_core::{AnyView, Environment, View};
use waterui_core::layout::SubView;

use crate::contract::{NativeLeaf, RenderContext};
use crate::seam;

/// One claim in the dispatch table: the handler and the claimed type's name,
/// kept for the seam's disjointness check.
type Handler = Box<dyn Fn(AnyView, &mut RenderContext<'_>) -> NativeLeaf>;

/// The dispatch table. Built once at startup by [`crate::registry`], then
/// immutable: children register through it, it is never written after
/// handlers could run.
pub(crate) struct Dispatcher {
    handlers: BTreeMap<TypeId, (Handler, &'static str)>,
}

#[expect(
    clippy::non_send_fields_in_send_ty,
    reason = "handlers run on the main thread only, proven by the MainThreadMarker every call path carries"
)]
// SAFETY: every entry point that can reach a handler carries a
// `MainThreadMarker`, so handlers run on the main thread only — a captured
// non-`Send`/`Sync` value (a `Binding`, an `Rc`) is never touched elsewhere.
// The table is frozen after `registry::install`, and `Dispatcher` is
// `pub(crate)`, so no call path can invoke it off the main thread.
unsafe impl Send for Dispatcher {}
// SAFETY: same main-thread contract as `Send` above.
unsafe impl Sync for Dispatcher {}

impl Dispatcher {
    /// An empty table; [`crate::registry`] fills it.
    pub(crate) fn new() -> Self {
        Self {
            handlers: BTreeMap::new(),
        }
    }

    /// Claims `Native<C>`: a native payload the handler renders into a
    /// platform view.
    ///
    /// Called by [`crate::registry`]; unused until the first port lands.
    #[expect(dead_code, reason = "the registration table fills as ports land")]
    ///
    /// The handler receives the payload itself — the wrapper is downcast and
    /// unwrapped for it. Registering `C` here is how a component port owns a
    /// leaf: `TextField`'s `Native<ResolvedTextFieldConfig>`,
    /// `Native<Spacer>`, `Native<FixedContainer>`, and every other
    /// `raw_view!`/`configurable!` payload.
    pub(crate) fn register_native<C: waterui_core::NativeView + 'static>(
        &mut self,
        handler: impl Fn(C, &mut RenderContext<'_>) -> NativeLeaf + 'static,
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
        self.handlers.insert(
            TypeId::of::<waterui_backend_core::Native<C>>(),
            (wrapped, core::any::type_name::<C>()),
        );
    }

    /// Claims `T` exactly as it appears in the view tree: a metadata wrapper
    /// (`Metadata<M>`, `IgnorableMetadata<M>`), or a composer the port takes
    /// before `body()` expands it.
    ///
    /// Called by [`crate::registry`]; unused until the first port lands.
    #[expect(dead_code, reason = "the registration table fills as ports land")]
    ///
    /// A transparent handler typically owns no platform view of its own: it
    /// applies `T`'s effect (an environment overlay, an attribute on the
    /// child's platform view) and returns the leaf its child rendered.
    pub(crate) fn register_transparent<T: 'static>(
        &mut self,
        handler: impl Fn(T, &mut RenderContext<'_>) -> NativeLeaf + 'static,
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
        self.handlers
            .insert(TypeId::of::<T>(), (wrapped, core::any::type_name::<T>()));
    }

    /// The handler claiming `type_id`, if any.
    fn handler(&self, type_id: TypeId) -> Option<&Handler> {
        self.handlers.get(&type_id).map(|(handler, _)| handler)
    }

    /// Renders `view` under `env` into the platform view it becomes.
    ///
    /// The walk: a registered handler claims the view; otherwise it expands
    /// through `body()`; a `Native<T>`/`Metadata<T>` that no handler claims
    /// crosses to the fallback. Returns `None` only when the fallback itself
    /// declines the view.
    pub(crate) fn render(
        &self,
        view: AnyView,
        env: &Environment,
        mtm: cocoa_ui::MainThreadMarker,
    ) -> Option<NativeLeaf> {
        let mut view = view;
        let mut ctx = RenderContext::new(env, self, mtm);
        loop {
            let type_id = view.type_id();
            if let Some(handler) = self.handler(type_id) {
                return Some(handler(view, &mut ctx));
            }
            if needs_fallback(&view) {
                #[cfg(debug_assertions)]
                seam::assert_disjoint();
                // SAFETY: the seam contract hands ownership of both boxes
                // across; the returned leaf is owned by this call.
                let leaf = unsafe {
                    seam::waterui_swift_render(
                        Box::into_raw(Box::new(view)),
                        Box::into_raw(Box::new(env.clone())),
                    )
                };
                if leaf.is_null() {
                    return None;
                }
                // SAFETY: a non-null leaf is owned by this call.
                let leaf = unsafe { *Box::from_raw(leaf) };
                return Some(NativeLeaf::borrowed(leaf.view, leaf.subview));
            }
            view = AnyView::new(view.body(env));
        }
    }

    /// The same walk for a view crossing the seam *from* Swift — the
    /// `waterui_apple_render` entry. The fallback already failed to claim
    /// it, so a `Native`/`Metadata` here is a double miss and answers `None`
    /// rather than recursing the seam.
    pub(crate) fn render_across_seam(
        &self,
        view: AnyView,
        env: &Environment,
        mtm: cocoa_ui::MainThreadMarker,
    ) -> Option<NativeLeaf> {
        let mut view = view;
        let mut ctx = RenderContext::new(env, self, mtm);
        loop {
            let type_id = view.type_id();
            if let Some(handler) = self.handler(type_id) {
                return Some(handler(view, &mut ctx));
            }
            if needs_fallback(&view) {
                return None;
            }
            view = AnyView::new(view.body(env));
        }
    }
}

/// Whether the erased view is a wrapper whose `body()` must not run — a
/// `Native<T>` or a `Metadata<T>` — meaning it crosses the seam (or, across
/// the seam already, is a miss).
fn needs_fallback(view: &AnyView) -> bool {
    let name = view.name();
    name.starts_with("waterui_core::components::native::Native<")
        || name.starts_with("waterui_core::components::metadata::Metadata<")
}

/// The process-wide dispatcher, built once by [`crate::registry`].
pub(crate) fn dispatcher() -> &'static Dispatcher {
    static DISPATCHER: std::sync::OnceLock<Dispatcher> = std::sync::OnceLock::new();
    DISPATCHER.get_or_init(|| {
        let mut dispatcher = Dispatcher::new();
        crate::registry::install(&mut dispatcher);
        dispatcher
    })
}

/// The type names this dispatcher claims — the seam's disjointness check
/// compares them against the fallback's table.
#[cfg(debug_assertions)]
pub(crate) fn claimed_type_names() -> impl Iterator<Item = &'static str> {
    dispatcher().handlers.values().map(|(_, name)| *name)
}

/// What `render_across_seam`'s answer wires into the C ABI.
pub(crate) struct SeamLeaf {
    /// A retained platform view, erased.
    pub(crate) view: *mut core::ffi::c_void,
    /// The leaf's layout face.
    pub(crate) subview: Box<dyn SubView>,
}

/// A leaf's layout face that owns the whole leaf: the platform view's
/// retain and every watcher guard ride inside the wire `SubView`, so the
/// leaf stays alive exactly as long as the other side measures through it.
struct SeamOwned(NativeLeaf);

impl SubView for SeamOwned {
    fn measure(
        &self,
        proposal: waterui_core::layout::ProposalSize,
    ) -> waterui_core::layout::ViewDimensions {
        self.0.subview.measure(proposal)
    }

    fn stretch_axis(&self) -> waterui_core::layout::StretchAxis {
        self.0.subview.stretch_axis()
    }

    fn priority(&self) -> i32 {
        self.0.subview.priority()
    }

    fn is_empty(&self) -> bool {
        self.0.subview.is_empty()
    }
}

/// Renders a view crossing the seam *from* Swift — the body of
/// [`crate::seam::waterui_apple_render`]. Runs on the main thread: that is a
/// caller requirement of the seam contract.
pub(crate) fn render_across_seam(view: AnyView, env: &Environment) -> Option<SeamLeaf> {
    let mtm = cocoa_ui::MainThreadMarker::new().expect("seam renders run on the main thread");
    dispatcher()
        .render_across_seam(view, env, mtm)
        .map(|leaf| SeamLeaf {
            view: leaf.platform_view(),
            subview: Box::new(SeamOwned(leaf)),
        })
}
