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
    precondition(item.tag.inner == collectionId, "Picker item collection id must equal its tag")
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

  #if canImport(UIKit)
    private let segmentedControl = UISegmentedControl()
    private let menuButton = UIButton(type: .system)
    private let radioStack = UIStackView()
    private var radioButtons: [Int32: UIButton] = [:]
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
      style: PickerStyle(picker.style)
    )
  }

  private init(items: OpaquePointer, selection: WuiBinding<WuiId>, style: PickerStyle) {
    self.source = WuiAnyViews(items)
    self.selectionBinding = selection
    self.style = style
    super.init(frame: .zero)

    configureSubviews()
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

  private func configureSubviews() {
    #if canImport(UIKit)
      segmentedControl.addTarget(self, action: #selector(segmentedChanged), for: .valueChanged)
      menuButton.configuration = .bordered()
      menuButton.showsMenuAsPrimaryAction = true
      radioStack.axis = .vertical
      radioStack.spacing = 8
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
        radioStack
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
        reconcileUIKitRadioButtons()
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
    syncSelection()
    invalidateIntrinsicContentSize()
    invalidateCapturedRendering()
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
        break
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

    private func reconcileUIKitRadioButtons() {
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
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.imagePadding = 8
            button.configuration = configuration
            button.contentHorizontalAlignment = .leading
            button.addTarget(self, action: #selector(radioTapped(_:)), for: .touchUpInside)
            radioButtons[item.collectionId] = button
            return button
          }()
        button.tag = index
        radioStack.addArrangedSubview(button)
      }
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
        for (index, item) in items.enumerated() {
          let button = radioButtons[item.collectionId]!
          let imageName = item.tag == selected ? "circle.inset.filled" : "circle"
          button.configuration?.image = UIImage(systemName: imageName)
          button.configuration?.title = item.text
          button.tag = index
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
        radioStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
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
    override var isFlipped: Bool { true }
  #endif

  #if canImport(UIKit)
    @objc private func segmentedChanged() {
      let index = segmentedControl.selectedSegmentIndex
      precondition(items.indices.contains(index), "Picker emitted an invalid segment index")
      selectionBinding.set(items[index].tag)
    }

    @objc private func radioTapped(_ sender: UIButton) {
      precondition(items.indices.contains(sender.tag), "Picker emitted an invalid radio index")
      selectionBinding.set(items[sender.tag].tag)
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
