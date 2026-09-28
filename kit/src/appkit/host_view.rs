//! The view that hosts content laid out by Rust.
//!
//! # Safety
//!
//! The `unsafe` here defines an `NSView` subclass and forwards to `NSView`'s
//! own implementation of each method it overrides. Every override has the
//! signature `NSView` declares, and `AppKit` calls them on the main thread;
//! `isFlipped` may be asked from any thread and answers a constant.

use std::cell::RefCell;
use std::fmt;
use std::ptr;
use std::rc::Rc;

use objc2::rc::Retained;
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
use objc2_app_kit::{NSScreen, NSView};
use objc2_foundation::{NSEdgeInsets, NSObjectProtocol, NSPoint, NSRect, NSSize};

use crate::callback::guarded;
use crate::geometry::{EdgeInsets, Point, Rect, Size};

/// What a [`HostView`]'s hit-test handler decides for a point.
#[derive(Debug, Clone)]
pub enum HitTest {
    /// Whatever `AppKit` would decide: the deepest subview under the point,
    /// or the host view itself.
    Default,
    /// Nothing here: the event goes to whatever lies beneath the host view.
    Pass,
    /// This view receives the event.
    View(Retained<NSView>),
}

type LayoutHandler = Rc<dyn Fn(&HostView)>;
type ResizeHandler = Rc<dyn Fn(&HostView, Size)>;
type HitTestHandler = Rc<dyn Fn(&HostView, Point) -> HitTest>;

/// The handlers a [`HostView`] calls.
#[derive(Default)]
pub struct HostViewIvars {
    layout: RefCell<Option<LayoutHandler>>,
    resize: RefCell<Option<ResizeHandler>>,
    hit_test: RefCell<Option<HitTestHandler>>,
}

impl fmt::Debug for HostViewIvars {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HostViewIvars")
            .field("layout", &self.layout.borrow().is_some())
            .field("resize", &self.resize.borrow().is_some())
            .field("hit_test", &self.hit_test.borrow().is_some())
            .finish()
    }
}

define_class!(
    // SAFETY: `NSView` asks a subclass to initialize through its designated
    // initializer, which `HostView::new` does, and the class does not
    // implement `Drop`.
    #[unsafe(super(NSView))]
    #[name = "WaterUIAppleKitHostView"]
    #[thread_kind = MainThreadOnly]
    #[ivars = HostViewIvars]
    #[derive(Debug)]
    /// A layer-backed view whose layout, resizing and hit testing are Rust
    /// closures.
    ///
    /// Its coordinates are flipped: the origin is the top-left corner and `y`
    /// grows downward, as on iOS. Place subviews from the layout handler,
    /// which runs whenever `AppKit` lays the view out.
    pub struct HostView;

    // SAFETY: `NSObjectProtocol` asks nothing of an `NSView` subclass.
    unsafe impl NSObjectProtocol for HostView {}

    impl HostView {
        // SAFETY: see the module safety note.
        #[unsafe(method(isFlipped))]
        fn is_flipped_override(&self) -> bool {
            true
        }

        // SAFETY: see the module safety note.
        #[unsafe(method(layout))]
        fn layout_override(&self) {
            guarded("HostView layout", || {
                // SAFETY: see the module safety note.
                let _: () = unsafe { msg_send![super(self), layout] };
                let handler = self.ivars().layout.borrow().clone();
                if let Some(handler) = handler {
                    handler(self);
                }
            });
        }

        // SAFETY: see the module safety note.
        #[unsafe(method(setFrameSize:))]
        fn set_frame_size_override(&self, new_size: NSSize) {
            guarded("HostView setFrameSize:", || {
                let old_size = self.frame().size;
                // SAFETY: see the module safety note.
                let _: () = unsafe { msg_send![super(self), setFrameSize: new_size] };
                if old_size == new_size {
                    return;
                }
                let handler = self.ivars().resize.borrow().clone();
                if let Some(handler) = handler {
                    handler(self, new_size.into());
                }
            });
        }

        // SAFETY: see the module safety note.
        #[unsafe(method_id(hitTest:))]
        fn hit_test_override(&self, point: NSPoint) -> Option<Retained<NSView>> {
            guarded("HostView hitTest:", || {
                let handler = self.ivars().hit_test.borrow().clone();
                match handler.map_or(HitTest::Default, |handler| handler(self, point.into())) {
                    // SAFETY: see the module safety note.
                    HitTest::Default => unsafe { msg_send![super(self), hitTest: point] },
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
        let this = Self::alloc(mtm).set_ivars(HostViewIvars::default());
        // SAFETY: `initWithFrame:` is `NSView`'s designated initializer.
        let view: Retained<Self> =
            unsafe { msg_send![super(this), initWithFrame: NSRect::from(frame)] };
        view.setWantsLayer(true);
        view
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

    /// Lets `handler` decide which view receives a mouse event at a point,
    /// replacing any handler set before.
    ///
    /// The point is in the coordinates of the host view's superview, as
    /// `AppKit` hit testing is.
    pub fn set_hit_test_handler(&self, handler: impl Fn(&Self, Point) -> HitTest + 'static) {
        self.ivars().hit_test.replace(Some(Rc::new(handler)));
    }

    /// Adds `view` above the existing subviews.
    pub fn add_subview(&self, view: &NSView) {
        self.addSubview(view);
    }

    /// Removes `view`, one of this view's subviews.
    ///
    /// # Panics
    ///
    /// If `view` is not a subview of this view.
    pub fn remove_subview(&self, view: &NSView) {
        let this: &NSView = self;
        // SAFETY: a main-thread read of the view's superview, which the view
        // hierarchy keeps alive while `view` is in it.
        let parent = unsafe { view.superview() };
        assert!(
            parent.is_some_and(|parent| ptr::eq(&*parent, this)),
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
        self.setNeedsLayout(true);
    }

    /// Runs any pending layout pass of this view and its subviews now.
    pub fn layout_if_needed(&self) {
        self.layoutSubtreeIfNeeded();
    }

    /// Device pixels per point where the view is drawn: its window's backing
    /// scale, or the main screen's before it is in a window.
    ///
    /// `None` when the view is in no window and the system has no screen.
    #[must_use]
    pub fn display_scale(&self) -> Option<f64> {
        self.window().map_or_else(
            || NSScreen::mainScreen(self.mtm()).map(|screen| screen.backingScaleFactor()),
            |window| Some(window.backingScaleFactor()),
        )
    }

    /// The distances from each edge within which content is obscured by the
    /// window's title bar or toolbar.
    #[must_use]
    pub fn safe_area_insets(&self) -> EdgeInsets {
        let NSEdgeInsets {
            top,
            left,
            bottom,
            right,
        } = self.safeAreaInsets();
        EdgeInsets::new(top, left, bottom, right)
    }
}
