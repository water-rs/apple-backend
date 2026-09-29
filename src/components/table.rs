//! The `table` leaf: `Native<TableConfig>` rendered through an
//! `NSTableView` on macOS and a manually framed header/cell grid on iOS.
//!
//! Mirrors `WuiTable` + `WuiTableColumnNode`: columns reconcile by their
//! `semantic_id` inside `with_platform_animation`, each column keeps an
//! id-keyed set of rendered cells driven by `rows().watch(..)`, cells are
//! `ctx.render(AnyView::new(text))` leaves measured under
//! `ProposalSize::UNSPECIFIED`, and `sizeThatFits` ignores the proposal —
//! width is the sum of the per-column fitted widths, height is the header
//! band plus the per-row maxima.
//!
//! Contract friction: `SubView` has no `place` hook, so the
//! `setPlacementProposal(WuiProposalSize())` the Swift port delivered to
//! each cell at layout/viewFor time has no channel here — cells measure
//! under unspecified proposals like every other ported container's
//! children.

#[cfg(target_os = "macos")]
use alloc::format;
use alloc::rc::Rc;
use alloc::vec::Vec;
use core::cell::RefCell;
use std::collections::HashMap;

use cocoa_ui::{Retained, view};
use waterui::animation::Animation;
use waterui::component::table::{TableColumn, TableConfig};
use waterui::id::{Id as RawId, SelfId};
use waterui::reactive::watcher::Metadata;
use waterui::reactive::{Computed, Signal};
use waterui::text::{StyledStr, Text};
use waterui::views::Views;
use waterui_backend_core::AnyView;
use waterui_core::layout::{ProposalSize, Size, StretchAxis, SubView, ViewDimensions};
use waterui_core::views::SharedAnyViews;

use crate::contract::{NativeLeaf, RenderContext, Renderer};
use crate::dispatch::Dispatcher;

#[cfg(target_os = "macos")]
use cocoa_ui::appkit::{HostView, TableView};
#[cfg(target_os = "ios")]
use cocoa_ui::uikit::HostView;

#[cfg(target_os = "macos")]
use cocoa_ui::objc2_app_kit::{NSTableColumn, NSTableHeaderView};

/// A row's identity: the collection id `Views` answers for an index.
type ItemId = SelfId<RawId>;

/// `HORIZONTAL_PADDING` — the cell inset on the horizontal axis.
const HORIZONTAL_PADDING: f64 = 12.0;
/// `VERTICAL_PADDING` — the cell inset on the vertical axis.
const VERTICAL_PADDING: f64 = 6.0;
/// `minimumColumnWidth` — a column never narrows below this.
const MINIMUM_COLUMN_WIDTH: f64 = 80.0;
/// `nativeHeaderHeight` — the macOS header band's fixed height.
#[cfg(target_os = "macos")]
const NATIVE_HEADER_HEIGHT: f64 = 24.0;
/// The minimum header band height on iOS (`max(28, ...)`).
#[cfg(target_os = "ios")]
const MIN_HEADER_HEIGHT: f64 = 28.0;
/// The minimum row height (`max(28, ...)`).
const MIN_ROW_HEIGHT: f64 = 28.0;

/// `withPlatformAnimation`: the watcher metadata's `Animation` mapped to a
/// kit timing — the same mapping `container` applies.
fn with_platform_animation(metadata: &Metadata, body: impl FnOnce() + 'static) {
    let timing = match metadata.try_get::<Animation>() {
        None => return body(),
        Some(Animation::Default) => cocoa_ui::core_animation::Timing::Bezier {
            duration: 0.25,
            control_points: [0.42, 0.0, 0.58, 1.0],
        },
        Some(Animation::Bezier {
            duration,
            x1,
            y1,
            x2,
            y2,
        }) => cocoa_ui::core_animation::Timing::Bezier {
            duration: duration.as_secs_f64(),
            control_points: [x1, y1, x2, y2],
        },
        Some(Animation::Spring { stiffness, damping }) => {
            cocoa_ui::core_animation::Timing::Spring {
                stiffness: f64::from(stiffness),
                damping: f64::from(damping),
            }
        }
    };
    cocoa_ui::core_animation::animate_with(timing, body);
}

/// A cell's platform view.
#[cfg(target_os = "ios")]
type CellStore = crate::contract::Mounted;
/// A cell's platform view — unmounted on `AppKit`: `NSTableView` takes the
/// view in `viewFor` and releases it on reuse.
#[cfg(target_os = "macos")]
type CellStore = NativeLeaf;

