import CWaterUI
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiResolvedShape: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_resolved_shape_id() }

    private let pathCommands: [WuiPathCommand]
    private let shapeLayer = CAShapeLayer()
    private(set) var stretchAxis: WuiStretchAxis

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))

        let shape = waterui_force_as_resolved_shape(anyview)
        pathCommands = WuiShapePath.commands(from: shape.commands)
        let fillColor = shape.fill

        super.init(frame: .zero)

        #if canImport(UIKit)
        backgroundColor = .clear
        shapeLayer.fillColor = fillColor.toUIColor().cgColor
        layer.addSublayer(shapeLayer)
        #elseif canImport(AppKit)
        wantsLayer = true
        shapeLayer.fillColor = fillColor.toNSColor().cgColor
        layer?.addSublayer(shapeLayer)
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let fallback: CGFloat = 10
        return CGSize(
            width: proposal.width.map { CGFloat($0) } ?? fallback,
            height: proposal.height.map { CGFloat($0) } ?? fallback
        )
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        updateShapeLayer()
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        updateShapeLayer()
    }
    #endif

    private func updateShapeLayer() {
        guard !bounds.isEmpty else { return }
        shapeLayer.frame = bounds
        shapeLayer.path = WuiShapePath.makePath(commands: pathCommands, in: bounds)
    }
}
