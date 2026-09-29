//! The `menu` leaf: `Native<ResolvedMenu>` rendered as a pull-down menu
//! trigger — an `NSPopUpButton` on `AppKit`, a `UIButton` presenting a
//! `UIMenu` on `UIKit` — with the resolved label drawn inside the button.
//!
//! Mirrors `WuiMenu`: the label is an arbitrary child view framed inside
//! the trigger (zero padding on `UIKit`, 12pt leading + 36pt chevron +
//! 4pt vertical on `AppKit`), measured under the offer minus that padding.
//! `accessibility_label` speaks on the trigger; on `UIKit` the trigger
//! tints with the theme accent and the label resolves `Foreground` to the
//! accent, as `makeMenuLabelEnvironment` installed it.
//!
//! The items collection is a `Computed<Vec<ResolvedMenuItem>>`: the whole
//! menu rebuilds on every change — the collection itself, or any item's
//! label / `disabled` / `selected` signal — matching `WuiMenuTree`'s
//! rebuild-everything semantics. Rebuilds run inside the platform
//! animation the watcher's metadata carries.

use alloc::boxed::Box;
use alloc::rc::Rc;
use alloc::string::String;
use alloc::vec::Vec;
use core::cell::{Cell, RefCell};

use cocoa_ui::{PlatformView, Rect, view};
use waterui::animation::Animation;
use waterui::component::menu::{CommandRole, ResolvedMenu, ResolvedMenuItem};
#[cfg(target_os = "macos")]
use waterui::component::menu::{ResolvedCommand, Shortcut};
use waterui::reactive::Signal;
use waterui::reactive::watcher::{BoxWatcherGuard, Metadata};
use waterui::text::StyledStr;
use waterui_backend_core::Environment;
use waterui_core::layout::{ProposalSize, StretchAxis, SubView, ViewDimensions};

use crate::contract::{Mounted, NativeLeaf};
use crate::dispatch::Dispatcher;
use crate::proposal;

#[cfg(target_os = "macos")]
mod platform {
    pub(super) use cocoa_ui::appkit::{
        HitTest, HostView, KeyModifiers, Menu, MenuButton, MenuItem,
    };
}

#[cfg(target_os = "ios")]
mod platform {
    pub(super) use cocoa_ui::uikit::{
        HitTest, HostView, Menu, MenuAction, MenuButton, MenuElement,
    };
}

use platform::{HostView, MenuButton};

/// The padding the trigger keeps around the label: the leading text inset
/// plus the chevron column on `AppKit`, nothing on `UIKit`.
#[cfg(target_os = "macos")]
const LABEL_PADDING: (f32, f32) = (48.0, 8.0);

/// The padding the trigger keeps around the label: `UIKit` buttons draw
/// their chrome around the label edge-to-edge.
#[cfg(target_os = "ios")]
const LABEL_PADDING: (f32, f32) = (0.0, 0.0);

/// The offer the embedded label measures under: the trigger's proposal
/// minus its label padding on each axis, never negative — `labelOffer`.
fn label_offer(proposal: ProposalSize) -> ProposalSize {
    let (horizontal, vertical) = LABEL_PADDING;
    ProposalSize {
        width: proposal.width.map(|width| (width - horizontal).max(0.0)),
        height: proposal.height.map(|height| (height - vertical).max(0.0)),
    }
}

/// A `ResolvedColor` as `UIColor` — the same extended-linear conversion
/// `button` uses for its tint.
#[cfg(target_os = "ios")]
fn platform_color(
    color: &waterui::graphics::color::ResolvedColor,
) -> cocoa_ui::Retained<cocoa_ui::objc2_ui_kit::UIColor> {
    cocoa_ui::uikit::colors::extended_linear(
        f64::from(color.red),
        f64::from(color.green),
        f64::from(color.blue),
        f64::from(color.opacity),
        f64::from(color.headroom),
    )
}

/// A styled string as display text: the plain characters with the bidi
/// control characters interpolation inserts for layout stripped.
fn item_title(styled: &StyledStr) -> String {
    cocoa_ui::text::strip_bidi_controls(styled.to_plain().as_str())
}

/// `withPlatformAnimation`: the watcher metadata's `Animation` mapped to a
/// kit timing — `Default` parses to the 0.25s bezier the FFI spells it as.
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

