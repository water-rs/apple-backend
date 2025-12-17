import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Offset>.
///
/// Applies a translation (offset) transform to the wrapped view.
/// Offsets are purely visual and do not affect layout.
@MainActor
final class WuiOffset: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_offset_id() }

    private let contentView: any WuiComponent
    private var offsetXWatcher: WatcherGuard?
    private var offsetYWatcher: WatcherGuard?

    // Current transform values
    private var currentOffsetX: CGFloat = 0.0
    private var currentOffsetY: CGFloat = 0.0

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_offset(anyview)

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

        // Setup watchers for reactive offset properties
        setupWatchers(metadata.value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWatchers(_ offset: WuiOffset_Struct) {
        let offsetX = WuiComputed<Float>(offset.x)
        let offsetY = WuiComputed<Float>(offset.y)

        // Initial values
        currentOffsetX = CGFloat(offsetX.value)
        currentOffsetY = CGFloat(offsetY.value)
        applyTransform()

        // Watch for changes
        offsetXWatcher = offsetX.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentOffsetX = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyTransform()
            }
        }

        offsetYWatcher = offsetY.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentOffsetY = CGFloat(value)
            withPlatformAnimation(metadata) {
                self.applyTransform()
            }
        }
    }

    private func applyTransform() {
        #if canImport(UIKit)
        // UIKit: Simple translation transform
        contentView.transform = CGAffineTransform(translationX: currentOffsetX, y: currentOffsetY)

        #elseif canImport(AppKit)
        // AppKit: Apply translation via layer transform
        let transform = CGAffineTransform(translationX: currentOffsetX, y: currentOffsetY)
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
        // Set bounds and center to match our bounds
        contentView.bounds = CGRect(origin: .zero, size: bounds.size)
        contentView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
        applyTransform()
    }
    #endif
}

// Type alias for the FFI offset struct
private typealias WuiOffset_Struct = CWaterUI.WuiOffset
