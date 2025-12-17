import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Scale>.
///
/// Applies a scale transform to the wrapped view around the specified anchor point.
/// Scales are purely visual and do not affect layout.
@MainActor
final class WuiScale: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_scale_id() }

    private let contentView: any WuiComponent
    private var scaleXWatcher: WatcherGuard?
    private var scaleYWatcher: WatcherGuard?

    // Current transform values
    private var currentScaleX: CGFloat = 1.0
    private var currentScaleY: CGFloat = 1.0
    private let anchor: CGPoint

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_scale(anyview)

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

        // Setup watchers for reactive transform properties
        setupWatchers(metadata.value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWatchers(_ scale: WuiScale_Struct) {
        let scaleX = WuiComputed<Float>(scale.x)
        let scaleY = WuiComputed<Float>(scale.y)

        // Initial values
        currentScaleX = CGFloat(scaleX.value)
        currentScaleY = CGFloat(scaleY.value)
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
    }

    private func applyTransform() {
        let transform = CGAffineTransform(scaleX: currentScaleX, y: currentScaleY)

        #if canImport(UIKit)
        contentView.transform = transform

        #elseif canImport(AppKit)
        // Enable implicit animation so WaterUI animation context applies to layer transform
        NSAnimationContext.current.allowsImplicitAnimation = true
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
        // Set anchorPoint and position for proper scale pivot
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

        guard let layer = contentView.layer else {
            applyTransform()
            return
        }

        // Set anchor point for transform pivot
        layer.anchorPoint = anchor

        // Calculate position to keep view visually in place after anchorPoint change
        // Position = frame.origin + anchorPoint * frame.size
        layer.position = CGPoint(
            x: bounds.origin.x + anchor.x * bounds.size.width,
            y: bounds.origin.y + anchor.y * bounds.size.height
        )

        applyTransform()
    }
    #endif
}

// Type alias for the FFI scale struct
private typealias WuiScale_Struct = CWaterUI.WuiScale
