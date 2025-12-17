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
        #if canImport(UIKit)
        // UIKit uses center anchorPoint (0.5, 0.5) by default
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: currentTranslateX, y: currentTranslateY)
        transform = transform.rotated(by: currentRotation * .pi / 180.0)
        transform = transform.scaledBy(x: currentScaleX, y: currentScaleY)
        contentView.transform = transform

        #elseif canImport(AppKit)
        // AppKit: Keep default anchorPoint, use matrix math to simulate center transform
        // This is the safest approach - won't cause frame/layer desync

        let size = bounds.size
        let centerX = size.width / 2.0
        let centerY = size.height / 2.0

        var transform = CGAffineTransform.identity

        // Step 1: Apply user's translation
        transform = transform.translatedBy(x: currentTranslateX, y: currentTranslateY)

        // Step 2: Simulate pivot point transform (center-based scale/rotate)
        // A. Move coordinate origin to view center
        transform = transform.translatedBy(x: centerX, y: centerY)

        // B. Apply rotation and scale
        transform = transform.rotated(by: currentRotation * .pi / 180.0)
        transform = transform.scaledBy(x: currentScaleX, y: currentScaleY)

        // C. Move coordinate origin back to top-left (undo step A)
        transform = transform.translatedBy(x: -centerX, y: -centerY)

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
        // Don't set frame when transform exists - use bounds and center instead
        contentView.bounds = CGRect(origin: .zero, size: bounds.size)
        contentView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()

        // Simple frame assignment - don't modify anchorPoint
        // Transform is purely visual, handled by matrix math in applyTransform()
        contentView.frame = bounds

        applyTransform()
    }
    #endif
}

// Type alias for the FFI transform struct
private typealias WuiTransform_Struct = CWaterUI.WuiTransform