/// The leaf's live state: the trigger, the latest resolved items, the
/// watchers keeping them observed, and the environment commands run
/// against.
struct MenuState {
    /// The pull-down trigger.
    button: MenuButton,
    /// The host view, for layout invalidation after a rebuild.
    host: cocoa_ui::Retained<HostView>,
    /// The environment item actions run against — `env.inner` in Swift.
    env: Environment,
    /// The resolved items the live menu was built from.
    items: Vec<ResolvedMenuItem>,
    /// Watchers on every item signal; replaced wholesale on rebuild.
    item_watchers: Vec<BoxWatcherGuard>,
    /// The proposal a Rust parent last placed this leaf at —
    /// `selectedProposal`.
    selected: Cell<Option<ProposalSize>>,
    /// Main-thread proof, captured for menu rebuilds inside watchers.
    mtm: cocoa_ui::MainThreadMarker,
}

impl core::fmt::Debug for MenuState {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("MenuState").finish_non_exhaustive()
    }
}

/// A menu item's watched signals re-snapshot the item list and rebuild —
/// `WuiMenuNode`'s per-field `onChange` handlers all funnel into
/// `rebuildNativeMenu`.
fn request_resync(state: &Rc<RefCell<MenuState>>, metadata: &Metadata) {
    let state = Rc::clone(state);
    with_platform_animation(metadata, move || {
        let items = state.borrow().items.clone();
        apply_items(&state, items);
    });
}

/// Re-snapshots `items` onto the state, installs a fresh watcher per item
/// signal, and rebuilds the platform menu.
fn apply_items(state: &Rc<RefCell<MenuState>>, items: Vec<ResolvedMenuItem>) {
    let mut watchers = Vec::new();
    collect_item_watchers(&items, state, &mut watchers);
    {
        let mut state = state.borrow_mut();
        state.items = items;
        state.item_watchers = watchers;
    }
    rebuild_menu(state);
    // `invalidateCapturedRendering`: a rebuilt menu may measure
    // differently.
    view::invalidate_layout(&state.borrow().host);
}

/// Installs one watcher per live item signal — the command and submenu
/// labels, `disabled` and `selected`, and each nested menu's `items` —
/// recursively, as `WuiMenuTree` did per node.
fn collect_item_watchers(
    items: &[ResolvedMenuItem],
    state: &Rc<RefCell<MenuState>>,
    watchers: &mut Vec<BoxWatcherGuard>,
) {
    for item in items {
        match item {
            ResolvedMenuItem::Command(command) => {
                for signal in [&command.disabled, &command.selected] {
                    let state = Rc::clone(state);
                    watchers.push(Box::new(signal.watch(move |wctx| {
                        request_resync(&state, wctx.metadata());
                    })));
                }
                let state = Rc::clone(state);
                watchers.push(Box::new(command.label.content.watch(move |wctx| {
                    request_resync(&state, wctx.metadata());
                })));
            }
            ResolvedMenuItem::Menu(submenu) => {
                watchers.push(Box::new(submenu.label.content.watch({
                    let state = Rc::clone(state);
                    move |wctx| {
                        request_resync(&state, wctx.metadata());
                    }
                })));
                let nested = submenu.items.clone();
                watchers.push(Box::new(nested.watch({
                    let state = Rc::clone(state);
                    move |wctx| {
                        request_resync(&state, wctx.metadata());
                    }
                })));
                collect_item_watchers(&submenu.items.snapshot(), state, watchers);
            }
            ResolvedMenuItem::Divider => {}
        }
    }
}

/// The key equivalent and modifier set a `Shortcut` describes; no shortcut
/// is the empty pair.
#[cfg(target_os = "macos")]
fn shortcut_parts(shortcut: &Shortcut) -> (String, platform::KeyModifiers) {
    let modifiers = [
        (
            shortcut.modifiers.command(),
            platform::KeyModifiers::COMMAND,
        ),
        (shortcut.modifiers.option(), platform::KeyModifiers::OPTION),
        (shortcut.modifiers.shift(), platform::KeyModifiers::SHIFT),
        (
            shortcut.modifiers.control(),
            platform::KeyModifiers::CONTROL,
        ),
    ]
    .into_iter()
    .filter(|(held, _)| *held)
    .fold(platform::KeyModifiers::empty(), |flags, (_, native)| {
        flags | native
    });
    (String::from(shortcut.key.as_str()), modifiers)
}

