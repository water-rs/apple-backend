import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<IgnoreSafeArea>.
///
/// Allows the wrapped view to extend beyond safe area insets on specified edges.
@MainActor
final class WuiIgnoreSafeArea: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_ignore_safe_area_id() }

    private let contentView: any WuiComponent
    private let edges: WuiEdgeSet

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_ignore_safe_area(anyview)

        self.edges = metadata.value.edges

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        #if canImport(UIKit)
        // iOS: Configure the view to ignore safe area
        clipsToBounds = false
        insetsLayoutMarginsFromSafeArea = false
        #elseif canImport(AppKit)
        // macOS doesn't have safe areas in the same way
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

        // Get the safe area insets from the window (most reliable source)
        let safeInsets = window?.safeAreaInsets ?? super.safeAreaInsets

        // Calculate extended frame to include safe area on ignored edges
        var extendedFrame = bounds

        if edges.top && safeInsets.top > 0 {
            extendedFrame.origin.y -= safeInsets.top
            extendedFrame.size.height += safeInsets.top
        }
        if edges.bottom && safeInsets.bottom > 0 {
            extendedFrame.size.height += safeInsets.bottom
        }
        if edges.leading && safeInsets.left > 0 {
            extendedFrame.origin.x -= safeInsets.left
            extendedFrame.size.width += safeInsets.left
        }
        if edges.trailing && safeInsets.right > 0 {
            extendedFrame.size.width += safeInsets.right
        }

        contentView.frame = extendedFrame
    }

    // Override to propagate zero safe area to child views for ignored edges
    override var safeAreaInsets: UIEdgeInsets {
        let originalInsets = super.safeAreaInsets
        return UIEdgeInsets(
            top: edges.top ? 0 : originalInsets.top,
            left: edges.leading ? 0 : originalInsets.left,
            bottom: edges.bottom ? 0 : originalInsets.bottom,
            right: edges.trailing ? 0 : originalInsets.right
        )
    }

    // Allow touches to reach content that extends beyond bounds (into safe area)
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Check if point is within the extended content frame
        return contentView.frame.contains(point)
    }

    // Custom hit testing to handle content that extends beyond bounds
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Convert point to content view's coordinate system and test there
        let convertedPoint = convert(point, to: contentView)
        if let hitView = contentView.hitTest(convertedPoint, with: event) {
            return hitView
        }
        return nil
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // macOS: safe area is less of a concern, just fill bounds
        contentView.frame = bounds
    }
    #endif
}
