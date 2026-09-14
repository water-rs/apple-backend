import CWaterUI
import OSLog

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for IgnorableMetadata<GlassBackground>.
///
/// Puts Liquid Glass behind the wrapped content: `UIGlassEffect` in a
/// `UIVisualEffectView` on iOS, `NSGlassEffectView` on macOS. The content is
/// hosted by the effect's own content view, which is where the platform expects
/// it — a subview added beside the effect gets none of the glass's treatment.
///
/// The outline is the effect's, not a mask's: a layer mask over a glass surface
/// takes its refraction and highlights with it, so the shape is handed to the
/// platform as a corner configuration (`cornerConfiguration` on iOS,
/// `cornerRadius` on macOS). Only the shapes a corner configuration can express
/// are glass outlines; anything else is a programming error, not a shape to
/// approximate.
@MainActor
final class WuiGlassBackground: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_ignorable_metadata_glass_background_id() }

  private let contentView: any WuiComponent
  private let shape: WuiShapeKind
  private let tint: WuiColor?
  private var tintObservation: WuiComputedObservation<WuiResolvedColor>?
  #if canImport(UIKit)
    private let effectView: UIVisualEffectView
    private let effect: UIGlassEffect
  #elseif canImport(AppKit)
    private let effectView: NSGlassEffectView
  #endif

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_ignorable_metadata_glass_background(anyview)

    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)
    self.shape = metadata.shape
    self.tint = metadata.tint.map(WuiColor.init)

    #if canImport(UIKit)
      let effect = UIGlassEffect(style: Self.uiStyle(from: metadata.style))
      effect.isInteractive = metadata.interactive
      self.effect = effect
      self.effectView = UIVisualEffectView(effect: effect)
    #elseif canImport(AppKit)
      self.effectView = NSGlassEffectView()
      effectView.style = Self.nsStyle(from: metadata.style)
    #endif

    super.init(frame: .zero)

    #if canImport(AppKit)
      wantsLayer = true
    #endif

    effectView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(effectView)
    contentView.translatesAutoresizingMaskIntoConstraints = false

    #if canImport(UIKit)
      effectView.contentView.addSubview(contentView)
      let host: UIView = effectView.contentView
    #elseif canImport(AppKit)
      // `contentView` is the view the glass displays over; the effect view
      // adds it as its own subview and keeps it above the glass.
      effectView.contentView = contentView
      let host: NSView = effectView
    #endif

    NSLayoutConstraint.activate([
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
      contentView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      contentView.topAnchor.constraint(equalTo: host.topAnchor),
      contentView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])

    if let tint {
      tintObservation = WuiComputedObservation(tint.resolve(in: env)) { [weak self] color, _ in
        self?.applyTint(color)
      }
      if let color = tintObservation?.value {
        applyTint(color)
      }
    }

    Logger.waterui.debug(
      "GlassBackground created with style: \(String(describing: metadata.style))")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func applyTint(_ color: WuiResolvedColor) {
    #if canImport(UIKit)
      effect.tintColor = color.toUIColor()
      // A `UIGlassEffect` is copied into the effect view; a property set
      // afterwards only reaches the view through reassignment.
      effectView.effect = effect
    #elseif canImport(AppKit)
      effectView.tintColor = color.toNSColor()
    #endif
  }

  func layoutPriority() -> Int32 {
    contentView.layoutPriority()
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  #if canImport(UIKit)
    private static func uiStyle(from style: WuiGlassStyle) -> UIGlassEffect.Style {
      switch style {
      case WuiGlassStyle_Regular:
        return .regular
      case WuiGlassStyle_Clear:
        return .clear
      default:
        fatalError("Unsupported WaterUI glass style: \(style.rawValue)")
      }
    }

    /// The outline as a corner configuration.
    ///
    /// A capsule and a circle are the platform's capsule; uniform and
    /// per-corner radii map to their configurations. An ellipse or a custom
    /// path has no corner configuration and cannot be a glass outline.
    private static func cornerConfiguration(
      for kind: WuiShapeKind, in bounds: CGRect
    ) -> UICornerConfiguration {
      let shorter = min(bounds.width, bounds.height)
      let limit = shorter / 2
      switch kind.tag {
      case 0:
        return .corners(radius: .fixed(0))
      case 1, 5:
        return .capsule()
      case 3:
        return .corners(radius: .fixed(min(CGFloat(kind.top_left) * shorter, limit)))
      case 7:
        return .corners(radius: .fixed(min(CGFloat(kind.top_left), limit)))
      case 4, 8:
        let scale: CGFloat = kind.tag == 4 ? shorter : 1
        return .corners(
          topLeftRadius: .fixed(min(CGFloat(kind.top_left) * scale, limit)),
          topRightRadius: .fixed(min(CGFloat(kind.top_right) * scale, limit)),
          bottomLeftRadius: .fixed(min(CGFloat(kind.bottom_left) * scale, limit)),
          bottomRightRadius: .fixed(min(CGFloat(kind.bottom_right) * scale, limit))
        )
      case 2, 6:
        fatalError(
          "WaterUI glass takes its outline from a corner configuration; shape kind \(kind.tag) "
            + "(ellipse or custom path) cannot be a glass outline")
      default:
        fatalError("unknown WaterUI shape kind tag \(kind.tag)")
      }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      effectView.cornerConfiguration = Self.cornerConfiguration(for: shape, in: bounds)
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    private static func nsStyle(from style: WuiGlassStyle) -> NSGlassEffectView.Style {
      switch style {
      case WuiGlassStyle_Regular:
        return .regular
      case WuiGlassStyle_Clear:
        return .clear
      default:
        fatalError("Unsupported WaterUI glass style: \(style.rawValue)")
      }
    }

    /// The outline as the glass view's uniform corner radius.
    ///
    /// `NSGlassEffectView` draws one radius for all four corners: a capsule
    /// and a circle are half the shorter side, uniform radii resolve against
    /// the bounds. Per-corner radii, an ellipse, or a custom path cannot be a
    /// glass outline on macOS.
    private static func cornerRadius(for kind: WuiShapeKind, in bounds: CGRect) -> CGFloat {
      let shorter = min(bounds.width, bounds.height)
      let limit = shorter / 2
      switch kind.tag {
      case 0:
        return 0
      case 1, 5:
        return limit
      case 3:
        return min(CGFloat(kind.top_left) * shorter, limit)
      case 7:
        return min(CGFloat(kind.top_left), limit)
      case 2, 4, 6, 8:
        fatalError(
          "WaterUI glass on macOS takes one corner radius; shape kind \(kind.tag) "
            + "(ellipse, per-corner radii, or custom path) cannot be a glass outline")
      default:
        fatalError("unknown WaterUI shape kind tag \(kind.tag)")
      }
    }

    override func layout() {
      super.layout()
      effectView.cornerRadius = Self.cornerRadius(for: shape, in: bounds)
    }
  #endif
}
