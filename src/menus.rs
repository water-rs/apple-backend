//! The standard macOS menu bar.
//!
//! `WaterUIMainMenu.create()` ported: App, Edit (the responder-chain items
//! keyboard shortcuts route through), and Window menus — installed at
//! launch, before any declared `menu_bar` content appends to it (the
//! declared-menu resolution lands with the navigation port).

#![cfg(target_os = "macos")]

use cocoa_ui::MainThreadMarker;
use cocoa_ui::appkit::{Application, KeyModifiers, Menu, MenuAction, MenuItem};

/// What this application calls itself in its own menu: the display name a
/// bundle chooses for people to read, then the bundle name, then the
/// process name — `WaterUIMainMenu.appName`'s order.
fn app_name() -> String {
    cocoa_ui::bundle::info_string("CFBundleDisplayName")
        .or_else(|| cocoa_ui::bundle::info_string("CFBundleName"))
        .unwrap_or_else(cocoa_ui::process::name)
}

/// The default menu bar: App, Edit, Window — the same content
/// `main.swift.tpl` installed before `app.run()`.
pub fn install_default(mtm: MainThreadMarker, application: &Application) {
    let name = app_name();
    let main = Menu::new(mtm, "");

    // App menu: About, Preferences, Services, Hide, Hide Others, Show All,
    // Quit.
    let app_menu = Menu::new(mtm, "");
    app_menu.add_item(MenuItem::new(
        mtm,
        &alloc::format!("About {name}"),
        Some(MenuAction::About),
        "",
    ));
    app_menu.add_separator();
    app_menu.add_item(MenuItem::new(mtm, "Preferences…", None, ","));
    app_menu.add_separator();
    let services = Menu::new(mtm, "Services");
    application.set_services_menu(&services);
    app_menu.add_item(MenuItem::new(mtm, "Services", None, "").with_submenu(&services));
    app_menu.add_separator();
    app_menu.add_item(MenuItem::new(
        mtm,
        &alloc::format!("Hide {name}"),
        Some(MenuAction::Hide),
        "h",
    ));
    app_menu.add_item(
        MenuItem::new(mtm, "Hide Others", Some(MenuAction::HideOthers), "h")
            .with_key_modifiers(KeyModifiers::COMMAND | KeyModifiers::OPTION),
    );
    app_menu.add_item(MenuItem::new(
        mtm,
        "Show All",
        Some(MenuAction::ShowAll),
        "",
    ));
    app_menu.add_separator();
    app_menu.add_item(MenuItem::new(
        mtm,
        &alloc::format!("Quit {name}"),
        Some(MenuAction::Quit),
        "q",
    ));
    main.add_item(MenuItem::new(mtm, "", None, "").with_submenu(&app_menu));

    // Edit menu: the responder-chain commands that make ⌘C/⌘V/⌘X/⌘A work
    // in text fields.
    let edit_menu = Menu::new(mtm, "Edit");
    edit_menu.add_item(MenuItem::new(mtm, "Undo", Some(MenuAction::Undo), "z"));
    edit_menu.add_item(
        MenuItem::new(mtm, "Redo", Some(MenuAction::Redo), "z")
            .with_key_modifiers(KeyModifiers::COMMAND | KeyModifiers::SHIFT),
    );
    edit_menu.add_separator();
    edit_menu.add_item(MenuItem::new(mtm, "Cut", Some(MenuAction::Cut), "x"));
    edit_menu.add_item(MenuItem::new(mtm, "Copy", Some(MenuAction::Copy), "c"));
    edit_menu.add_item(MenuItem::new(mtm, "Paste", Some(MenuAction::Paste), "v"));
    edit_menu.add_item(MenuItem::new(mtm, "Delete", Some(MenuAction::Delete), ""));
    edit_menu.add_item(MenuItem::new(
        mtm,
        "Select All",
        Some(MenuAction::SelectAll),
        "a",
    ));
    main.add_item(MenuItem::new(mtm, "Edit", None, "").with_submenu(&edit_menu));

    // Window menu: registered so AppKit fills it with the window list.
    let window_menu = Menu::new(mtm, "Window");
    window_menu.add_item(MenuItem::new(
        mtm,
        "Minimize",
        Some(MenuAction::Minimize),
        "m",
    ));
    window_menu.add_item(MenuItem::new(mtm, "Zoom", Some(MenuAction::Zoom), ""));
    window_menu.add_separator();
    window_menu.add_item(MenuItem::new(
        mtm,
        "Bring All to Front",
        Some(MenuAction::BringAllToFront),
        "",
    ));
    application.set_windows_menu(&window_menu);
    main.add_item(MenuItem::new(mtm, "Window", None, "").with_submenu(&window_menu));

    application.set_main_menu(&main);
}
