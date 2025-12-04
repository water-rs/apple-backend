import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Shadow>.
///
/// Applies a shadow effect to the wrapped view.
@MainActor
final class WuiShadow: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_shadow_id() }

    private let contentView: any WuiComponent

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_shadow(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Apply shadow from metadata
        applyShadow(metadata.value, env: env)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyShadow(_ shadow: WuiShadow_Struct, env: WuiEnvironment) {
        // Resolve the shadow color
        let resolvedColor = waterui_resolve_color(shadow.color, env.inner)
        let color = waterui_read_computed_resolved_color(resolvedColor)
        waterui_drop_computed_resolved_color(resolvedColor)

        #if canImport(UIKit)
        layer.shadowColor = UIColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: 1.0
        ).cgColor
        layer.shadowOpacity = Float(color.opacity)
        layer.shadowOffset = CGSize(width: CGFloat(shadow.offset_x), height: CGFloat(shadow.offset_y))
        layer.shadowRadius = CGFloat(shadow.radius)
        layer.masksToBounds = false
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.shadowColor = NSColor(
            calibratedRed: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: 1.0
        ).cgColor
        layer?.shadowOpacity = Float(color.opacity)
        layer?.shadowOffset = CGSize(width: CGFloat(shadow.offset_x), height: CGFloat(shadow.offset_y))
        layer?.shadowRadius = CGFloat(shadow.radius)
        layer?.masksToBounds = false
        #endif
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
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
    }
    #endif
}

// Type alias for the FFI shadow struct
private typealias WuiShadow_Struct = CWaterUI.WuiShadow
