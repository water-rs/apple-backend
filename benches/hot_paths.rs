//! Hot-path benchmarks for the Apple backend's port surface: leaf
//! mount/unmount, the binding → watcher → applied-property update path, and
//! `set_layout_handler` running `waterui-layout` frames over a container
//! with N children.
//!
//! `#[cfg(target_os = "macos")]` only — the leaves are `AppKit` objects.
//! Criterion drives benches from the real main thread, so
//! `MainThreadMarker::new()` yields a genuine marker and every view here is
//! main-thread sound. Run with `cargo bench`; nothing gates CI on these.

#[cfg(target_os = "macos")]
mod hot_paths {
    use std::hint::black_box;

    use cocoa_ui::appkit::{HostView, Label};
    use cocoa_ui::geometry::Rect;
    use cocoa_ui::{MainThreadMarker, PlatformView};
    use criterion::{Criterion, criterion_group};
    use waterui::layout::stack::VStackLayout;
    use waterui::reactive::{Binding, binding};
    use waterui_apple::contract::{Mounted, NativeLeaf};
    use waterui_core::layout::{
        Layout, Point, ProposalSize, Size, StretchAxis, SubView, ViewDimensions,
    };

    /// A fixed-size leaf: the smallest `SubView` the negotiation path needs.
    struct BenchLeaf {
        size: Size,
    }

    impl SubView for BenchLeaf {
        fn measure(&self, _proposal: ProposalSize) -> ViewDimensions {
            ViewDimensions::new(self.size)
        }

        fn stretch_axis(&self) -> StretchAxis {
            StretchAxis::None
        }

        fn priority(&self) -> i32 {
            0
        }
    }

    /// Mount → unmount a representative leaf (`Label`) against a host view.
    fn leaf_mount_unmount(c: &mut Criterion) {
        let mtm = MainThreadMarker::new().expect("benches run on the main thread");
        let parent = HostView::new(mtm, Rect::new(0.0, 0.0, 800.0, 600.0));
        c.bench_function("leaf_mount_unmount", |b| {
            b.iter(|| {
                let label = Label::new(mtm);
                let view: &PlatformView = &label;
                let leaf = NativeLeaf::new(
                    view,
                    BenchLeaf {
                        size: Size::new(40.0, 20.0),
                    },
                );
                let mounted = leaf.mount(&parent);
                black_box(mounted.unmount());
            });
        });
    }

    /// Binding write → watcher → applied platform property (`set_text`).
    fn binding_update_path(c: &mut Criterion) {
        let mtm = MainThreadMarker::new().expect("benches run on the main thread");
        let parent = HostView::new(mtm, Rect::new(0.0, 0.0, 800.0, 600.0));
        let label = Label::new(mtm);
        let text: Binding<String> = binding(String::new());
        let view: &PlatformView = &label;
        let mut leaf = NativeLeaf::new(
            view,
            BenchLeaf {
                size: Size::new(40.0, 20.0),
            },
        );
        leaf.bind(&text, {
            let label = label.clone();
            move |value| label.set_text(&value)
        });
        let _mounted = leaf.mount(&parent);
        c.bench_function("binding_update_to_label", |b| {
            b.iter(|| {
                text.set(String::from("bench"));
                text.set(String::from("update"));
            });
        });
    }

    /// `set_layout_handler` running a `waterui-layout` `VStack` placement over a
    /// container with N leaf children, applying each returned frame.
    fn frame_application(c: &mut Criterion) {
        let mtm = MainThreadMarker::new().expect("benches run on the main thread");
        let mut group = c.benchmark_group("frame_application");
        for count in [8_usize, 64] {
            let host = HostView::new(mtm, Rect::new(0.0, 0.0, 640.0, 480.0));
            let host_view: &PlatformView = &host;
            let mut children = Vec::with_capacity(count);
            for index in 0..count {
                let label = Label::new(mtm);
                let view: &PlatformView = &label;
                let leaf = NativeLeaf::new(
                    view,
                    BenchLeaf {
                        size: Size::new(
                            50.0,
                            10.0 + f32::from(u8::try_from(index % 4).unwrap_or_default()),
                        ),
                    },
                );
                children.push(leaf.mount(host_view));
            }
            let layout = VStackLayout::default();
            host.set_layout_handler(move |host_view| {
                let bounds = host_view.bounds();
                #[expect(
                    clippy::cast_possible_truncation,
                    reason = "the layout contract is f32; view extents always fit"
                )]
                let proposal = ProposalSize::new(
                    Some(bounds.size.width as f32),
                    Some(bounds.size.height as f32),
                );
                let child_layouts: Vec<&dyn SubView> =
                    children.iter().map(Mounted::layout).collect();
                let placements = layout.place(
                    waterui_core::layout::Rect::new(
                        Point::new(0.0, 0.0),
                        #[expect(
                            clippy::cast_possible_truncation,
                            reason = "the layout contract is f32; view extents always fit"
                        )]
                        Size::new(bounds.size.width as f32, bounds.size.height as f32),
                    ),
                    proposal,
                    &child_layouts,
                );
                for (child, placement) in children.iter().zip(placements.iter()) {
                    cocoa_ui::view::set_frame(
                        child.view(),
                        Rect::new(
                            f64::from(placement.frame.x()),
                            f64::from(placement.frame.y()),
                            f64::from(placement.frame.width()),
                            f64::from(placement.frame.height()),
                        ),
                    );
                }
            });
            group.bench_function(format!("children_{count}"), |b| {
                b.iter(|| {
                    host.set_needs_layout();
                    host.layout_if_needed();
                });
            });
        }
        group.finish();
    }

    criterion_group!(
        benches,
        leaf_mount_unmount,
        binding_update_path,
        frame_application
    );
}

#[cfg(target_os = "macos")]
criterion::criterion_main!(hot_paths::benches);

#[cfg(not(target_os = "macos"))]
fn main() {}
