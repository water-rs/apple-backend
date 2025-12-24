import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Border>.
///
/// Applies a border effect to the wrapped view.
@MainActor
final class WuiBorder: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_border_id() }

    private let contentView: any WuiComponent

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_border(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Apply border from metadata
        applyBorder(metadata.value, env: env)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyBorder(_ border: WuiBorder_Struct, env: WuiEnvironment) {
        // Resolve the border color
        let resolvedColor = waterui_resolve_color(border.color, env.inner)
        let color = waterui_read_computed_resolved_color(resolvedColor)
        waterui_drop_computed_resolved_color(resolvedColor)

        let edges = border.edges

        #if canImport(UIKit)
        // Check if all edges are set (simple case - use layer border)
        if edges.top && edges.leading && edges.bottom && edges.trailing {
            layer.borderColor = UIColor(
                red: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: CGFloat(color.opacity)
            ).cgColor
            layer.borderWidth = CGFloat(border.width)
            layer.cornerRadius = CGFloat(border.corner_radius)
            if border.corner_radius > 0 {
                layer.masksToBounds = true
            }
        } else {
            // Edge-specific borders require CAShapeLayer
            applyEdgeSpecificBorder(border, color: color)
        }
        #elseif canImport(AppKit)
        wantsLayer = true
        // Check if all edges are set (simple case - use layer border)
        if edges.top && edges.leading && edges.bottom && edges.trailing {
            layer?.borderColor = NSColor(
                calibratedRed: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: CGFloat(color.opacity)
            ).cgColor
            layer?.borderWidth = CGFloat(border.width)
            layer?.cornerRadius = CGFloat(border.corner_radius)
            if border.corner_radius > 0 {
                layer?.masksToBounds = true
            }
        } else {
            // Edge-specific borders require CAShapeLayer
            applyEdgeSpecificBorder(border, color: color)
        }
        #endif
    }

    private var borderLayer: CAShapeLayer?

    private func applyEdgeSpecificBorder(_ border: WuiBorder_Struct, color: WuiResolvedColor) {
        // Create shape layer for edge-specific borders
        let shapeLayer = CAShapeLayer()
        shapeLayer.fillColor = nil

        #if canImport(UIKit)
        shapeLayer.strokeColor = UIColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.opacity)
        ).cgColor
        #elseif canImport(AppKit)
        shapeLayer.strokeColor = NSColor(
            calibratedRed: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.opacity)
        ).cgColor
        #endif

        shapeLayer.lineWidth = CGFloat(border.width)

        self.borderLayer = shapeLayer
        #if canImport(UIKit)
        layer.addSublayer(shapeLayer)
        #elseif canImport(AppKit)
        layer?.addSublayer(shapeLayer)
        #endif
    }

    private func updateBorderPath() {
        guard let shapeLayer = borderLayer else { return }
        // Update path based on current bounds and edge settings
        // This is called during layout
        let path = CGMutablePath()
        _ = bounds  // Will be used when implementing edge-specific borders

        // For now, just draw the edges that are enabled
        // A full implementation would read the edge settings
        // and only draw those specific edges

        shapeLayer.path = path
    }

    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        contentView.sizeThatFits(proposal)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds
        borderLayer?.frame = bounds
        updateBorderPath()
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
        borderLayer?.frame = bounds
        updateBorderPath()
    }
    #endif
}

// Type alias for the FFI border struct
private typealias WuiBorder_Struct = CWaterUI.WuiBorder
