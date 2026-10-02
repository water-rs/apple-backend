//! Native tests for the Rust `AppKit`/`UIKit` backend — real platform
//! objects, no visible windows, no application run loop.
//!
//! These cases create `NSView`/`NSWindow`/`UIView` objects, which
//! `MainThreadMarker`-protected APIs only allow on the process's actual
//! main thread. The stock harness runs cases on worker threads, so this
//! target is `harness = false`: [`libtest_mimic`] gives it the libtest CLI
//! that nextest enumerates (`--list`, `--exact`, one process per case), and
//! `test_threads = 1` makes it run every case on `main`, where
//! [`MainThreadMarker::new`] answers `Some`.
//!
//! Everything here goes through the backend's public typed surfaces —
//! `dispatch::install`/`dispatch::render`, `windows::bind_root_window`,
//! `contract::NativeLeaf` — plus the `cocoa-ui` kit API, so the suite
//! exercises exactly what a host embedding the backend could.

// The suite only exists on the crate's supported targets.
#![cfg(any(target_os = "macos", target_os = "ios"))]

use cocoa_ui::{MainThreadMarker, PlatformView, Retained};
use libtest_mimic::{Arguments, Trial};

#[cfg(target_os = "macos")]
use cocoa_ui::appkit::{HostView, Label};
#[cfg(target_os = "ios")]
use cocoa_ui::uikit::{HostView, Label};

fn main() {
    let mut args = Arguments::from_args();
    // `AppKit`/`UIKit` objects may only be built on the real main thread;
    // `run` executes sequentially in the calling thread at one thread.
    args.test_threads = Some(1);
    libtest_mimic::run(&args, trials()).exit();
}

fn trials() -> Vec<Trial> {
    let tests = vec![
        Trial::test("leaf::mount_attaches_and_unmount_detaches", || {
            leaf::mount_attaches_and_unmount_detaches();
            Ok(())
        }),
        Trial::test("leaf::dropping_mounted_detaches_the_view", || {
            leaf::dropping_mounted_detaches_the_view();
            Ok(())
        }),
        Trial::test("leaf::bind_applies_now_and_on_every_change", || {
            leaf::bind_applies_now_and_on_every_change();
            Ok(())
        }),
        Trial::test("leaf::mounting_installs_the_intrinsic_measure", || {
            leaf::mounting_installs_the_intrinsic_measure();
            Ok(())
        }),
        Trial::test("leaf::a_layout_pass_applies_the_handler_frame", || {
            leaf::a_layout_pass_applies_the_handler_frame();
            Ok(())
        }),
        Trial::test("resolve::unit_view_maps_to_a_hidden_empty_host", || {
            resolve::unit_view_maps_to_a_hidden_empty_host();
            Ok(())
        }),
        Trial::test("resolve::a_string_maps_to_the_text_leaf", || {
            resolve::a_string_maps_to_the_text_leaf();
            Ok(())
        }),
        Trial::test("resolve::spacer_maps_to_a_stretching_host", || {
            resolve::spacer_maps_to_a_stretching_host();
            Ok(())
        }),
        Trial::test("resolve::opacity_metadata_wraps_the_child", || {
            resolve::opacity_metadata_wraps_the_child();
            Ok(())
        }),
        Trial::test("resolve::an_unclaimed_metadata_view_panics", || {
            resolve::an_unclaimed_metadata_view_panics();
            Ok(())
        }),
        Trial::test("resolve::ignorable_metadata_renders_its_content", || {
            resolve::ignorable_metadata_renders_its_content();
            Ok(())
        }),
        Trial::test("resolve::a_native_with_fallback_resolves_to_it", || {
            resolve::a_native_with_fallback_resolves_to_it();
            Ok(())
        }),
        Trial::test(
            "resolve::unclaimed_wrappers_panic_while_claimed_render",
            || {
                resolve::unclaimed_wrappers_panic_while_claimed_render();
                Ok(())
            },
        ),
        Trial::test(
            "signals::watch_sees_updates_but_not_the_present_value",
            || {
                signals::watch_sees_updates_but_not_the_present_value();
                Ok(())
            },
        ),
        Trial::test("signals::a_watcher_receives_every_update_in_order", || {
            signals::a_watcher_receives_every_update_in_order();
            Ok(())
        }),
        Trial::test("signals::dropping_the_leaf_cancels_its_watchers", || {
            signals::dropping_the_leaf_cancels_its_watchers();
            Ok(())
        }),
    ];
    #[cfg(target_os = "ios")]
    let tests = {
        let mut tests = tests;
        tests.extend([
            Trial::test("uikit::list_cells_give_nested_text_real_frames", || {
                uikit_surface::list_cells_give_nested_text_real_frames();
                Ok(())
            }),
            Trial::test("uikit::text_field_renders_plain_with_a_real_height", || {
                uikit_surface::text_field_renders_plain_with_a_real_height();
                Ok(())
            }),
            Trial::test(
                "uikit::list_row_height_pitches_and_respects_the_floor",
                || {
                    uikit_surface::list_row_height_pitches_and_respects_the_floor();
                    Ok(())
                },
            ),
            Trial::test("uikit::compact_split_shows_the_sidebar", || {
                uikit_surface::compact_split_shows_the_sidebar();
                Ok(())
            }),
        ]);
        tests
    };
    #[cfg(all(target_os = "macos", feature = "native-test-support"))]
    let tests = {
        let mut tests = tests;
        tests.extend([
            Trial::test("window::manager_installs_into_the_environment", || {
                window::manager_installs_into_the_environment(mtm());
                Ok(())
            }),
            Trial::test("window::bind_root_window_wires_a_live_window", || {
                window::bind_root_window_wires_a_live_window(mtm());
                Ok(())
            }),
        ]);
        tests
    };
    tests
}

