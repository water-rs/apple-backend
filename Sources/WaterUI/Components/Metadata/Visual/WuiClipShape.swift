import CWaterUI
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<ClipShape>.
///
/// Clips the wrapped view to a shape defined by path commands.
@MainActor
final class WuiClipShape: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_clip_shape_id() }

    private let contentView: any WuiComponent
    private let pathCommands: [WuiPathCommand]
    private var maskLayer: CAShapeLayer?

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_clip_shape(anyview)
        contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)
        pathCommands = WuiShapePath.commands(from: metadata.value.commands)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        #if canImport(UIKit)
        clipsToBounds = true
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.masksToBounds = true
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        updateMask()
    }
    #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
        updateMask()
    }
    #endif

    private func updateMask() {
        guard !bounds.isEmpty else { return }

        if maskLayer == nil {
            let newMask = CAShapeLayer()
            maskLayer = newMask
            #if canImport(UIKit)
            layer.mask = newMask
            #elseif canImport(AppKit)
            layer?.mask = newMask
            #endif
        }

        maskLayer?.path = WuiShapePath.makePath(commands: pathCommands, in: bounds)
    }
}
