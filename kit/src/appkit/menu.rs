//! Menus built from standard actions.
//!
//! # Safety
//!
//! The `unsafe` here creates menu items whose action is sent to the first
//! responder: the item has no target, so `AppKit` walks the responder chain
//! for an object that implements the action and disables the item when none
//! does. No action can reach an object that does not understand it.

use bitflags::bitflags;
use objc2::rc::Retained;
use objc2::runtime::Sel;
use objc2::{MainThreadMarker, MainThreadOnly, sel};
use objc2_app_kit::{NSEventModifierFlags, NSMenu, NSMenuItem};
use objc2_foundation::NSString;

/// A menu: a list of items, shown as the menu bar or as a submenu.
///
/// A `Menu` is a handle: clones refer to the same menu.
#[derive(Debug, Clone)]
pub struct Menu {
    menu: Retained<NSMenu>,
}

impl Menu {
    /// An empty menu titled `title`.
    #[must_use]
    pub fn new(mtm: MainThreadMarker, title: &str) -> Self {
        Self {
            menu: NSMenu::initWithTitle(NSMenu::alloc(mtm), &NSString::from_str(title)),
        }
    }

    /// Appends `item`, which belongs to this menu from then on.
    pub fn add_item(&self, item: MenuItem) {
        let MenuItem { item } = item;
        self.menu.addItem(&item);
    }

    /// Appends a separator line.
    pub fn add_separator(&self) {
        self.menu
            .addItem(&NSMenuItem::separatorItem(self.menu.mtm()));
    }

    pub(super) fn native(&self) -> &NSMenu {
        &self.menu
    }
}

/// One entry of a [`Menu`].
#[derive(Debug)]
pub struct MenuItem {
    item: Retained<NSMenuItem>,
}

impl MenuItem {
    /// An item titled `title` that performs `action` when chosen, or does
    /// nothing when `action` is `None`.
    ///
    /// `key_equivalent` is the key that chooses the item with ⌘ held (a
    /// lowercase letter, or `""` for none); [`MenuItem::with_key_modifiers`]
    /// changes which modifiers it takes.
    #[must_use]
    pub fn new(
        mtm: MainThreadMarker,
        title: &str,
        action: Option<MenuAction>,
        key_equivalent: &str,
    ) -> Self {
        // SAFETY: see the module safety note.
        let item = unsafe {
            NSMenuItem::initWithTitle_action_keyEquivalent(
                NSMenuItem::alloc(mtm),
                &NSString::from_str(title),
                action.map(MenuAction::selector),
                &NSString::from_str(key_equivalent),
            )
        };
        Self { item }
    }

    /// The same item, chosen by its key equivalent with exactly `modifiers`
    /// held instead of ⌘ alone.
    #[must_use]
    pub fn with_key_modifiers(self, modifiers: KeyModifiers) -> Self {
        self.item.setKeyEquivalentModifierMask(modifiers.native());
        self
    }

    /// The same item, opening `submenu` instead of performing an action.
    #[must_use]
    pub fn with_submenu(self, submenu: &Menu) -> Self {
        self.item.setSubmenu(Some(&submenu.menu));
        self
    }
}

/// A standard command a menu item sends to whichever object currently
/// handles it: the focused text view for editing commands, the key window for
/// window commands, the application for the rest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MenuAction {
    /// Shows the standard About panel.
    About,
    /// Hides the application.
    Hide,
    /// Hides every other application.
    HideOthers,
    /// Shows every hidden application.
    ShowAll,
    /// Quits the application.
    Quit,
    /// Undoes the last change.
    Undo,
    /// Redoes the last undone change.
    Redo,
    /// Cuts the selection to the pasteboard.
    Cut,
    /// Copies the selection to the pasteboard.
    Copy,
    /// Pastes the pasteboard's contents.
    Paste,
    /// Deletes the selection.
    Delete,
    /// Selects everything.
    SelectAll,
    /// Minimizes the key window into the Dock.
    Minimize,
    /// Toggles the key window between its standard and its user size.
    Zoom,
    /// Brings every window of the application to the front.
    BringAllToFront,
}

impl MenuAction {
    fn selector(self) -> Sel {
        match self {
            Self::About => sel!(orderFrontStandardAboutPanel:),
            Self::Hide => sel!(hide:),
            Self::HideOthers => sel!(hideOtherApplications:),
            Self::ShowAll => sel!(unhideAllApplications:),
            Self::Quit => sel!(terminate:),
            Self::Undo => sel!(undo:),
            Self::Redo => sel!(redo:),
            Self::Cut => sel!(cut:),
            Self::Copy => sel!(copy:),
            Self::Paste => sel!(paste:),
            Self::Delete => sel!(delete:),
            Self::SelectAll => sel!(selectAll:),
            Self::Minimize => sel!(miniaturize:),
            Self::Zoom => sel!(zoom:),
            Self::BringAllToFront => sel!(arrangeInFront:),
        }
    }
}

bitflags! {
    /// Modifier keys held with a key equivalent.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub struct KeyModifiers: u8 {
        /// The Command key, ⌘.
        const COMMAND = 1 << 0;
        /// The Option key, ⌥.
        const OPTION = 1 << 1;
        /// The Shift key, ⇧.
        const SHIFT = 1 << 2;
        /// The Control key, ⌃.
        const CONTROL = 1 << 3;
    }
}

impl KeyModifiers {
    fn native(self) -> NSEventModifierFlags {
        [
            (Self::COMMAND, NSEventModifierFlags::Command),
            (Self::OPTION, NSEventModifierFlags::Option),
            (Self::SHIFT, NSEventModifierFlags::Shift),
            (Self::CONTROL, NSEventModifierFlags::Control),
        ]
        .into_iter()
        .filter(|(modifier, _)| self.contains(*modifier))
        .fold(NSEventModifierFlags::empty(), |flags, (_, native)| {
            flags | native
        })
    }
}

#[cfg(test)]
mod tests {
    use objc2_app_kit::NSEventModifierFlags;

    use super::KeyModifiers;

    #[test]
    fn modifiers_map_to_their_event_flags() {
        assert_eq!(
            (KeyModifiers::COMMAND | KeyModifiers::OPTION).native(),
            NSEventModifierFlags::Command | NSEventModifierFlags::Option
        );
        assert_eq!(
            (KeyModifiers::COMMAND | KeyModifiers::SHIFT).native(),
            NSEventModifierFlags::Command | NSEventModifierFlags::Shift
        );
        assert_eq!(
            KeyModifiers::CONTROL.native(),
            NSEventModifierFlags::Control
        );
        assert_eq!(
            KeyModifiers::empty().native(),
            NSEventModifierFlags::empty()
        );
    }
}
