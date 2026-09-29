//! The coexistence seam between `waterui-apple` and the Swift fallback.
//!
//! Two entry points carry a view across the boundary, one in each direction:
//! [`waterui_apple_render`] (defined here, called by Swift) and
//! [`waterui_swift_render`] (defined by the fallback, called from here). Each
//! answers a [`WateruiLeaf`]: a +1 platform view plus the [`WateruiSubView`]
//! layout face the other side's containers measure through. A null `view`
//! means "not claimed" — a miss never re-enters the other direction, so the
//! seam cannot ping-pong.
//!
//! `Views` and `Environments` cross as owning pointers to `AnyView` /
//! `Environment` — the same heap values both sides hold — and each receiver
//! clones or consumes by its own rules.
//!
//! # Safety
//!
//! Every `unsafe extern "C"` here is a boundary function; the contracts on it
//! are the ownership rules above, spelled out per parameter.

use alloc::boxed::Box;
use core::ffi::c_void;
use core::ptr;

use cocoa_ui::Retained;
use waterui_backend_core::{AnyView, Environment};
use waterui_core::layout::{
    HorizontalAlignment, ProposalSize, Size, StretchAxis, SubView, VerticalAlignment,
    ViewDimensions,
};

// ============================================================================
// Wire types
// ============================================================================

/// A `std::any::TypeId` on the wire: FNV-1a-128 of `type_name::<T>()` as a
/// `u128`, passed as its low and high halves.
#[repr(C)]
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct WateruiTypeId {
    /// The low 64 bits of the hash.
    pub low: u64,
    /// The high 64 bits of the hash.
    pub high: u64,
}

impl WateruiTypeId {
    /// The offset basis FNV-1a-128 starts from.
    const OFFSET: u128 = 0x6c62_272e_07bb_0142_62b8_2175_6295_c58d;
    /// The prime FNV-1a-128 multiplies by.
    const PRIME: u128 = 0x0000_0000_0100_0000_0000_0000_0000_013b;

    /// The wire identity of `T`.
    #[must_use]
    pub fn of<T: 'static>() -> Self {
        Self::from_name(core::any::type_name::<T>())
    }

    /// The wire identity of the type `name` names — `AnyView::name()`'s
    /// answer for a type-erased view.
    #[must_use]
    pub const fn from_name(name: &str) -> Self {
        let bytes = name.as_bytes();
        let mut hash = Self::OFFSET;
        let mut index = 0;
        while index < bytes.len() {
            hash = (hash ^ bytes[index] as u128).wrapping_mul(Self::PRIME);
            index += 1;
        }
        #[expect(
            clippy::cast_possible_truncation,
            reason = "splitting the u128 hash into its two u64 halves is the intent"
        )]
        Self {
            low: hash as u64,
            high: (hash >> 64) as u64,
        }
    }
}

/// `ProposalSize` on the wire: a `f32` per axis, `NaN` when the axis is
/// unspecified.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct WateruiProposalSize {
    /// The width proposal, or NaN.
    pub width: f32,
    /// The height proposal, or NaN.
    pub height: f32,
}

impl WateruiProposalSize {
    fn into_proposal(self) -> ProposalSize {
        ProposalSize::new(
            (!self.width.is_nan()).then_some(self.width),
            (!self.height.is_nan()).then_some(self.height),
        )
    }

    fn from_proposal(proposal: ProposalSize) -> Self {
        Self {
            width: proposal.width.unwrap_or(f32::NAN),
            height: proposal.height.unwrap_or(f32::NAN),
        }
    }
}

/// `Size` on the wire.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct WateruiSize {
    /// The width.
    pub width: f32,
    /// The height.
    pub height: f32,
}

/// `Point` on the wire.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct WateruiPoint {
    /// The x coordinate.
    pub x: f32,
    /// The y coordinate.
    pub y: f32,
}

/// `Rect` on the wire: an origin and a size.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct WateruiRect {
    /// The origin.
    pub origin: WateruiPoint,
    /// The size.
    pub size: WateruiSize,
}

