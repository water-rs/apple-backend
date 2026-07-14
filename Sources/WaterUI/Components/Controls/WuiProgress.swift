import CWaterUI
import QuartzCore

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
private protocol WuiProgressGeometry {
  static var intrinsicSize: CGSize { get }
  static var lineWidth: CGFloat { get }
  static var indeterminateStrokeEnd: CGFloat { get }
  static var hidesTrackWhenIndeterminate: Bool { get }

  static func path(in bounds: CGRect) -> CGPath
  static func makeIndeterminateAnimation() -> CAAnimation
}

private struct WuiCircularProgressGeometry: WuiProgressGeometry {
  static let intrinsicSize = CGSize(width: 20, height: 20)
  static let lineWidth: CGFloat = 3
  static let indeterminateStrokeEnd: CGFloat = 0.28
  static let hidesTrackWhenIndeterminate = true

  static func path(in bounds: CGRect) -> CGPath {
    CGPath(
      ellipseIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
      transform: nil
    )
  }

  static func makeIndeterminateAnimation() -> CAAnimation {
    let animation = CABasicAnimation(keyPath: "transform.rotation.z")
    animation.fromValue = 0
    animation.toValue = Double.pi * 2
    animation.duration = 0.9
    animation.repeatCount = .infinity
    return animation
  }
}

private struct WuiLinearProgressGeometry: WuiProgressGeometry {
  static let intrinsicSize = CGSize(width: 100, height: 4)
  static let lineWidth: CGFloat = 4
  static let indeterminateStrokeEnd: CGFloat = 0.25
  static let hidesTrackWhenIndeterminate = false

  static func path(in bounds: CGRect) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: lineWidth / 2, y: bounds.midY))
    path.addLine(to: CGPoint(x: bounds.width - lineWidth / 2, y: bounds.midY))
    return path
  }

  static func makeIndeterminateAnimation() -> CAAnimation {
    let start = CAKeyframeAnimation(keyPath: "strokeStart")
    start.values = [0, 0, 0.75, 1]
    start.keyTimes = [0, 0.2, 0.8, 1]

    let end = CAKeyframeAnimation(keyPath: "strokeEnd")
    end.values = [0.25, 0.25, 1, 1]
    end.keyTimes = [0, 0.2, 0.8, 1]

    let animation = CAAnimationGroup()
    animation.animations = [start, end]
    animation.duration = 1.4
    animation.repeatCount = .infinity
    return animation
  }
}

@MainActor
private final class WuiLayerProgressView<Geometry: WuiProgressGeometry>: PlatformView {
  private let trackLayer = CAShapeLayer()
  private let fillLayer = CAShapeLayer()
  private var isIndeterminate = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    #if canImport(AppKit)
      wantsLayer = true
      guard let layer else {
        fatalError("AppKit failed to create a layer for circular progress")
      }
    #elseif canImport(UIKit)
      let layer = layer
    #endif
    for progressLayer in [trackLayer, fillLayer] {
      progressLayer.fillColor = nil
      progressLayer.lineWidth = Geometry.lineWidth
      progressLayer.lineCap = .round
      layer.addSublayer(progressLayer)
    }
    trackLayer.strokeEnd = 1
    fillLayer.strokeEnd = 0
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    Geometry.intrinsicSize
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      layoutProgressLayers()
    }
  #elseif canImport(AppKit)
    override func layout() {
      super.layout()
      layoutProgressLayers()
    }
  #endif

  func setColors(track: PlatformColor, fill: PlatformColor) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trackLayer.strokeColor = track.cgColor
    fillLayer.strokeColor = fill.cgColor
    CATransaction.commit()
  }

  func setProgress(_ value: Double, metadata: WuiWatcherMetadata?) {
    setIndeterminate(false)
    let previous = fillLayer.presentation()?.strokeEnd ?? fillLayer.strokeEnd
    let target = CGFloat(value)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fillLayer.strokeEnd = target
    CATransaction.commit()

    guard let metadata else {
      fillLayer.removeAnimation(forKey: "progress")
      return
    }
    switch parseAnimation(metadata.getAnimation()) {
    case .none:
      fillLayer.removeAnimation(forKey: "progress")
    case .bezier(let duration, let x1, let y1, let x2, let y2):
      let animation = CABasicAnimation(keyPath: "strokeEnd")
      animation.fromValue = previous
      animation.toValue = target
      animation.duration = duration
      animation.timingFunction = CAMediaTimingFunction(
        controlPoints: Float(x1), Float(y1), Float(x2), Float(y2)
      )
      fillLayer.add(animation, forKey: "progress")
    case .spring(let stiffness, let damping):
      let animation = CASpringAnimation(keyPath: "strokeEnd")
      animation.fromValue = previous
      animation.toValue = target
      animation.mass = 1
      animation.stiffness = Double(stiffness)
      animation.damping = Double(damping)
      animation.initialVelocity = 0
      animation.duration = animation.settlingDuration
      fillLayer.add(animation, forKey: "progress")
    }
  }

  func setIndeterminate(_ indeterminate: Bool) {
    guard indeterminate != isIndeterminate else { return }
    isIndeterminate = indeterminate
    fillLayer.removeAnimation(forKey: "progress")
    fillLayer.removeAnimation(forKey: "indeterminate")

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trackLayer.isHidden = indeterminate && Geometry.hidesTrackWhenIndeterminate
    fillLayer.strokeStart = 0
    fillLayer.strokeEnd = indeterminate ? Geometry.indeterminateStrokeEnd : 0
    CATransaction.commit()

    if indeterminate {
      fillLayer.add(Geometry.makeIndeterminateAnimation(), forKey: "indeterminate")
    }
  }

  private func layoutProgressLayers() {
    let layerBounds = bounds
    let path = Geometry.path(in: layerBounds)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for progressLayer in [trackLayer, fillLayer] {
      progressLayer.frame = layerBounds
      progressLayer.path = path
    }
    CATransaction.commit()
  }
}