/// The marker the whole suite builds objects under — the real one, on the
/// thread `main` runs on.
fn mtm() -> MainThreadMarker {
    MainThreadMarker::new().expect("the custom harness runs cases on the process's main thread")
}

/// `NativeLeaf` mount/watch/bind against real views.
mod leaf {
    use waterui::reactive::binding;
    use waterui_apple::contract::NativeLeaf;
    use waterui_core::layout::{ProposalSize, Size, StretchAxis, SubView, ViewDimensions};

    use super::{HostView, Label, MainThreadMarker, PlatformView, mtm};

    /// A fixed-size leaf: the smallest `SubView` the mount path needs.
    pub(super) struct TestSubView;

    impl SubView for TestSubView {
        fn measure(&self, _proposal: ProposalSize) -> ViewDimensions {
            ViewDimensions::new(Size::new(40.0, 20.0))
        }

        fn stretch_axis(&self) -> StretchAxis {
            StretchAxis::None
        }

        fn priority(&self) -> i32 {
            0
        }
    }

    /// Mounting adds the leaf's view to the parent's subview list, and the
    /// returned `Mounted`'s `unmount` detaches it again and hands the leaf
    /// back for reuse.
    pub fn mount_attaches_and_unmount_detaches() {
        let mtm = mtm();
        let parent = HostView::new(mtm, cocoa_ui::Rect::new(0.0, 0.0, 200.0, 100.0));
        let child = HostView::new(mtm, cocoa_ui::Rect::ZERO);
        let leaf = NativeLeaf::new(&*child, TestSubView);
        let mounted = leaf.mount(&parent);
        assert_eq!(cocoa_ui::view::subviews(&parent).len(), 1);
        let leaf = mounted.unmount();
        assert!(cocoa_ui::view::superview(leaf.view()).is_none());
        assert_eq!(cocoa_ui::view::subviews(&parent).len(), 0);
    }

    /// Dropping a `Mounted` — how a container releases a replaced child —
    /// detaches the view from its superview before releasing the leaf.
    pub fn dropping_mounted_detaches_the_view() {
        let mtm = mtm();
        let parent = HostView::new(mtm, cocoa_ui::Rect::new(0.0, 0.0, 200.0, 100.0));
        let child = Label::new(mtm);
        let child_view: &PlatformView = &child;
        let mounted = NativeLeaf::new(child_view, TestSubView).mount(&parent);
        let view = cocoa_ui::view::retain_base(mounted.view());
        drop(mounted);
        assert!(cocoa_ui::view::superview(&view).is_none());
    }

    /// `bind` applies the current value immediately and every later write —
    /// the path every reactive property takes into its platform object.
    pub fn bind_applies_now_and_on_every_change() {
        let mtm = mtm();
        let host = HostView::new(mtm, cocoa_ui::Rect::ZERO);
        let mut leaf = NativeLeaf::new(&*host, TestSubView);
        let target = cocoa_ui::view::retain_base(leaf.view());
        let flag = binding(false);
        leaf.bind(&flag, move |value| {
            cocoa_ui::view::set_hidden(&target, value);
        });
        assert!(!cocoa_ui::view::is_hidden(&host));
        flag.set(true);
        assert!(cocoa_ui::view::is_hidden(&host));
    }