/// `wuiApplyCommandPresentation`: title, key equivalent, enabled, checked
/// state, subtitle, destructive red, icon — then the action a pick runs.
#[cfg(target_os = "macos")]
fn command_item(
    mtm: cocoa_ui::MainThreadMarker,
    command: &ResolvedCommand,
    env: &Environment,
) -> platform::MenuItem {
    let title = item_title(&command.label.content.snapshot());
    let (key, modifiers) = command.shortcut.as_ref().map_or_else(
        || (String::new(), platform::KeyModifiers::empty()),
        shortcut_parts,
    );
    let mut item = platform::MenuItem::new(mtm, &title, None, &key)
        .with_key_modifiers(modifiers)
        .with_enabled(!command.disabled.snapshot())
        .with_selected(command.selected.snapshot());
    if let Some(subtitle) = &command.subtitle {
        item = item.with_subtitle(subtitle.as_str());
    }
    // `attributedTitle` replaces the plain title, so it lands after the
    // subtitle is committed.
    if matches!(command.role, CommandRole::Destructive) {
        item = item.with_destructive();
    }
    if let Some(icon) = &command.icon {
        item = item.with_icon(icon.name.as_str());
    }
    let action = command.action.clone();
    let env = env.clone();
    item.with_action(move || {
        action.call(&env);
    })
}

/// `appendAppKitMenuItems`: each item appended in order — commands, a
/// separator per divider, nested menus under a titled item.
#[cfg(target_os = "macos")]
fn append_items(
    mtm: cocoa_ui::MainThreadMarker,
    menu: &platform::Menu,
    items: &[ResolvedMenuItem],
    env: &Environment,
) {
    for item in items {
        match item {
            ResolvedMenuItem::Divider => menu.add_separator(),
            ResolvedMenuItem::Command(command) => {
                menu.add_item(command_item(mtm, command, env));
            }
            ResolvedMenuItem::Menu(submenu) => {
                let title = item_title(&submenu.label.content.snapshot());
                let nested = platform::Menu::new(mtm, &title);
                append_items(mtm, &nested, &submenu.items.snapshot(), env);
                let mut item = platform::MenuItem::new(mtm, &title, None, "");
                if let Some(icon) = &submenu.icon {
                    item = item.with_icon(icon.name.as_str());
                }
                menu.add_item(item.with_submenu(&nested));
            }
        }
    }
}

/// Rebuilds the trigger's `UIMenu`: dividers split the items into
/// `.displayInline` groups, flattened when a single group remains —
/// `splitMenuGroups` + `buildUIKitMenu`.
#[cfg(target_os = "ios")]
fn build_menu(
    mtm: cocoa_ui::MainThreadMarker,
    title: &str,
    icon: Option<&str>,
    items: &[ResolvedMenuItem],
    env: &Environment,
) -> platform::Menu {
    let mut groups: Vec<&[ResolvedMenuItem]> = items
        .split(|item| matches!(item, ResolvedMenuItem::Divider))
        .filter(|group| !group.is_empty())
        .collect();
    let flat = groups.len() <= 1;
    if groups.is_empty() {
        groups.push(&[]);
    }
    let children: Vec<platform::MenuElement> = if flat {
        menu_elements(groups[0], env, mtm)
    } else {
        groups
            .iter()
            .map(|group| {
                platform::MenuElement::Submenu(platform::Menu::new(
                    mtm,
                    "",
                    None,
                    true,
                    &menu_elements(group, env, mtm),
                ))
            })
            .collect()
    };
    platform::Menu::new(mtm, title, icon, false, &children)
}

/// `buildUIKitMenuElements`: one element per item — `UIAction`s for
/// commands carrying title, subtitle, icon, disabled/destructive
/// attributes, on-state and handler; nested menus recurse.
#[cfg(target_os = "ios")]
fn menu_elements(
    items: &[ResolvedMenuItem],
    env: &Environment,
    mtm: cocoa_ui::MainThreadMarker,
) -> Vec<platform::MenuElement> {
    items
        .iter()
        .filter_map(|item| match item {
            ResolvedMenuItem::Divider => None,
            ResolvedMenuItem::Command(command) => {
                let title = item_title(&command.label.content.snapshot());
                let action = command.action.clone();
                let env = env.clone();
                Some(platform::MenuElement::Action(
                    platform::MenuAction::new(mtm, &title, move || {
                        action.call(&env);
                    })
                    .with_subtitle(command.subtitle.as_deref())
                    .with_icon(command.icon.as_ref().map(|icon| icon.name.as_str()))
                    .with_disabled(command.disabled.snapshot())
                    .with_destructive(matches!(command.role, CommandRole::Destructive))
                    .with_selected(command.selected.snapshot()),
                ))
            }
            ResolvedMenuItem::Menu(submenu) => {
                let title = item_title(&submenu.label.content.snapshot());
                Some(platform::MenuElement::Submenu(build_menu(
                    mtm,
                    &title,
                    submenu.icon.as_ref().map(|icon| icon.name.as_str()),
                    &submenu.items.snapshot(),
                    env,
                )))
            }
        })
        .collect()
}

