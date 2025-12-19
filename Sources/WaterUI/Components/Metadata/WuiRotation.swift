import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Rotation>.
///
/// Applies a rotation transform to the wrapped view around the specified anchor point.
/// Rotations are purely visual and do not affect layout.
@MainActor
final class WuiRotation: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_rotation_id() }

    private let contentView: any WuiComponent
    private var rotationWatcher: WatcherGuard?

    // Current transform value
    private var currentRotation: CGFloat = 0.0
    private let anchor: CGPoint

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_rotation(anyview)

        // Convert anchor from normalized (0-1) to CGPoint
        self.anchor = CGPoint(
            x: CGFloat(metadata.value.anchor.x),
            y: CGFloat(metadata.value.anchor.y)
        )

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        // Enable layer for transforms
        #if canImport(AppKit)
        wantsLayer = true
        contentView.wantsLayer = true
        #endif

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Setup watcher for reactive rotation property
        setupWatcher(metadata.value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWatcher(_ rotation: WuiRotation_Struct) {
        let rotationComputed = WuiComputed<Float>(rotation.angle)

        // Initial value
        currentRotation = CGFloat(rotationComputed.value)
        applyTransform()

        // Watch for changes
        rotationWatcher = rotationComputed.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentRotation = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyTransform()
            }
        }
    }

    private func applyTransform() {
        let radians = currentRotation * .pi / 180.0

        #if canImport(UIKit)
        let transform = CGAffineTransform(rotationAngle: radians)
        contentView.transform = transform

        #elseif canImport(AppKit)
        let size = contentView.bounds.size
        let anchorPoint = CGPoint(x: size.width * anchor.x, y: size.height * anchor.y)
        let centerPoint = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let offset = CGPoint(x: anchorPoint.x - centerPoint.x, y: anchorPoint.y - centerPoint.y)
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: offset.x, y: offset.y)
        transform = transform.rotated(by: radians)
        transform = transform.translatedBy(x: -offset.x, y: -offset.y)
        contentView.layer?.setAffineTransform(transform)
        #endif
    }

    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Transform doesn't affect layout size
        contentView.sizeThatFits(proposal)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        // Set anchorPoint and position for proper rotation pivot
        contentView.layer.anchorPoint = anchor
        contentView.bounds = CGRect(origin: .zero, size: bounds.size)
        contentView.center = CGPoint(
            x: bounds.width * anchor.x,
            y: bounds.height * anchor.y
        )
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()

        // First set frame to trigger contentView's internal layout
        contentView.frame = bounds

        applyTransform()
    }
    #endif
}

// Type alias for the FFI rotation struct
private typealias WuiRotation_Struct = CWaterUI.WuiRotation