    /// A `HostView` leaf mirrors its layout face onto the view's intrinsic
    /// measure only once mounted — before it, the view answers exactly what
    /// an unattached kit host answers.
    #[expect(
        clippy::float_cmp,
        reason = "the fixture's size is an exact constant the platform returns unchanged"
    )]
    pub fn mounting_installs_the_intrinsic_measure() {
        let mtm = mtm();
        let parent = HostView::new(mtm, cocoa_ui::Rect::new(0.0, 0.0, 200.0, 100.0));
        let unattached = HostView::new(mtm, cocoa_ui::Rect::ZERO);
        let child = HostView::new(mtm, cocoa_ui::Rect::ZERO);
        let leaf = NativeLeaf::new(&*child, TestSubView);
        assert_eq!(
            cocoa_ui::view::fitting_size(leaf.view()),
            cocoa_ui::view::fitting_size(&unattached)
        );
        let _mounted = leaf.mount(&parent);
        let fitting = cocoa_ui::view::fitting_size(&child);
        assert_eq!(fitting.width, 40.0);
        assert_eq!(fitting.height, 20.0);
    }

    /// A host inside a real (never shown) window runs its layout pass, and
    /// the handler's frames land on the children — the bridge every
    /// container leans on.
    #[expect(
        clippy::float_cmp,
        reason = "the asserted frame fields are exact constants the platform stores verbatim"
    )]
    pub fn a_layout_pass_applies_the_handler_frame() {
        let mtm = mtm();
        let host = HostView::new(mtm, cocoa_ui::Rect::new(0.0, 0.0, 200.0, 100.0));
        let child = HostView::new(mtm, cocoa_ui::Rect::ZERO);
        let mounted = NativeLeaf::new(&*child, TestSubView).mount(&host);
        let child_view = cocoa_ui::view::retain_base(mounted.view());
        host.set_layout_handler(move |host| {
            let host_view: &PlatformView = host;
            cocoa_ui::view::set_frame(&child_view, cocoa_ui::view::bounds(host_view));
        });
        let _window = attach(mtm, &host);
        host.set_needs_layout();
        host.layout_if_needed();
        // `set_content_view` resizes the host to the window's content
        // area, so the expected child frame is the host's real bounds —
        // the handler must land that frame verbatim.
        let expected = cocoa_ui::view::bounds(&host);
        let frame = cocoa_ui::view::frame(mounted.view());
        assert_eq!(frame.size.width, expected.size.width);
        assert_eq!(frame.size.height, expected.size.height);
    }

    /// Puts `content` inside a real window that is never ordered in — the
    /// smallest environment in which the frameworks still run their full
    /// layout path.
    #[cfg(target_os = "macos")]
    fn attach(mtm: MainThreadMarker, content: &PlatformView) -> cocoa_ui::appkit::Window {
        let window = cocoa_ui::appkit::Window::new(
            mtm,
            cocoa_ui::Rect::new(0.0, 0.0, 640.0, 480.0),
            cocoa_ui::appkit::WindowStyle::TITLED | cocoa_ui::appkit::WindowStyle::CLOSABLE,
        );
        window.set_content_view(content);
        window
    }

    /// `UIKit` does not need a scene for `layoutSubviews` to run; the
    /// window exists so `window`-dependent paths see a real one.
    #[cfg(target_os = "ios")]
    fn attach(
        mtm: MainThreadMarker,
        content: &PlatformView,
    ) -> cocoa_ui::Retained<cocoa_ui::objc2_ui_kit::UIWindow> {
        use cocoa_ui::objc2_ui_kit::UIWindow;
        use objc2::{MainThreadOnly, msg_send};

        // SAFETY: `initWithFrame:` is `UIWindow`'s plain initializer and
        // `mtm` proves the main-thread confinement the harness provides.
        let window: cocoa_ui::Retained<UIWindow> = unsafe {
            msg_send![
                UIWindow::alloc(mtm),
                initWithFrame: objc2_core_foundation::CGRect::new(
                    objc2_core_foundation::CGPoint::new(0.0, 0.0),
                    objc2_core_foundation::CGSize::new(390.0, 844.0),
                )
            ]
        };
        window.addSubview(content);
        window
    }
}

/// View → leaf mapping through `dispatch::render` — the typed entry point
/// a host reaches. A view nobody claims panics (there is no foreign caller
/// to hand it back to), so a spurious empty render could not masquerade as
/// a pass.
mod resolve {
    use waterui::filter::Opacity;
    use waterui::layout::Spacer;
    use waterui::reactive::{SignalExt, binding};
    use waterui_apple::contract::NativeLeaf;
    use waterui_backend_core::{AnyView, Environment, View};
    use waterui_core::layout::{ProposalSize, Size, StretchAxis};
    use waterui_core::metadata::MetadataKey;
    use waterui_core::{IgnorableMetadata, Metadata, Native, NativeView};

    use super::{HostView, Label, Retained, mtm};

    /// A `Metadata` key no handler is registered for — an honest miss,
    /// never fabricated.
    struct Unregistered;

    impl MetadataKey for Unregistered {}

    /// A `NativeView` no handler is registered for.
    struct UnclaimedNative;

    impl NativeView for UnclaimedNative {}

