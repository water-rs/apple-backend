//! The `resolved_gradient` leaf: `Native<ResolvedGradient>` rendered through
//! a `CAGradientLayer` pinned to a host view — `WuiResolvedGradientView`.
//!
//! The layer is re-framed to the view's bounds on every layout pass and the
//! gradient type maps one-to-one onto the layer's three kinds (`Mesh` is an
//! authoring error, as the Swift `fatalError` was).

use cocoa_ui::gradient::{GradientKind, GradientLayer, GradientStop};
use waterui::graphics::color::WorkingColor;
use waterui::graphics::{GradientType, ResolvedGradient};
use waterui_core::layout::{ProposalSize, Size, StretchAxis, SubView, ViewDimensions};

use crate::contract::NativeLeaf;
use crate::dispatch::Dispatcher;

#[cfg(target_os = "macos")]
mod platform {
    pub(super) use cocoa_ui::appkit::HostView;
}

#[cfg(target_os = "ios")]
mod platform {
    pub(super) use cocoa_ui::uikit::HostView;
}

use platform::HostView;

/// A `WorkingColor` as a `CGColor` in extended sRGB — channels carried
/// straight; values above `1.0` are the color's HDR headroom already.
fn cg_color(
    color: &WorkingColor,
) -> cocoa_ui::objc2_core_foundation::CFRetained<cocoa_ui::objc2_core_graphics::CGColor> {
    let [red, green, blue, alpha] = color.components;
    cocoa_ui::color::cg_extended_linear_display_p3(
        f64::from(red),
        f64::from(green),
        f64::from(blue),
        f64::from(alpha),
    )
}

/// The gradient's shape and normalized vector on the layer —
/// `applyGradient` in `WuiResolvedGradientView`.
fn configure(layer: &GradientLayer, gradient: &ResolvedGradient) {
    let start = cocoa_ui::Point::new(
        f64::from(gradient.start_point[0]),
        f64::from(gradient.start_point[1]),
    );
    let end = cocoa_ui::Point::new(
        f64::from(gradient.end_point[0]),
        f64::from(gradient.end_point[1]),
    );
    let (kind, start, end) = match gradient.gradient_type {
        GradientType::Linear => (GradientKind::Linear, start, end),
        // `endPoint` sits `endValue` points past the center on x — the rim
        // point the radial gradient's radius reads from.
        GradientType::Radial => (
            GradientKind::Radial,
            start,
            cocoa_ui::Point::new(end.x + f64::from(gradient.end_value), end.y),
        ),
        GradientType::Angular => (GradientKind::Angular, start, start),
        GradientType::Mesh => {
            panic!("Mesh gradients are not supported by WuiResolvedGradientView")
        }
    };
    layer.configure(kind, start, end);
}

/// The host view's layout face: greedy, stretching both axes — the face
/// `WuiGraphicsPrimitiveSizing` gave every graphics leaf.
struct GradientSubView;

impl core::fmt::Debug for GradientSubView {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("GradientSubView").finish_non_exhaustive()
    }
}

impl SubView for GradientSubView {
    fn measure(&self, proposal: ProposalSize) -> ViewDimensions {
        // Greedy: take the whole proposal on every axis.
        ViewDimensions::new(Size::new(
            proposal.width.unwrap_or(0.0),
            proposal.height.unwrap_or(0.0),
        ))
    }

    fn stretch_axis(&self) -> StretchAxis {
        StretchAxis::Both
    }

    fn priority(&self) -> i32 {
        0
    }
}

/// Installs the `resolved_gradient` handler.
pub fn install(dispatcher: &mut Dispatcher) {
    dispatcher.register_native::<ResolvedGradient>(|gradient, ctx| {
        let mtm = ctx.mtm();
        let view = HostView::new(mtm, cocoa_ui::Rect::ZERO);
        #[cfg(target_os = "macos")]
        cocoa_ui::view::ensure_layer_backed(&view);
        let layer = GradientLayer::new();
        cocoa_ui::view::layer(&view)
            .expect("host view is layer-backed")
            .addSublayer(&layer.layer());

        let stops: Vec<GradientStop> = gradient
            .stops
            .iter()
            .map(|stop| GradientStop {
                position: f64::from(stop.position),
                color: cg_color(&stop.color),
            })
            .collect();
        layer.set_stops(&stops);
        configure(&layer, &gradient);
        layer.set_frame(cocoa_ui::view::bounds(&view));

        // `gradientLayer.frame = bounds` on every layout pass — the Swift
        // `layout()` override.
        view.set_layout_handler(move |view| {
            layer.set_frame(cocoa_ui::view::bounds(view));
        });

        NativeLeaf::new(&*view, GradientSubView)
    });
}
