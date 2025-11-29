#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import CWaterUI

/// A native AppKit scroll view that uses the Rust layout engine for content sizing.
/// This replaces SwiftUI.ScrollView to ensure proper width constraints are passed to content.
@MainActor
final class AppKitScrollHost: NSScrollView, WaterUILayoutMeasurable {
    private let contentContainer: AppKitLayoutContainer
    private var contentLayout: WuiLayout
    
    var descriptor: PlatformViewDescriptor {
        PlatformViewDescriptor(typeId: WuiScrollView.id, isSpacer: false)
    }

    init(layout: WuiLayout, children: [NSView]) {
        self.contentLayout = layout
        self.contentContainer = AppKitLayoutContainer(layout: layout, children: children)
        super.init(frame: .zero)
        
        // Configure scroll view
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        
        // Use flipped document view for top-left origin
        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentContainer)
        self.documentView = documentView
        
        contentContainer.translatesAutoresizingMaskIntoConstraints = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> UInt8 { 0 }

    func measure(in proposal: WuiProposalSize) -> CGSize {
        // ScrollView fills available space
        let width = proposal.width.map { CGFloat($0) } ?? NSScreen.main?.frame.width ?? 800
        let height = proposal.height.map { CGFloat($0) } ?? NSScreen.main?.frame.height ?? 600
        return CGSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        
        // KEY FIX: Content width is ALWAYS the viewport width (no horizontal scroll)
        // Content height is determined by the Rust layout engine
        let visibleWidth = contentView.bounds.width
        let contentProposal = WuiProposalSize(
            width: Float(visibleWidth),
            height: nil  // Let content determine its own height
        )
        
        // Measure content with the constrained width
        let contentSize = contentContainer.measure(in: contentProposal)
        
        // Set content container frame
        contentContainer.frame = CGRect(
            x: 0,
            y: 0,
            width: visibleWidth,
            height: max(contentSize.height, contentView.bounds.height)
        )
        
        // Set document view size
        documentView?.frame = CGRect(
            x: 0,
            y: 0,
            width: visibleWidth,
            height: contentSize.height
        )
        
        // Trigger layout in content container
        contentContainer.needsLayout = true
        contentContainer.layoutSubtreeIfNeeded()
    }

    override var fittingSize: NSSize {
        let proposal = WuiProposalSize()
        return measure(in: proposal)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

// MARK: - Flipped Document View

/// A simple NSView subclass with flipped coordinates (origin at top-left)
private class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
#endif

