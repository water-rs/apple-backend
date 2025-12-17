import CWaterUI
import CoreImage

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Brightness>.
///
/// Applies a brightness adjustment to the wrapped view.
/// Brightness is purely visual and does not affect layout.
@MainActor
final class WuiBrightness: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_brightness_id() }

    private let contentView: any WuiComponent
    private var brightnessWatcher: WatcherGuard?
    private var currentBrightness: CGFloat = 0.0

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_brightness(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        #if canImport(AppKit)
        wantsLayer = true
        contentView.wantsLayer = true
        #endif

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Setup watcher for reactive brightness
        setupWatcher(metadata.value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWatcher(_ brightness: WuiBrightness_Struct) {
        let brightnessComputed = WuiComputed<Float>(brightness.amount)

        // Initial value
        currentBrightness = CGFloat(brightnessComputed.value)
        applyBrightness()

        // Watch for changes
        brightnessWatcher = brightnessComputed.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentBrightness = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyBrightness()
            }
        }
    }

    private func applyBrightness() {
        #if canImport(UIKit)
        // Use CIColorControls filter for brightness
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(currentBrightness, forKey: kCIInputBrightnessKey)
            contentView.layer.filters = [filter]
        }
        #elseif canImport(AppKit)
        NSAnimationContext.current.allowsImplicitAnimation = true
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(currentBrightness, forKey: kCIInputBrightnessKey)
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

// Type alias for the FFI brightness struct
private typealias WuiBrightness_Struct = CWaterUI.WuiBrightness