impl WateruiRect {
    /// The frame as a kit `Rect` (kit geometry is `f64`).
    #[must_use]
    pub fn into_kit(self) -> cocoa_ui::Rect {
        cocoa_ui::Rect::new(
            f64::from(self.origin.x),
            f64::from(self.origin.y),
            f64::from(self.size.width),
            f64::from(self.size.height),
        )
    }

    /// The frame as a `WaterUI` `Rect`.
    #[must_use]
    pub const fn into_layout(self) -> waterui_core::layout::Rect {
        waterui_core::layout::Rect::new(
            waterui_core::layout::Point::new(self.origin.x, self.origin.y),
            waterui_core::layout::Size::new(self.size.width, self.size.height),
        )
    }
}

impl From<cocoa_ui::Rect> for WateruiRect {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "kit geometry is f64; WaterUI layout is f32 by contract"
    )]
    fn from(rect: cocoa_ui::Rect) -> Self {
        Self {
            origin: WateruiPoint {
                x: rect.origin.x as f32,
                y: rect.origin.y as f32,
            },
            size: WateruiSize {
                width: rect.size.width as f32,
                height: rect.size.height as f32,
            },
        }
    }
}

/// A `HorizontalAlignment` on the wire, by its position in the table below.
#[repr(u8)]
#[derive(Clone, Copy, Debug)]
pub enum WateruiHorizontalGuideAlignment {
    /// The leading edge.
    Leading = 0,
    /// The horizontal center.
    Center = 1,
    /// The trailing edge.
    Trailing = 2,
}

impl WateruiHorizontalGuideAlignment {
    const fn into_alignment(self) -> HorizontalAlignment {
        match self {
            Self::Leading => HorizontalAlignment::Leading,
            Self::Center => HorizontalAlignment::Center,
            Self::Trailing => HorizontalAlignment::Trailing,
        }
    }

    fn from_alignment(alignment: HorizontalAlignment) -> Self {
        if alignment == HorizontalAlignment::Leading {
            Self::Leading
        } else if alignment == HorizontalAlignment::Trailing {
            Self::Trailing
        } else {
            Self::Center
        }
    }
}

/// A `VerticalAlignment` on the wire.
#[repr(u8)]
#[derive(Clone, Copy, Debug)]
pub enum WateruiVerticalGuideAlignment {
    /// The top edge.
    Top = 0,
    /// The vertical center.
    Center = 1,
    /// The bottom edge.
    Bottom = 2,
    /// The first text baseline.
    FirstBaseline = 3,
    /// The last text baseline.
    LastBaseline = 4,
}

impl WateruiVerticalGuideAlignment {
    const fn into_alignment(self) -> VerticalAlignment {
        match self {
            Self::Top => VerticalAlignment::Top,
            Self::Center => VerticalAlignment::Center,
            Self::Bottom => VerticalAlignment::Bottom,
            Self::FirstBaseline => VerticalAlignment::FirstBaseline,
            Self::LastBaseline => VerticalAlignment::LastBaseline,
        }
    }

    fn from_alignment(alignment: VerticalAlignment) -> Self {
        if alignment == VerticalAlignment::Top {
            Self::Top
        } else if alignment == VerticalAlignment::Bottom {
            Self::Bottom
        } else if alignment == VerticalAlignment::FirstBaseline {
            Self::FirstBaseline
        } else if alignment == VerticalAlignment::LastBaseline {
            Self::LastBaseline
        } else {
            Self::Center
        }
    }
}

/// An explicit horizontal guide: an alignment and its offset.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct WateruiHorizontalGuide {
    /// Which alignment the guide belongs to.
    pub alignment: WateruiHorizontalGuideAlignment,
    /// The guide's offset within the measured size.
    pub value: f32,
}

/// An explicit vertical guide: an alignment and its offset.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct WateruiVerticalGuide {
    /// Which alignment the guide belongs to.
    pub alignment: WateruiVerticalGuideAlignment,
    /// The guide's offset within the measured size.
    pub value: f32,
}