@MainActor
private struct WuiProgressAdditionalPaletteObservations {
  let accentContainer: WuiComputedObservation<WuiResolvedColor>
  let tertiary: WuiComputedObservation<WuiResolvedColor>
  let tertiaryContainer: WuiComputedObservation<WuiResolvedColor>

  var colors: [PlatformColor] {
    [
      wuiProgressPlatformColor(accentContainer.value),
      wuiProgressPlatformColor(tertiary.value),
      wuiProgressPlatformColor(tertiaryContainer.value),
    ]
  }
}

@MainActor
final class WuiProgress: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_progress_id() }

  private(set) var stretchAxis: WuiStretchAxis
  private let labelView: WuiAnyView
  private let valueLabelView: WuiAnyView
  private let style: WuiProgressStyle
  private let fourColor: Bool
  private let circularProgress = WuiLayerProgressView<WuiCircularProgressGeometry>()
  private var valueObservation: WuiComputedObservation<Double>?
  private var accentObservation: WuiComputedObservation<WuiResolvedColor>?
  private var additionalPaletteObservations: WuiProgressAdditionalPaletteObservations?
  private var borderObservation: WuiComputedObservation<WuiResolvedColor>?
  private var indicatorPalette: [PlatformColor] = []
  private var trackColor: PlatformColor?
  private var tintIndex = 0
  private var tintCycleTask: Task<Void, Never>?
  private let verticalSpacing: CGFloat = 6

  #if canImport(UIKit)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
  #elseif canImport(AppKit)
    private let linearProgress = WuiLayerProgressView<WuiLinearProgressGeometry>()
  #endif

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
    let progress = waterui_force_as_progress(anyview)
    self.init(
      stretchAxis: stretchAxis,
      label: WuiAnyView(anyview: progress.label, env: env),
      valueLabel: WuiAnyView(anyview: progress.value_label, env: env),
      value: WuiComputed<Double>(progress.value),
      style: progress.style,
      fourColor: progress.four_color,
      env: env
    )
  }

  private init(
    stretchAxis: WuiStretchAxis,
    label: WuiAnyView,
    valueLabel: WuiAnyView,
    value: WuiComputed<Double>,
    style: WuiProgressStyle,
    fourColor: Bool,
    env: WuiEnvironment
  ) {
    self.stretchAxis = stretchAxis
    self.labelView = label
    self.valueLabelView = valueLabel
    self.style = style
    self.fourColor = fourColor
    super.init(frame: .zero)

    configureSubviews()
    installThemeObservers(env: env)
    let observation = WuiComputedObservation(value) { [weak self] value, metadata in
      self?.applyValue(value, metadata: metadata)
    }
    valueObservation = observation
    applyValue(observation.value, metadata: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @MainActor deinit {
    tintCycleTask?.cancel()
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    let value = currentValue
    let labelSize = labelView.sizeThatFits(WuiProposalSize(width: proposal.width))
    let valueLabelSize =
      value.isFinite
      ? valueLabelView.sizeThatFits(WuiProposalSize(width: proposal.width)) : .zero
    let controlSize = progressControlSize
    let labelSpacing = labelSize.height > 0 ? verticalSpacing : 0
    let valueSpacing = valueLabelSize.height > 0 ? verticalSpacing : 0
    let intrinsicWidth = max(controlSize.width, max(labelSize.width, valueLabelSize.width))
    let intrinsicHeight =
      labelSize.height + labelSpacing + controlSize.height + valueSpacing + valueLabelSize.height
    let width =
      style == WuiProgressStyle_Linear
      ? proposal.width.map { max(CGFloat($0), max(50, intrinsicWidth)) }
        ?? max(50, intrinsicWidth)
      : intrinsicWidth
    return CGSize(width: width, height: intrinsicHeight)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      performLayout()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      updateTintCycleState()
    }
  #elseif canImport(AppKit)
    override func layout() {
      super.layout()
      performLayout()
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      updateTintCycleState()
    }
  #endif

  private var currentValue: Double {
    guard let valueObservation else {
      fatalError("Progress value was read before its observation was installed")
    }
    return valueObservation.value
  }

  private var progressControlSize: CGSize {
    if style == WuiProgressStyle_Circular {
      return circularProgress.intrinsicContentSize
    }
    #if canImport(UIKit)
      return progressView.intrinsicContentSize
    #elseif canImport(AppKit)
      return linearProgress.intrinsicContentSize
    #endif
  }

  private func configureSubviews() {
    addSubview(labelView)
    addSubview(valueLabelView)
    addSubview(circularProgress)
    #if canImport(UIKit)
      activityIndicator.hidesWhenStopped = true
      addSubview(progressView)
      addSubview(activityIndicator)
    #elseif canImport(AppKit)
      addSubview(linearProgress)
    #endif
  }

  private func installThemeObservers(env: WuiEnvironment) {
    func observePaletteColor(
      _ slot: WuiColorSlot
    ) -> WuiComputedObservation<WuiResolvedColor> {
      WuiComputedObservation(themeColor: slot, env: env) { [weak self] _, _ in
        self?.applyPalette()
      }
    }

    accentObservation = observePaletteColor(WuiColorSlot_Accent)
    if fourColor {
      additionalPaletteObservations = WuiProgressAdditionalPaletteObservations(
        accentContainer: observePaletteColor(WuiColorSlot_AccentContainer),
        tertiary: observePaletteColor(WuiColorSlot_Tertiary),
        tertiaryContainer: observePaletteColor(WuiColorSlot_TertiaryContainer)
      )
    }
    applyPalette()

    let border = WuiComputedObservation(
      themeColor: WuiColorSlot_Border,
      env: env
    ) { [weak self] border, _ in
      self?.applyTrackColor(border)
    }
    borderObservation = border
    applyTrackColor(border.value)
  }

  private func applyPalette() {
    guard let accentObservation else { return }
    let accent = wuiProgressPlatformColor(accentObservation.value)
    if fourColor {
      guard let additionalPaletteObservations else { return }
      indicatorPalette = [accent] + additionalPaletteObservations.colors
    } else {
      indicatorPalette = [accent]
    }
    tintIndex %= indicatorPalette.count
    applyCurrentTint(animated: false)
  }

  private func applyTrackColor(_ border: WuiResolvedColor) {
    let color = wuiProgressPlatformColor(border)
    trackColor = color
    #if canImport(UIKit)
      progressView.trackTintColor = color
    #endif
    applyLayerProgressColors()
  }

  private func applyCurrentTint(animated: Bool) {
    guard !indicatorPalette.isEmpty else {
      fatalError("Progress indicator palette must not be empty")
    }
    let color = indicatorPalette[tintIndex]
    let apply = {
      #if canImport(UIKit)
        self.progressView.progressTintColor = color
        self.activityIndicator.color = color
      #endif
      self.applyLayerProgressColors()
    }
    guard animated else {
      apply()
      return
    }
    #if canImport(UIKit)
      UIView.animate(
        withDuration: 0.3,
        delay: 0,
        options: [.allowUserInteraction, .beginFromCurrentState],
        animations: apply
      )
    #elseif canImport(AppKit)
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.3
        context.allowsImplicitAnimation = true
        apply()
      }
    #endif
  }

  private func applyLayerProgressColors() {
    guard let trackColor, !indicatorPalette.isEmpty else { return }
    let tint = indicatorPalette[tintIndex]
    circularProgress.setColors(track: trackColor, fill: tint)
    #if canImport(AppKit)
      linearProgress.setColors(track: trackColor, fill: tint)
    #endif
  }

  private func applyValue(_ value: Double, metadata: WuiWatcherMetadata?) {
    guard value == .infinity || (value.isFinite && (0...1).contains(value)) else {
      fatalError("Progress value must be finite within 0...1 or positive infinity")
    }
    let isIndeterminate = value == .infinity

    #if canImport(UIKit)
      if style == WuiProgressStyle_Circular {
        progressView.isHidden = true
        if isIndeterminate {
          circularProgress.isHidden = true
          activityIndicator.isHidden = false
          activityIndicator.startAnimating()
        } else {
          activityIndicator.stopAnimating()
          circularProgress.isHidden = false
          circularProgress.setProgress(value, metadata: metadata)
        }
      } else {
        circularProgress.isHidden = true
        if isIndeterminate {
          progressView.isHidden = true
          activityIndicator.isHidden = false
          activityIndicator.startAnimating()
        } else {
          activityIndicator.stopAnimating()
          progressView.isHidden = false
          progressView.setProgress(
            Float(value),
            animated: metadata.map {
              shouldAnimate(parseAnimation($0.getAnimation()))
            } ?? false)
        }
      }
    #elseif canImport(AppKit)
      if style == WuiProgressStyle_Circular {
        linearProgress.isHidden = true
        circularProgress.isHidden = false
        if isIndeterminate {
          circularProgress.setIndeterminate(true)
        } else {
          circularProgress.setProgress(value, metadata: metadata)
        }
      } else {
        circularProgress.isHidden = true
        linearProgress.isHidden = false
        if isIndeterminate {
          linearProgress.setIndeterminate(true)
        } else {
          linearProgress.setProgress(value, metadata: metadata)
        }
      }
    #endif

    valueLabelView.isHidden = isIndeterminate
    invalidateLayoutHierarchy()
    updateTintCycleState()
  }

  private func performLayout() {
    let width = bounds.width
    let labelSize = labelView.sizeThatFits(WuiProposalSize(width: Float(width)))
    let valueLabelSize =
      currentValue.isFinite
      ? valueLabelView.sizeThatFits(WuiProposalSize(width: Float(width))) : .zero
    let controlSize = progressControlSize
    var y: CGFloat = 0

    labelView.frame = CGRect(
      x: 0, y: y, width: min(width, labelSize.width), height: labelSize.height)
    y += labelSize.height
    if labelSize.height > 0 { y += verticalSpacing }

    let controlFrame = CGRect(
      x: style == WuiProgressStyle_Circular ? (width - controlSize.width) / 2 : 0,
      y: y,
      width: style == WuiProgressStyle_Circular ? controlSize.width : width,
      height: controlSize.height
    )
    circularProgress.frame = controlFrame
    #if canImport(UIKit)
      progressView.frame = controlFrame
      activityIndicator.frame = controlFrame
    #elseif canImport(AppKit)
      linearProgress.frame = controlFrame
    #endif
    y += controlSize.height

    if valueLabelSize.height > 0 {
      y += verticalSpacing
      valueLabelView.frame = CGRect(
        x: 0,
        y: y,
        width: min(width, valueLabelSize.width),
        height: valueLabelSize.height
      )
    } else {
      valueLabelView.frame = .zero
    }
  }

  private func updateTintCycleState() {
    let shouldCycle = fourColor && valueObservation?.value == .infinity && window != nil
    if shouldCycle {
      guard tintCycleTask == nil else { return }
      let stepDuration = Duration.seconds(1)
      tintCycleTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: stepDuration)
          } catch is CancellationError {
            return
          } catch {
            fatalError("Progress tint animation failed: \(error)")
          }
          guard let self else { return }
          tintIndex = (tintIndex + 1) % indicatorPalette.count
          applyCurrentTint(animated: true)
        }
      }
    } else {
      tintCycleTask?.cancel()
      tintCycleTask = nil
      tintIndex = 0
      if !indicatorPalette.isEmpty {
        applyCurrentTint(animated: false)
      }
    }
  }
}

private func wuiProgressPlatformColor(_ color: WuiResolvedColor) -> PlatformColor {
  #if canImport(UIKit)
    color.toUIColor(allowHdr: false)
  #elseif canImport(AppKit)
    color.toNSColor(allowHdr: false)
  #endif
}
