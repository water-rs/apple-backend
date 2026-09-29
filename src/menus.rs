//! The application's menu bar.
//!
//! `WaterUIMainMenu.create()` + `WuiRootContext`'s
//! `installMenuBar`/`menuBarDidChange` ported: the standard App, Edit (the
//! responder-chain items keyboard shortcuts route through) and Window menus,
//! with the declared `menu_bar` content appended — macOS rebuilds the whole
//! bar on every change, iOS rebuilds through `application:buildMenuWith:`.

use alloc::vec::Vec;

use waterui::component::menu::{Menu as DeclaredMenu, ResolvedMenuItem};
use waterui::reactive::Computed;
use waterui_backend_core::Environment;

/// Resolves `menu_bar` against `env` — items live-resolve under the
/// environment's locale.
#[must_use]
fn resolve(
    menu_bar: &Computed<Vec<DeclaredMenu>>,
    env: &Environment,
) -> Computed<Vec<ResolvedMenuItem>> {
    waterui::component::menu::resolve_menu_bar_items(menu_bar, env)
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use imp::*;

#[cfg(target_os = "macos")]
mod imp {
    use alloc::boxed::Box;
    use alloc::rc::Rc;
    use alloc::string::String;
    use alloc::vec::Vec;
    use core::any::Any;

    use cocoa_ui::MainThreadMarker;
    use cocoa_ui::appkit::{Application, KeyModifiers, Menu, MenuAction, MenuItem};
    use waterui::component::menu::Menu as DeclaredMenu;
    use waterui::reactive::{Computed, Signal};
    use waterui_backend_core::Environment;

    use super::resolve;

    /// What this application calls itself in its own menu: the display name a
    /// bundle chooses for people to read, then the bundle name, then the
    /// process name — `WaterUIMainMenu.appName`'s order.
    fn app_name() -> String {
        cocoa_ui::bundle::info_string("CFBundleDisplayName")
            .or_else(|| cocoa_ui::bundle::info_string("CFBundleName"))
            .unwrap_or_else(cocoa_ui::process::name)
    }

    /// The standard menu bar's content: App, Edit, Window — the same menus
    /// `main.swift.tpl` installed before `app.run()`. Declared menus append
    /// to it in [`install`].
    fn build_default(mtm: MainThreadMarker, application: &Application) -> Menu {
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

        main
    }

    /// The standard macOS menu bar: the default menus plus the declared
    /// `nodes` appended in order — `menuBarDidChange`'s full rebuild.
    pub fn install(
        mtm: MainThreadMarker,
        application: &Application,
        nodes: &[cocoa_ui::menu::MenuTreeNode],
    ) {
        let main = build_default(mtm, application);
        main.append_nodes(nodes);
        application.set_main_menu(&main);
    }

    /// The menu bar before `app(env)` reports its declared content.
    pub fn install_default(mtm: MainThreadMarker, application: &Application) {
        install(mtm, application, &[]);
    }

    /// Installs `menu_bar` and rebuilds the bar on every change —
    /// `installMenuBar` + `menuBarDidChange`. The returned guard keeps the
    /// watcher alive; hold it for the process.
    pub fn install_declared(
        mtm: MainThreadMarker,
        application: &Application,
        menu_bar: &Computed<Vec<DeclaredMenu>>,
        env: &Environment,
    ) -> Box<dyn Any> {
        let resolved = resolve(menu_bar, env);
        let application = application.clone();
        let env = env.clone();
        let rebuild = {
            let resolved = resolved.clone();
            Rc::new(move || {
                let items = resolved.snapshot();
                let nodes = crate::components::navigation::menu_tree(&items, &env);
                install(mtm, &application, &nodes);
            })
        };
        rebuild();
        let guard = resolved.watch(move |_| rebuild());
        Box::new(guard)
    }
}

/// iOS: the declared content fills the builder `application:buildMenuWith:`
/// hands the delegate; a watch on the resolved items requests each rebuild.
#[cfg(target_os = "ios")]
mod imp {
    use alloc::boxed::Box;
    use alloc::rc::Rc;
    use alloc::vec::Vec;
    use core::any::Any;
    use core::cell::RefCell;

    use cocoa_ui::MainThreadMarker;
    use cocoa_ui::uikit::MenuBuilder;
    use waterui::component::menu::{Menu as DeclaredMenu, ResolvedMenuItem};
    use waterui::reactive::{Computed, Signal};
    use waterui_backend_core::Environment;

    use super::resolve;

    /// What `install_declared` shares with the `build_menus` handler: the
    /// resolved items plus the environment their actions run under, filled
    /// once `app(env)` has returned its own environment.
    pub type Declared = Rc<RefCell<Option<(Computed<Vec<ResolvedMenuItem>>, Environment)>>>;

    /// The slot `build_menus` reads — empty until `app(env)` has run.
    #[must_use]
    pub fn declared() -> Declared {
        Rc::new(RefCell::new(None))
    }

    /// The `build_menus` handler: each top-level declared `Menu` becomes a
    /// `UIMenu` at the end of the root bar, replaced in place on rebuild.
    pub fn build_handler(declared: Declared) -> impl Fn(&MenuBuilder<'_>) + 'static {
        move |builder| {
            let Some((resolved, env)) = declared.borrow().clone() else {
                return;
            };
            let mtm = MainThreadMarker::new().expect("build_menus runs on the main thread");
            for (index, item) in resolved.snapshot().iter().enumerate() {
                let ResolvedMenuItem::Menu(menu) = item else {
                    panic!("App::menu_bar only accepts top-level Menu values");
                };
                let identifier = alloc::format!("dev.waterui.menu.{index}");
                let command = crate::components::navigation::kit_command_for_menu(menu);
                let nodes = crate::components::navigation::menu_tree(&menu.items.snapshot(), &env);
                let ui_menu =
                    cocoa_ui::uikit::menu_with_identifier(mtm, &command, Some(&identifier), &nodes);
                if builder.contains(&identifier) {
                    builder.replace(&identifier, &ui_menu);
                } else {
                    builder.insert_at_root_end(&ui_menu);
                }
            }
        }
    }

    /// Fills `declared` and flags each change for rebuild. The returned
    /// guard keeps the watcher alive; hold it for the process.
    pub fn install_declared(
        menu_bar: &Computed<Vec<DeclaredMenu>>,
        env: &Environment,
        declared: &Declared,
    ) -> Box<dyn Any> {
        let resolved = resolve(menu_bar, env);
        let guard = resolved.watch(|_| {
            if let Some(mtm) = MainThreadMarker::new() {
                cocoa_ui::uikit::request_main_menu_rebuild(mtm);
            }
        });
        *declared.borrow_mut() = Some((resolved, env.clone()));
        Box::new(guard)
    }
}
