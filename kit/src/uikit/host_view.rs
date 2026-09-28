//! The view that hosts content laid out by Rust.
//!
//! # Safety
//!
//! The `unsafe` here defines a `UIView` subclass, forwards to `UIView`'s own
//! implementation of each method it overrides, and reads the view's trait
//! collection. Every override has the signature `UIView` declares, and
//! `UIKit` calls them, and trait collections are read, on the main thread.

use std::cell::{Cell, RefCell};
use std::fmt;
use std::ptr;
use std::rc::Rc;

use objc2::rc::Retained;
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
use objc2_core_foundation::{CGPoint, CGRect, CGSize};
use objc2_foundation::NSObjectProtocol;
use objc2_ui_kit::{UIEdgeInsets, UIEvent, UITraitEnvironment, UIView};

use crate::callback::guarded;
use crate::geometry::{EdgeInsets, Point, Rect, Size};

/// What a [`HostView`]'s hit-test handler decides for a point.
#[derive(Debug, Clone)]
pub enum HitTest {
    /// Whatever `UIKit` would decide: the deepest subview under the point, or
    /// the host view itself.
    Default,
    /// Nothing here: the touch goes to whatever lies beneath the host view.
    Pass,
    /// This view receives the touch.
    View(Retained<UIView>),
}

type LayoutHandler = Rc<dyn Fn(&HostView)>;
type ResizeHandler = Rc<dyn Fn(&HostView, Size)>;
type HitTestHandler = Rc<dyn Fn(&HostView, Point) -> HitTest>;

/// The handlers a [`HostView`] calls, and the state it keeps for them.
#[derive(Default)]
pub struct HostViewIvars {
    layout: RefCell<Option<LayoutHandler>>,
    resize: RefCell<Option<ResizeHandler>>,
    hit_test: RefCell<Option<HitTestHandler>>,
    /// The size the resize handler was last told about.
    reported_size: Cell<CGSize>,
    /// Whether this is a view controller's root view, which always fills its
    /// window; see [`window_root`].
    fills_window: Cell<bool>,
}

impl fmt::Debug for HostViewIvars {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HostViewIvars")
            .field("layout", &self.layout.borrow().is_some())
            .field("resize", &self.resize.borrow().is_some())
            .field("hit_test", &self.hit_test.borrow().is_some())
            .field("reported_size", &self.reported_size.get())
            .field("fills_window", &self.fills_window.get())
            .finish()
    }
}

define_class!(
    // SAFETY: `UIView` asks a subclass to initialize through its designated
    // initializer, which `HostView::new` does, and the class does not
    // implement `Drop`.
    #[unsafe(super(UIView))]
    #[name = "WaterUIAppleKitHostView"]
    #[thread_kind = MainThreadOnly]
    #[ivars = HostViewIvars]
    #[derive(Debug)]
    /// A view whose layout, resizing and hit testing are Rust closures.
    ///
    /// Place subviews from the layout handler, which runs whenever `UIKit`
    /// lays the view out.
    pub struct HostView;

    // SAFETY: `NSObjectProtocol` asks nothing of a `UIView` subclass.
    unsafe impl NSObjectProtocol for HostView {}

    impl HostView {
        // SAFETY: see the module safety note.
        #[unsafe(method(layoutSubviews))]
        fn layout_subviews_override(&self) {
            guarded("HostView layoutSubviews", || {
                // SAFETY: see the module safety note.
                let _: () = unsafe { msg_send![super(self), layoutSubviews] };
                if self.ivars().fills_window.get()
                    && let Some(window) = self.window()
                {
                    self.setFrame(window.bounds());
                }
                let handler = self.ivars().layout.borrow().clone();
                if let Some(handler) = handler {
                    handler(self);
                }
            });
        }

        // SAFETY: see the module safety note.
        #[unsafe(method(setFrame:))]
        fn set_frame_override(&self, frame: CGRect) {
            guarded("HostView setFrame:", || {
                // SAFETY: see the module safety note.
                let _: () = unsafe { msg_send![super(self), setFrame: frame] };
                self.report_size();
            });
        }

        // SAFETY: see the module safety note.
        #[unsafe(method(setBounds:))]
        fn set_bounds_override(&self, bounds: CGRect) {
            guarded("HostView setBounds:", || {
                // SAFETY: see the module safety note.
                let _: () = unsafe { msg_send![super(self), setBounds: bounds] };
                self.report_size();
            });
        }

        // SAFETY: see the module safety note.
        #[unsafe(method(safeAreaInsets))]
        fn safe_area_insets_override(&self) -> UIEdgeInsets {
            guarded("HostView safeAreaInsets", || {
                // A window root reports its window's insets, so content that
                // fills the window still learns where the window is obscured.
                if self.ivars().fills_window.get()
                    && let Some(window) = self.window()
                {
                    return window.safeAreaInsets();
                }
                // SAFETY: see the module safety note.
                unsafe { msg_send![super(self), safeAreaInsets] }
            })
        }

        // SAFETY: see the module safety note.
        #[unsafe(method_id(hitTest:withEvent:))]
        fn hit_test_override(
            &self,
            point: CGPoint,
            event: Option<&UIEvent>,
        ) -> Option<Retained<UIView>> {
            guarded("HostView hitTest:withEvent:", || {
                let handler = self.ivars().hit_test.borrow().clone();
                match handler.map_or(HitTest::Default, |handler| handler(self, point.into())) {
                    HitTest::Default => self.default_hit_test(point, event),
                    HitTest::Pass => None,
                    HitTest::View(view) => Some(view),
                }
            })
        }
    }
);

