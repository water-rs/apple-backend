import CWaterUI
import CoreImage

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Contrast>.
///
/// Applies a contrast adjustment to the wrapped view.
/// Contrast is purely visual and does not affect layout.
@MainActor
final class WuiContrast: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_contrast_id() }

    private let contentView: any WuiComponent
    private var contrastWatcher: WatcherGuard?
    private var currentContrast: CGFloat = 1.0

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_contrast(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        #if canImport(AppKit)
        wantsLayer = true
        contentView.wantsLayer = true
        #endif

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Setup watcher for reactive contrast
        setupWatcher(metadata.value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWatcher(_ contrast: WuiContrast_Struct) {
        let contrastComputed = WuiComputed<Float>(contrast.amount)

        // Initial value
        currentContrast = CGFloat(contrastComputed.value)
        applyContrast()

        // Watch for changes
        contrastWatcher = contrastComputed.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentContrast = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyContrast()
            }
        }
    }

    private func applyContrast() {
        #if canImport(UIKit)
        // Use CIColorControls filter for contrast
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(currentContrast, forKey: kCIInputContrastKey)
            contentView.layer.filters = [filter]
        }
        #elseif canImport(AppKit)
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(currentContrast, forKey: kCIInputContrastKey)
            contentView.layer?.filters = [filter]
        }
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

// Type alias for the FFI contrast struct
private typealias WuiContrast_Struct = CWaterUI.WuiContrast