    /// The minimum environment a real render needs: `dispatch::install`
    /// performs the backend's half of the embedding contract (dispatcher,
    /// window manager, realizations); the theme slots text resolves
    /// through are the framework's.
    pub(super) fn env() -> Environment {
        use waterui::graphics::color::WorkingColor;
        use waterui::text::font::{Body, Caption, FontSlot, Subheadline};

        let mut env = Environment::new();
        waterui_apple::dispatch::install(&mut env);
        waterui::theme::install_color_scheme(
            &mut env,
            binding(waterui::theme::ColorScheme::Light).computed(),
        );
        let black = || binding(WorkingColor::BLACK).computed();
        waterui::theme::install_color_signal::<waterui::theme::color::Foreground>(
            &mut env,
            black(),
        );
        // The richer fixtures (list rows, stacked text) resolve muted and
        // accent roles plus the caption/subheadline slots — install them so
        // a theme miss can't masquerade as a render failure.
        waterui::theme::install_color_signal::<waterui::theme::color::MutedForeground>(
            &mut env,
            black(),
        );
        waterui::theme::install_color_signal::<waterui::theme::color::Accent>(&mut env, black());
        waterui::theme::install_font_signal::<Body>(&mut env, binding(Body::DEFAULT).computed());
        waterui::theme::install_font_signal::<Caption>(
            &mut env,
            binding(Caption::DEFAULT).computed(),
        );
        waterui::theme::install_font_signal::<Subheadline>(
            &mut env,
            binding(Subheadline::DEFAULT).computed(),
        );
        env
    }

    /// Renders `view` through the typed dispatch entry point, main thread,
    /// fresh env. Panics when nothing claims the view — the typed
    /// contract's answer to a miss.
    pub(super) fn render(view: impl View) -> NativeLeaf {
        let _mtm = mtm();
        waterui_apple::dispatch::render(AnyView::new(view), &env())
    }

    /// Renders `view`, reporting whether `render` panicked instead of
    /// producing a leaf — for the cases asserting the miss path itself.
    fn render_or_panic(view: impl View) -> Option<NativeLeaf> {
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| render(view))).ok()
    }

    /// `()` lands as a hidden `HostView` that measures zero and answers
    /// `is_empty` — the leaf a stack ignores.
    pub fn unit_view_maps_to_a_hidden_empty_host() {
        let leaf = render(());
        let view = cocoa_ui::view::retain_base(leaf.view());
        assert!(view.downcast_ref::<HostView>().is_some());
        assert!(cocoa_ui::view::is_hidden(&view));
        assert!(leaf.layout().is_empty());
        assert_eq!(
            leaf.layout()
                .measure(ProposalSize::new(Some(100.0), Some(100.0)))
                .size,
            Size::new(0.0, 0.0)
        );
    }

    /// A `&'static str` expands `Str` → `Native<Str>` → the text leaf: a
    /// `HostView` wrapper holding a real kit `Label` with the string's
    /// attributed text on it — and the layout face still answers measure.
    pub fn a_string_maps_to_the_text_leaf() {
        let leaf = render("hello waterui");
        let view = cocoa_ui::view::retain_base(leaf.view());
        assert!(view.downcast_ref::<HostView>().is_some());
        assert!(!cocoa_ui::view::is_hidden(&view));
        let subviews = cocoa_ui::view::subviews(&view);
        assert_eq!(subviews.len(), 1);
        let label = subviews[0]
            .downcast_ref::<Label>()
            .expect("the text leaf mounts a kit label");
        let text = label
            .source_text()
            .expect("the label carries attributed text");
        assert_eq!(text.string().to_string(), "hello waterui");
        let measured = leaf.layout().measure(ProposalSize::UNSPECIFIED);
        assert!(measured.size.width > 0.0);
        assert!(measured.size.height > 0.0);
    }

    /// `Native<Spacer>` maps to a transparent host whose layout face
    /// stretches on the enclosing stack's main axis.
    pub fn spacer_maps_to_a_stretching_host() {
        let leaf = render(Spacer::new(12.0));
        let view = cocoa_ui::view::retain_base(leaf.view());
        assert!(view.downcast_ref::<HostView>().is_some());
        assert!(!cocoa_ui::view::is_hidden(&view));
        assert_eq!(leaf.layout().stretch_axis(), StretchAxis::MainAxis);
        assert_eq!(leaf.layout().priority(), i32::MIN);
    }

    /// `Metadata<Opacity>` is claimed by its handler: the wrapper is a
    /// `HostView` at the declared alpha with the content mounted inside.
    #[expect(
        clippy::float_cmp,
        reason = "the declared alpha lands on `alphaValue` unmodified"
    )]
    pub fn opacity_metadata_wraps_the_child() {
        let leaf = render(Metadata::new((), Opacity::new(0.5)));
        let view = cocoa_ui::view::retain_base(leaf.view());
        assert_eq!(cocoa_ui::view::alpha(&view), 0.5);
        let subviews = cocoa_ui::view::subviews(&view);
        assert_eq!(subviews.len(), 1);
        let primary = cocoa_ui::view::primary_content(&view)
            .expect("the wrapper forwards its primary content");
        assert_eq!(Retained::as_ptr(&primary), Retained::as_ptr(&subviews[0]));
    }

    /// A `Metadata` nobody claims panics in `body()` — on the typed
    /// contract there is no seam to catch it and hand the view back, so
    /// the panic propagates out of `render` itself.
    pub fn an_unclaimed_metadata_view_panics() {
        assert!(render_or_panic(Metadata::new((), Unregistered)).is_none());
    }

    /// `IgnorableMetadata` is transparent: its `body()` returns the
    /// content, so an unregistered key renders through to the content's
    /// leaf.
    pub fn ignorable_metadata_renders_its_content() {
        let leaf = render(IgnorableMetadata::new((), Unregistered));
        let view = cocoa_ui::view::retain_base(leaf.view());
        assert!(view.downcast_ref::<HostView>().is_some());
        assert!(cocoa_ui::view::is_hidden(&view));
    }

    /// `Native::with_fallback` is the honest port of "not claimed here":
    /// the dispatcher expands to the embedded fallback and resolves it —
    /// here, to the spacer host — inside the one `render` call.
    pub fn a_native_with_fallback_resolves_to_it() {
        let leaf = render(Native::new(UnclaimedNative).with_fallback(Spacer::new(8.0)));
        let view = cocoa_ui::view::retain_base(leaf.view());
        assert!(view.downcast_ref::<HostView>().is_some());
        assert_eq!(leaf.layout().stretch_axis(), StretchAxis::MainAxis);
    }

    /// The typed equivalent of the seam's `needs_fallback` probe: a view
    /// whose `body()` panics — `Metadata`/`Native` wrappers nobody claims
    /// — propagates the panic out of `render`; composable views resolve.
    pub fn unclaimed_wrappers_panic_while_claimed_render() {
        assert!(render_or_panic(Metadata::new((), Unregistered)).is_none());
        assert!(render_or_panic(Native::new(UnclaimedNative)).is_none());
        render(());
        render(Spacer::new(8.0));
        render(IgnorableMetadata::new((), Unregistered));
    }
}

