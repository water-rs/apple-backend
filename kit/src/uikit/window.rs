//! Windows shown in a window scene.

use objc2::MainThreadOnly;
use objc2::rc::Retained;
use objc2_ui_kit::{UIViewController, UIWindow};

use super::application::WindowScene;

/// A window, shown in the scene it was created for.
#[derive(Debug)]
pub struct Window {
    window: Retained<UIWindow>,
}

impl Window {
    /// A hidden window filling `scene`.
    #[must_use]
    pub fn new(scene: &WindowScene) -> Self {
        let scene = scene.native();
        Self {
            window: UIWindow::initWithWindowScene(UIWindow::alloc(scene.mtm()), scene),
        }
    }

    /// Makes `controller` the window's root, whose view fills the window.
    pub fn set_root_view_controller(&self, controller: &UIViewController) {
        self.window.setRootViewController(Some(controller));
    }

    /// Shows the window and makes it the key window of its scene.
    pub fn make_key_and_visible(&self) {
        self.window.makeKeyAndVisible();
    }

    /// Runs any pending layout pass of the window's views now.
    pub fn layout_if_needed(&self) {
        self.window.layoutIfNeeded();
    }

    pub(super) fn into_native(self) -> Retained<UIWindow> {
        self.window
    }
}
