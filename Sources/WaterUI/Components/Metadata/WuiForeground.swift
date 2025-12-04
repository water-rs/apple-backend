import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<ForegroundColor>.
///
/// Sets the foreground/text color for the wrapped view.
/// The color is passed down through the environment to child text views.
@MainActor
final class WuiForeground: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_foreground_id() }

    private let contentView: any WuiComponent
    private var colorComputed: WuiComputed<WuiResolvedColor>?
    private var colorWatcher: WatcherGuard?

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_foreground(anyview)

        // Resolve the content - foreground color is typically applied via text styling
        // rather than directly on the container view
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Set tint color for the container (affects child views)
        setupForegroundColor(colorPtr: metadata.value.color, env: env)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupForegroundColor(colorPtr: OpaquePointer!, env: WuiEnvironment) {
        guard let colorPtr else { return }

        // Read the Color from Computed<Color>, then resolve it to get Computed<ResolvedColor>
        let color = WuiColor(waterui_read_computed_color(colorPtr)!)
        let resolved = color.resolve(in: env)

        // Keep strong reference to the computed value
        self.colorComputed = resolved

        // Apply initial color
        applyColor(resolved.value)

        // Watch for changes
        colorWatcher = resolved.watch { [weak self] color, metadata in
            guard let self else { return }
            withPlatformAnimation(metadata) {
                self.applyColor(color)
            }
        }
    }

    private func applyColor(_ color: WuiResolvedColor) {
        #if canImport(UIKit)
        tintColor = color.toUIColor()
        #elseif canImport(AppKit)
        // macOS doesn't have a direct tintColor equivalent
        // Color is typically applied through text attributes
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
