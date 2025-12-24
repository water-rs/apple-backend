import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Background>.
///
/// Applies a background color, material (blur), or image to the wrapped view.
/// Background fills the entire bounds behind the content.
///
/// For rounded cards, apply `.background()` first, then `.clip_shape()`.
@MainActor
final class WuiBackground: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_background_id() }

    private let contentView: any WuiComponent
    private var colorComputed: WuiComputed<WuiResolvedColor>?
    private var colorWatcher: WatcherGuard?
    #if canImport(UIKit)
    private var effectView: UIVisualEffectView?
    #elseif canImport(AppKit)
    private var effectView: NSVisualEffectView?
    #endif

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_background(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        // Apply background based on type
        switch metadata.value.tag {
        case WuiBackground_Color:
            setupColorBackground(colorPtr: metadata.value.color.color, env: env)
        case WuiBackground_Image:
            setupImageBackground(imagePtr: metadata.value.image.image)
        case WuiBackground_Material:
            setupMaterialBackground(material: metadata.value.material.material)
        default:
            break
        }

        // Add content on top of background
        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)
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

    private func setupMaterialBackground(material: WuiMaterial) {
        #if canImport(UIKit)
        let blurStyle = material.toUIBlurStyle()
        let blurEffect = UIBlurEffect(style: blurStyle)
        let visualEffectView = UIVisualEffectView(effect: blurEffect)
        visualEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        visualEffectView.translatesAutoresizingMaskIntoConstraints = true
        insertSubview(visualEffectView, at: 0)
        self.effectView = visualEffectView
        #elseif canImport(AppKit)
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material.toNSMaterial()
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(visualEffectView, positioned: .below, relativeTo: nil)
        self.effectView = visualEffectView
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
        effectView?.frame = bounds
        contentView.frame = bounds
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        effectView?.frame = bounds
        contentView.frame = bounds
    }
    #endif
}

// MARK: - Material to Native Blur Style Conversion

extension WuiMaterial {
    #if canImport(UIKit)
    /// Converts WuiMaterial to UIBlurEffect.Style
    func toUIBlurStyle() -> UIBlurEffect.Style {
        switch self {
        case WuiMaterial_UltraThin:
            return .systemUltraThinMaterial
        case WuiMaterial_Thin:
            return .systemThinMaterial
        case WuiMaterial_Regular:
            return .systemMaterial
        case WuiMaterial_Thick:
            return .systemThickMaterial
        case WuiMaterial_UltraThick:
            return .systemChromeMaterial
        default:
            return .systemMaterial
        }
    }
    #elseif canImport(AppKit)
    /// Converts WuiMaterial to NSVisualEffectView.Material
    func toNSMaterial() -> NSVisualEffectView.Material {
        switch self {
        case WuiMaterial_UltraThin:
            return .hudWindow
        case WuiMaterial_Thin:
            return .menu
        case WuiMaterial_Regular:
            return .popover
        case WuiMaterial_Thick:
            return .sidebar
        case WuiMaterial_UltraThick:
            return .titlebar
        default:
            return .popover
        }
    }
    #endif
}