/// Window lifecycle on a real, never-shown `NSWindow` — only reachable
/// because the harness runs on the true main thread, which is the only
/// place `-[NSWindow init]` is legal. The assertion bodies live in the
/// crate's `native-test-support` feature, which owns the private reach
/// into `windows` and `embedding`.
#[cfg(all(target_os = "macos", feature = "native-test-support"))]
mod window {
    pub use waterui_apple::native_test_support::{
        bind_root_window_wires_a_live_window, manager_installs_into_the_environment,
    };
}

/// Signal subscription semantics at the typed contract — the native
/// equivalents of the removed C-wire `WuiSignal`/`WuiCancellation` cases:
/// `leaf.watch` registers without delivering the current value, updates
/// arrive synchronously in order, and dropping the leaf (the guard's
/// owner) is the cancellation.
mod signals {
    use std::cell::RefCell;
    use std::rc::Rc;

    use waterui::reactive::binding;
    use waterui_apple::contract::NativeLeaf;

    use super::leaf::TestSubView;
    use super::{HostView, mtm};

    /// `watch` subscribes without replaying the present value — the first
    /// call is the first `set`. (Initial delivery is `bind`'s contract,
    /// asserted by `leaf::bind_applies_now_and_on_every_change`.)
    pub fn watch_sees_updates_but_not_the_present_value() {
        let mtm = mtm();
        let host = HostView::new(mtm, cocoa_ui::Rect::ZERO);
        let mut leaf = NativeLeaf::new(&*host, TestSubView);
        let flag = binding(false);
        let seen = Rc::new(RefCell::new(Vec::new()));
        {
            let seen = Rc::clone(&seen);
            leaf.watch(&flag, move |ctx| seen.borrow_mut().push(ctx.into_value()));
        }
        assert!(
            seen.borrow().is_empty(),
            "watch fired before any change was written"
        );
        flag.set(true);
        assert_eq!(*seen.borrow(), vec![true]);
    }

