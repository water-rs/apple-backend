//! `NavigationSplitLayout` — the two/three-column adaptive container.
//!
//! iOS renders a `UISplitViewController` (double or triple column); each
//! column hosts a [`NavContentController`] wrapping the rendered subtree, so a
//! column's own `NavigationView` draws its standalone bar inside the column.
//! macOS renders the kit [`SplitViewController`] (`NSSplitViewController`).
//! Selection bindings rebuild the downstream columns; column visibility maps
//! to per-column collapse.

use core::cell::RefCell;

use crate::contract::NativeLeaf;
use crate::dispatch::Dispatcher;
use waterui::navigation::{
    NavigationSplitLayout, split::NavigationSplitDetailBuilder as DetailBuilder,
};
use waterui::reactive::{Binding, Signal};
use waterui_backend_core::AnyView;
use waterui_core::handler::AnyViewBuilder;
use waterui_core::id::Id;
use waterui_core::layout::{StretchAxis, SubView, ViewDimensions};

use crate::contract::KeepAlive;

/// Installs the `NavigationSplitLayout` handler.
pub fn install(dispatcher: &mut Dispatcher) {
    dispatcher.register_native::<NavigationSplitLayout>(platform::split_leaf);
}

struct Fill;

impl SubView for Fill {
    fn measure(&self, _proposal: waterui_core::layout::ProposalSize) -> ViewDimensions {
        ViewDimensions::new(waterui_core::layout::Size::new(0.0, 0.0))
    }

    fn stretch_axis(&self) -> StretchAxis {
        StretchAxis::Both
    }

    fn priority(&self) -> i32 {
        0
    }
}

/// What a selection change must rebuild: everything downstream of it.
struct Columns {
    /// Renders views after the handler returns.
    renderer: crate::contract::Renderer,
    /// The middle column's builder, when the split has three columns.
    content: Option<DetailBuilder>,
    /// The detail column's builder.
    detail: DetailBuilder,
    /// The middle column's empty-selection placeholder.
    placeholder: AnyViewBuilder<AnyView>,
    /// Sidebar selection.
    primary: Binding<Option<Id>>,
    /// Middle-column selection, three-column splits only.
    secondary: Option<Binding<Option<Id>>>,
    /// Guard for every leaf mounted in a column.
    mounted: RefCell<KeepAlive>,
    /// The selection-watcher guards — separate from `mounted` because
    /// `bind` fires immediately while its borrow is still held, and the
    /// watcher re-borrows `mounted`.
    watchers: RefCell<KeepAlive>,
}

impl Columns {
    /// The middle column's leaf: built from the primary selection (three
    /// columns) or the placeholder.
    fn middle(&self) -> NativeLeaf {
        let view = match (&self.content, self.primary.snapshot()) {
            (Some(content), Some(id)) => AnyView::new(content.build(id)),
            _ => self.placeholder.build(),
        };
        self.renderer.render(view)
    }

    /// The detail column's leaf: the primary selection drives two-column
    /// splits; the secondary selection drives three-column splits.
    fn detail(&self) -> NativeLeaf {
        let view = self
            .secondary
            .as_ref()
            .map_or_else(
                || self.primary.snapshot(),
                waterui::reactive::Signal::snapshot,
            )
            .map_or_else(
                || self.placeholder.build(),
                |id| AnyView::new(self.detail.build(id)),
            );
        self.renderer.render(view)
    }
}

#[cfg(target_os = "ios")]
mod platform {
    use super::{Columns, Fill};
    use alloc::rc::Rc;
    use core::cell::RefCell;

    use crate::contract::{NativeLeaf, RenderContext};
    use cocoa_ui::Retained;
    use cocoa_ui::objc2_ui_kit::UISplitViewControllerColumn;
    use cocoa_ui::uikit::{NavContentController, SplitController};
    use waterui::navigation::{NavigationSplitColumnVisibility, NavigationSplitLayout};

    use crate::contract::KeepAlive;

    struct Split {
        columns: Columns,
        nav: Retained<SplitController>,
        mtm: cocoa_ui::MainThreadMarker,
    }

