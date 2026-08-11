import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<AccessibilityIdentifier>.
///
/// Applies a stable automation identifier to the wrapped view so XCUITest can
/// locate it via `accessibilityIdentifier`. The identifier is invisible to end
/// users and never spoken by VoiceOver.
@MainActor
final class WuiAccessibilityIdentifier: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_ignorable_metadata_accessibility_identifier_id() }

    private let contentView: any WuiComponent

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_ignorable_metadata_accessibility_identifier(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        let identifier = WuiStr(metadata.identifier).toString()
        #if canImport(UIKit)
        contentView.accessibilityIdentifier = identifier
        #elseif canImport(AppKit)
        contentView.setAccessibilityIdentifier(identifier)
        #endif

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)
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
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
    }
    #endif
}