/// A rendered column: the `WuiTableColumnNode` — its rows collection,
/// id-keyed cells, header label, and watcher guards.
struct ColumnState {
    /// `semantic_id` — the reconcile key.
    semantic_id: usize,
    /// The rows collection, for `get_view`/`get_id` during reconcile.
    rows: SharedAnyViews<Text>,
    /// `rows.len()` — the delegate's per-column row count source.
    len: Computed<usize>,
    /// Current row ids in display order.
    ids: Vec<ItemId>,
    /// Rendered cells by row id.
    cells: HashMap<ItemId, CellStore>,
    /// `UILabel` header — the label's rendered `Text` leaf (iOS).
    #[cfg(target_os = "ios")]
    label: crate::contract::Mounted,
    /// The label's `content` signal — on `AppKit` the header title reads its
    /// snapshot; the watch drives `reloadContent`.
    #[cfg(target_os = "macos")]
    label_content: Computed<StyledStr>,
    /// The same signal on `UIKit`, kept alive so `_label_guard`'s watch stays
    /// subscribed; the rendered label leaf reads its own copy.
    #[cfg(target_os = "ios")]
    _label_content: Computed<StyledStr>,
    /// `labelContentObservation` / `labelObservation` — kept alive by the
    /// field, never read: dropping it unsubscribes the watch.
    _label_guard: <Computed<StyledStr> as Signal>::Guard,
    /// The `rows.watch` guard — kept alive like `_label_guard`.
    _rows_guard: waterui::reactive::watcher::BoxWatcherGuard,
    /// `nativeColumns[id]` (macOS).
    #[cfg(target_os = "macos")]
    ns_column: Retained<NSTableColumn>,
}

/// The table's shared state — `WuiTable`'s stored properties.
struct TableState {
    /// The leaf's view: the `WuiTable` itself (`UIView` / `NSView` host).
    host: Retained<HostView>,
    /// `tableView` (macOS).
    #[cfg(target_os = "macos")]
    table: Retained<TableView>,
    /// `nativeHeader` (macOS).
    #[cfg(target_os = "macos")]
    header: Retained<NSTableHeaderView>,
    /// Renders row `Text`s and label `Text`s after `install` returns.
    renderer: Renderer,
    /// `collection.ordered` — columns in display order.
    columns: Vec<ColumnState>,
    /// `appKitRowHeights` — the cached row heights the delegate answers.
    #[cfg(target_os = "macos")]
    row_heights: Vec<f64>,
}

/// `sizeThatFits` measure of a leaf under the fully unspecified proposal —
/// `row.sizeThatFits(WuiProposalSize())`.
fn intrinsic_size(layout: &dyn SubView) -> (f64, f64) {
    let measured = layout.measure(ProposalSize::UNSPECIFIED);
    (
        f64::from(measured.size.width),
        f64::from(measured.size.height),
    )
}

/// `columnWidths` for one column: `max(minimumColumnWidth, headerWidth,
/// cellWidths + HORIZONTAL_PADDING * 2)`.
fn fitted_column_width(header_width: f64, cell_widths: impl Iterator<Item = f64>) -> f64 {
    cell_widths.fold(MINIMUM_COLUMN_WIDTH.max(header_width), |width, cell| {
        width.max(HORIZONTAL_PADDING.mul_add(2.0, cell))
    })
}

/// One entry of `rowHeights`: `max(28, cells + VERTICAL_PADDING * 2)`.
fn fitted_row_height(cell_heights: impl Iterator<Item = f64>) -> f64 {
    cell_heights
        .reduce(f64::max)
        .unwrap_or(0.0)
        .mul_add(1.0, VERTICAL_PADDING * 2.0)
        .max(MIN_ROW_HEIGHT)
}

/// `headerHeight` on iOS: `max(28, labels + VERTICAL_PADDING * 2)`; on
/// macOS the fixed `nativeHeaderHeight`. Empty table answers `0`.
#[cfg_attr(
    target_os = "macos",
    expect(
        clippy::missing_const_for_fn,
        reason = "the iOS branch measures leaves and cannot be const"
    )
)]
fn header_height(state: &TableState) -> f64 {
    if state.columns.is_empty() {
        return 0.0;
    }
    #[cfg(target_os = "ios")]
    {
        state
            .columns
            .iter()
            .map(|column| intrinsic_size(column.label.layout()).1)
            .reduce(f64::max)
            .unwrap_or(0.0)
            .mul_add(1.0, VERTICAL_PADDING * 2.0)
            .max(MIN_HEADER_HEIGHT)
    }
    #[cfg(target_os = "macos")]
    {
        NATIVE_HEADER_HEIGHT
    }
}