impl HostView {
    /// A host view occupying `frame` in its future superview's coordinates.
    #[must_use]
    pub fn new(mtm: MainThreadMarker, frame: Rect) -> Retained<Self> {
        Self::with_ivars(mtm, frame, HostViewIvars::default())
    }

    fn with_ivars(mtm: MainThreadMarker, frame: Rect, ivars: HostViewIvars) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(ivars);
        // SAFETY: `initWithFrame:` is `UIView`'s designated initializer.
        unsafe { msg_send![super(this), initWithFrame: CGRect::from(frame)] }
    }

    /// Calls `handler` at the end of every layout pass, replacing any handler
    /// set before. This is where subviews are given their frames.
    pub fn set_layout_handler(&self, handler: impl Fn(&Self) + 'static) {
        self.ivars().layout.replace(Some(Rc::new(handler)));
    }

    /// Calls `handler` with the new size every time the view's size changes,
    /// replacing any handler set before.
    pub fn set_resize_handler(&self, handler: impl Fn(&Self, Size) + 'static) {
        self.ivars().resize.replace(Some(Rc::new(handler)));
    }

    /// Lets `handler` decide which view receives a touch at a point,
    /// replacing any handler set before.
    ///
    /// The point is in the host view's own coordinates, as `UIKit` hit
    /// testing is.
    pub fn set_hit_test_handler(&self, handler: impl Fn(&Self, Point) -> HitTest + 'static) {
        self.ivars().hit_test.replace(Some(Rc::new(handler)));
    }

    /// Adds `view` above the existing subviews.
    pub fn add_subview(&self, view: &UIView) {
        self.addSubview(view);
    }

    /// Removes `view`, one of this view's subviews.
    ///
    /// # Panics
    ///
    /// If `view` is not a subview of this view.
    pub fn remove_subview(&self, view: &UIView) {
        let this: &UIView = self;
        assert!(
            view.superview()
                .is_some_and(|parent| ptr::eq(&*parent, this)),
            "{view:?} is not a subview of {this:?}"
        );
        view.removeFromSuperview();
    }

    /// Moves and resizes the view to `frame`, in its superview's coordinates.
    pub fn set_frame(&self, frame: Rect) {
        self.setFrame(frame.into());
    }

    /// Marks the view as needing a layout pass before it is next drawn.
    pub fn set_needs_layout(&self) {
        self.setNeedsLayout();
    }

    /// Runs any pending layout pass of this view and its subviews now.
    pub fn layout_if_needed(&self) {
        self.layoutIfNeeded();
    }

    /// Device pixels per point where the view is drawn, from its trait
    /// collection.
    ///
    /// `None` while the view is outside any window scene, where the scale is
    /// not yet known.
    #[must_use]
    pub fn display_scale(&self) -> Option<f64> {
        // SAFETY: see the module safety note.
        let scale = unsafe { self.traitCollection().displayScale() };
        (scale > 0.0).then_some(scale)
    }

    /// The distances from each edge within which content is obscured by bars,
    /// the status bar, or the rounded corners and sensor housing of the
    /// screen.
    #[must_use]
    pub fn safe_area_insets(&self) -> EdgeInsets {
        let UIEdgeInsets {
            top,
            left,
            bottom,
            right,
        } = self.safeAreaInsets();
        EdgeInsets::new(top, left, bottom, right)
    }

    /// Tells the resize handler about the current size, once per size.
    fn report_size(&self) {
        let size = self.bounds().size;
        if self.ivars().reported_size.replace(size) == size {
            return;
        }
        let handler = self.ivars().resize.borrow().clone();
        if let Some(handler) = handler {
            handler(self, size.into());
        }
    }

    /// `UIKit`'s hit test, extended for a window root: when no subview claims
    /// the point, each subview is asked again, topmost first, with the point
    /// in its own coordinates, so content placed outside the root's bounds
    /// (into the safe area, say) still receives touches.
    fn default_hit_test(
        &self,
        point: CGPoint,
        event: Option<&UIEvent>,
    ) -> Option<Retained<UIView>> {
        // SAFETY: see the module safety note.
        let hit: Option<Retained<UIView>> =
            unsafe { msg_send![super(self), hitTest: point, withEvent: event] };
        let this: &UIView = self;
        if !self.ivars().fills_window.get() || !hit.as_deref().is_some_and(|hit| ptr::eq(hit, this))
        {
            return hit;
        }
        self.subviews()
            .to_vec()
            .into_iter()
            .rev()
            .find_map(|subview| {
                subview.hitTest_withEvent(self.convertPoint_toView(point, Some(&*subview)), event)
            })
            .or(hit)
    }
}

/// A host view that serves as a view controller's root view: it always fills
/// its window, reports its window's safe-area insets, and extends hit testing
/// to subviews placed outside its bounds.
pub fn window_root(mtm: MainThreadMarker) -> Retained<HostView> {
    HostView::with_ivars(
        mtm,
        Rect::ZERO,
        HostViewIvars {
            fills_window: Cell::new(true),
            ..HostViewIvars::default()
        },
    )
}