    /// Updates arrive synchronously inside `set`, in write order, to every
    /// watcher — several updates in a row all land.
    pub fn a_watcher_receives_every_update_in_order() {
        let mtm = mtm();
        let host = HostView::new(mtm, cocoa_ui::Rect::ZERO);
        let mut leaf = NativeLeaf::new(&*host, TestSubView);
        let counter = binding(0_i32);
        let seen = Rc::new(RefCell::new(Vec::new()));
        {
            let seen = Rc::clone(&seen);
            leaf.watch(&counter, move |ctx| {
                seen.borrow_mut().push(ctx.into_value());
            });
        }
        for value in [1, 2, 3] {
            counter.set(value);
            // synchronous: the write's watcher has already run
            assert_eq!(seen.borrow().last(), Some(&value));
        }
        assert_eq!(*seen.borrow(), vec![1, 2, 3]);
    }

    /// Dropping the leaf drops the watcher guards it keeps — the cancel /
    /// deinit contract: a write after the leaf is gone reaches nobody.
    pub fn dropping_the_leaf_cancels_its_watchers() {
        let mtm = mtm();
        let host = HostView::new(mtm, cocoa_ui::Rect::ZERO);
        let flag = binding(false);
        let seen = Rc::new(RefCell::new(Vec::new()));
        {
            let mut leaf = NativeLeaf::new(&*host, TestSubView);
            {
                let seen = Rc::clone(&seen);
                leaf.watch(&flag, move |ctx| {
                    seen.borrow_mut().push(ctx.into_value());
                });
            }
            flag.set(true);
            drop(leaf);
        }
        flag.set(false);
        assert_eq!(
            *seen.borrow(),
            vec![true],
            "a dropped leaf's watchers must not be reached"
        );
    }
}

/// `UIKit` render assertions — ports of the hosted `WaterUITests` cases
/// that introspected a running app's view tree. The typed contract makes
/// the same tree reachable in-process: `dispatch::render` hands back the
/// leaf, and mounting it into a real `UIWindow` gives it the trait
/// collections and layout the hosted app gave it.
#[cfg(target_os = "ios")]
mod uikit_surface {
    use cocoa_ui::objc2::MainThreadOnly;
    use cocoa_ui::objc2_core_foundation::{CGPoint, CGRect, CGSize};
    use cocoa_ui::objc2_ui_kit::{
        UITableView, UITableViewCell, UITextBorderStyle, UITextField, UIWindow,
    };
    use waterui::Str;
    use waterui::component::list::{List, ListItem};
    use waterui::prelude::theme_color::{Accent, Foreground};
    use waterui::prelude::*;
    use waterui::reactive::binding;
    use waterui::shape::Circle;
    use waterui_backend_core::AnyView;

    use super::{PlatformView, Retained, mtm};

    /// Every descendant of `view`, depth-first — the hosted suite's tree
    /// walk, here over the leaf's own view.
    fn descendants(view: &PlatformView) -> Vec<Retained<PlatformView>> {
        let mut all = Vec::new();
        let mut stack = cocoa_ui::view::subviews(view);
        while let Some(next) = stack.pop() {
            stack.extend(cocoa_ui::view::subviews(&next));
            all.push(next);
        }
        all
    }