/// `columnWidths` for every column.
fn column_widths(state: &TableState) -> Vec<f64> {
    state
        .columns
        .iter()
        .map(|column| {
            #[cfg(target_os = "ios")]
            let header_width =
                HORIZONTAL_PADDING.mul_add(2.0, intrinsic_size(column.label.layout()).0);
            // The native header cell measures its own title, padding
            // included.
            #[cfg(target_os = "macos")]
            let header_width = column.ns_column.headerCell().cellSize().width;
            fitted_column_width(
                header_width,
                column
                    .ids
                    .iter()
                    .filter_map(|id| column.cells.get(id))
                    .map(|cell| intrinsic_size(cell.layout()).0),
            )
        })
        .collect()
}

/// `rowHeights`: per row index, the max fitted cell height across columns.
fn row_heights(state: &TableState) -> Vec<f64> {
    let count = state
        .columns
        .iter()
        .map(|column| column.len.snapshot())
        .max()
        .unwrap_or(0);
    (0..count)
        .map(|row| {
            fitted_row_height(state.columns.iter().filter_map(|column| {
                column
                    .ids
                    .get(row)
                    .and_then(|id| column.cells.get(id))
                    .map(|cell| intrinsic_size(cell.layout()).1)
            }))
        })
        .collect()
}

/// `sizeThatFits` — the proposal is ignored on both platforms.
fn size_that_fits(state: &TableState) -> Size {
    let width: f64 = column_widths(state).iter().sum();
    let height = header_height(state) + row_heights(state).iter().sum::<f64>();
    #[expect(
        clippy::cast_possible_truncation,
        reason = "kit geometry is f64; the layout contract is f32"
    )]
    Size::new(width as f32, height as f32)
}

/// `updateAttachedViews` (iOS): the host's subviews are exactly the labels
/// in column order, then every column's cells in row order.
#[cfg(target_os = "ios")]
fn update_attached_views(state: &TableState) {
    let desired: Vec<Retained<cocoa_ui::PlatformView>> = state
        .columns
        .iter()
        .map(|column| view::retain_base(column.label.view()))
        .chain(state.columns.iter().flat_map(|column| {
            column
                .ids
                .iter()
                .filter_map(|id| column.cells.get(id))
                .map(|cell| view::retain_base(cell.view()))
        }))
        .collect();
    view::reconcile_subviews(&state.host, &desired);
}

/// `reloadContent` (iOS): reconcile the attached views and invalidate.
#[cfg(target_os = "ios")]
fn reload_content(state: &TableState) {
    update_attached_views(state);
    state.host.set_needs_layout();
    view::invalidate_layout(&state.host);
}

/// `reloadContent` (`AppKit`): refresh the column titles, recompute row
/// heights and column widths, reload, and propagate the invalidation
/// upward.
#[cfg(target_os = "macos")]
fn reload_content(state: &mut TableState) {
    for column in &state.columns {
        column
            .ns_column
            .setTitle(&objc2_foundation::NSString::from_str(
                &column.label_content.snapshot().to_plain(),
            ));
    }
    state.row_heights = row_heights(state);
    for (column, width) in state.columns.iter().zip(column_widths(state)) {
        column.ns_column.setWidth(width);
    }
    state.table.reload_data();
    TableView::refresh_header(&state.header);
    state.host.set_needs_layout();
    view::invalidate_layout(&state.host);
}

/// `WuiStableViewCollection`'s reconcile for one column's rows: reuse the
/// rendered cell of every unchanged id, render only the joins, drop the
/// leaves that left.
fn sync_column_cells(
    column: &mut ColumnState,
    renderer: &Renderer,
    host: &cocoa_ui::PlatformView,
    ids: Vec<ItemId>,
) {
    #[cfg(target_os = "macos")]
    let _ = host;
    for (index, &id) in ids.iter().enumerate() {
        if column.cells.contains_key(&id) {
            continue;
        }
        let text = column
            .rows
            .get_view(index)
            .expect("table row index is in bounds");
        let leaf = renderer.render(AnyView::new(text));
        #[cfg(target_os = "ios")]
        let cell = {
            let mounted = leaf.mount(host);
            view::set_translates_autoresizing(mounted.view(), true);
            mounted
        };
        #[cfg(target_os = "macos")]
        let cell = leaf;
        column.cells.insert(id, cell);
    }
    let dropped: Vec<ItemId> = column
        .cells
        .keys()
        .copied()
        .filter(|id| !ids.contains(id))
        .collect();
    for id in dropped {
        if let Some(cell) = column.cells.remove(&id) {
            // `AppKit`: the leaf is unmounted, so detach its view by hand —
            // `Mounted`'s drop does this on `UIKit`.
            #[cfg(target_os = "macos")]
            view::remove_from_superview(cell.view());
            drop(cell);
        }
    }
    column.ids = ids;
}