/// An owned array on the wire: the allocation, its length and capacity, and
/// the function that frees it.
///
/// The producer allocates `data` however it chooses and must answer `free`
/// with a function that releases exactly that allocation given `data`, `len`
/// and `cap`; a Rust `Vec<T>` is released by rebuilding it. An empty array
/// has `data` null and `free` never called.
#[repr(C)]
#[derive(Debug)]
pub struct WateruiArray<T: 'static> {
    /// The first element, or null.
    pub data: *mut T,
    /// The number of elements.
    pub len: usize,
    /// The elements the allocation can hold.
    pub cap: usize,
    /// Frees the allocation once; never called on a null `data`.
    pub free: Option<unsafe extern "C" fn(data: *mut T, len: usize, cap: usize)>,
}

impl<T: 'static> Default for WateruiArray<T> {
    fn default() -> Self {
        Self {
            data: ptr::null_mut(),
            len: 0,
            cap: 0,
            free: None,
        }
    }
}

impl<T: 'static> WateruiArray<T> {
    /// The array's elements as a slice.
    ///
    /// # Safety
    ///
    /// `data` must point to `len` initialized `T`s, as the producer's contract
    /// requires.
    #[must_use]
    pub const unsafe fn as_slice(&self) -> &[T] {
        // SAFETY: the caller contract requires `data` to head `len`
        // initialized `T`s.
        unsafe {
            if self.data.is_null() {
                &[]
            } else {
                core::slice::from_raw_parts(self.data, self.len)
            }
        }
    }

    fn from_vec(mut vec: Vec<T>) -> Self {
        /// Rebuilds the `Vec` and drops it.
        ///
        /// # Safety
        ///
        /// `data`, `len` and `cap` must be the raw parts of a `Vec<T>`.
        unsafe extern "C" fn free_vec<T>(data: *mut T, len: usize, cap: usize) {
            // SAFETY: `WateruiArray::from_vec` pairs this free function with the
            // raw parts of the `Vec<T>` it consumed.
            unsafe { drop(Vec::from_raw_parts(data, len, cap)) };
        }
        let array = Self {
            data: vec.as_mut_ptr(),
            len: vec.len(),
            cap: vec.capacity(),
            free: Some(free_vec::<T>),
        };
        core::mem::forget(vec);
        array
    }
}

impl<T: 'static> Drop for WateruiArray<T> {
    fn drop(&mut self) {
        if let Some(free) = self.free {
            // SAFETY: the producer's contract pairs `free` with this
            // allocation, and `Drop` runs once.
            unsafe { free(self.data, self.len, self.cap) };
        }
    }
}

/// `ViewDimensions` on the wire.
#[repr(C)]
#[derive(Debug, Default)]
pub struct WateruiViewDimensions {
    /// The measured size.
    pub size: WateruiSize,
    /// The explicit horizontal guides.
    pub horizontal_guides: WateruiArray<WateruiHorizontalGuide>,
    /// The explicit vertical guides.
    pub vertical_guides: WateruiArray<WateruiVerticalGuide>,
}

impl WateruiViewDimensions {
    fn into_dimensions(self) -> ViewDimensions {
        // SAFETY: the producer contract makes each guide array own `len`
        // initialized entries at `data`.
        let (horizontals, verticals) = unsafe {
            (
                self.horizontal_guides.as_slice(),
                self.vertical_guides.as_slice(),
            )
        };
        let mut dimensions = ViewDimensions::new(Size {
            width: self.size.width,
            height: self.size.height,
        });
        for guide in horizontals {
            dimensions.set_horizontal(guide.alignment.into_alignment(), guide.value);
        }
        for guide in verticals {
            dimensions.set_vertical(guide.alignment.into_alignment(), guide.value);
        }
        dimensions
    }

    fn from_dimensions(dimensions: &ViewDimensions) -> Self {
        Self {
            size: WateruiSize {
                width: dimensions.size.width,
                height: dimensions.size.height,
            },
            horizontal_guides: WateruiArray::from_vec(
                dimensions
                    .explicit_horizontal_guides()
                    .map(|(alignment, value)| WateruiHorizontalGuide {
                        alignment: WateruiHorizontalGuideAlignment::from_alignment(alignment),
                        value,
                    })
                    .collect(),
            ),
            vertical_guides: WateruiArray::from_vec(
                dimensions
                    .explicit_vertical_guides()
                    .map(|(alignment, value)| WateruiVerticalGuide {
                        alignment: WateruiVerticalGuideAlignment::from_alignment(alignment),
                        value,
                    })
                    .collect(),
            ),
        }
    }
}

