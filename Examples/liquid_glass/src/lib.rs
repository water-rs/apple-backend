//! Liquid Glass on Apple platforms.
//!
//! Every surface here is a semantic declaration that the Apple backend projects
//! onto the platform's own glass: `Glass` becomes `UIGlassEffect` on iOS and
//! `NSGlassEffectView` on macOS. Other backends approximate or ignore it, so
//! the same views render without glass where the platform has none.
//!
//! The backdrop is deliberately loud — glass is a lens, and a lens needs
//! something to bend.

use waterui::app::App;
use waterui::background::Glass;
use waterui::icon::SystemIcon;
use waterui::prelude::theme_color::Accent;
use waterui::prelude::*;
use waterui::preview;
use waterui::reactive::binding;
use waterui::shape::{Circle, RoundedRectangle, ShapeExt};

/// Tab identity. `Tabs` is generic over it, so no `Id` reaches app code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Pane {
    Surfaces,
    Controls,
    About,
}

#[preview]
pub fn main() -> impl View {
    let pane = binding(Pane::Surfaces);

    Tabs::new(
        &pane,
        vec![
            Tab::container(
                Pane::Surfaces,
                label("Surfaces").icon(SystemIcon::new("square.on.square")),
                surfaces_page,
            ),
            Tab::container(
                Pane::Controls,
                label("Controls").icon(SystemIcon::new("button.horizontal")),
                controls_page,
            ),
            Tab::container(
                Pane::About,
                label("About").icon(SystemIcon::new("info.circle")),
                about_page,
            ),
        ],
    )
    .style(tab_style::automatic())
}

/// Glass surfaces over a colorful backdrop: the four parameters glass has —
/// style, interactivity, tint, and outline — each shown on its own.
fn surfaces_page() -> impl View {
    zstack((
        backdrop(),
        scroll(
            vstack((
                caption(
                    "Regular glass is the default: a capsule that stays legible over anything.",
                ),
                pill("Now Playing", Glass::regular()),
                caption("Clear glass diffuses less, for surfaces over media."),
                pill("Clear", Glass::clear()),
                caption(
                    "Interactive glass answers touch and hover with the platform's own effects.",
                ),
                pill("Tap me", Glass::regular().interactive(true)),
                caption("A tint washes the glass toward a color."),
                pill("Accent", Glass::regular().tint(Accent)),
                pill("Tomato", Glass::clear().tint(Color::srgb(255, 99, 71))),
                caption("The outline belongs to the glass, not to an outer clip."),
                card(),
            ))
            .spacing(12.0)
            .padding(),
        ),
    ))
    .title("Surfaces")
    .large_title()
}

/// Glass button styles beside the bordered ones they correspond to on
/// platforms without glass.
fn controls_page() -> impl View {
    zstack((
        backdrop(),
        scroll(
            vstack((
                caption("Glass: the capsule is the emphasis, the label keeps the primary color."),
                hstack((
                    button("Glass").style(ButtonStyle::Glass),
                    button("Bordered").style(ButtonStyle::Bordered),
                ))
                .spacing(12.0),
                caption("Prominent glass: the accent fills the capsule, for the primary action."),
                hstack((
                    button("Glass Prominent").style(ButtonStyle::GlassProminent),
                    button("Bordered Prominent").style(ButtonStyle::BorderedProminent),
                ))
                .spacing(12.0),
                caption("Labels with symbols get the same capsule."),
                hstack((
                    button(label("Share").icon(SystemIcon::new("square.and.arrow.up")))
                        .style(ButtonStyle::Glass),
                    button(label("Play").icon(SystemIcon::new("play.fill")))
                        .style(ButtonStyle::GlassProminent),
                ))
                .spacing(12.0),
            ))
            .spacing(12.0)
            .padding(),
        ),
    ))
    .title("Controls")
    .large_title()
}

fn about_page() -> impl View {
    vstack((
        text("Liquid Glass").size(24.0),
        "Glass is the chrome-layer surface of iOS 26 and macOS 26. This app declares it; the Apple backend projects it.",
    ))
    .spacing(12.0)
    .padding()
    .title("About")
}

fn caption(body: &'static str) -> impl View {
    text(body).size(15.0)
}

fn pill(title: &'static str, glass: Glass) -> impl View {
    text(title).bold().padding().background(glass)
}

fn card() -> impl View {
    vstack((
        text("Rounded card").bold(),
        "Text inside glass keeps its full contrast; the glass adapts to what is behind it.",
    ))
    .spacing(6.0)
    .padding()
    .background(Glass::regular().shape(RoundedRectangle::new(0.2)))
}

/// Large colored discs, so the lensing at each glass edge has edges to bend.
fn backdrop() -> impl View {
    zstack((
        Circle
            .fill(Color::srgb(255, 149, 0))
            .size(320.0, 320.0)
            .offset(-120.0, -160.0),
        Circle
            .fill(Color::srgb(48, 176, 199))
            .size(280.0, 280.0)
            .offset(140.0, 40.0),
        Circle
            .fill(Color::srgb(175, 82, 222))
            .size(360.0, 360.0)
            .offset(-60.0, 320.0),
        Circle
            .fill(Color::srgb(52, 199, 89))
            .size(220.0, 220.0)
            .offset(150.0, 560.0),
    ))
}

pub fn app(env: Environment) -> App {
    App::new(main, env)
}
