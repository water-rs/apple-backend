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
        insetsLayoutMarginsFromSafeArea = false
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }

    /// Transparent for layout: the proposal selected for this
    /// wrapper is the proposal its content was negotiated with.
    func setPlacementProposal(_ proposal: WuiProposalSize) {
      contentView.setPlacementProposal(proposal)
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        contentView.sizeThatFits(proposal)
    }

    func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
      contentView.measure(proposal)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        // The holder extends this view to the edges it touches; the content
        // lays itself out against the insets that remain once the ignored
        // edges are erased (`wuiSafeAreaRect` consults this wrapper).
        contentView.frame = wuiContentFrame(of: contentView, in: self)
    }

    /// `insets` with the ignored edges set to zero.
    func erasingIgnoredEdges(from insets: UIEdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(
            top: edges.top ? 0 : insets.top,
            left: edges.leading ? 0 : insets.left,
            bottom: edges.bottom ? 0 : insets.bottom,
            right: edges.trailing ? 0 : insets.right
        )
    }
    #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // macOS: safe area is less of a concern, just fill bounds
        contentView.frame = bounds
    }
    #endif
}

/// Escaping the safe area is the component's whole purpose; a window whose
/// root ignores the safe area must be handed the full window bounds.
extension WuiIgnoreSafeArea: WuiSafeAreaManaging {}
