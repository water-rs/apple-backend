// WuiColorPicker.swift
// ColorPicker component with HDR support - merged UIKit and AppKit implementation
//
// # Layout Behavior
// ColorPicker sizes itself to fit its content and never stretches to fill extra space.
// In a stack, it takes only the space it needs.

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

#if canImport(UIKit)
  @MainActor
  final class WuiColorPicker: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_color_picker_id() }

    private let colorWell: UIColorWell
    private let labelView: WuiAnyView
    private let binding: WuiBinding<OpaquePointer>
    private var bindingWatcher: WatcherGuard?
    private var resolvedColorObservation: WuiComputedObservation<WuiResolvedColor>?
    private let env: WuiEnvironment
    private let supportAlpha: Bool
    private let supportHdr: Bool
    private var isSyncingFromBinding = false
    private var accessibility: WuiControlAccessibility?

    private let spacing: CGFloat = 8.0

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
      let ffiColorPicker: CWaterUI.WuiColorPicker = waterui_force_as_color_picker(anyview)
      let labelView = WuiAnyView(anyview: ffiColorPicker.label.view, env: env)
      let binding = WuiBinding<OpaquePointer>.color(ffiColorPicker.value)
      let supportAlpha = ffiColorPicker.support_alpha
      let supportHdr = ffiColorPicker.support_hdr
      self.init(
        label: labelView,
        binding: binding,
        env: env,
        supportAlpha: supportAlpha,
        supportHdr: supportHdr,
        semanticLabel: ffiColorPicker.label
      )
    }

    // MARK: - Designated Init

    init(
      label: WuiAnyView,
      binding: WuiBinding<OpaquePointer>,
      env: WuiEnvironment,
      supportAlpha: Bool,
      supportHdr: Bool,
      semanticLabel: CWaterUI.WuiLabel
    ) {
      self.labelView = label
      self.binding = binding
      self.env = env
      self.supportAlpha = supportAlpha
      self.supportHdr = supportHdr
      self.colorWell = UIColorWell()
      super.init(frame: .zero)
      configureSubviews()
      startBindingWatcher()
      configureColorWell()
      accessibility = WuiControlAccessibility(
        consuming: semanticLabel,
        target: colorWell,
        visualLabel: label
      )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
      let labelSize = labelView.sizeThatFits(WuiProposalSize())
      let wellSize = colorWell.intrinsicContentSize
      let hasLabel = labelSize.width > 0 && labelSize.height > 0

      var totalWidth: CGFloat = wellSize.width
      var maxHeight: CGFloat = wellSize.height

      if hasLabel {
        totalWidth += spacing + labelSize.width
        maxHeight = max(maxHeight, labelSize.height)
      }

      return CGSize(width: totalWidth, height: maxHeight)
    }

    // MARK: - Configuration

    private func configureSubviews() {
      labelView.translatesAutoresizingMaskIntoConstraints = false
      colorWell.translatesAutoresizingMaskIntoConstraints = false

      addSubview(labelView)
      addSubview(colorWell)

      labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
      labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

      NSLayoutConstraint.activate([
        labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
        labelView.centerYAnchor.constraint(equalTo: centerYAnchor),

        colorWell.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: spacing),
        colorWell.trailingAnchor.constraint(equalTo: trailingAnchor),
        colorWell.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }

    private func configureColorWell() {
      colorWell.supportsAlpha = supportAlpha

      observeColor(binding.value)

      colorWell.addTarget(self, action: #selector(colorChanged), for: .valueChanged)
    }

    private func startBindingWatcher() {
      bindingWatcher = binding.watch { [weak self] colorPtr, _ in
        self?.observeColor(colorPtr)
      }
    }

    @objc private func colorChanged() {
      guard !isSyncingFromBinding, let selectedColor = colorWell.selectedColor else { return }
      updateBindingWithColor(selectedColor)
    }

    // MARK: - Color Conversion

    private func observeColor(_ colorPtr: OpaquePointer) {
      guard let resolvedPtr = waterui_resolve_color(colorPtr, env.inner) else {
        fatalError("Failed to resolve ColorPicker color")
      }
      let observation = WuiComputedObservation(WuiComputed<WuiResolvedColor>(resolvedPtr)) {
        [weak self] resolved, _ in
        self?.applyResolvedColor(resolved)
      }
      resolvedColorObservation = observation
      applyResolvedColor(observation.value)
    }

    private func applyResolvedColor(_ resolved: WuiResolvedColor) {
      isSyncingFromBinding = true
      colorWell.selectedColor = resolvedColorToUIColor(resolved)
      isSyncingFromBinding = false
    }

    private func resolvedColorToUIColor(_ resolved: WuiResolvedColor) -> UIColor {
      resolved.toUIColor(allowHdr: supportHdr)
    }

    private func updateBindingWithColor(_ color: UIColor) {
      var r: CGFloat = 0
      var g: CGFloat = 0
      var b: CGFloat = 0
      var a: CGFloat = 0
      var headroom: Float = 0.0
      var baseColor = color
      if supportHdr {
        let exposure = Float(color.linearExposure)
        if exposure > 1.0 {
          baseColor = color.standardDynamicRange
          headroom = max(0.0, exposure - 1.0)
        }
      }
      guard baseColor.getRed(&r, green: &g, blue: &b, alpha: &a) else {
        fatalError("UIColorWell returned a color that cannot convert to extended sRGB")
      }

      let linearR = wuiSrgbToLinear(Float(r))
      let linearG = wuiSrgbToLinear(Float(g))
      let linearB = wuiSrgbToLinear(Float(b))
      guard
        let colorPtr = waterui_color_from_linear_rgba_headroom(
          linearR,
          linearG,
          linearB,
          Float(a),
          headroom
        )
      else {
        fatalError("waterui_color_from_linear_rgba_headroom returned null")
      }
      binding.set(colorPtr)
    }
  }

#elseif canImport(AppKit)
  @MainActor
  final class WuiColorPicker: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_color_picker_id() }

    private let colorWell: NSColorWell
    private let labelView: WuiAnyView
    private let binding: WuiBinding<OpaquePointer>
    private var bindingWatcher: WatcherGuard?
    private var resolvedColorObservation: WuiComputedObservation<WuiResolvedColor>?
    private let env: WuiEnvironment
    private let supportAlpha: Bool
    private let supportHdr: Bool
    private var isSyncingFromBinding = false
    private var accessibility: WuiControlAccessibility?

    private let spacing: CGFloat = 8.0

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
      let ffiColorPicker: CWaterUI.WuiColorPicker = waterui_force_as_color_picker(anyview)
      let labelView = WuiAnyView(anyview: ffiColorPicker.label.view, env: env)
      let binding = WuiBinding<OpaquePointer>.color(ffiColorPicker.value)
      let supportAlpha = ffiColorPicker.support_alpha
      let supportHdr = ffiColorPicker.support_hdr
      self.init(
        label: labelView,
        binding: binding,
        env: env,
        supportAlpha: supportAlpha,
        supportHdr: supportHdr,
        semanticLabel: ffiColorPicker.label
      )
    }

    // MARK: - Designated Init

    init(
      label: WuiAnyView,
      binding: WuiBinding<OpaquePointer>,
      env: WuiEnvironment,
      supportAlpha: Bool,
      supportHdr: Bool,
      semanticLabel: CWaterUI.WuiLabel
    ) {
      self.labelView = label
      self.binding = binding
      self.env = env
      self.supportAlpha = supportAlpha
      self.supportHdr = supportHdr
      self.colorWell = NSColorWell()
      super.init(frame: .zero)
      configureSubviews()
      startBindingWatcher()
      configureColorWell()
      accessibility = WuiControlAccessibility(
        consuming: semanticLabel,
        target: colorWell,
        visualLabel: label
      )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
      let labelSize = labelView.sizeThatFits(WuiProposalSize())
      let wellSize = colorWell.intrinsicContentSize
      let hasLabel = labelSize.width > 0 && labelSize.height > 0

      var totalWidth: CGFloat = wellSize.width
      var maxHeight: CGFloat = wellSize.height

      if hasLabel {
        totalWidth += spacing + labelSize.width
        maxHeight = max(maxHeight, labelSize.height)
      }

      return CGSize(width: totalWidth, height: maxHeight)
    }

    // MARK: - Configuration

    private func configureSubviews() {
      labelView.translatesAutoresizingMaskIntoConstraints = false
      colorWell.translatesAutoresizingMaskIntoConstraints = false

      addSubview(labelView)
      addSubview(colorWell)

      labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
      labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

      NSLayoutConstraint.activate([
        labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
        labelView.centerYAnchor.constraint(equalTo: centerYAnchor),

        colorWell.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: spacing),
        colorWell.trailingAnchor.constraint(equalTo: trailingAnchor),
        colorWell.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }

    private func configureColorWell() {
      observeColor(binding.value)

      // Configure color panel for alpha/HDR if needed
      if supportAlpha {
        NSColorPanel.shared.showsAlpha = true
      }

      colorWell.target = self
      colorWell.action = #selector(colorChanged)
    }

    private func startBindingWatcher() {
      bindingWatcher = binding.watch { [weak self] colorPtr, _ in
        self?.observeColor(colorPtr)
      }
    }

    @objc private func colorChanged() {
      guard !isSyncingFromBinding else { return }
      let selectedColor = colorWell.color
      updateBindingWithColor(selectedColor)
    }

    // MARK: - Color Conversion

    private func observeColor(_ colorPtr: OpaquePointer) {
      guard let resolvedPtr = waterui_resolve_color(colorPtr, env.inner) else {
        fatalError("Failed to resolve ColorPicker color")
      }
      let observation = WuiComputedObservation(WuiComputed<WuiResolvedColor>(resolvedPtr)) {
        [weak self] resolved, _ in
        self?.applyResolvedColor(resolved)
      }
      resolvedColorObservation = observation
      applyResolvedColor(observation.value)
    }

    private func applyResolvedColor(_ resolved: WuiResolvedColor) {
      isSyncingFromBinding = true
      colorWell.color = resolvedColorToNSColor(resolved)
      isSyncingFromBinding = false
    }

    private func resolvedColorToNSColor(_ resolved: WuiResolvedColor) -> NSColor {
      resolved.toNSColor(allowHdr: supportHdr)
    }

    private func updateBindingWithColor(_ color: NSColor) {
      var headroom: Float = 0.0
      var baseColor = color
      if supportHdr {
        let exposure = color.linearExposure
        if exposure > 1.0 {
          headroom = Float(exposure - 1.0)
          baseColor = color.standardDynamicRange
        }
      }

      let rgbColor = baseColor.usingColorSpace(.extendedSRGB) ?? baseColor.usingColorSpace(.sRGB)
      guard let rgbColor else {
        fatalError("NSColorWell returned a color that cannot convert to extended sRGB")
      }

      let r = Float(rgbColor.redComponent)
      let g = Float(rgbColor.greenComponent)
      let b = Float(rgbColor.blueComponent)
      let a = Float(rgbColor.alphaComponent)
      let linearR = wuiSrgbToLinear(r)
      let linearG = wuiSrgbToLinear(g)
      let linearB = wuiSrgbToLinear(b)
      guard
        let colorPtr = waterui_color_from_linear_rgba_headroom(
          linearR,
          linearG,
          linearB,
          a,
          headroom
        )
      else {
        fatalError("waterui_color_from_linear_rgba_headroom returned null")
      }
      binding.set(colorPtr)
    }
  }
#endif
