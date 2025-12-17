import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Transform>.
///
/// Applies a 2D transform (scale, rotation, translation) to the wrapped view.
/// Transforms are purely visual and do not affect layout.
@MainActor
final class WuiTransform: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_transform_id() }

    private let contentView: any WuiComponent
    private var scaleXWatcher: WatcherGuard?
    private var scaleYWatcher: WatcherGuard?
    private var rotationWatcher: WatcherGuard?
    private var translateXWatcher: WatcherGuard?
    private var translateYWatcher: WatcherGuard?

    // Current transform values
    private var currentScaleX: CGFloat = 1.0
    private var currentScaleY: CGFloat = 1.0
    private var currentRotation: CGFloat = 0.0
    private var currentTranslateX: CGFloat = 0.0
    private var currentTranslateY: CGFloat = 0.0

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_transform(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        // Enable layer for transforms
        #if canImport(AppKit)
        wantsLayer = true
        // Set up content view's layer for centered transforms
        contentView.wantsLayer = true
        #endif

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Setup watchers for reactive transform properties
        setupWatchers(metadata.value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWatchers(_ transform: WuiTransform_Struct) {
        let scaleX = WuiComputed<Float>(transform.scale_x)
        let scaleY = WuiComputed<Float>(transform.scale_y)
        let rotation = WuiComputed<Float>(transform.rotation)
        let translateX = WuiComputed<Float>(transform.translate_x)
        let translateY = WuiComputed<Float>(transform.translate_y)

        // Initial values
        currentScaleX = CGFloat(scaleX.value)
        currentScaleY = CGFloat(scaleY.value)
        currentRotation = CGFloat(rotation.value)
        currentTranslateX = CGFloat(translateX.value)
        currentTranslateY = CGFloat(translateY.value)
        applyTransform()

        // Watch for changes
        scaleXWatcher = scaleX.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentScaleX = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyTransform()
            }
        }

        scaleYWatcher = scaleY.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentScaleY = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyTransform()
            }
        }

        rotationWatcher = rotation.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentRotation = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyTransform()
            }
        }

        translateXWatcher = translateX.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentTranslateX = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyTransform()
            }
        }

        translateYWatcher = translateY.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentTranslateY = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyTransform()
            }
        }
    }

    private func applyTransform() {
        // Build the combined transform
        // Order: scale -> rotate -> translate
        var transform = CGAffineTransform.identity
        transform = transform.scaledBy(x: currentScaleX, y: currentScaleY)
        transform = transform.rotated(by: currentRotation * .pi / 180.0) // Convert degrees to radians
        transform = transform.translatedBy(x: currentTranslateX, y: currentTranslateY)

        #if canImport(UIKit)
        contentView.transform = transform
        #elseif canImport(AppKit)
        // For AppKit, we apply the transform via the layer
        // anchorPoint is managed in layout() to ensure transforms apply from center
        if let layer = contentView.layer {
            layer.setAffineTransform(transform)
        }
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
        contentView.frame = bounds
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()

        // For AppKit layer-backed transforms, we need to:
        // 1. Set the view's frame for proper layout
        // 2. Set anchorPoint to (0.5, 0.5) so transforms apply from center
        // 3. Adjust layer position to compensate for anchorPoint change

        let targetFrame = bounds

        // Set view frame first (this also sets layer.frame initially)
        contentView.frame = targetFrame

        if let layer = contentView.layer {
            // Change anchorPoint to center for proper transform origin
            // Default in AppKit is (0, 0), we want (0.5, 0.5)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

            // When anchorPoint changes from (0,0) to (0.5,0.5), we must adjust position.
            // Position should be the center of the view in superlayer coordinates.
            layer.position = CGPoint(
                x: targetFrame.midX,
                y: targetFrame.midY
            )

            // Reapply transform after anchor point is set
            applyTransform()
        }
    }
    #endif
}

// Type alias for the FFI transform struct
private typealias WuiTransform_Struct = CWaterUI.WuiTransform
