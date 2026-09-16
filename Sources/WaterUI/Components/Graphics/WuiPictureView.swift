import CWaterUI
import CoreGraphics
import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// A `Picture`: a recorded drawing rasterised once at the display's scale and
/// shown by the platform image view, so a static icon costs no Metal layer.
@MainActor
final class WuiPictureView: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_picture_id() }

  #if canImport(UIKit)
    private let imageView = UIImageView()
  #elseif canImport(AppKit)
    private let imageView = NSImageView()
  #endif

  private let picture: OpaquePointer
  private let pointSize: CGSize
  private var bitmaps: WuiComputed<WuiBitmap>?
  private var bitmapGuard: WatcherGuard?
  private var rasterScale: CGFloat = 0

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffi = waterui_force_as_picture(anyview)
    guard let handle = ffi.picture else {
      fatalError("waterui_force_as_picture returned a null picture")
    }
    self.init(
      picture: handle,
      pointSize: CGSize(width: CGFloat(ffi.width), height: CGFloat(ffi.height)),
      label: WuiStr(ffi.label).toString(),
      value: WuiStr(ffi.value).toString()
    )
  }

  /// `label` is the name the drawing offers a screen reader and `value` the
  /// semantic content it offers beside the name, each empty when it offers
  /// none; an application's own label or value is applied by the metadata view
  /// above this one and replaces it.
  init(picture: OpaquePointer, pointSize: CGSize, label: String, value: String) {
    self.picture = picture
    self.pointSize = pointSize
    super.init(frame: .zero)
    #if canImport(UIKit)
      registerForTraitChanges([UITraitDisplayScale.self]) {
        (view: WuiPictureView, _: UITraitCollection) in
        view.rasterize(at: view.traitCollection.displayScale)
      }
    #endif
    configureImageView()
    if !label.isEmpty || !value.isEmpty {
      #if canImport(UIKit)
        isAccessibilityElement = true
        if !label.isEmpty {
          accessibilityLabel = label
          accessibilityTraits.insert(.image)
        }
        if !value.isEmpty {
          accessibilityValue = value
        }
      #elseif canImport(AppKit)
        setAccessibilityElement(true)
        if !label.isEmpty {
          setAccessibilityLabel(label)
          setAccessibilityRole(.image)
        }
        if !value.isEmpty {
          setAccessibilityValue(value)
        }
      #endif
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @MainActor deinit {
    bitmapGuard = nil
    bitmaps = nil
    waterui_drop_picture(picture)
  }

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
      wantsLayer = true
      imageView.imageScaling = .scaleProportionallyUpOrDown
    #endif
  }

  #if canImport(UIKit)
    override func didMoveToWindow() {
      super.didMoveToWindow()
      rasterize(at: traitCollection.displayScale)
    }

  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      rasterize(at: window?.backingScaleFactor ?? 0)
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      rasterize(at: window?.backingScaleFactor ?? 0)
    }
  #endif

  /// Asks the picture for a bitmap signal at `scale` and follows it. A window
  /// that has not reported a scale yet is skipped; the move into one calls
  /// back here.
  private func rasterize(at scale: CGFloat) {
    guard scale > 0, scale != rasterScale else { return }
    rasterScale = scale
    guard let computed = waterui_picture_bitmap(picture, Float(scale)) else {
      fatalError("waterui_picture_bitmap returned a null signal")
    }
    let bitmaps = WuiComputed<WuiBitmap>(computed)
    bitmapGuard = bitmaps.watch { [weak self] bitmap, _ in
      self?.show(bitmap)
    }
    self.bitmaps = bitmaps
    show(bitmaps.value)
  }

  private func show(_ bitmap: WuiBitmap) {
    defer { waterui_drop_bitmap(bitmap) }
    imageView.image = Self.makeImage(bitmap, scale: rasterScale, pointSize: pointSize)
    invalidateCapturedRendering()
  }

  private static func makeImage(_ bitmap: WuiBitmap, scale: CGFloat, pointSize: CGSize)
    -> PlatformImage
  {
    let width = Int(bitmap.width)
    let height = Int(bitmap.height)
    guard let data = bitmap.data else {
      fatalError("picture bitmap has no pixels")
    }
    let bytes = Data(bytes: data, count: Int(bitmap.len))
    let bitmapInfo = CGBitmapInfo(
      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    )
    guard
      let provider = CGDataProvider(data: bytes as CFData),
      let cgImage = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      )
    else {
      fatalError("picture bitmap \(width)x\(height) could not become a CGImage")
    }
    #if canImport(UIKit)
      return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    #elseif canImport(AppKit)
      return NSImage(cgImage: cgImage, size: pointSize)
    #endif
  }

  /// A picture keeps its aspect ratio: one proposed side scales the other,
  /// no proposal means its own size, and two proposed sides are the layout's
  /// decision.
  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    switch (proposal.width, proposal.height) {
    case (nil, nil):
      return pointSize
    case let (width?, height?):
      return CGSize(width: CGFloat(width), height: CGFloat(height))
    case let (width?, nil):
      let width = CGFloat(width)
      guard width.isFinite else { return pointSize }
      return CGSize(width: width, height: width * pointSize.height / pointSize.width)
    case let (nil, height?):
      let height = CGFloat(height)
      guard height.isFinite else { return pointSize }
      return CGSize(width: height * pointSize.width / pointSize.height, height: height)
    }
  }
}
