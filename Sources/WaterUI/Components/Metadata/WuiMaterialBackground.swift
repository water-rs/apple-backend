import CWaterUI
import os.log

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "MaterialBackground")

/// Component for IgnorableMetadata<MaterialBackground>.
///
/// Applies a native blur effect behind the wrapped view content.
/// Uses NSVisualEffectView on macOS and UIVisualEffectView on iOS.
@MainActor
final class WuiMaterialBackground: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_ignorable_metadata_material_background_id() }

    private let contentView: any WuiComponent
    #if canImport(UIKit)
    private let blurView: UIVisualEffectView
    #elseif canImport(AppKit)
    private let blurView: NSVisualEffectView
    #endif

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_ignorable_metadata_material_background(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        // Create blur view with appropriate material
        #if canImport(UIKit)
        let blurEffect = UIBlurEffect(style: Self.uiBlurStyle(from: metadata.material))
        self.blurView = UIVisualEffectView(effect: blurEffect)
        #elseif canImport(AppKit)
        self.blurView = NSVisualEffectView()
        blurView.material = Self.nsMaterial(from: metadata.material)
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        #endif

        super.init(frame: .zero)

        #if canImport(AppKit)
        wantsLayer = true
        #endif

        // Add blur view first (behind content)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        // Add content on top
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        // Setup constraints
        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        logger.debug("MaterialBackground created with material: \(String(describing: metadata.material))")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    #if canImport(UIKit)
    private static func uiBlurStyle(from material: WuiMaterial) -> UIBlurEffect.Style {
        switch material {
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
    #endif

    #if canImport(AppKit)
    private static func nsMaterial(from material: WuiMaterial) -> NSVisualEffectView.Material {
        switch material {
        case WuiMaterial_UltraThin:
            return .hudWindow
        case WuiMaterial_Thin:
            return .titlebar
        case WuiMaterial_Regular:
            return .menu
        case WuiMaterial_Thick:
            return .sidebar
        case WuiMaterial_UltraThick:
            return .sidebar
        default:
            return .menu
        }
    }
    #endif

    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        contentView.sizeThatFits(proposal)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
    }
    #endif
}
