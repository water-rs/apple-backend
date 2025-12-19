import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Opacity>.
///
/// Applies an opacity adjustment to the wrapped view.
/// Opacity is purely visual and does not affect layout.
@MainActor
final class WuiOpacity: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_opacity_id() }

    private let contentView: any WuiComponent
    private var opacityWatcher: WatcherGuard?
    private var currentOpacity: CGFloat = 1.0

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_opacity(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        #if canImport(AppKit)
        wantsLayer = true
        #endif

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Setup watcher for reactive opacity
        setupWatcher(metadata.value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWatcher(_ opacity: WuiOpacity_Struct) {
        let opacityComputed = WuiComputed<Float>(opacity.value)

        // Initial value
        currentOpacity = CGFloat(opacityComputed.value)
        applyOpacity()

        // Watch for changes
        opacityWatcher = opacityComputed.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentOpacity = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyOpacity()
            }
        }
    }

    private func applyOpacity() {
        #if canImport(UIKit)
        contentView.alpha = currentOpacity
        #elseif canImport(AppKit)
        contentView.alphaValue = currentOpacity
        #endif
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

// Type alias for the FFI opacity struct
private typealias WuiOpacity_Struct = CWaterUI.WuiOpacity