    /// The sidebar column is a navigation-content host around the sidebar
    /// leaf; middle/detail columns are rebuilt on selection changes.
    pub(super) fn split_leaf(layout: NavigationSplitLayout, ctx: &RenderContext) -> NativeLeaf {
        let (
            sidebar,
            placeholder,
            primary,
            content,
            secondary,
            detail,
            visibility,
            sidebar_width,
            _style,
        ) = layout.into_parts();
        let mtm = ctx.mtm();
        let nav = SplitController::new(mtm, content.is_some());

        let sidebar_leaf = ctx.render(sidebar.build());
        let sidebar_vc = NavContentController::new(mtm, sidebar_leaf.view());
        nav.set_column(UISplitViewControllerColumn::Primary, &sidebar_vc);

        let columns = Columns {
            renderer: ctx.renderer(),
            content,
            detail,
            placeholder,
            primary,
            secondary,
            mounted: RefCell::new(KeepAlive::default()),
            watchers: RefCell::new(KeepAlive::default()),
        };
        let mut keep = KeepAlive::default();
        keep.keep(sidebar_leaf);
        keep.keep(sidebar_vc);
        let nav_for_binds = nav.clone();
        keep.keep(nav.clone());
        let has_middle = columns.content.is_some();
        let split = Rc::new(Split { columns, nav, mtm });

        if split.columns.content.is_some() {
            split.mount_middle(&mut keep);
        }
        split.mount_detail(&mut keep);
        *split.columns.mounted.borrow_mut() = keep;

        // Selection bindings rebuild the downstream columns.
        let primary = split.columns.primary.clone();
        split.columns.watchers.borrow_mut().bind(&primary, {
            let split = split.clone();
            move |_| {
                let mut keep = split.columns.mounted.borrow_mut();
                if split.columns.content.is_some() {
                    split.mount_middle(&mut keep);
                } else {
                    split.mount_detail(&mut keep);
                }
            }
        });
        if let Some(secondary) = &split.columns.secondary {
            split.columns.watchers.borrow_mut().bind(secondary, {
                let split = split.clone();
                move |_| {
                    let mut keep = split.columns.mounted.borrow_mut();
                    split.mount_detail(&mut keep);
                }
            });
        }

        split.columns.watchers.borrow_mut().bind(&visibility, {
            let nav = nav_for_binds.clone();
            move |visibility| {
                let (sidebar, content) = match visibility {
                    NavigationSplitColumnVisibility::All
                    | NavigationSplitColumnVisibility::Automatic => (false, false),
                    NavigationSplitColumnVisibility::DoubleColumn => (true, false),
                    NavigationSplitColumnVisibility::DetailOnly => (true, true),
                };
                nav.set_collapsed(UISplitViewControllerColumn::Primary, sidebar);
                if has_middle {
                    nav.set_collapsed(UISplitViewControllerColumn::Supplementary, content);
                }
            }
        });

        nav_for_binds.set_column_widths(
            UISplitViewControllerColumn::Primary,
            f64::from(sidebar_width.ideal()),
            f64::from(sidebar_width.min()),
            f64::from(sidebar_width.max()),
        );

        let mut leaf = NativeLeaf::new(&*nav_for_binds.view().expect("split view"), Fill);
        leaf.keep(split);
        leaf
    }

    impl Split {
        fn mount_middle(&self, keep: &mut KeepAlive) {
            let leaf = self.columns.middle();
            let vc = NavContentController::new(self.mtm, leaf.view());
            self.nav
                .set_column(UISplitViewControllerColumn::Supplementary, &vc);
            keep.keep(leaf);
            keep.keep(vc);
        }

        fn mount_detail(&self, keep: &mut KeepAlive) {
            let leaf = self.columns.detail();
            let vc = NavContentController::new(self.mtm, leaf.view());
            self.nav
                .set_column(UISplitViewControllerColumn::Secondary, &vc);
            keep.keep(leaf);
            keep.keep(vc);
        }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::{Columns, Fill};
    use alloc::rc::Rc;
    use core::cell::RefCell;

