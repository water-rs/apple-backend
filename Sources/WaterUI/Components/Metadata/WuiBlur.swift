import CWaterUI
import CoreImage

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Blur>.
///
/// Applies a Gaussian blur filter to the wrapped view.
/// Blur is purely visual and does not affect layout.
@MainActor
final class WuiBlur: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_blur_id() }

    private let contentView: any WuiComponent
    private var radiusWatcher: WatcherGuard?
    private var currentRadius: CGFloat = 0.0

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_blur(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        #if canImport(AppKit)
        wantsLayer = true
        contentView.wantsLayer = true
        #endif

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Setup watcher for reactive blur radius
        setupWatcher(metadata.value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWatcher(_ blur: WuiBlur_Struct) {
        let radiusComputed = WuiComputed<Float>(blur.radius)

        // Initial value
        currentRadius = CGFloat(radiusComputed.value)
        applyBlur()

        // Watch for changes
        radiusWatcher = radiusComputed.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentRadius = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyBlur()
            }
        }
    }

    private func applyBlur() {
        #if canImport(UIKit)
        // Remove existing blur view if any
        if let existingBlur = subviews.first(where: { $0 is UIVisualEffectView }) {
            existingBlur.removeFromSuperview()
        }

        if currentRadius > 0 {
            // Use UIVisualEffectView for blur on iOS
            // Map radius to blur style (rough approximation)
            let blurStyle: UIBlurEffect.Style = currentRadius > 10 ? .regular : .light
            let blurEffect = UIBlurEffect(style: blurStyle)
            let blurView = UIVisualEffectView(effect: blurEffect)
            blurView.translatesAutoresizingMaskIntoConstraints = false
            blurView.alpha = min(1.0, currentRadius / 20.0)
            insertSubview(blurView, aboveSubview: contentView)
            NSLayoutConstraint.activate([
                blurView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                blurView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                blurView.topAnchor.constraint(equalTo: contentView.topAnchor),
                blurView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
        #elseif canImport(AppKit)
        NSAnimationContext.current.allowsImplicitAnimation = true
        if currentRadius > 0, let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(currentRadius, forKey: kCIInputRadiusKey)
            contentView.layer?.filters = [filter]
        } else {
            contentView.layer?.filters = nil
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

// Type alias for the FFI blur struct
private typealias WuiBlur_Struct = CWaterUI.WuiBlur