/// `StretchAxis` on the wire.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WateruiStretchAxis {
    /// Content-sized on both axes.
    None = 0,
    /// Stretches horizontally only.
    Horizontal = 1,
    /// Stretches vertically only.
    Vertical = 2,
    /// Stretches on both axes.
    Both = 3,
    /// Stretches along the container's main axis.
    MainAxis = 4,
    /// Stretches along the container's cross axis.
    CrossAxis = 5,
}

impl From<WateruiStretchAxis> for StretchAxis {
    fn from(axis: WateruiStretchAxis) -> Self {
        match axis {
            WateruiStretchAxis::None => Self::None,
            WateruiStretchAxis::Horizontal => Self::Horizontal,
            WateruiStretchAxis::Vertical => Self::Vertical,
            WateruiStretchAxis::Both => Self::Both,
            WateruiStretchAxis::MainAxis => Self::MainAxis,
            WateruiStretchAxis::CrossAxis => Self::CrossAxis,
        }
    }
}

impl From<StretchAxis> for WateruiStretchAxis {
    fn from(axis: StretchAxis) -> Self {
        match axis {
            StretchAxis::None => Self::None,
            StretchAxis::Horizontal => Self::Horizontal,
            StretchAxis::Vertical => Self::Vertical,
            StretchAxis::Both => Self::Both,
            StretchAxis::MainAxis => Self::MainAxis,
            StretchAxis::CrossAxis => Self::CrossAxis,
        }
    }
}

/// A leaf's layout face: the `SubView` contract as a context pointer and a
/// callback per question the parent asks.
///
/// `context` is whatever the producer needs its callbacks to see — a
/// retained object on the Swift side, a boxed `dyn SubView` here. `drop` runs
/// once, when the leaf's owner lets go; the leaf's native view is retained
/// and released separately from `context`. The query callbacks are live
/// reads — a leaf whose stretch axis or emptiness changes answers the new
/// value on the next call, not the one fixed at creation.
#[repr(C)]
#[derive(Debug)]
pub struct WateruiSubView {
    /// The producer's opaque context; null on an unclaimed leaf.
    pub context: *mut c_void,
    /// Measures the leaf for a proposal; the returned dimensions are owned by
    /// the caller, which drops them (releasing the guide arrays).
    pub measure: unsafe extern "C" fn(
        context: *mut c_void,
        proposal: WateruiProposalSize,
    ) -> WateruiViewDimensions,
    /// Delivers the proposal the parent selected when it placed the leaf —
    /// `WuiComponent.setPlacementProposal`. Leaves may ignore it.
    pub place: unsafe extern "C" fn(context: *mut c_void, proposal: WateruiProposalSize),
    /// Which axes the leaf stretches on, asked on every layout pass.
    pub stretch_axis: unsafe extern "C" fn(context: *mut c_void) -> WateruiStretchAxis,
    /// Layout priority; higher is measured first.
    pub priority: unsafe extern "C" fn(context: *mut c_void) -> i32,
    /// Whether the leaf renders nothing.
    pub is_empty: unsafe extern "C" fn(context: *mut c_void) -> bool,
    /// Releases `context` once.
    pub drop: unsafe extern "C" fn(context: *mut c_void),
}

impl Drop for WateruiSubView {
    fn drop(&mut self) {
        if self.context.is_null() {
            return;
        }
        // SAFETY: `context` was registered with this `drop` by the producer
        // and is released exactly once, here.
        unsafe { (self.drop)(self.context) }
    }
}

impl SubView for WateruiSubView {
    fn measure(&self, proposal: ProposalSize) -> ViewDimensions {
        // SAFETY: `context` is alive for as long as the leaf is, by the leaf
        // contract; the returned `WateruiViewDimensions` is consumed here.
        unsafe { (self.measure)(self.context, WateruiProposalSize::from_proposal(proposal)) }
            .into_dimensions()
    }

    fn stretch_axis(&self) -> StretchAxis {
        // SAFETY: `context` is alive for as long as the leaf is.
        unsafe { (self.stretch_axis)(self.context) }.into()
    }