/// `WuiTableColumnNode.init` — build a column: render the label, take the
/// initial row ids, and subscribe the row and label watches that drive
/// `reloadContent` (row changes additionally animate through
/// `withPlatformAnimation`).
fn materialize_column(state: &Rc<RefCell<TableState>>, column: &TableColumn) -> ColumnState {
    let (renderer, host, env) = {
        let state = state.borrow();
        (
            state.renderer.clone(),
            state.host.clone(),
            state.renderer.context().env().clone(),
        )
    };
    let rows = column.rows();
    let len = rows.len();

    // The label's `content` drives `reloadContent` (`onContentChange`) and,
    // on `AppKit`, the `NSTableColumn` title. The rest of the resolved
    // `TextConfig` — `paragraph_alignment`, `line_limit` — is consumed and
    // released here, as `WuiTableColumnNode` releases the alignment signal.
    let label_config = column.label().resolve(&env);
    let label_content = label_config.content;

    let weak = Rc::downgrade(state);
    let label_guard = label_content.watch(move |_ctx| {
        if let Some(state) = weak.upgrade() {
            #[cfg(target_os = "ios")]
            reload_content(&state.borrow());
            #[cfg(target_os = "macos")]
            reload_content(&mut state.borrow_mut());
        }
    });

    #[cfg(target_os = "ios")]
    let label = {
        let leaf = renderer.render(AnyView::new(column.label()));
        let mounted = leaf.mount(&host);
        view::set_translates_autoresizing(mounted.view(), true);
        mounted
    };

    #[cfg(target_os = "macos")]
    let ns_column = {
        let id = column.semantic_id();
        let ns_column = NSTableColumn::initWithIdentifier(
            state
                .borrow()
                .renderer
                .context()
                .mtm()
                .alloc::<NSTableColumn>(),
            &objc2_foundation::NSString::from_str(&format!("waterui.table.{id}")),
        );
        ns_column.setMinWidth(MINIMUM_COLUMN_WIDTH);
        ns_column.setTitle(&objc2_foundation::NSString::from_str(
            &label_content.snapshot().to_plain(),
        ));
        ns_column
    };

    let semantic_id = column.semantic_id();
    let weak = Rc::downgrade(state);
    let rows_guard = rows.watch(.., move |ctx, _change| {
        let Some(state) = weak.upgrade() else {
            return;
        };
        let ids: Vec<ItemId> = ctx.value().to_vec();
        let metadata = ctx.metadata().clone();
        with_platform_animation(&metadata, move || {
            let mut state = state.borrow_mut();
            let Some(index) = state
                .columns
                .iter()
                .position(|column| column.semantic_id == semantic_id)
            else {
                return;
            };
            let (renderer, host) = (state.renderer.clone(), state.host.clone());
            sync_column_cells(&mut state.columns[index], &renderer, &host, ids);
            #[cfg(target_os = "ios")]
            reload_content(&state);
            #[cfg(target_os = "macos")]
            reload_content(&mut state);
        });
    });

    let mut column_state = ColumnState {
        semantic_id,
        rows: rows.clone(),
        len,
        ids: Vec::new(),
        cells: HashMap::new(),
        #[cfg(target_os = "ios")]
        label,
        #[cfg(target_os = "macos")]
        label_content,
        #[cfg(target_os = "ios")]
        _label_content: label_content,
        _label_guard: label_guard,
        _rows_guard: rows_guard,
        #[cfg(target_os = "macos")]
        ns_column,
    };
    let ids: Vec<ItemId> = (0..column_state.len.snapshot())
        .filter_map(|index| rows.get_id(index))
        .collect();
    sync_column_cells(&mut column_state, &renderer, &host, ids);
    column_state
}

