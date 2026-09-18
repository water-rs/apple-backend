import CWaterUI
import OSLog

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

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
      let material = Self.nsMaterial(from: metadata.material)
      blurView.material = material
      // Match typical AppKit/SF Symbols vibrancy behavior:
      // - Titlebar/HUD materials blend behind the window
      // - Sidebar/content materials blend within the window
      switch material {
      case .titlebar, .hudWindow:
        blurView.blendingMode = .behindWindow
      default:
        blurView.blendingMode = .withinWindow
      }
      blurView.state = .active
    #endif

    super.init(frame: .zero)

    #if canImport(AppKit)
      wantsLayer = true
    #endif

    // Add blur view first (behind content)
    addSubview(blurView)

    // Add content on top
    addSubview(contentView)

    // The blur tracks the content's frame, not the wrapper's — resolved in
    // layout, where the negotiated size is known.
    blurView.translatesAutoresizingMaskIntoConstraints = true
    contentView.translatesAutoresizingMaskIntoConstraints = true

    Logger.waterui.debug(
      "MaterialBackground created with material: \(String(describing: metadata.material))")
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
        fatalError("Unsupported WaterUI material: \(material.rawValue)")
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
        fatalError("Unsupported WaterUI material: \(material.rawValue)")
      }
    }
  #endif

  func layoutPriority() -> Int32 {
    contentView.layoutPriority()
  }

  /// Transparent for layout: the proposal selected for this
  /// wrapper is the proposal its content was negotiated with.
  func setPlacementProposal(_ proposal: WuiProposalSize) {
    lastProposal = proposal
    contentView.setPlacementProposal(proposal)
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    contentView.measure(proposal)
  }

  /// The offer the parent selected for this wrapper, echoed back when the
  /// host stamps the frame without delivering a proposal.
  private var lastProposal = WuiProposalSize()

  /// Places the blur and the content over the content's negotiated frame.
  ///
  /// `.background(material)` in SwiftUI covers exactly the view it backs: a
  /// `width`-constrained content keeps its narrower material column while the
  /// wrapper itself may be stamped wider by a parent that fills its offer.
  /// The material is layout-transparent, so the content's own
  /// `sizeThatFits` under the delivered proposal is the frame both get.
  private func layoutContent() {
    let size = contentView.sizeThatFits(
      WuiProposalSize(
        width: lastProposal.width ?? Float(bounds.width),
        height: lastProposal.height ?? Float(bounds.height)
      ))
    let rect = CGRect(
      x: (bounds.width - size.width) / 2,
      y: (bounds.height - size.height) / 2,
      width: size.width,
      height: size.height
    )
    contentView.frame = rect
    blurView.frame = rect
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      layoutContent()
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      layoutContent()
    }
  #endif
}

/// A material is chrome, not content: SwiftUI's `.background(material)`
/// covers its view's whole frame — a sidebar's blur runs behind the status
/// bar and the home indicator — while the view it backs keeps its own
/// safe-area insets. Owning the insets makes the host stamp this wrapper the
/// full bounds; the content view inside still gets the safe-area rect.
extension WuiMaterialBackground: WuiSafeAreaManaging {}