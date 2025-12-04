import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Secure>.
///
/// Marks a view as secure, preventing screenshot capture.
/// On iOS, uses secure text field overlay technique.
/// On macOS, uses window-level security features.
@MainActor
final class WuiSecure: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_secure_id() }

    private let contentView: any WuiComponent

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_secure(anyview)

        // Resolve the content with the same environment
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        #if canImport(UIKit)
        // iOS: Use a secure container approach
        // Create a secure text field and use its layer for rendering
        let secureField = UITextField()
        secureField.isSecureTextEntry = true
        secureField.isUserInteractionEnabled = false
        secureField.alpha = 0.01 // Nearly invisible but triggers secure mode
        insertSubview(secureField, at: 0)

        // The content view sits on top
        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)
        #elseif canImport(AppKit)
        // macOS: Add content directly, secure window features handled at window level
        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)
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
        // Layout secure field to fill bounds
        if let secureField = subviews.first as? UITextField {
            secureField.frame = bounds
        }
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
