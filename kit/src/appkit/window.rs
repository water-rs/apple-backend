//! Top-level windows.
//!
//! # Safety
//!
//! The `unsafe` here creates a window, keeps it from releasing itself, and
//! defines its delegate class. A window created in code releases itself when
//! closed unless told otherwise, which would free it under the `Retained` this
//! wrapper owns; [`Window::new`] turns that off before anything else touches
//! the window. The delegate's method has the signature `NSWindowDelegate`
//! declares, and `AppKit` sends it on the main thread.

use std::cell::RefCell;
use std::fmt;
use std::rc::Rc;

use bitflags::bitflags;
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
use objc2_app_kit::{NSBackingStoreType, NSView, NSWindow, NSWindowDelegate, NSWindowStyleMask};
use objc2_foundation::{NSNotification, NSObject, NSObjectProtocol, NSString};

use crate::callback::guarded;
use crate::geometry::{Rect, Size};

bitflags! {
    /// The parts of a window's frame. No flags is a borderless window.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub struct WindowStyle: u8 {
        /// A title bar.
        const TITLED = 1 << 0;
        /// A close button.
        const CLOSABLE = 1 << 1;
        /// A minimize button.
        const MINIATURIZABLE = 1 << 2;
        /// Resizable edges and a zoom button.
        const RESIZABLE = 1 << 3;
    }
}

impl WindowStyle {
    fn native(self) -> NSWindowStyleMask {
        [
            (Self::TITLED, NSWindowStyleMask::Titled),
            (Self::CLOSABLE, NSWindowStyleMask::Closable),
            (Self::MINIATURIZABLE, NSWindowStyleMask::Miniaturizable),
            (Self::RESIZABLE, NSWindowStyleMask::Resizable),
        ]
        .into_iter()
        .filter(|(part, _)| self.contains(*part))
        .fold(NSWindowStyleMask::Borderless, |mask, (_, native)| {
            mask | native
        })
    }
}

/// A top-level window.
///
/// The window lives as long as this value: dropping it closes the window.
pub struct Window {
    window: Retained<NSWindow>,
    delegate: Retained<Delegate>,
}

impl Window {
    /// A hidden window whose content area is `content_rect`, in screen
    /// coordinates, with the frame parts in `style`.
    ///
    /// The window draws into a buffer and creates it immediately. Show it
    /// with [`Window::make_key_and_order_front`].
    #[must_use]
    pub fn new(mtm: MainThreadMarker, content_rect: Rect, style: WindowStyle) -> Self {
        // SAFETY: see the module safety note.
        let window = unsafe {
            NSWindow::initWithContentRect_styleMask_backing_defer(
                NSWindow::alloc(mtm),
                content_rect.into(),
                style.native(),
                NSBackingStoreType::Buffered,
                false,
            )
        };
        // SAFETY: see the module safety note.
        unsafe { window.setReleasedWhenClosed(false) };
        let delegate = Delegate::new(mtm);
        window.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
        Self { window, delegate }
    }

    /// Sets the text of the title bar.
    pub fn set_title(&self, title: &str) {
        self.window.setTitle(&NSString::from_str(title));
    }

    /// The window's content area, in screen coordinates: its frame without
    /// the title bar and borders.
    #[must_use]
    pub fn content_rect(&self) -> Rect {
        self.window
            .contentRectForFrameRect(self.window.frame())
            .into()
    }

    /// Makes `view` fill the content area, replacing the view there.
    pub fn set_content_view(&self, view: &NSView) {
        self.window.setContentView(Some(view));
    }

    /// Moves the window to the center of its screen, a little above the
    /// middle.
    pub fn center(&self) {
        self.window.center();
    }

    /// Shows the window in front of the application's other windows and gives
    /// it keyboard focus.
    pub fn make_key_and_order_front(&self) {
        self.window.makeKeyAndOrderFront(None);
    }

    /// The smallest content area the user can resize the window to.
    #[must_use]
    pub fn content_min_size(&self) -> Size {
        self.window.contentMinSize().into()
    }

    /// Sets the smallest content area the user can resize the window to.
    pub fn set_content_min_size(&self, size: Size) {
        self.window.setContentMinSize(size.into());
    }

    /// Calls `handler` every time the window is about to close, replacing any
    /// handler set before.
    pub fn on_close(&self, handler: impl Fn() + 'static) {
        self.delegate.ivars().close.replace(Some(Rc::new(handler)));
    }

    /// Draws every part of the window marked as needing display, now rather
    /// than at the end of this turn of the run loop.
    pub fn display_if_needed(&self) {
        self.window.displayIfNeeded();
    }
}

impl fmt::Debug for Window {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Window")
            .field("window", &self.window)
            .finish_non_exhaustive()
    }
}

impl Drop for Window {
    fn drop(&mut self) {
        // The close handler belongs to the value being dropped, so it does not
        // hear about this close.
        self.window.setDelegate(None);
        self.window.close();
    }
}

#[derive(Default)]
struct DelegateIvars {
    close: RefCell<Option<Rc<dyn Fn()>>>,
}

define_class!(
    // SAFETY: `NSObject` has no subclassing requirements, and the class does
    // not implement `Drop`.
    #[unsafe(super(NSObject))]
    #[name = "WaterUIAppleKitWindowDelegate"]
    #[thread_kind = MainThreadOnly]
    #[ivars = DelegateIvars]
    struct Delegate;

    // SAFETY: `NSObjectProtocol` asks nothing of an `NSObject` subclass.
    unsafe impl NSObjectProtocol for Delegate {}

    // SAFETY: see the module safety note.
    unsafe impl NSWindowDelegate for Delegate {
        #[unsafe(method(windowWillClose:))]
        fn window_will_close(&self, _notification: &NSNotification) {
            guarded("windowWillClose:", || {
                // Cloned out of the cell so the handler may replace itself.
                let handler = self.ivars().close.borrow().clone();
                if let Some(handler) = handler {
                    handler();
                }
            });
        }
    }
);

impl Delegate {
    fn new(mtm: MainThreadMarker) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(DelegateIvars::default());
        // SAFETY: `init` is `NSObject`'s designated initializer.
        unsafe { msg_send![super(this), init] }
    }
}

#[cfg(test)]
mod tests {
    use objc2_app_kit::NSWindowStyleMask;

    use super::WindowStyle;

    #[test]
    fn style_maps_to_its_mask() {
        assert_eq!(
            WindowStyle::all().native(),
            NSWindowStyleMask::Titled
                | NSWindowStyleMask::Closable
                | NSWindowStyleMask::Miniaturizable
                | NSWindowStyleMask::Resizable
        );
        assert_eq!(
            (WindowStyle::TITLED | WindowStyle::RESIZABLE).native(),
            NSWindowStyleMask::Titled | NSWindowStyleMask::Resizable
        );
        assert_eq!(WindowStyle::empty().native(), NSWindowStyleMask::Borderless);
    }
}
