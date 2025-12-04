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
        // iOS: The actual safe area extension is handled during layout
        // by adjusting the content frame beyond the safe area insets
        clipsToBounds = false
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

        // Calculate extended frame based on ignored edges
        var extendedFrame = bounds
        let safeInsets = safeAreaInsets

        if edges.top {
            extendedFrame.origin.y -= safeInsets.top
            extendedFrame.size.height += safeInsets.top
        }
        if edges.bottom {
            extendedFrame.size.height += safeInsets.bottom
        }
        if edges.leading {
            extendedFrame.origin.x -= safeInsets.left
            extendedFrame.size.width += safeInsets.left
        }
        if edges.trailing {
            extendedFrame.size.width += safeInsets.right
        }

        contentView.frame = extendedFrame
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
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