    fn priority(&self) -> i32 {
        // SAFETY: `context` is alive for as long as the leaf is.
        unsafe { (self.priority)(self.context) }
    }

    fn is_empty(&self) -> bool {
        // SAFETY: `context` is alive for as long as the leaf is.
        unsafe { (self.is_empty)(self.context) }
    }
}

/// A leaf crossing the seam, returned by value.
///
/// `view` is +1 retained and owned by the receiver (Rust:
/// `Retained::from_raw`; Swift: `takeRetainedValue`), or null for "not
/// claimed" — in which case `subview.drop` is a no-op and `context` is
/// null.
#[repr(C)]
#[derive(Debug)]
pub struct WateruiLeaf {
    /// A retained `NSView`/`UIView`, or null when the view is unclaimed.
    pub view: *mut c_void,
    /// The leaf's `SubView` face.
    pub subview: WateruiSubView,
}

impl WateruiLeaf {
    /// The answer for a view nobody claims.
    fn unclaimed() -> Self {
        unsafe extern "C" fn measure(
            _context: *mut c_void,
            _proposal: WateruiProposalSize,
        ) -> WateruiViewDimensions {
            WateruiViewDimensions::default()
        }
        const unsafe extern "C" fn place(_context: *mut c_void, _proposal: WateruiProposalSize) {}
        const unsafe extern "C" fn stretch_axis(_context: *mut c_void) -> WateruiStretchAxis {
            WateruiStretchAxis::None
        }
        const unsafe extern "C" fn priority(_context: *mut c_void) -> i32 {
            0
        }
        const unsafe extern "C" fn is_empty(_context: *mut c_void) -> bool {
            true
        }
        const unsafe extern "C" fn drop(_context: *mut c_void) {}
        Self {
            view: ptr::null_mut(),
            subview: WateruiSubView {
                context: ptr::null_mut(),
                measure,
                place,
                stretch_axis,
                priority,
                is_empty,
                drop,
            },
        }
    }
}

/// Packages a Rust `SubView` for the other side of the seam.
///
/// The returned `WateruiSubView` answers every query live through `subview`
/// and drops it once. `place` is a no-op until `SubView` grows a placement
/// hook a container needs.
#[must_use]
pub fn into_wire(subview: Box<dyn SubView>) -> WateruiSubView {
    unsafe extern "C" fn measure(
        context: *mut c_void,
        proposal: WateruiProposalSize,
    ) -> WateruiViewDimensions {
        // SAFETY: `into_wire` pairs `context` with the `Box<dyn SubView>` it
        // consumed; the box is alive until `drop` runs.
        let subview = unsafe { &**context.cast::<Box<dyn SubView>>() };
        WateruiViewDimensions::from_dimensions(&subview.measure(proposal.into_proposal()))
    }

    const unsafe extern "C" fn place(_context: *mut c_void, _proposal: WateruiProposalSize) {
        // `SubView` has no placement hook yet; the field exists in the ABI so
        // a later one does not change it.
    }

    unsafe extern "C" fn stretch_axis(context: *mut c_void) -> WateruiStretchAxis {
        // SAFETY: as `measure`.
        let subview = unsafe { &**context.cast::<Box<dyn SubView>>() };
        subview.stretch_axis().into()
    }

    unsafe extern "C" fn priority(context: *mut c_void) -> i32 {
        // SAFETY: as `measure`.
        let subview = unsafe { &**context.cast::<Box<dyn SubView>>() };
        subview.priority()
    }

    unsafe extern "C" fn is_empty(context: *mut c_void) -> bool {
        // SAFETY: as `measure`.
        let subview = unsafe { &**context.cast::<Box<dyn SubView>>() };
        subview.is_empty()
    }

    unsafe extern "C" fn drop(context: *mut c_void) {
        // SAFETY: `context` is the `Box::into_raw` of the `Box<Box<dyn SubView>>`
        // `into_wire` consumed; reclaiming it frees the leaf exactly once.
        unsafe { std::mem::drop(Box::from_raw(context.cast::<Box<dyn SubView>>())) };
    }

    let context = Box::into_raw(Box::new(subview)).cast::<c_void>();
    WateruiSubView {
        context,
        measure,
        place,
        stretch_axis,
        priority,
        is_empty,
        drop,
    }
}

