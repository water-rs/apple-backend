//! Native behavior migrated from the former Swift backend tests.

use crate::{HostView, mtm};
use libtest_mimic::Trial;

pub fn trials() -> Vec<Trial> {
    let tests = vec![
        Trial::test("migration::signals::silent_watch", || {
            signals::watch_sees_updates_but_not_the_present_value();
            Ok(())
        }),
        Trial::test("migration::signals::ordered_updates", || {
            signals::a_watcher_receives_every_update_in_order();
            Ok(())
        }),
        Trial::test("migration::signals::drop_cancels", || {
            signals::dropping_the_leaf_cancels_its_watchers();
            Ok(())
        }),
        Trial::test("migration::signals::independent_owners", || {
            signals::independent_owners();
            Ok(())
        }),
        Trial::test("migration::signals::owned_values", || {
            signals::owned_values();
            Ok(())
        }),
        Trial::test("migration::color::native_hdr_and_updates", || {
            colors::native_hdr_and_updates();
            Ok(())
        }),
        Trial::test("migration::color::srgb_known_values", || {
            colors::srgb_known_values();
            Ok(())
        }),
    ];
    #[cfg(target_os = "macos")]
    let tests = {
        let mut tests = tests;
        tests.push(Trial::test(
            "migration::color::native_well_round_trip",
            || {
                colors::native_well_round_trip();
                Ok(())
            },
        ));
        tests
    };
    #[cfg(target_os = "ios")]
    let tests = {
        let mut tests = tests;
        tests.extend([
            Trial::test("migration::uikit::nested_list_frames", || {
                uikit_surface::list_cells_give_nested_text_real_frames();
                Ok(())
            }),
            Trial::test("migration::uikit::plain_field_matches_swiftui", || {
                uikit_surface::text_field_renders_plain_with_a_real_height();
                Ok(())
            }),
            Trial::test("migration::uikit::list_chrome_matches_swiftui", || {
                uikit_surface::list_row_height_pitches_and_respects_the_floor();
                Ok(())
            }),
            Trial::test("migration::uikit::compact_split", || {
                uikit_surface::compact_split_shows_the_sidebar();
                Ok(())
            }),
        ]);
        tests
    };
    tests
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

    use super::{HostView, mtm};
    use crate::leaf::TestSubView;

    #[derive(Debug)]
    struct Released {
        id: i32,
        drops: Rc<RefCell<Vec<i32>>>,
    }

    impl Drop for Released {
        fn drop(&mut self) {
            self.drops.borrow_mut().push(self.id);
        }
    }

    pub fn independent_owners() {
        let host = HostView::new(mtm(), cocoa_ui::Rect::ZERO);
        let source = binding(5);
        let drops = Rc::new(RefCell::new(Vec::new()));
        let first_seen = Rc::new(RefCell::new(Vec::new()));
        let second_seen = Rc::new(RefCell::new(Vec::new()));
        let mut first = NativeLeaf::new(&*host, TestSubView);
        let mut second = NativeLeaf::new(&*host, TestSubView);
        for (id, leaf, seen) in [
            (1, &mut first, first_seen.clone()),
            (2, &mut second, second_seen.clone()),
        ] {
            let released = Released {
                id,
                drops: drops.clone(),
            };
            leaf.bind(&source, move |value| {
                // Capture the whole resource so the watcher owns its destructor.
                let _owned = &released;
                seen.borrow_mut().push(value);
            });
        }
        assert_eq!(*first_seen.borrow(), [5]);
        assert_eq!(*second_seen.borrow(), [5]);
        source.set(9);
        assert_eq!(*first_seen.borrow(), [5, 9]);
        assert_eq!(*second_seen.borrow(), [5, 9]);
        assert!(drops.borrow().is_empty());
        let mut first = Some(first);
        drop(first.take());
        drop(first.take());
        assert_eq!(*drops.borrow(), [1], "one owner releases exactly once");
        source.set(12);
        assert_eq!(
            *first_seen.borrow(),
            [5, 9],
            "removed watcher is never called"
        );
        assert_eq!(
            *second_seen.borrow(),
            [5, 9, 12],
            "other owner remains active"
        );
        drop(second);
        assert_eq!(*drops.borrow(), [1, 2]);
    }

    pub fn owned_values() {
        let host = HostView::new(mtm(), cocoa_ui::Rect::ZERO);
        let mut leaf = NativeLeaf::new(&*host, TestSubView);
        let drops = Rc::new(RefCell::new(Vec::new()));
        let value = |id| {
            Rc::new(Released {
                id,
                drops: drops.clone(),
            })
        };
        let source = binding(value(1));
        let displayed = Rc::new(RefCell::new(None));
        let target = displayed.clone();
        leaf.bind(&source, move |value| *target.borrow_mut() = Some(value));
        assert_eq!(displayed.borrow().as_ref().unwrap().id, 1);
        source.set(value(2));
        assert_eq!(
            *drops.borrow(),
            [1],
            "replacing releases the previous value"
        );
        source.set(value(3));
        assert_eq!(*drops.borrow(), [1, 2]);
        assert_eq!(displayed.borrow().as_ref().unwrap().id, 3);
        let weak = Rc::downgrade(&displayed);
        drop(displayed);
        assert!(weak.upgrade().is_some(), "binding owns its native target");
        drop(leaf);
        assert!(
            weak.upgrade().is_none(),
            "leaf destruction releases its target"
        );
        drop(source);
        assert_eq!(
            *drops.borrow(),
            [1, 2, 3],
            "final value releases exactly once"
        );
    }

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
    use cocoa_ui::objc2_core_foundation::{CGPoint, CGRect, CGSize};
    use cocoa_ui::objc2_ui_kit::{UILabel, UITableView, UITextBorderStyle};
    use waterui::Str;
    use waterui::component::list::{List, ListItem};
    use waterui::prelude::theme_color::{Accent, Foreground};
    use waterui::prelude::*;
    use waterui::reactive::binding;
    use waterui::shape::Circle;
    use waterui_backend_core::AnyView;

    use crate::{PlatformView, Retained, mtm};

    /// Every descendant of `view`, depth-first — the hosted suite's tree
    /// walk, here over the leaf's own view.
    fn descendants(view: &PlatformView) -> Vec<Retained<PlatformView>> {
        let mut all = Vec::new();
        let mut stack = vec![cocoa_ui::view::retain_base(view)];
        while let Some(next) = stack.pop() {
            stack.extend(cocoa_ui::view::subviews(&next));
            all.push(next);
        }
        all
    }

    fn table(root: &PlatformView) -> Retained<UITableView> {
        descendants(root)
            .into_iter()
            .find_map(|view| view.downcast::<UITableView>().ok())
            .expect("the list leaf mounts a UITableView")
    }

    fn reference(key: &str) -> f64 {
        let path = std::env::var("WATERUI_REFERENCE_METRICS")
            .expect("run prepare-native-reference.sh on this simulator first");
        let metrics: serde_json::Value = serde_json::from_slice(
            &std::fs::read(path).expect("read live SwiftUI reference metrics"),
        )
        .expect("valid reference metrics");
        metrics[key].as_f64().expect("reference metric exists")
    }

    fn close(actual: f64, expected: f64) {
        assert!(
            (actual - expected).abs() <= 0.5,
            "actual {actual} must match live platform reference {expected} within 0.5pt"
        );
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

    /// Every nonempty label in every visible cell retains a nonempty,
    /// intersecting frame, including the nested inbox stacks.
    pub fn list_cells_give_nested_text_real_frames() {
        let env = crate::resolve::env();
        let mount = waterui_apple::native_test_support::mount_uikit(
            mtm(),
            AnyView::new(inbox()),
            &env,
            cocoa_ui::Rect::new(0.0, 0.0, 393.0, 852.0),
        );
        let table = table(mount.content.view());
        let cells = table.visibleCells();
        assert!(cells.count() > 0, "the list materializes visible cells");
        let mut labels = 0;
        for cell in cells {
            for view in descendants(&cell.contentView()) {
                let Some(label) = view.downcast_ref::<UILabel>() else {
                    continue;
                };
                if label.text().is_none_or(|text| text.is_empty()) {
                    continue;
                }
                labels += 1;
                assert!(
                    view.frame().size.width > 0.0 && view.frame().size.height > 0.0,
                    "a nonempty label has an empty frame"
                );
                let frame = cocoa_ui::view::convert_rect(&view, view.bounds().into(), Some(&cell));
                let bounds = cell.bounds();
                assert!(
                    frame.origin.x < bounds.origin.x + bounds.size.width + 1.0
                        && frame.origin.x + frame.size.width > bounds.origin.x - 1.0
                        && frame.origin.y < bounds.origin.y + bounds.size.height + 1.0
                        && frame.origin.y + frame.size.height > bounds.origin.y - 1.0,
                    "a nonempty label does not intersect its cell"
                );
            }
        }
        assert!(
            labels >= 3,
            "expected at least three nonempty labels, found {labels}"
        );
    }

    /// Compare the actual plain field to the independently hosted SwiftUI field.
    pub fn text_field_renders_plain_with_a_real_height() {
        let value = binding(Str::from("x"));
        let env = crate::resolve::env();
        let mount = waterui_apple::native_test_support::mount_uikit(
            mtm(),
            AnyView::new(TextField::new("", &value)),
            &env,
            cocoa_ui::Rect::new(0.0, 0.0, 402.0, 874.0),
        );
        let field = descendants(mount.content.view())
            .into_iter()
            .find_map(|view| view.downcast::<cocoa_ui::uikit::TextField>().ok())
            .expect("the text field leaf mounts the kit UITextField");
        assert_eq!(field.borderStyle(), UITextBorderStyle::None);
        assert!(field.layer().borderWidth().abs() <= f64::EPSILON);
        if let Some(background) = field.backgroundColor() {
            assert!(
                objc2_core_graphics::CGColor::alpha(Some(&background.CGColor())) <= f64::EPSILON
            );
        }
        let bounds = CGRect::new(CGPoint::ZERO, CGSize::new(402.0, 60.0));
        for rect in [
            field.textRectForBounds(bounds),
            field.editingRectForBounds(bounds),
        ] {
            assert!((rect.origin.x - bounds.origin.x).abs() <= f64::EPSILON);
            assert!((rect.origin.y - bounds.origin.y).abs() <= f64::EPSILON);
            assert!((rect.size.width - bounds.size.width).abs() <= f64::EPSILON);
            assert!((rect.size.height - bounds.size.height).abs() <= f64::EPSILON);
        }
        close(
            field.sizeThatFits(CGSize::new(402.0, f64::MAX)).height,
            reference("textFieldHeight"),
        );
    }

    /// Platform margins, 24pt row pitch, and the 4pt-content minimum all
    /// compare against actual displayed UIKit/SwiftUI reference rows.
    pub fn list_row_height_pitches_and_respects_the_floor() {
        for (height, metric) in [(24.0_f32, "row24Height"), (4.0, "row4Height")] {
            let env = crate::resolve::env();
            let mount = waterui_apple::native_test_support::mount_uikit(
                mtm(),
                AnyView::new(List::content((move || {
                    ListItem::new(Color::srgb(255, 0, 0).height(height))
                },))),
                &env,
                cocoa_ui::Rect::new(0.0, 0.0, 402.0, 874.0),
            );
            let table = table(mount.content.view());
            let cells = table.visibleCells();
            assert_eq!(cells.count(), 1, "one reference row materializes");
            let cell = cells.objectAtIndex(0);
            close(cell.frame().size.height, reference(metric));
            let cell = cell
                .downcast_ref::<cocoa_ui::uikit::TableCell>()
                .expect("the backend uses the kit's row cell");
            let hosted = cell.content().expect("the cell owns rendered content");
            let content = cell.contentView();
            let rect =
                cocoa_ui::view::convert_rect(&hosted, hosted.bounds().into(), Some(&content));
            let bounds = content.bounds();
            close(rect.origin.y - bounds.origin.y, reference("rowTop"));
            close(rect.origin.x - bounds.origin.x, reference("rowLeading"));
            close(
                bounds.origin.y + bounds.size.height - rect.origin.y - rect.size.height,
                reference("rowBottom"),
            );
            close(
                bounds.origin.x + bounds.size.width - rect.origin.x - rect.size.width,
                reference("rowTrailing"),
            );
        }
    }

    pub fn compact_split_shows_the_sidebar() {
        use cocoa_ui::objc2_ui_kit::{UISplitViewController, UISplitViewControllerColumn};
        use waterui::navigation::{NavigationSplitView, NavigationView};
        let selection = binding(Some(1_i32));
        let split = NavigationSplitView::new(&selection, text("Sidebar"), |id: i32| {
            NavigationView::new(format!("Detail {id}"), text("detail"))
        });
        let env = crate::resolve::env();
        let mount = waterui_apple::native_test_support::mount_uikit(
            mtm(),
            AnyView::new(split),
            &env,
            cocoa_ui::Rect::new(0.0, 0.0, 393.0, 852.0),
        );
        let controller = descendants(mount.content.view())
            .into_iter()
            .find_map(|view| {
                cocoa_ui::uikit::view_controller::enclosing_controller(&view)
                    .and_then(|vc| vc.downcast::<UISplitViewController>().ok())
            })
            .expect("the split owns a UISplitViewController");
        assert!(
            controller.isCollapsed(),
            "a compact window collapses the split"
        );
        let sidebar = controller
            .viewControllerForColumn(UISplitViewControllerColumn::Primary)
            .expect("the primary column exists");
        assert!(
            sidebar
                .viewIfLoaded()
                .is_some_and(|view| view.window().is_some()),
            "the collapsed sidebar is attached to the window"
        );
        if let Some(detail) =
            controller.viewControllerForColumn(UISplitViewControllerColumn::Secondary)
        {
            assert!(
                !detail
                    .viewIfLoaded()
                    .is_some_and(|view| view.window().is_some()),
                "an existing secondary column must not be visible"
            );
        }
    }
}

mod colors {
    use objc2_core_graphics::{CGColor, CGColorSpace, kCGColorSpaceExtendedLinearDisplayP3};
    use waterui::graphics::color::{Color, Working, WorkingColor, signal_color, srgb_to_linear};
    use waterui::reactive::binding;
    use waterui_backend_core::AnyView;

    #[cfg(target_os = "macos")]
    pub fn native_well_round_trip() {
        use cocoa_ui::objc2_app_kit::NSColorWell;
        use waterui::Signal;
        use waterui::component::form::picker::color::ColorPicker;

        let env = crate::resolve::env();
        let components = [0.9, 0.4, 0.1, 0.6];
        let source = binding(Color::new(Working(WorkingColor::new(components))));
        let leaf = waterui_apple::dispatch::render(
            AnyView::new(ColorPicker::new("Color", &source).with_alpha().with_hdr()),
            &env,
        );
        let well = cocoa_ui::view::subviews(leaf.view())
            .into_iter()
            .find_map(|view| view.downcast::<NSColorWell>().ok())
            .expect("the native color picker owns an NSColorWell");
        let color = well.color();
        well.setColor(&color);
        // SAFETY: the backend installed this selector on this retained target;
        // both remain owned by the live leaf on the actual main thread.
        assert!(unsafe { well.sendAction_to(well.action(), well.target().as_deref()) });
        let actual = source.snapshot().resolve(&env).snapshot();
        for (actual, expected) in actual.components.into_iter().zip(components) {
            assert!(
                (actual - expected).abs() < 1e-3,
                "native well round trip changed {expected} to {actual}"
            );
        }
    }

    fn assert_fill(view: &cocoa_ui::PlatformView, expected: [f32; 4]) {
        #[cfg(target_os = "macos")]
        let color = {
            view.layer()
                .expect("the color leaf has a backing layer")
                .backgroundColor()
                .expect("the color leaf has a fill")
        };
        #[cfg(target_os = "ios")]
        let color = view
            .backgroundColor()
            .expect("the color leaf has a fill")
            .CGColor();
        assert_eq!(CGColor::number_of_components(Some(&color)), 4);
        let space = CGColor::color_space(Some(&color)).expect("the fill has a color space");
        let name = CGColorSpace::name(Some(&space)).expect("the fill space is named");
        // SAFETY: CoreGraphics provides this immutable color-space identifier.
        assert_eq!(&*name, unsafe { kCGColorSpaceExtendedLinearDisplayP3 });
        // SAFETY: the retained color owns exactly four components, checked above.
        let actual = unsafe { std::slice::from_raw_parts(CGColor::components(Some(&color)), 4) };
        for (actual, expected) in actual.iter().zip(expected) {
            assert!(
                (actual - f64::from(expected)).abs() < 1e-4,
                "native channel {actual} differs from straight working channel {expected}"
            );
        }
    }

    pub fn native_hdr_and_updates() {
        let env = crate::resolve::env();
        let initial = [1.4, -0.2, 0.3, 0.4];
        let source = binding(Color::new(Working(WorkingColor::new(initial))));
        let leaf =
            waterui_apple::dispatch::render(AnyView::new(signal_color(source.clone())), &env);
        assert_fill(leaf.view(), initial);
        for components in [[1.4, 0.25, 0.125, 0.5], [0.9, 0.4, 0.1, 1.0]] {
            source.set(Color::new(Working(WorkingColor::new(components))));
            assert_fill(leaf.view(), components);
        }
    }

    pub fn srgb_known_values() {
        for (input, expected) in [
            (0.0, 0.0),
            (1.0, 1.0),
            (0.5, 0.214_041_14),
            (0.040_45, 0.040_45 / 12.92),
        ] {
            assert!((srgb_to_linear(input) - expected).abs() < 1e-7);
        }
    }
}
