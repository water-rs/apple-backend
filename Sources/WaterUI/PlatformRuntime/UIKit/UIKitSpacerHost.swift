#if canImport(UIKit)
import UIKit

@MainActor
final class UIKitSpacerHost: UIView, WaterUILayoutMeasurable {
    var descriptor: PlatformViewDescriptor {
        PlatformViewDescriptor(typeId: WuiSpacer.id, isSpacer: true)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> UInt8 { 0 }

    func measure(in proposal: WuiProposalSize) -> CGSize {
        CGSize(width: proposal.width.map { CGFloat($0) } ?? 0, height: proposal.height.map { CGFloat($0) } ?? 0)
    }
}
#endif
