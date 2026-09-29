//! The navigation group: navigation stacks, split views, tab containers,
//! the navigation bar model, menus and the window's toolbar, plus the
//! metadata the group consumes.
//!
//! `Native<NavigationView>` is a page: chrome (title, items, search) plus
//! content. Inside a `NavigationStack` the platform's own navigation chrome
//! hosts the bar (`UINavigationBar` on `UIKit`, the window toolbar on
//! `AppKit`); standalone it draws an in-content bar. `Native<NavigationStack>`
//! is the stack container, `Native<NavigationSplitLayout>` a two- or
//! three-column split, `Native<TabsLayout>` the platform's tab container,
//! and `Native<ResolvedMenu>` a menu trigger.

use alloc::rc::Rc;
use alloc::string::String;
use alloc::vec::Vec;

use cocoa_ui::PlatformView;
use waterui::component::menu::{
    CommandRole, ResolvedCommand, ResolvedMenuItem, ResolvedNestedMenu,
};
use waterui::reactive::Signal;
use waterui_backend_core::Environment;

pub mod bar;
pub mod menu;
pub mod metadata;
pub mod nav_view;
pub mod split;
pub mod stack;
pub mod tabs;

/// Installs every navigation handler on the dispatcher.
pub fn install(dispatcher: &mut crate::dispatch::Dispatcher) {
    metadata::install(dispatcher);
    menu::install(dispatcher);
    nav_view::install(dispatcher);
    stack::install(dispatcher);
    split::install(dispatcher);
    tabs::install(dispatcher);
}

/// The first plain-text string a rendered subtree's text views carry —
/// `extractNavigationTitleText`'s walk: labels on `UIKit`, text fields on
/// `AppKit`, depth-first.
#[cfg(target_os = "macos")]
pub fn extract_title_text(view: &PlatformView) -> Option<String> {
    use cocoa_ui::objc2_app_kit::NSTextField;
    for subview in cocoa_ui::view::subviews(view)
        .iter()
        .chain(core::iter::once(&cocoa_ui::view::retain_base(view)))
    {
        if let Some(field) = subview.downcast_ref::<NSTextField>() {
            let text = field.stringValue().to_string();
            if !text.is_empty() {
                return Some(text);
            }
            let attributed = field.attributedStringValue().string().to_string();
            if !attributed.is_empty() {
                return Some(attributed);
            }
        }
        if let Some(found) = extract_title_text(subview) {
            return Some(found);
        }
    }
    None
}

/// The first plain-text string a rendered subtree's text views carry —
/// `extractNavigationTitleText`'s walk on `UIKit`.
#[cfg(target_os = "ios")]
pub fn extract_title_text(view: &PlatformView) -> Option<String> {
    use cocoa_ui::objc2_ui_kit::UILabel;
    for subview in cocoa_ui::view::subviews(view)
        .iter()
        .chain(core::iter::once(&cocoa_ui::view::retain_base(view)))
    {
        if let Some(label) = subview.downcast_ref::<UILabel>() {
            let text = label
                .attributedText()
                .map(|text| text.string().to_string())
                .or_else(|| label.text().map(|text| text.to_string()));
            if let Some(text) = text.filter(|text| !text.is_empty()) {
                return Some(text);
            }
        }
        if let Some(found) = extract_title_text(subview) {
            return Some(found);
        }
    }
    None
}

/// A resolved command as the kit's shared `Command` payload — label text,
/// subtitle, symbol name, destructive flag and shortcut.
fn kit_command(command: &ResolvedCommand) -> cocoa_ui::menu::Command {
    kit_command_fields(
        command.label.content.snapshot().to_plain().to_string(),
        command.subtitle.as_ref().map(ToString::to_string),
        command.icon.as_ref().map(|icon| icon.name.to_string()),
        command.role,
        command.shortcut.as_ref(),
    )
}

/// A resolved nested menu's header as the kit's shared `Command` payload.
fn kit_command_for_menu(menu: &ResolvedNestedMenu) -> cocoa_ui::menu::Command {
    kit_command_fields(
        menu.label.content.snapshot().to_plain().to_string(),
        None,
        menu.icon.as_ref().map(|icon| icon.name.to_string()),
        CommandRole::Standard,
        None,
    )
}

fn kit_command_fields(
    label: String,
    subtitle: Option<String>,
    symbol: Option<String>,
    role: CommandRole,
    shortcut: Option<&waterui::component::menu::Shortcut>,
) -> cocoa_ui::menu::Command {
    let mut modifiers = cocoa_ui::menu::KeyModifiers::empty();
    let mut key_equivalent = String::new();
    if let Some(shortcut) = shortcut {
        key_equivalent = shortcut.key.to_string();
        if shortcut.modifiers.command() {
            modifiers |= cocoa_ui::menu::KeyModifiers::COMMAND;
        }
        if shortcut.modifiers.shift() {
            modifiers |= cocoa_ui::menu::KeyModifiers::SHIFT;
        }
        if shortcut.modifiers.option() {
            modifiers |= cocoa_ui::menu::KeyModifiers::OPTION;
        }
        if shortcut.modifiers.control() {
            modifiers |= cocoa_ui::menu::KeyModifiers::CONTROL;
        }
    }
    cocoa_ui::menu::Command {
        label,
        subtitle,
        symbol,
        destructive: matches!(role, CommandRole::Destructive),
        enabled: true,
        selected: false,
        key_equivalent,
        modifiers,
    }
}

/// Resolved items as the kit's shared `MenuTreeNode` list, with each
/// command's action bound to fire under `env`.
pub fn menu_tree(
    items: &[ResolvedMenuItem],
    env: &Environment,
) -> Vec<cocoa_ui::menu::MenuTreeNode> {
    items
        .iter()
        .map(|item| match item {
            ResolvedMenuItem::Divider => cocoa_ui::menu::MenuTreeNode::Divider,
            ResolvedMenuItem::Command(command) => {
                let action = command.action.clone();
                let env = env.clone();
                cocoa_ui::menu::MenuTreeNode::Command(
                    kit_command(command),
                    Rc::new(move || {
                        action.call(&env);
                    }),
                )
            }
            ResolvedMenuItem::Menu(menu) => cocoa_ui::menu::MenuTreeNode::Submenu(
                kit_command_for_menu(menu),
                menu_tree(&menu.items.snapshot(), env),
            ),
        })
        .collect()
}