    /// A never-shown 393×852 window — the compact-width host the hosted
    /// suite ran inside. Adding views into it gives real trait
    /// collections without any run loop or key window.
    #[expect(
        deprecated,
        reason = "a test process has no UIWindowScene to attach; the frame \
                  initializer is the only way to host views offscreen"
    )]
    fn compact_host() -> Retained<UIWindow> {
        let mtm = mtm();
        let frame = CGRect::new(CGPoint::ZERO, CGSize::new(393.0, 852.0));
        UIWindow::initWithFrame(UIWindow::alloc(mtm), frame)
    }

    /// Lays the window out and returns the first `UITableView` found at
    /// or inside `root` — the list leaf's view may be the table itself.
    fn laid_out_table(window: &UIWindow, root: &PlatformView) -> Retained<UITableView> {
        window.layoutIfNeeded();
        // A frame applied mid-pass does not re-run the leaf's own layout
        // handler; a second pass guarantees interior frames settle.
        cocoa_ui::view::layout_immediately(root);
        core::iter::once(cocoa_ui::view::retain_base(root))
            .chain(descendants(root))
            .find_map(|view| view.downcast::<UITableView>().ok())
            .expect("the list leaf mounts a UITableView")
    }

    /// The device fixture's row: `Label` wrapping
    /// `hstack(icon, vstack(hstack(text, spacer, flag), text, text))` —
    /// the nested-stack shape whose inner text lost its frames.
    fn message_row(sender: &'static str, subject: &'static str, preview: &'static str) -> ListItem {
        ListItem::new(Label::new(
            Str::from(format!("{sender}: {subject}")),
            move || {
                hstack((
                    hstack((Accent.size(8.0, 8.0).clip(Circle),)).size(8.0, 8.0),
                    vstack((
                        hstack((
                            text(sender).sub_headline().foreground(Foreground),
                            spacer(),
                            text("flag").caption().muted(),
                        ))
                        .spacing(6.0),
                        text(subject).body().foreground(Foreground),
                        text(preview).caption().muted(),
                    ))
                    .leading()
                    .spacing(2.0),
                ))
                .top()
                .spacing(6.0)
                .padding_vertical(8.0)
            },
        ))
    }

    /// The hosted list: five of the nested-stack rows, the same content
    /// `IOSTestHost` packages for the device lane.
    fn inbox() -> impl View {
        List::content((
            || {
                message_row(
                    "Ada Lovelace",
                    "WaterUI render loop",
                    "The nested vstack inside this row must paint its text.",
                )
            },
            || {
                message_row(
                    "Grace Hopper",
                    "List cell layout",
                    "Three lines sit in a vstack nested in the row's hstack.",
                )
            },
            || {
                message_row(
                    "Edsger Dijkstra",
                    "Placement proposals",
                    "Every nested stack receives the width its parent proposes.",
                )
            },
            || {
                message_row(
                    "Barbara Liskov",
                    "Substitution",
                    "Cells measure correctly; their text must render too.",
                )
            },
            || {
                message_row(
                    "Margaret Hamilton",
                    "Priority display",
                    "Zero-width frames are the regression this fixture guards.",
                )
            },
        ))
    }

    /// Materialized cells' nested text views all carry real frames inside
    /// their cell — the hosted `nestedStack` regression case.
    pub fn list_cells_give_nested_text_real_frames() {
        let mtm = mtm();
        let env = super::resolve::env();
        let (host, mounted) = waterui_apple::native_test_support::mount_uikit(
            mtm,
            AnyView::new(inbox()),
            &env,
            cocoa_ui::Rect::new(0.0, 0.0, 393.0, 852.0),
        );
        let window = compact_host();
        cocoa_ui::view::add_subview(&window, &host);
        let table = laid_out_table(&window, mounted.view());
        let cells = table.visibleCells();
        assert!(
            cells.count() >= 4,
            "expected the list to materialize at least four cells"
        );
        let cell = cells
            .objectAtIndex(0)
            .downcast::<UITableViewCell>()
            .expect("visible cells are UITableViewCell");
        let mut labels = 0_u32;
        let cell_view: &PlatformView = &cell;
        for view in descendants(&cell.contentView()) {
            if view.downcast_ref::<cocoa_ui::uikit::Label>().is_some() {
                labels += 1;
                let frame =
                    cocoa_ui::view::convert_rect(&view, view.bounds().into(), Some(cell_view));
                assert!(
                    frame.size.width > 0.0 && frame.size.height > 0.0,
                    "a nested text view has an empty frame inside its cell"
                );
                let bounds = cell.bounds();
                assert!(
                    frame.origin.x < bounds.origin.x + bounds.size.width
                        && frame.origin.x + frame.size.width > bounds.origin.x
                        && frame.origin.y < bounds.origin.y + bounds.size.height
                        && frame.origin.y + frame.size.height > bounds.origin.y,
                    "a nested text view's frame escapes its cell"
                );
            }
        }
        assert!(
            labels >= 3,
            "the row's nested stacks should carry at least three text views, found {labels}"
        );
    }

    /// A `TextField` resolves to the kit's `UITextField` in plain
    /// configuration — `.none` border, a clear background — and its
    /// laid-out height at width 402 tracks a live reference: the
    /// intrinsic height a fresh `UITextField` reports for the same
    /// width, the same metric the hosted suite read off a real
    /// `UIHostingController`.
    pub fn text_field_renders_plain_with_a_real_height() {
        let mtm = mtm();
        let value = binding(Str::from("seed"));
        let env = super::resolve::env();
        let (host, mounted) = waterui_apple::native_test_support::mount_uikit(
            mtm,
            AnyView::new(TextField::new("Field", &value)),
            &env,
            // Tall enough that the compact window's top safe-area inset
            // still leaves the field's real height inside the content frame.
            cocoa_ui::Rect::new(0.0, 0.0, 402.0, 852.0),
        );
        let window = compact_host();
        cocoa_ui::view::add_subview(&window, &host);
        window.layoutIfNeeded();
        cocoa_ui::view::layout_immediately(&host);
        cocoa_ui::view::layout_immediately(mounted.view());
        let field = descendants(mounted.view())
            .into_iter()
            .find_map(|view| view.downcast::<cocoa_ui::uikit::TextField>().ok())
            .expect("the text field leaf mounts the kit UITextField");
        assert_eq!(field.borderStyle(), UITextBorderStyle::None);
        assert!(
            field.backgroundColor().is_none(),
            "a plain field keeps a clear background"
        );
        // The live reference the hosted case compared against: the
        // field's own intrinsic height for a 402pt proposal, measured
        // on this runtime — the leaf must lay the component out at the
        // height the component itself reports, not collapsed or
        // stretched.
        let reference_height = field.sizeThatFits(CGSize::new(402.0, f64::INFINITY)).height;
        let laid_out = field.frame().size.height;
        assert!(
            (laid_out - reference_height).abs() <= 0.5,
            "laid-out height {laid_out} must match the live {reference_height} reference"
        );
    }

    /// Row pitch: equal rows get equal heights; a `.list_min_row_height`
    /// floor bigger than the content wins; the hosted content is inset
    /// inside the cell, not edge-to-edge.
    pub fn list_row_height_pitches_and_respects_the_floor() {
        let mtm = mtm();
        let env = super::resolve::env();
        let (host, mounted) = waterui_apple::native_test_support::mount_uikit(
            mtm,
            AnyView::new(
                List::content((
                    || ListItem::new(text("first")),
                    || ListItem::new(text("second")),
                ))
                .list_min_row_height(40.0),
            ),
            &env,
            cocoa_ui::Rect::new(0.0, 0.0, 393.0, 852.0),
        );
        let window = compact_host();
        cocoa_ui::view::add_subview(&window, &host);
        let table = laid_out_table(&window, mounted.view());
        let cells = table.visibleCells();
        assert!(cells.count() >= 2, "two rows materialize");
        let first: Retained<UITableViewCell> = cells
            .objectAtIndex(0)
            .downcast::<UITableViewCell>()
            .expect("visible cells are UITableViewCell");
        let second: Retained<UITableViewCell> = cells
            .objectAtIndex(1)
            .downcast::<UITableViewCell>()
            .expect("visible cells are UITableViewCell");
        let first_height = first.frame().size.height;
        let second_height = second.frame().size.height;
        assert!(
            (first_height - second_height).abs() < 0.5,
            "equal rows pitch equal heights ({first_height} vs {second_height})"
        );
        assert!(
            first_height >= 40.0,
            "the declared 40pt floor wins over shorter content"
        );
        let content = cocoa_ui::view::subviews(&first.contentView());
        assert!(!content.is_empty(), "the cell hosts rendered row content");
        let hosted = &content[0];
        let first_view: &PlatformView = &first;
        let hosted_frame =
            cocoa_ui::view::convert_rect(hosted, hosted.bounds().into(), Some(first_view));
        assert!(
            hosted_frame.origin.x > 0.0,
            "the row content is inset from the cell edge, not edge-to-edge"
        );
    }

    /// A compact-width `NavigationSplitView` collapses, and the column on
    /// the window is the sidebar — `set_collapsed_top_column(Primary)`
    /// under the hood.
    pub fn compact_split_shows_the_sidebar() {
        use cocoa_ui::objc2_ui_kit::{UISplitViewController, UISplitViewControllerColumn};
        use waterui::navigation::{NavigationSplitView, NavigationView};

        let selection = binding(Option::<i32>::None);
        let split = NavigationSplitView::new(&selection, text("Sidebar"), |id: i32| {
            NavigationView::new(format!("Detail {id}"), text("detail"))
        });
        let mtm = mtm();
        let env = super::resolve::env();
        let (host, mounted) = waterui_apple::native_test_support::mount_uikit(
            mtm,
            AnyView::new(split),
            &env,
            cocoa_ui::Rect::new(0.0, 0.0, 393.0, 852.0),
        );
        let window = compact_host();
        cocoa_ui::view::add_subview(&window, &host);
        window.layoutIfNeeded();

        // The split's controller owns a descendant view — ask every view
        // in the leaf's tree for its enclosing controller until the
        // `UISplitViewController` answers.
        let controller = core::iter::once(cocoa_ui::view::retain_base(mounted.view()))
            .chain(descendants(mounted.view()))
            .find_map(|view| {
                cocoa_ui::uikit::view_controller::enclosing_controller(&view)
                    .and_then(|vc| vc.downcast::<UISplitViewController>().ok())
            })
            .expect("the split leaf owns a UISplitViewController");
        assert!(
            controller.isCollapsed(),
            "a 393pt window collapses the split"
        );
        let sidebar = controller
            .viewControllerForColumn(UISplitViewControllerColumn::Primary)
            .expect("the primary column has a controller");
        assert!(
            sidebar
                .view()
                .expect("the sidebar column's view is loaded")
                .window()
                .is_some(),
            "the collapsed split shows the sidebar column"
        );
        let detail = controller
            .viewControllerForColumn(UISplitViewControllerColumn::Secondary)
            .expect("the secondary column has a controller");
        let detail_visible = detail
            .view()
            .map(|view| view.window().is_some())
            .unwrap_or(false);
        assert!(
            !detail_visible,
            "the collapsed split does not show the detail column"
        );
    }
}
