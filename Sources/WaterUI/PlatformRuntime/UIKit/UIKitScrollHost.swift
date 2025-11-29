#if canImport(UIKit)
import UIKit
import CWaterUI

/// A native UIKit scroll view that uses the Rust layout engine for content sizing.
/// This replaces SwiftUI.ScrollView to ensure proper width constraints are passed to content.
@MainActor
final class UIKitScrollHost: UIScrollView, WaterUILayoutMeasurable {
    private let contentContainer: UIKitLayoutContainer
    private var contentLayout: WuiLayout
    
    var descriptor: PlatformViewDescriptor {
        PlatformViewDescriptor(typeId: WuiScrollView.id, isSpacer: false)
    }

    init(layout: WuiLayout, children: [UIView]) {
        self.contentLayout = layout
        self.contentContainer = UIKitLayoutContainer(layout: layout, children: children)
        super.init(frame: .zero)
        
        contentContainer.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentContainer)
        
        // Configure scroll view
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = true
        alwaysBounceHorizontal = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> UInt8 { 0 }

    func measure(in proposal: WuiProposalSize) -> CGSize {
        // ScrollView fills available space
        let width = proposal.width.map { CGFloat($0) } ?? UIScreen.main.bounds.width
        let height = proposal.height.map { CGFloat($0) } ?? UIScreen.main.bounds.height
        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        
        // KEY FIX: Content width is ALWAYS the viewport width (no horizontal scroll)
        // Content height is determined by the Rust layout engine
        let contentProposal = WuiProposalSize(
            width: Float(bounds.width),
            height: nil  // Let content determine its own height
        )
        
        // Measure content with the constrained width
        let contentSize = contentContainer.measure(in: contentProposal)
        
        // Set content container frame
        contentContainer.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(contentSize.height, bounds.height)
        )
        
        // Set scroll content size
        self.contentSize = CGSize(
            width: bounds.width,
            height: contentSize.height
        )
        
        // Trigger layout in content container
        contentContainer.setNeedsLayout()
        contentContainer.layoutIfNeeded()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let proposal = WuiProposalSize(size: size)
        return measure(in: proposal)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }
}
#endif

