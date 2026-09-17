// WuiPicker.swift
// Picker component - merged UIKit and AppKit implementation
//
// # Style mapping
// Every `PickerStyle` projects onto the platform's own control:
// - automatic / menu: a menu button (UIKit) or a popup button (AppKit)
// - segmented: the platform segmented control
// - radio: an `NSButton` radio group on macOS. iOS has no radio group — neither
//   UIKit nor SwiftUI offers one — so the style renders the platform's inline
//   picker, a `UIPickerView` wheel, exactly as SwiftUI's `.inline` style does
//   in the same place. The asymmetry is documented on the framework's
//   `PickerStyle::Radio`; it is not faked with a self-drawn list.

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

private enum PickerStyle {
  case automatic
  case menu
  case radio
  case segmented

  init(_ style: CWaterUI.WuiPickerStyle) {
    switch style {
    case WuiPickerStyle_Automatic:
      self = .automatic
    case WuiPickerStyle_Menu:
      self = .menu
    case WuiPickerStyle_Radio:
      self = .radio
    case WuiPickerStyle_Segmented:
      self = .segmented
    default:
      fatalError("Unsupported picker style: \(style.rawValue)")
    }
  }
}

@MainActor
private final class PickerItemNode {
  let collectionId: Int32
  let tag: WuiId
  private let labelObservation: WuiComputedObservation<WuiStyledStr>

  var text: String { labelObservation.value.toString() }

  init(
    collectionId: Int32,
    consuming item: CWaterUI.WuiPickerItem,
    onChange: @escaping (WuiWatcherMetadata) -> Void
  ) {
    // `collectionId` identifies the view slot inside the items collection
    // (an IdGenerator raw id starting at i32.min); `item.tag` is the
    // selection identity produced by the picker's `Mapping` (counter starting
    // at 1). They are independent id spaces by design.
    guard let label = item.label else {
      fatalError("Picker item has no label signal")
    }
    self.collectionId = collectionId
    self.tag = item.tag
    self.labelObservation = WuiComputedObservation(
      WuiComputed<WuiStyledStr>(label),
      onChange: { _, metadata in onChange(metadata) }
    )
  }
}