// ============================================================================
// The seam itself
// ============================================================================

// The opaque-pointer contract: `AnyView` and `Environment` cross as owning
// `*mut` pointers whose layout stays private to Rust — the FFI-safety lint
// flags the names, but these types are opaque on the other side by design.
#[expect(
    improper_ctypes,
    reason = "views and environments are opaque across the seam"
)]
unsafe extern "C" {
    /// Renders `view` through the Swift fallback's registry.
    ///
    /// `view` and `env` are consumed: the fallback retains what it needs of
    /// each. The returned leaf's `view` is +1 and owned by this call
    /// (`Retained::from_raw`); a null `view` means the fallback does not
    /// claim the view either.
    pub fn waterui_swift_render(view: *mut AnyView, env: *mut Environment) -> WateruiLeaf;

    /// Installs the fallback's environment services into `env`: the GPU
    /// runtime (whose creation is asynchronous) and the service objects the
    /// fallback's components read (`WuiNativeServices`, the window manager,
    /// the view renderer). `env` is borrowed for the call; `callback` runs
    /// on the main thread once everything is installed.
    ///
    /// The web view controller is deliberately absent: an application that
    /// installs its own engine must not find the platform one already
    /// occupying the slot. [`waterui_swift_install_webview`] fills it on the
    /// render environment after `app` has run.
    pub fn waterui_swift_prepare_env(
        env: *mut Environment,
        context: *mut c_void,
        callback: unsafe extern "C" fn(*mut c_void),
    );

    /// Installs the platform `WebViewController` into `env` when the
    /// application left the slot empty — the fallback's `WebView` draws
    /// through it. Runs on the main thread; `env` is borrowed for the call.
    pub fn waterui_swift_install_webview(env: *mut Environment);

    /// Runs `callback` on the main thread once `view` — a platform view the
    /// fallback produced through [`waterui_swift_render`] — reports its first
    /// frame ready.
    pub fn waterui_swift_when_ready(
        view: *mut c_void,
        context: *mut c_void,
        callback: unsafe extern "C" fn(*mut c_void),
    );

    /// Attaches the window's toolbar: `content` renders as the fallback's
    /// toolbar host and is installed on the platform window `window`. Both
    /// pointers are consumed (the toolbar keeps what it retains).
    #[cfg(target_os = "macos")]
    pub fn waterui_swift_install_toolbar(
        content: *mut AnyView,
        env: *mut Environment,
        window: *mut c_void,
    );

    /// The frame a leaf's platform view takes inside a host of `bounds`,
    /// after safe-area rules: `host.bounds` when the leaf manages its own
    /// safe area, otherwise the host's safe-area-inset rect. `view` is
    /// borrowed for the call; only the fallback can answer it, because
    /// whether a leaf manages the safe area is a property of the Swift leaf
    /// class (`wuiHandlesSafeArea`).
    pub fn waterui_swift_content_frame(view: *mut c_void, bounds: WateruiRect) -> WateruiRect;

    /// Answers the identity of every view type the fallback currently claims,
    /// for the debug-time disjointness check. The returned array is owned by
    /// the caller.
    #[cfg(debug_assertions)]
    pub fn waterui_swift_claims() -> WateruiArray<WateruiTypeId>;
}

/// The layout face a Rust leaf carries across the seam: the leaf's own
/// `SubView` plus its `KeepAlive`, so watchers stay alive exactly as long
/// as the other side can measure through it.
struct SeamOwned {
    _keepalive: crate::contract::KeepAlive,
    layout: Box<dyn SubView>,
}

impl SubView for SeamOwned {
    fn measure(&self, proposal: ProposalSize) -> ViewDimensions {
        self.layout.measure(proposal)
    }

    fn stretch_axis(&self) -> StretchAxis {
        self.layout.stretch_axis()
    }

    fn priority(&self) -> i32 {
        self.layout.priority()
    }

    fn is_empty(&self) -> bool {
        self.layout.is_empty()
    }
}