/// Rebuilds the trigger's menu from the live items.
#[cfg(target_os = "macos")]
fn rebuild_menu(state: &Rc<RefCell<MenuState>>) {
    let (button, env, items, mtm) = {
        let state = state.borrow();
        (
            state.button.clone(),
            state.env.clone(),
            state.items.clone(),
            state.mtm,
        )
    };
    // Pull-down menus keep a blank first item the button draws as its
    // face title; the real label is the mounted child.
    let menu = platform::Menu::new(mtm, "");
    menu.add_item(platform::MenuItem::new(mtm, "", None, ""));
    append_items(mtm, &menu, &items, &env);
    button.set_menu(&menu);
}

/// Rebuilds the trigger's menu from the live items.
#[cfg(target_os = "ios")]
fn rebuild_menu(state: &Rc<RefCell<MenuState>>) {
    let (button, env, items, mtm) = {
        let state = state.borrow();
        (
            state.button.clone(),
            state.env.clone(),
            state.items.clone(),
            state.mtm,
        )
    };
    button.set_menu(&build_menu(mtm, "", None, &items, &env));
}

/// The container's layout face: the label's measurement plus the label
/// padding — `sizeThatFits`.
struct MenuSubView {
    /// The mounted label child.
    label: Mounted,
}

impl core::fmt::Debug for MenuSubView {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("MenuSubView").finish_non_exhaustive()
    }
}

impl SubView for MenuSubView {
    fn measure(&self, proposal: ProposalSize) -> ViewDimensions {
        let measured = self.label.layout().measure(label_offer(proposal));
        let (horizontal, vertical) = LABEL_PADDING;
        ViewDimensions::new(waterui_core::layout::Size::new(
            measured.size.width + horizontal,
            measured.size.height + vertical,
        ))
    }

    fn stretch_axis(&self) -> StretchAxis {
        StretchAxis::None
    }

    fn priority(&self) -> i32 {
        0
    }
}