    use crate::contract::{NativeLeaf, RenderContext};
    use cocoa_ui::Retained;
    use cocoa_ui::appkit::{Column, ColumnWidth, SplitViewController};
    use waterui::navigation::{NavigationSplitColumnVisibility, NavigationSplitLayout};

    use crate::contract::KeepAlive;

    struct Split {
        columns: Columns,
        nav: Retained<SplitViewController>,
        /// The sidebar column's view, reinstalled on every `set_columns`.
        sidebar: Retained<cocoa_ui::PlatformView>,
    }

    /// `NSSplitViewController` with the sidebar leaf and rebuilt
    /// supplementary/detail columns.
    pub(super) fn split_leaf(layout: NavigationSplitLayout, ctx: &RenderContext) -> NativeLeaf {
        let (
            sidebar,
            placeholder,
            primary,
            content,
            secondary,
            detail,
            visibility,
            sidebar_width,
            _style,
        ) = layout.into_parts();
        let mtm = ctx.mtm();
        let nav = SplitViewController::new(mtm);

        let sidebar_leaf = ctx.render(sidebar.build());
        let columns = Columns {
            renderer: ctx.renderer(),
            content,
            detail,
            placeholder,
            primary,
            secondary,
            mounted: RefCell::new(KeepAlive::default()),
            watchers: RefCell::new(KeepAlive::default()),
        };
        let sidebar_view = cocoa_ui::view::retain_base(sidebar_leaf.view());
        let nav_for_binds = nav.clone();
        let split = Rc::new(Split {
            columns,
            nav,
            sidebar: sidebar_view,
        });

        let mut keep = KeepAlive::default();
        keep.keep(sidebar_leaf);
        split.mount(&mut keep);
        *split.columns.mounted.borrow_mut() = keep;

        let primary = split.columns.primary.clone();
        split.columns.watchers.borrow_mut().bind(&primary, {
            let split = split.clone();
            move |_| {
                let mut keep = split.columns.mounted.borrow_mut();
                split.mount(&mut keep);
            }
        });
        if let Some(secondary) = &split.columns.secondary {
            split.columns.watchers.borrow_mut().bind(secondary, {
                let split = split.clone();
                move |_| {
                    let mut keep = split.columns.mounted.borrow_mut();
                    split.mount(&mut keep);
                }
            });
        }

        split.columns.watchers.borrow_mut().bind(&visibility, {
            let nav = nav_for_binds.clone();
            move |visibility| {
                let (sidebar, content) = match visibility {
                    NavigationSplitColumnVisibility::All
                    | NavigationSplitColumnVisibility::Automatic => (false, false),
                    NavigationSplitColumnVisibility::DoubleColumn => (true, false),
                    NavigationSplitColumnVisibility::DetailOnly => (true, true),
                };
                nav.set_collapsed(Column::Sidebar, sidebar);
                nav.set_collapsed(Column::Supplementary, content);
            }
        });

        nav_for_binds.set_column_widths(&[
            ColumnWidth {
                preferred: Some(f64::from(sidebar_width.ideal())),
                minimum: Some(f64::from(sidebar_width.min())),
                maximum: Some(f64::from(sidebar_width.max())),
            },
            ColumnWidth {
                preferred: None,
                minimum: None,
                maximum: None,
            },
            ColumnWidth {
                preferred: None,
                minimum: None,
                maximum: None,
            },
        ]);

        let mut leaf = NativeLeaf::new(&*nav_for_binds.view(), Fill);
        leaf.keep(split);
        leaf
    }

    impl Split {
        /// Rebuilds the columns from the current selections and installs them
        /// (`set_columns` replaces the split items in place).
        fn mount(&self, keep: &mut KeepAlive) {
            // The sidebar leaf is already retained; the first column stays
            // mounted — only downstream columns rebuild.
            let middle = self.columns.middle();
            let detail = self.columns.detail();
            self.nav.set_columns(
                &self.sidebar,
                if self.columns.content.is_some() {
                    Some(middle.view())
                } else {
                    None
                },
                detail.view(),
            );
            keep.keep(middle);
            keep.keep(detail);
        }
    }
}
