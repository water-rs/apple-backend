import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Background>.
///
/// Applies a background color or image to the wrapped view.
@MainActor
final class WuiBackground: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_background_id() }

    private let contentView: any WuiComponent
    private var colorComputed: WuiComputed<WuiResolvedColor>?
    private var colorWatcher: WatcherGuard?

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_background(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Apply background based on type
        switch metadata.value.tag {
        case WuiBackground_Color:
            setupColorBackground(colorPtr: metadata.value.color.color, env: env)
        case WuiBackground_Image:
            setupImageBackground(imagePtr: metadata.value.image.image)
        default:
            break
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupColorBackground(colorPtr: OpaquePointer!, env: WuiEnvironment) {
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
        backgroundColor = color.toUIColor()
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.backgroundColor = color.toNSColor().cgColor
        #endif
    }

    private func setupImageBackground(imagePtr: OpaquePointer!) {
        // TODO: Implement image background support
        // Would need to load image from path/URL and set as layer contents
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