/// `reconcileColumns` — the `semantic_id`-keyed reconcile: keep surviving
/// columns (their cells, watches, and platform objects untouched), build
/// the joins, drop the leaves that left.
fn reconcile_columns(state: &Rc<RefCell<TableState>>, columns: Vec<TableColumn>) {
    let mut kept = HashMap::new();
    for existing in core::mem::take(&mut state.borrow_mut().columns) {
        kept.insert(existing.semantic_id, existing);
    }
    let mut ordered = Vec::with_capacity(columns.len());
    for column in columns {
        let id = column.semantic_id();
        ordered.push(
            kept.remove(&id)
                .unwrap_or_else(|| materialize_column(state, &column)),
        );
    }
    // `kept`'s leftovers are the departed columns; dropping them releases
    // their cells and unsubscribes their watchers.
    drop(kept);
    state.borrow_mut().columns = ordered;
    #[cfg(target_os = "ios")]
    update_columns(&state.borrow());
    #[cfg(target_os = "macos")]
    update_columns(&mut state.borrow_mut());
}

/// `updateColumns` (iOS) — reconcile attached views, then reload.
#[cfg(target_os = "ios")]
fn update_columns(state: &TableState) {
    update_attached_views(state);
    reload_content(state);
}

/// `updateColumns` (`AppKit`) — push the current column list to the
/// `NSTableView`, then reload.
#[cfg(target_os = "macos")]
fn update_columns(state: &mut TableState) {
    {
        let ordered: Vec<Retained<NSTableColumn>> = state
            .columns
            .iter()
            .map(|column| column.ns_column.clone())
            .collect();
        state.table.set_columns(&ordered);
    }
    reload_content(state);
}

/// `layoutSubviews` on `UIKit` — frame labels across the top band and cells
/// on their row/column grid.
#[cfg(target_os = "ios")]
fn layout_children(state: &TableState) {
    let widths = column_widths(state);
    let header_height = header_height(state);
    let row_heights = row_heights(state);
    let mut x = 0.0;
    for (index, column) in state.columns.iter().enumerate() {
        view::set_frame(
            column.label.view(),
            cocoa_ui::Rect::new(x, 0.0, widths[index], header_height),
        );
        x += widths[index];
    }
    let mut y = header_height;
    for (row, row_height) in row_heights.iter().enumerate() {
        x = 0.0;
        for (index, column) in state.columns.iter().enumerate() {
            if let Some(cell) = column.ids.get(row).and_then(|id| column.cells.get(id)) {
                view::set_frame(
                    cell.view(),
                    cocoa_ui::Rect::new(
                        x + HORIZONTAL_PADDING,
                        y + VERTICAL_PADDING,
                        HORIZONTAL_PADDING.mul_add(-2.0, widths[index]),
                        VERTICAL_PADDING.mul_add(-2.0, *row_height),
                    ),
                );
            }
            x += widths[index];
        }
        y += row_height;
    }
}

/// `layout` on `AppKit` — refresh the column widths, then frame the header
/// band and the table inside the host's bounds.
#[cfg(target_os = "macos")]
fn layout_children(state: &TableState) {
    for (column, width) in state.columns.iter().zip(column_widths(state)) {
        column.ns_column.setWidth(width);
    }
    let header_height = header_height(state);
    let bounds = view::bounds(&state.host);
    view::set_frame(
        &state.header,
        cocoa_ui::Rect::new(0.0, 0.0, bounds.size.width, header_height),
    );
    view::set_frame(
        &state.table,
        cocoa_ui::Rect::new(
            0.0,
            header_height,
            bounds.size.width,
            (bounds.size.height - header_height).max(0.0),
        ),
    );
}

/// The table's layout face: `sizeThatFits` — the proposal is ignored.
struct TableSubView {
    state: Rc<RefCell<TableState>>,
}

impl core::fmt::Debug for TableSubView {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("TableSubView").finish_non_exhaustive()
    }
}

impl SubView for TableSubView {
    fn measure(&self, _proposal: ProposalSize) -> ViewDimensions {
        ViewDimensions::new(size_that_fits(&self.state.borrow()))
    }

    /// `NSTableView`-driven stretch: `.none`.
    fn stretch_axis(&self) -> StretchAxis {
        StretchAxis::None
    }

    fn priority(&self) -> i32 {
        0
    }
}