/// Installs the `menu` handler on the dispatcher: `Native<ResolvedMenu>`
/// maps to a host view holding the pull-down trigger and its label child.
#[expect(
    clippy::too_many_lines,
    reason = "the handler's wiring is sequential; splitting it would obscure the mount order"
)]
pub fn install(dispatcher: &mut Dispatcher) {
    dispatcher.register_native::<ResolvedMenu>(|config, ctx| {
        let mtm = ctx.mtm();
        let host = HostView::new(mtm, Rect::ZERO);
        let button = MenuButton::new(mtm);
        let label_container = HostView::new(mtm, Rect::ZERO);
        // The label never intercepts input meant for the trigger.
        label_container.set_hit_test_handler(|_, _| platform::HitTest::Pass);

        let host_view: &PlatformView = &host;
        view::add_subview(host_view, button.view());
        view::add_subview(button.view(), &label_container);

        // `makeMenuLabelEnvironment`: on `UIKit` the label's `Foreground`
        // resolves to the accent so it reads as the button's title.
        #[cfg(target_os = "ios")]
        let label_env = {
            use waterui::reactive::SignalExt;
            use waterui::resolve::Resolvable;
            use waterui::theme::color::{Accent, Foreground};
            use waterui::theme::install_color_signal;
            let mut env = ctx.env().clone();
            install_color_signal::<Foreground>(&mut env, Accent.resolve(ctx.env()).computed());
            env
        };
        #[cfg(target_os = "macos")]
        let label_env = ctx.env().clone();

        let label_leaf = ctx.with_env(&label_env).render(config.label);
        let child_view = view::retain_base(label_leaf.view());
        let mounted = label_leaf.mount(&label_container);
        {
            let child_view = child_view.clone();
            label_container.set_layout_handler(move |host| {
                view::set_frame(&child_view, view::bounds(host));
            });
        }

        let state = Rc::new(RefCell::new(MenuState {
            button,
            host: host.clone(),
            env: ctx.env().clone(),
            items: Vec::new(),
            item_watchers: Vec::new(),
            selected: Cell::new(None),
            mtm,
        }));

        // `layoutSubviews` / `layout`: the trigger fills the host, the
        // label sits inside it under the platform's padding, and the
        // selected proposal — or the bounds — reaches the label as its
        // offer.
        host.set_layout_handler({
            let state = Rc::clone(&state);
            move |host| {
                let bounds = view::bounds(host);
                let state = state.borrow();
                view::set_frame(state.button.view(), bounds);
                let width = bounds.size.width;
                let height = bounds.size.height;
                #[cfg(target_os = "macos")]
                {
                    // 12pt leading text inset, 36pt trailing chevron, 4pt
                    // top and bottom; RTL mirrors the leading inset.
                    let leading = if view::is_right_to_left(host) {
                        36.0
                    } else {
                        12.0
                    };
                    view::set_frame(
                        &label_container,
                        Rect::new(
                            leading,
                            4.0,
                            (width - 48.0).max(0.0),
                            (height - 8.0).max(0.0),
                        ),
                    );
                }
                #[cfg(target_os = "ios")]
                view::set_frame(&label_container, Rect::new(0.0, 0.0, width, height));

                let base = state.selected.get().unwrap_or({
                    #[expect(
                        clippy::cast_possible_truncation,
                        reason = "the layout contract is f32; host bounds always fit"
                    )]
                    ProposalSize {
                        width: Some(width as f32),
                        height: Some(height as f32),
                    }
                });
                proposal::deliver(&child_view, label_offer(base));
            }
        });

        let mut leaf = NativeLeaf::new(host_view, MenuSubView { label: mounted });
        leaf.keep(label_env);

        // Items → menu: rebuild on every change (`watch` so the rebuild
        // carries the watcher's animation metadata), with the initial list
        // applied up front.
        apply_items(&state, config.items.snapshot());
        leaf.watch(&config.items, {
            let state = Rc::clone(&state);
            move |wctx| {
                let items = wctx.value().clone();
                let state = Rc::clone(&state);
                with_platform_animation(wctx.metadata(), move || {
                    apply_items(&state, items);
                });
            }
        });

        // The proposal a Rust parent selected invalidates placement even
        // when the frame does not move.
        let sink_guard = proposal::register_sink(&host, {
            let state = Rc::clone(&state);
            let host = host.clone();
            move |selected| {
                let state = state.borrow();
                if state.selected.get() != Some(selected) {
                    state.selected.set(Some(selected));
                    host.set_needs_layout();
                }
            }
        });
        leaf.keep(sink_guard);

        // `accessibility_label` speaks on the trigger — and carries its
        // `AppKit` tooltip.
        let trigger = view::retain_base(state.borrow().button.view());
        leaf.bind(&config.accessibility_label, move |styled| {
            view::set_accessibility_label(&trigger, &item_title(&styled));
        });

        // `UIKit` tints the trigger by the theme accent.
        #[cfg(target_os = "ios")]
        {
            use waterui::resolve::Resolvable;
            use waterui::theme::color::Accent;
            let accent = Accent.resolve(ctx.env());
            leaf.bind(&accent, {
                let button = state.borrow().button.clone();
                move |color| button.set_tint_color(&platform_color(&color))
            });
        }

        leaf.keep(state);
        leaf
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn label_offer_subtracts_padding_and_clamps() {
        let (horizontal, vertical) = LABEL_PADDING;
        let offer = label_offer(ProposalSize {
            width: Some(120.0),
            height: Some(40.0),
        });
        assert_eq!(offer.width, Some((120.0 - horizontal).max(0.0)));
        assert_eq!(offer.height, Some((40.0 - vertical).max(0.0)));

        // Padding larger than the proposal clamps to zero rather than
        // going negative, matching the Swift `max(0, ...)`.
        let clamped = label_offer(ProposalSize {
            width: Some(0.0),
            height: Some(0.0),
        });
        assert_eq!(clamped.width, Some(0.0));
        assert_eq!(clamped.height, Some(0.0));
    }

    #[test]
    fn item_title_strips_bidi_marks() {
        assert_eq!(item_title(&StyledStr::from("a\u{202a}b\u{202c}")), "ab");
    }

    /// Dividers split the item list into groups; consecutive and trailing
    /// dividers produce no empty groups, matching `splitMenuGroups`.
    #[test]
    fn groups_split_on_dividers() {
        fn divider() -> ResolvedMenuItem {
            ResolvedMenuItem::Divider
        }
        let items = [divider(), divider()];
        assert!(
            items
                .split(|item| matches!(item, ResolvedMenuItem::Divider))
                .all(<[ResolvedMenuItem]>::is_empty)
        );
    }
}