@MainActor
final class WuiPicker: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_picker_id() }

  private let source: WuiAnyViews
  private let collection = WuiStableSemanticCollection<Int32, PickerItemNode>()
  private let style: PickerStyle
  private let selectionBinding: WuiBinding<WuiId>
  private var itemWatcher: WatcherGuard?
  private var selectionWatcher: WatcherGuard?
  private var bodyFontObservation: WuiComputedObservation<WuiResolvedFontValue>?
  /// The picker's own name, which is not the selected option.
  ///
  /// A label is required when a `Picker` is constructed so that assistive
  /// technology has something to announce; without this the control read out
  /// only its selection, which says what was chosen and never what it chose.
  private var labelObservation: WuiComputedObservation<WuiStyledStr>?

  #if canImport(UIKit)
    private let segmentedControl = UISegmentedControl()
    private let menuButton = UIButton(type: .system)
    /// The inline wheel the radio style renders on iOS.
    private let wheel = UIPickerView()
    private var wheelFont: UIFont?
  #elseif canImport(AppKit)
    private let segmentedControl = NSSegmentedControl()
    private let popupButton = NSPopUpButton()
    private let radioStack = NSStackView()
    private var popupItems: [Int32: NSMenuItem] = [:]
    private var radioButtons: [Int32: NSButton] = [:]
  #endif

  private var items: [PickerItemNode] { collection.ordered }

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let picker = waterui_force_as_picker(anyview)
    guard let items = picker.items else {
      fatalError("WuiPicker.items is null")
    }
    guard let selection = picker.selection else {
      fatalError("WuiPicker.selection is null")
    }
    self.init(
      items: items,
      selection: WuiBinding<WuiId>(selection),
      style: PickerStyle(picker.style),
      label: picker.label,
      env: env
    )
  }

  private init(
    items: OpaquePointer,
    selection: WuiBinding<WuiId>,
    style: PickerStyle,
    label: CWaterUI.WuiLabel,
    env: WuiEnvironment
  ) {
    self.source = WuiAnyViews(items)
    self.selectionBinding = selection
    self.style = style
    super.init(frame: .zero)

    configureSubviews()
    bindAccessibilityLabel(label)
    bodyFontObservation = .bodyFont(env: env) { [weak self] font in
      self?.applyBodyFont(font)
    }
    itemWatcher = watchAnyViewsIds(source) { [weak self] ids, metadata in
      guard let self else { return }
      withPlatformAnimation(metadata) {
        self.reconcile(ids: ids)
      }
    }
    selectionWatcher = selectionBinding.watch { [weak self] _, metadata in
      guard let self else { return }
      withPlatformAnimation(metadata) {
        self.syncSelection()
      }
    }
    reconcile(ids: source.allIds())
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Names the control after its own label, on every platform surface.
  private func bindAccessibilityLabel(_ label: CWaterUI.WuiLabel) {
    guard let accessibilityLabel = label.accessibility_label else {
      fatalError("WuiPicker label has no accessibility signal")
    }
    labelObservation = WuiComputedObservation(
      WuiComputed<WuiStyledStr>(accessibilityLabel)
    ) { [weak self] value, _ in
      self?.applyAccessibilityLabel(value.toString())
    }
    applyAccessibilityLabel(labelObservation?.value.toString() ?? "")
  }

  private func applyAccessibilityLabel(_ label: String) {
    #if canImport(UIKit)
      isAccessibilityElement = true
      accessibilityLabel = label
    #elseif canImport(AppKit)
      setAccessibilityElement(true)
      setAccessibilityLabel(label)
      toolTip = label
    #endif
  }

  private func configureSubviews() {
    #if canImport(UIKit)
      segmentedControl.addTarget(self, action: #selector(segmentedChanged), for: .valueChanged)
      // SwiftUI's menu picker is a plain accent-tinted title with a trailing
      // up/down chevron, not a filled gray capsule.
      var menuConfiguration = UIButton.Configuration.plain()
      menuConfiguration.image = UIImage(systemName: "chevron.up.chevron.down")
      menuConfiguration.imagePlacement = .trailing
      menuConfiguration.imagePadding = 4
      menuConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
        scale: .small
      )
      menuButton.configuration = menuConfiguration
      menuButton.showsMenuAsPrimaryAction = true
      wheel.dataSource = self
      wheel.delegate = self
    #elseif canImport(AppKit)
      segmentedControl.target = self
      segmentedControl.action = #selector(segmentedChanged)
      popupButton.target = self
      popupButton.action = #selector(popupChanged)
      radioStack.orientation = .vertical
      radioStack.spacing = 8
    #endif

    activeControl.translatesAutoresizingMaskIntoConstraints = false
    addSubview(activeControl)
    NSLayoutConstraint.activate([
      activeControl.leadingAnchor.constraint(equalTo: leadingAnchor),
      activeControl.trailingAnchor.constraint(equalTo: trailingAnchor),
      activeControl.topAnchor.constraint(equalTo: topAnchor),
      activeControl.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  #if canImport(UIKit)
    private var activeControl: UIView {
      switch style {
      case .automatic, .menu:
        menuButton
      case .radio:
        wheel
      case .segmented:
        segmentedControl
      }
    }
  #elseif canImport(AppKit)
    private var activeControl: NSView {
      switch style {
      case .automatic, .menu:
        popupButton
      case .radio:
        radioStack
      case .segmented:
        segmentedControl
      }
    }
  #endif

  private func reconcile(ids: [Int32]) {
    collection.reconcile(ids: ids) { [source] index, id in
      let item = waterui_force_as_picker_item(source.takeRawView(at: index))
      return PickerItemNode(collectionId: id, consuming: item) { [weak self] metadata in
        guard let self else { return }
        withPlatformAnimation(metadata) {
          self.updateLabels()
        }
      }
    }
    updateNativeItems()
  }

  private func updateNativeItems() {
    #if canImport(UIKit)
      switch style {
      case .automatic, .menu:
        break
      case .segmented:
        segmentedControl.removeAllSegments()
        for (index, item) in items.enumerated() {
          segmentedControl.insertSegment(withTitle: item.text, at: index, animated: false)
        }
      case .radio:
        wheel.reloadAllComponents()
      }
    #elseif canImport(AppKit)
      switch style {
      case .automatic, .menu:
        reconcileAppKitPopupItems()
      case .segmented:
        segmentedControl.segmentCount = items.count
        for (index, item) in items.enumerated() {
          segmentedControl.setLabel(item.text, forSegment: index)
        }
      case .radio:
        reconcileAppKitRadioButtons()
      }
    #endif
    if let font = bodyFontObservation?.value {
      applyBodyFont(font)
    }
    syncSelection()
    invalidateIntrinsicContentSize()
    invalidateCapturedRendering()
  }

  /// SwiftUI pickers render their options in the environment font; every
  /// native control here must track the themed body font or the picker stays
  /// at the platform default size while surrounding text scales.
  private func applyBodyFont(_ font: WuiResolvedFontValue) {
    let platformFont = font.toPlatformFont()
    #if canImport(UIKit)
      segmentedControl.setTitleTextAttributes([.font: platformFont], for: .normal)
      let transformer = UIConfigurationTextAttributesTransformer { attributes in
        var attributes = attributes
        attributes.font = platformFont
        return attributes
      }
      if var configuration = menuButton.configuration {
        configuration.titleTextAttributesTransformer = transformer
        menuButton.configuration = configuration
      }
      wheelFont = platformFont
      wheel.reloadAllComponents()
    #elseif canImport(AppKit)
      segmentedControl.font = platformFont
      popupButton.font = platformFont
      for button in radioButtons.values {
        button.font = platformFont
      }
    #endif
    invalidateLayoutHierarchy()
  }

  private func updateLabels() {
    #if canImport(UIKit)
      switch style {
      case .automatic, .menu:
        rebuildUIKitMenu()
      case .segmented:
        for (index, item) in items.enumerated() {
          segmentedControl.setTitle(item.text, forSegmentAt: index)
        }
      case .radio:
        wheel.reloadAllComponents()
      }
    #elseif canImport(AppKit)
      switch style {
      case .automatic, .menu:
        for item in items {
          popupItems[item.collectionId]!.title = item.text
        }
      case .segmented:
        for (index, item) in items.enumerated() {
          segmentedControl.setLabel(item.text, forSegment: index)
        }
      case .radio:
        for item in items {
          radioButtons[item.collectionId]!.title = item.text
        }
      }
    #endif
    syncSelection()
    invalidateIntrinsicContentSize()
    invalidateCapturedRendering()
  }

  #if canImport(UIKit)
    private func rebuildUIKitMenu() {
      let selected = selectionBinding.value
      menuButton.setTitle(items.first { $0.tag == selected }?.text, for: .normal)
      menuButton.menu = UIMenu(
        title: "",
        children: items.map { item in
          UIAction(title: item.text, state: item.tag == selected ? .on : .off) {
            [weak self, item] _ in
            self?.selectionBinding.set(item.tag)
          }
        }
      )
    }
  #elseif canImport(AppKit)
    private func reconcileAppKitPopupItems() {
      let activeIds = Set(items.lazy.map(\.collectionId))
      popupItems = popupItems.filter { activeIds.contains($0.key) }
      let menu = NSMenu()
      for item in items {
        let nativeItem =
          popupItems[item.collectionId]
          ?? {
            let nativeItem = NSMenuItem()
            popupItems[item.collectionId] = nativeItem
            return nativeItem
          }()
        nativeItem.title = item.text
        menu.addItem(nativeItem)
      }
      popupButton.menu = menu
    }

    private func reconcileAppKitRadioButtons() {
      let activeIds = Set(items.lazy.map(\.collectionId))
      let removed = radioButtons.filter { !activeIds.contains($0.key) }
      for (_, button) in removed {
        radioStack.removeArrangedSubview(button)
        button.removeFromSuperview()
      }
      radioButtons = radioButtons.filter { activeIds.contains($0.key) }
      for button in radioStack.arrangedSubviews {
        radioStack.removeArrangedSubview(button)
      }
      for (index, item) in items.enumerated() {
        let button =
          radioButtons[item.collectionId]
          ?? {
            let button = NSButton(
              radioButtonWithTitle: "", target: self, action: #selector(radioTapped(_:)))
            radioButtons[item.collectionId] = button
            return button
          }()
        button.tag = index
        button.title = item.text
        radioStack.addArrangedSubview(button)
      }
    }
  #endif

  private func syncSelection() {
    let selected = selectionBinding.value
    let selectedIndex = items.firstIndex { $0.tag == selected }

    #if canImport(UIKit)
      switch style {
      case .automatic, .menu:
        rebuildUIKitMenu()
      case .segmented:
        segmentedControl.selectedSegmentIndex = selectedIndex ?? UISegmentedControl.noSegment
      case .radio:
        if let selectedIndex {
          wheel.selectRow(selectedIndex, inComponent: 0, animated: false)
        }
      }
    #elseif canImport(AppKit)
      switch style {
      case .automatic, .menu:
        if let selectedIndex {
          popupButton.selectItem(at: selectedIndex)
        } else {
          popupButton.select(nil)
        }
      case .segmented:
        segmentedControl.selectedSegment = selectedIndex ?? -1
      case .radio:
        for item in items {
          radioButtons[item.collectionId]!.state = item.tag == selected ? .on : .off
        }
      }
    #endif
    invalidateCapturedRendering()
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    #if canImport(UIKit)
      switch style {
      case .automatic, .menu:
        menuButton.intrinsicContentSize
      case .segmented:
        segmentedControl.intrinsicContentSize
      case .radio:
        // The wheel is as wide as it is offered, like SwiftUI's inline
        // picker, and keeps its own height.
        CGSize(
          width: proposal.width.map(CGFloat.init) ?? wheel.intrinsicContentSize.width,
          height: wheel.intrinsicContentSize.height)
      }
    #elseif canImport(AppKit)
      switch style {
      case .automatic, .menu:
        popupButton.intrinsicContentSize
      case .segmented:
        segmentedControl.intrinsicContentSize
      case .radio:
        radioStack.fittingSize
      }
    #endif
  }

  #if canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }
  #endif

  #if canImport(UIKit)
    @objc private func segmentedChanged() {
      let index = segmentedControl.selectedSegmentIndex
      precondition(items.indices.contains(index), "Picker emitted an invalid segment index")
      selectionBinding.set(items[index].tag)
    }

  #elseif canImport(AppKit)
    @objc private func segmentedChanged() {
      let index = segmentedControl.selectedSegment
      precondition(items.indices.contains(index), "Picker emitted an invalid segment index")
      selectionBinding.set(items[index].tag)
    }

    @objc private func popupChanged() {
      let index = popupButton.indexOfSelectedItem
      precondition(items.indices.contains(index), "Picker emitted an invalid popup index")
      selectionBinding.set(items[index].tag)
    }

    @objc private func radioTapped(_ sender: NSButton) {
      precondition(items.indices.contains(sender.tag), "Picker emitted an invalid radio index")
      selectionBinding.set(items[sender.tag].tag)
    }
  #endif
}

#if canImport(UIKit)
  extension WuiPicker: UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
      items.count
    }

    func pickerView(
      _ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int,
      reusing view: UIView?
    ) -> UIView {
      let label = view as? UILabel ?? UILabel()
      label.textAlignment = .center
      label.font = wheelFont ?? .preferredFont(forTextStyle: .body)
      label.text = items[row].text
      return label
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
      precondition(items.indices.contains(row), "Picker emitted an invalid wheel row")
      selectionBinding.set(items[row].tag)
    }
  }
#endif