/// Renders a `TableConfig` into the host: `WuiTable.init(columns:env:)`.
fn render(config: TableConfig, ctx: &RenderContext<'_>) -> NativeLeaf {
    let TableConfig { columns } = config;
    let mtm = ctx.mtm();
    let host = HostView::new(mtm, cocoa_ui::Rect::ZERO);
    #[cfg(target_os = "ios")]
    view::set_clips_to_bounds(&host, true);

    #[cfg(target_os = "macos")]
    let (table, header) = {
        let table = TableView::new(mtm);
        let header = table.install_header();
        host.add_subview(&table);
        host.add_subview(&header);
        (table, header)
    };

    let state = Rc::new(RefCell::new(TableState {
        host: host.clone(),
        #[cfg(target_os = "macos")]
        table,
        #[cfg(target_os = "macos")]
        header,
        renderer: ctx.renderer(),
        columns: Vec::new(),
        #[cfg(target_os = "macos")]
        row_heights: Vec::new(),
    }));

    host.set_measure_handler({
        let state = Rc::clone(&state);
        move |_host, _proposal| {
            let size = size_that_fits(&state.borrow());
            cocoa_ui::Size::new(f64::from(size.width), f64::from(size.height))
        }
    });
    host.set_layout_handler({
        let state = Rc::clone(&state);
        move |_host| layout_children(&state.borrow())
    });

    #[cfg(target_os = "macos")]
    {
        let table = &state.borrow().table;
        table.set_row_count_handler({
            let weak = Rc::downgrade(&state);
            move || {
                weak.upgrade().map_or(0, |state| {
                    state
                        .borrow()
                        .columns
                        .iter()
                        .map(|column| column.len.snapshot())
                        .max()
                        .unwrap_or(0)
                })
            }
        });
        table.set_row_height_handler({
            let weak = Rc::downgrade(&state);
            move |row| {
                weak.upgrade()
                    .map_or(0.0, |state| state.borrow().row_heights[row])
            }
        });
        table.set_cell_view_handler({
            let weak = Rc::downgrade(&state);
            move |ns_column, row| {
                let state = weak.upgrade()?;
                let state = state.borrow();
                let column = state.columns.iter().find(|column| {
                    std::ptr::eq(
                        std::ptr::from_ref(&*column.ns_column),
                        std::ptr::from_ref(ns_column),
                    )
                })?;
                let id = column.ids.get(row)?;
                let cell = column.cells.get(id)?;
                Some(view::retain_base(cell.view()))
            }
        });
    }

    // `watchAnyViewsIds` — the columns watch, wrapping each reconcile in the
    // metadata's animation.
    let columns_guard = columns.watch({
        let weak = Rc::downgrade(&state);
        move |ctx| {
            let Some(state) = weak.upgrade() else {
                return;
            };
            let metadata = ctx.metadata().clone();
            let columns = ctx.into_value();
            with_platform_animation(&metadata, move || {
                reconcile_columns(&state, columns);
            });
        }
    });

    // `reconcileColumns(ids: source.allIds())` — the initial population.
    reconcile_columns(&state, columns.snapshot());

    let mut leaf = NativeLeaf::new(
        &*host,
        TableSubView {
            state: Rc::clone(&state),
        },
    );
    leaf.keep(columns_guard);
    leaf.keep(state);
    leaf
}

/// Registers the `table` leaf.
pub fn install(dispatcher: &mut Dispatcher) {
    dispatcher.register_native::<TableConfig>(render);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_f64_eq(actual: f64, expected: f64) {
        assert!(
            (actual - expected).abs() < f64::EPSILON,
            "{actual} != {expected}"
        );
    }

    #[test]
    fn column_width_floors_at_the_minimum() {
        assert_f64_eq(
            fitted_column_width(0.0, [].into_iter()),
            MINIMUM_COLUMN_WIDTH,
        );
    }

    #[test]
    fn column_width_takes_the_header_when_wider() {
        assert_f64_eq(fitted_column_width(120.0, [40.0].into_iter()), 120.0);
    }

    #[test]
    fn column_width_takes_the_widest_cell_plus_padding() {
        assert_f64_eq(
            fitted_column_width(30.0, [100.0, 50.0].into_iter()),
            HORIZONTAL_PADDING.mul_add(2.0, 100.0),
        );
    }

    #[test]
    fn row_height_floors_at_28() {
        assert_f64_eq(fitted_row_height([10.0].into_iter()), MIN_ROW_HEIGHT);
        assert_f64_eq(fitted_row_height([].into_iter()), MIN_ROW_HEIGHT);
    }

    #[test]
    fn row_height_takes_the_tallest_cell_plus_padding() {
        assert_f64_eq(
            fitted_row_height([20.0, 44.0].into_iter()),
            VERTICAL_PADDING.mul_add(2.0, 44.0),
        );
    }
}
