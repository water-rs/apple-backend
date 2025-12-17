import CWaterUI
import CoreImage

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Saturation>.
///
/// Applies a saturation adjustment to the wrapped view.
/// Saturation is purely visual and does not affect layout.
@MainActor
final class WuiSaturation: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_saturation_id() }

    private let contentView: any WuiComponent
    private var saturationWatcher: WatcherGuard?
    private var currentSaturation: CGFloat = 1.0

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_saturation(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        #if canImport(AppKit)
        wantsLayer = true
        contentView.wantsLayer = true
        #endif

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Setup watcher for reactive saturation
        setupWatcher(metadata.value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWatcher(_ saturation: WuiSaturation_Struct) {
        let saturationComputed = WuiComputed<Float>(saturation.amount)

        // Initial value
        currentSaturation = CGFloat(saturationComputed.value)
        applySaturation()

        // Watch for changes
        saturationWatcher = saturationComputed.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentSaturation = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applySaturation()
            }
        }
    }

    private func applySaturation() {
        #if canImport(UIKit)
        // Use CIColorControls filter for saturation
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(currentSaturation, forKey: kCIInputSaturationKey)
            contentView.layer.filters = [filter]
        }
        #elseif canImport(AppKit)
        NSAnimationContext.current.allowsImplicitAnimation = true
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(currentSaturation, forKey: kCIInputSaturationKey)
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

// Type alias for the FFI saturation struct
private typealias WuiSaturation_Struct = CWaterUI.WuiSaturation
