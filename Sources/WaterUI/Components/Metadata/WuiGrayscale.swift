import CWaterUI
import CoreImage

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Grayscale>.
///
/// Applies a grayscale filter to the wrapped view.
/// Grayscale is purely visual and does not affect layout.
@MainActor
final class WuiGrayscale: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_grayscale_id() }

    private let contentView: any WuiComponent
    private var intensityWatcher: WatcherGuard?
    private var currentIntensity: CGFloat = 0.0

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_grayscale(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        #if canImport(AppKit)
        wantsLayer = true
        contentView.wantsLayer = true
        #endif

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Setup watcher for reactive grayscale intensity
        setupWatcher(metadata.value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWatcher(_ grayscale: WuiGrayscale_Struct) {
        let intensityComputed = WuiComputed<Float>(grayscale.intensity)

        // Initial value
        currentIntensity = CGFloat(intensityComputed.value)
        applyGrayscale()

        // Watch for changes
        intensityWatcher = intensityComputed.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentIntensity = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyGrayscale()
            }
        }
    }

    private func applyGrayscale() {
        // Use saturation to implement grayscale
        // intensity 0 = full color (saturation 1), intensity 1 = grayscale (saturation 0)
        let saturation = 1.0 - currentIntensity

        #if canImport(UIKit)
        // Use CIColorControls filter with saturation for grayscale effect
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(saturation, forKey: kCIInputSaturationKey)
            contentView.layer.filters = [filter]
        }
        #elseif canImport(AppKit)
        NSAnimationContext.current.allowsImplicitAnimation = true
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(saturation, forKey: kCIInputSaturationKey)
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

// Type alias for the FFI grayscale struct
private typealias WuiGrayscale_Struct = CWaterUI.WuiGrayscale
