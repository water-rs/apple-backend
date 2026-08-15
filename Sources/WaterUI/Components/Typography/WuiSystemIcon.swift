// WuiSystemIcon.swift
// SystemIcon component - renders SF Symbols on Apple platforms
//
// # Layout Behavior
// SystemIcon is content-sized, using the intrinsic size of the symbol.
// The default size is based on system font body size.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .none (content-sized, does not expand)
// // - sizeThatFits: Returns intrinsic size based on symbol
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiSystemIcon: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_system_icon_id() }

  #if canImport(UIKit)
    private let imageView = UIImageView()
  #elseif canImport(AppKit)
    private let imageView = NSImageView()
  #endif

  private let iconName: String
  private var foregroundObservation: WuiComputedObservation<WuiResolvedColor>?
  private var bodyFontObservation: WuiComputedObservation<WuiResolvedFontValue>?

  // MARK: - WuiComponent Init

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffiIcon: CWaterUI.WuiSystemIcon = waterui_force_as_system_icon(anyview)
    let name = WuiStr(ffiIcon.name).toString()
    self.init(name: name, env: env)
  }

  // MARK: - Designated Init

  init(name: String, env: WuiEnvironment) {
    self.iconName = name
    super.init(frame: .zero)
    configureImageView()
    loadSymbol()
    foregroundObservation = WuiComputedObservation(
      themeColor: WuiColorSlot_Foreground,
      env: env
    ) { [weak self] color, _ in
      self?.applyForeground(color)
    }
    if let color = foregroundObservation?.value {
      applyForeground(color)
    }
    // SwiftUI's Image(systemName:) scales with the environment font; the
    // glyph must track the themed body font instead of freezing at the
    // symbol's default point size.
    bodyFontObservation = .bodyFont(env: env) { [weak self] font in
      self?.applySymbolFont(font)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Configuration

  private func configureImageView() {
    imageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    #if canImport(UIKit)
      imageView.contentMode = .scaleAspectFit
    #elseif canImport(AppKit)
      imageView.imageScaling = .scaleProportionallyUpOrDown
    #endif
  }

  private func loadSymbol() {
    #if canImport(UIKit)
      guard let image = UIImage(systemName: iconName) else {
        fatalError("Unknown SF Symbol name: \(iconName)")
      }
      imageView.image = image
    #elseif canImport(AppKit)
      guard let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) else {
        fatalError("Unknown SF Symbol name: \(iconName)")
      }
      imageView.image = image
    #endif
  }

  private func applySymbolFont(_ font: WuiResolvedFontValue) {
    #if canImport(UIKit)
      imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
        font: font.toPlatformFont()
      )
    #elseif canImport(AppKit)
      let size = CGFloat(font.size)
      let configuration = NSImage.SymbolConfiguration(
        pointSize: size,
        weight: font.weight.toNSFontWeight()
      )
      guard
        let base = NSImage(systemSymbolName: iconName, accessibilityDescription: nil),
        let sized = base.withSymbolConfiguration(configuration)
      else {
        fatalError("SF Symbol \(iconName) rejected the themed font configuration")
      }
      imageView.image = sized
    #endif
    invalidateLayoutHierarchy()
  }

  private func applyForeground(_ color: WuiResolvedColor) {
    #if canImport(UIKit)
      imageView.tintColor = color.toUIColor()
    #elseif canImport(AppKit)
      imageView.contentTintColor = color.toNSColor()
    #endif
    invalidateCapturedRendering()
  }

  // MARK: - WuiComponent

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    // Default size for SF Symbols is roughly 17pt (body text size)
    // We use intrinsic content size if available
    #if canImport(UIKit)
      let intrinsic = imageView.intrinsicContentSize
      if intrinsic.width > 0 && intrinsic.height > 0 {
        return intrinsic
      }
      fatalError("SF Symbol \(iconName) has no intrinsic size")
    #elseif canImport(AppKit)
      if let image = imageView.image {
        return image.size
      }
      fatalError("SF Symbol \(iconName) has no intrinsic size")
    #endif
  }

  #if canImport(AppKit)
    override var isFlipped: Bool { true }
  #endif
}