/// A `waterui_apple_resolve` answer.
///
/// `leaf` carries the claimed leaf, or `expanded` carries a `Box<AnyView>`
/// the caller re-walks — the unclaimed `Native` expanded to its
/// `with_fallback` view. Both empty means neither side claims the view.
#[repr(C)]
#[derive(Debug)]
pub struct WateruiResolution {
    /// The claimed leaf, or [`WateruiLeaf::unclaimed`] when `expanded` is set
    /// or nobody claims the view.
    pub leaf: WateruiLeaf,
    /// The expanded `AnyView` to re-walk, or null.
    pub expanded: *mut AnyView,
}

/// Resolves `view` through the Rust dispatcher.
///
/// `Swift` calls this for a view it does not claim — a leaf, metadata or
/// `Native` config registered on the Rust side. `view` and `env` are
/// consumed: this function retains what it keeps. The answer's `leaf.view` is
/// +1 and owned by the caller (`takeRetainedValue`); `expanded` carries a
/// `Box<AnyView>` the caller takes and re-walks. One direction only, so the
/// seam cannot recurse.
///
/// # Safety
///
/// `view` must be a `Box<AnyView>` allocation and `env` a `Box<Environment>`
/// one, each owned by this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn waterui_apple_resolve(
    view: *mut AnyView,
    env: *mut Environment,
) -> WateruiResolution {
    // SAFETY: the caller contract hands ownership of both boxes to this call.
    let (view, env) = unsafe { (*Box::from_raw(view), *Box::from_raw(env)) };
    match crate::dispatch::render_across_seam(view, &env) {
        crate::dispatch::SeamResolution::Claimed(leaf) => {
            let (view, layout, keepalive) = leaf.into_parts();
            WateruiResolution {
                leaf: WateruiLeaf {
                    // `into_raw` hands the +1 to the caller; `SeamOwned` keeps
                    // the leaf's watchers and layout face inside the wire
                    // `subview`.
                    view: Retained::into_raw(view).cast::<c_void>(),
                    subview: into_wire(Box::new(SeamOwned {
                        _keepalive: keepalive,
                        layout,
                    })),
                },
                expanded: ptr::null_mut(),
            }
        }
        crate::dispatch::SeamResolution::Expand(view) => WateruiResolution {
            leaf: WateruiLeaf::unclaimed(),
            expanded: Box::into_raw(Box::new(view)),
        },
        crate::dispatch::SeamResolution::Miss => WateruiResolution {
            leaf: WateruiLeaf::unclaimed(),
            expanded: ptr::null_mut(),
        },
    }
}

/// Whether `view` is a `Native`/`Metadata` wrapper — the types whose
/// `body()` panics instead of expanding, so the Swift resolve walk asks this
/// before it calls `waterui_view_body`.
///
/// # Safety
///
/// `view` is borrowed for the call and must point at a live `AnyView`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn waterui_apple_needs_fallback(view: *const AnyView) -> bool {
    // SAFETY: the caller contract keeps `view` a live `AnyView` for the call.
    crate::dispatch::needs_fallback(unsafe { &*view })
}

/// The type ids the Rust dispatcher claims — the debug half of the seam's
/// "exactly one owner per type" invariant. Stage 0 claims none.
#[cfg(debug_assertions)]
fn rust_claims(mtm: cocoa_ui::MainThreadMarker) -> Vec<WateruiTypeId> {
    crate::dispatch::claimed_type_names(mtm)
        .map(WateruiTypeId::from_name)
        .collect()
}

/// Asserts the seam's disjointness invariant: no `TypeId` may be registered
/// on both sides. Runs once, when the first view crosses.
#[cfg(debug_assertions)]
pub(crate) fn assert_disjoint(mtm: cocoa_ui::MainThreadMarker) {
    static ONCE: std::sync::Once = std::sync::Once::new();
    let _ = mtm;
    ONCE.call_once(|| {
        // SAFETY: the returned array is owned by this call per the seam
        // contract; `as_slice` borrows it for the read.
        let claims = unsafe { waterui_swift_claims() };
        // SAFETY: `claims` heads `len` initialized ids.
        let claims = unsafe { claims.as_slice() };
        let mine = rust_claims(mtm);
        for &claim in claims {
            debug_assert!(
                !mine.contains(&claim),
                "a WaterUI view type is registered on both sides of the Rust/Swift seam"
            );
        }
    });
}
