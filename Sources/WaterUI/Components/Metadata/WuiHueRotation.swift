import CWaterUI
import CoreImage

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<HueRotation>.
///
/// Applies a hue rotation to the wrapped view.
/// Hue rotation is purely visual and does not affect layout.
@MainActor
final class WuiHueRotation: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_hue_rotation_id() }

    private let contentView: any WuiComponent
    private var angleWatcher: WatcherGuard?
    private var currentAngle: CGFloat = 0.0

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_hue_rotation(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        #if canImport(AppKit)
        wantsLayer = true
        contentView.wantsLayer = true
        #endif

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Setup watcher for reactive hue rotation
        setupWatcher(metadata.value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWatcher(_ hueRotation: WuiHueRotation_Struct) {
        let angleComputed = WuiComputed<Float>(hueRotation.angle)

        // Initial value
        currentAngle = CGFloat(angleComputed.value)
        applyHueRotation()

        // Watch for changes
        angleWatcher = angleComputed.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentAngle = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyHueRotation()
            }
        }
    }

    private func applyHueRotation() {
        // Convert degrees to radians for CIHueAdjust
        let angleInRadians = currentAngle * .pi / 180.0

        #if canImport(UIKit)
        // Use CIHueAdjust filter for hue rotation
        if let filter = CIFilter(name: "CIHueAdjust") {
            filter.setValue(angleInRadians, forKey: kCIInputAngleKey)
            contentView.layer.filters = [filter]
        }
        #elseif canImport(AppKit)
        if let filter = CIFilter(name: "CIHueAdjust") {
            filter.setValue(angleInRadians, forKey: kCIInputAngleKey)
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

// Type alias for the FFI hue rotation struct
private typealias WuiHueRotation_Struct = CWaterUI.WuiHueRotation
