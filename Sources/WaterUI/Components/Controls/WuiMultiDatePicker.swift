import CWaterUI
import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

private struct WuiNativeDateKey: Hashable, Comparable {
  let year: Int32
  let month: UInt8
  let day: UInt8

  init(_ date: CWaterUI.WuiDate) {
    year = date.year
    month = date.month
    day = date.day
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.year != rhs.year { return lhs.year < rhs.year }
    if lhs.month != rhs.month { return lhs.month < rhs.month }
    return lhs.day < rhs.day
  }
}

@MainActor
final class WuiMultiDatePicker: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_multi_date_picker_id() }

  private let labelView: WuiAnyView
  private let binding: WuiBinding<[CWaterUI.WuiDate]>
  private let decorated: WuiComputed<[CWaterUI.WuiDate]>
  private let range: CWaterUI.WuiRange_WuiDate
  private let env: WuiEnvironment
  private let calendar = Calendar(identifier: .gregorian)
  private var decoratedDateKeys: Set<WuiNativeDateKey> = []
  private var bindingWatcher: WatcherGuard?
  private var decoratedWatcher: WatcherGuard?
  private var accessibility: WuiControlAccessibility?

  #if canImport(UIKit)
    private let calendarView = UICalendarView()
    private lazy var calendarDelegate = UIKitMultiDateCoordinator(owner: self)
    private lazy var calendarSelection = UICalendarSelectionMultiDate(delegate: calendarDelegate)
    private var isSyncingCalendarSelection = false
    private lazy var decorationColorObservation = WuiComputedObservation(
      themeColor: WuiColorSlot_MutedForeground,
      env: env
    ) { [weak self] _, _ in
      self?.reloadDecoratedDates()
    }
  #elseif canImport(AppKit)
    private let picker = NSDatePicker()
    private let toggleButton = NSButton(title: "", target: nil, action: nil)
    private let selectionList = NSStackView()
    private lazy var selectionForegroundObservation = WuiComputedObservation(
      themeColor: WuiColorSlot_Foreground,
      env: env
    ) { [weak self] _, _ in
      self?.syncFromModel()
    }
    private lazy var selectionFontObservation = WuiComputedObservation(
      themeFont: WuiFontSlot_Body,
      env: env
    ) { [weak self] _, _ in
      self?.syncFromModel()
    }
  #endif

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffiPicker: CWaterUI.WuiMultiDatePicker = waterui_force_as_multi_date_picker(anyview)
    guard let value = ffiPicker.value, let decorated = ffiPicker.decorated else {
      fatalError("MultiDatePicker requires value and decorated date signals")
    }
    self.init(
      label: WuiAnyView(anyview: ffiPicker.label.view, env: env),
      binding: makeDateArrayBinding(value),
      decorated: makeDateArrayComputed(decorated),
      range: ffiPicker.range,
      semanticLabel: ffiPicker.label,
      env: env
    )
  }

  private init(
    label: WuiAnyView,
    binding: WuiBinding<[CWaterUI.WuiDate]>,
    decorated: WuiComputed<[CWaterUI.WuiDate]>,
    range: CWaterUI.WuiRange_WuiDate,
    semanticLabel: CWaterUI.WuiLabel,
    env: WuiEnvironment
  ) {
    self.labelView = label
    self.binding = binding
    self.decorated = decorated
    self.range = range
    self.env = env
    super.init(frame: .zero)
    configureSubviews()
    installThemeObservers()
    startObservers()
    syncFromModel()
    #if canImport(UIKit)
      accessibility = WuiControlAccessibility(
        consuming: semanticLabel,
        target: calendarView,
        visualLabel: label
      )
    #elseif canImport(AppKit)
      accessibility = WuiControlAccessibility(
        consuming: semanticLabel,
        target: picker,
        additionalTargets: [toggleButton],
        visualLabel: label
      )
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    #if canImport(UIKit)
      systemLayoutSizeFitting(
        CGSize(
          width: proposal.width.map { $0.isFinite ? CGFloat($0) : UIView.noIntrinsicMetric }
            ?? UIView.noIntrinsicMetric,
          height: proposal.height.map { $0.isFinite ? CGFloat($0) : UIView.noIntrinsicMetric }
            ?? UIView.noIntrinsicMetric
        )
      )
    #elseif canImport(AppKit)
      fittingSize
    #endif
  }

  private func configureSubviews() {
    #if canImport(UIKit)
      let root = UIStackView(arrangedSubviews: [labelView])
      root.axis = .vertical
      root.spacing = 8
      root.translatesAutoresizingMaskIntoConstraints = false
      calendarView.availableDateRange = DateInterval(
        start: toDate(range.start),
        end: toDate(range.end)
      )
      calendarView.delegate = calendarDelegate
      calendarView.selectionBehavior = calendarSelection
      root.addArrangedSubview(calendarView)
      addSubview(root)
      NSLayoutConstraint.activate([
        root.leadingAnchor.constraint(equalTo: leadingAnchor),
        root.trailingAnchor.constraint(equalTo: trailingAnchor),
        root.topAnchor.constraint(equalTo: topAnchor),
        root.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    #elseif canImport(AppKit)
      let root = NSStackView(views: [labelView, picker, toggleButton, selectionList])
      root.orientation = .vertical
      root.spacing = 8
      root.translatesAutoresizingMaskIntoConstraints = false
      selectionList.orientation = .vertical
      selectionList.spacing = 4
      picker.datePickerElements = .yearMonthDay
      picker.minDate = toDate(range.start)
      picker.maxDate = toDate(range.end)
      picker.target = self
      picker.action = #selector(toggleCurrentDate)
      toggleButton.target = self
      toggleButton.action = #selector(toggleCurrentDate)
      addSubview(root)
      NSLayoutConstraint.activate([
        root.leadingAnchor.constraint(equalTo: leadingAnchor),
        root.trailingAnchor.constraint(equalTo: trailingAnchor),
        root.topAnchor.constraint(equalTo: topAnchor),
        root.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    #endif
  }

  private func installThemeObservers() {
    #if canImport(UIKit)
      _ = decorationColorObservation
    #elseif canImport(AppKit)
      _ = selectionForegroundObservation
      _ = selectionFontObservation
    #endif
  }

  private func startObservers() {
    bindingWatcher = binding.watch { [weak self] _, _ in
      self?.syncFromModel()
    }
    decoratedWatcher = decorated.watch { [weak self] _, _ in
      self?.syncFromModel()
    }
  }

  private func selectedDates() -> [CWaterUI.WuiDate] {
    binding.value
  }

  private func decoratedDates() -> [CWaterUI.WuiDate] {
    decorated.value
  }

  private func syncFromModel() {
    let selected = selectedDates()
    let decorated = decoratedDates()
    decoratedDateKeys = Set(decorated.map(dateKey))
    #if canImport(UIKit)
      let selectedComponents = selected.map(dateComponents)
      let decoratedComponents = decorated.map(dateComponents)
      isSyncingCalendarSelection = true
      calendarSelection.selectedDates = selectedComponents
      calendarView.reloadDecorations(forDateComponents: selectedComponents, animated: false)
      calendarView.reloadDecorations(forDateComponents: decoratedComponents, animated: false)
      isSyncingCalendarSelection = false
    #elseif canImport(AppKit)
      let current = selected.first ?? range.start
      picker.dateValue = toDate(current)
      toggleButton.title = buttonTitle(for: current, selected: selected)
      for view in selectionList.arrangedSubviews {
        selectionList.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
      for date in selected {
        let label = NSTextField(
          labelWithString: formatted(date, decorated: decoratedDateKeys.contains(dateKey(date)))
        )
        label.textColor = selectionForegroundObservation.value.toNSColor()
        let font = selectionFontObservation.value
        label.font = NSFont.systemFont(
          ofSize: CGFloat(font.size),
          weight: font.weight.toNSFontWeight()
        )
        selectionList.addArrangedSubview(label)
      }
    #endif
  }

  #if canImport(AppKit)
    @objc private func toggleCurrentDate() {
      let current = currentDate()
      applySelectionToggle(current)
    }
  #endif

  private func applySelectionToggle(_ current: CWaterUI.WuiDate) {
    var selected = selectedDates()
    if let index = selected.firstIndex(where: { dateKey($0) == dateKey(current) }) {
      selected.remove(at: index)
    } else {
      selected.append(current)
      selected.sort { lhs, rhs in
        dateKey(lhs) < dateKey(rhs)
      }
    }
    binding.set(selected)
  }

  #if canImport(AppKit)
    private func currentDate() -> CWaterUI.WuiDate {
      let components = calendar.dateComponents([.year, .month, .day], from: pickerDate())
      guard let year = components.year, let month = components.month, let day = components.day
      else {
        fatalError("AppKit date picker returned incomplete date components")
      }
      return CWaterUI.WuiDate(
        year: Int32(year),
        month: UInt8(month),
        day: UInt8(day)
      )
    }

    private func buttonTitle(for current: CWaterUI.WuiDate, selected: [CWaterUI.WuiDate]) -> String
    {
      selected.contains { dateKey($0) == dateKey(current) } ? "Remove Date" : "Add Date"
    }

    private func formatted(_ date: CWaterUI.WuiDate, decorated: Bool) -> String {
      let suffix = decorated ? " •" : ""
      return
        "\(date.year)-\(String(format: "%02d", date.month))-\(String(format: "%02d", date.day))\(suffix)"
    }

  #endif

  private func dateKey(_ date: CWaterUI.WuiDate) -> WuiNativeDateKey {
    WuiNativeDateKey(date)
  }

  #if canImport(UIKit)
    private func dateComponents(_ date: CWaterUI.WuiDate) -> DateComponents {
      DateComponents(year: Int(date.year), month: Int(date.month), day: Int(date.day))
    }

    fileprivate func canToggle(_ components: DateComponents) -> Bool {
      let date = requireDate(from: components)
      let currentDate = toDate(date)
      return currentDate >= toDate(range.start) && currentDate <= toDate(range.end)
    }

    fileprivate func toggleFromCalendar(_ components: DateComponents) {
      guard !isSyncingCalendarSelection else { return }
      applySelectionToggle(requireDate(from: components))
    }

    fileprivate func decoration(for components: DateComponents) -> UICalendarView.Decoration? {
      let date = requireDate(from: components)
      guard decoratedDateKeys.contains(dateKey(date)) else {
        return nil
      }
      return .default(color: decorationColorObservation.value.toUIColor(), size: .small)
    }

    private func reloadDecoratedDates() {
      calendarView.reloadDecorations(
        forDateComponents: decoratedDates().map(dateComponents),
        animated: false
      )
    }

    private func requireDate(from components: DateComponents) -> CWaterUI.WuiDate {
      guard let year = components.year,
        let month = components.month,
        let day = components.day
      else {
        fatalError("UICalendarView returned incomplete date components")
      }
      return CWaterUI.WuiDate(year: Int32(year), month: UInt8(month), day: UInt8(day))
    }
  #endif

  private func toDate(_ date: CWaterUI.WuiDate) -> Date {
    var components = DateComponents()
    components.year = Int(date.year)
    components.month = Int(date.month)
    components.day = Int(date.day)
    guard let value = calendar.date(from: components) else {
      fatalError("WaterUI received an invalid calendar date")
    }
    return value
  }

  #if canImport(AppKit)
    private func pickerDate() -> Date {
      picker.dateValue
    }
  #endif
}

#if canImport(UIKit)
  @MainActor
  private final class UIKitMultiDateCoordinator: NSObject, UICalendarSelectionMultiDateDelegate,
    UICalendarViewDelegate
  {
    private unowned let owner: WuiMultiDatePicker

    init(owner: WuiMultiDatePicker) {
      self.owner = owner
    }

    func multiDateSelection(
      _ selection: UICalendarSelectionMultiDate, canSelectDate dateComponents: DateComponents
    ) -> Bool {
      owner.canToggle(dateComponents)
    }

    func multiDateSelection(
      _ selection: UICalendarSelectionMultiDate, canDeselectDate dateComponents: DateComponents
    ) -> Bool {
      owner.canToggle(dateComponents)
    }

    func multiDateSelection(
      _ selection: UICalendarSelectionMultiDate, didSelectDate dateComponents: DateComponents
    ) {
      owner.toggleFromCalendar(dateComponents)
    }

    func multiDateSelection(
      _ selection: UICalendarSelectionMultiDate, didDeselectDate dateComponents: DateComponents
    ) {
      owner.toggleFromCalendar(dateComponents)
    }

    func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents)
      -> UICalendarView.Decoration?
    {
      owner.decoration(for: dateComponents)
    }
  }
#endif

@MainActor
private func makeDateArrayBinding(
  _ inner: OpaquePointer
) -> WuiBinding<[CWaterUI.WuiDate]> {
  WuiBinding<[CWaterUI.WuiDate]>(
    inner: inner,
    read: { inner in
      WuiArray<CWaterUI.WuiDate>(waterui_read_binding_date_vec(inner)).toArray()
    },
    watch: { inner, f in
      let watcher = makeDateArrayWatcher { value, metadata in
        f(WuiArray<CWaterUI.WuiDate>(value).toArray(), metadata)
      }
      let g = waterui_watch_binding_date_vec(inner, watcher)
      return WatcherGuard(g!)
    },
    set: { inner, value in
      waterui_set_binding_date_vec(inner, WuiArray(array: value).intoWuiDateArray())
    },
    drop: waterui_drop_binding_date_vec
  )
}

@MainActor
private func makeDateArrayComputed(
  _ inner: OpaquePointer
) -> WuiComputed<[CWaterUI.WuiDate]> {
  WuiComputed<[CWaterUI.WuiDate]>(
    inner: inner,
    read: { inner in
      WuiArray<CWaterUI.WuiDate>(waterui_read_computed_date_vec(inner)).toArray()
    },
    watch: { inner, f in
      let watcher = makeDateArrayWatcher { value, metadata in
        f(WuiArray<CWaterUI.WuiDate>(value).toArray(), metadata)
      }
      let g = waterui_watch_computed_date_vec(inner, watcher)
      return WatcherGuard(g!)
    },
    drop: waterui_drop_computed_date_vec
  )
}

@MainActor
private func makeDateArrayWatcher(
  _ f: @escaping (CWaterUI.WuiArray_WuiDate, WuiWatcherMetadata) -> Void
) -> OpaquePointer {
  let data = wrap(f)
  let call:
    @convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiArray_WuiDate, OpaquePointer?) -> Void =
      { data, value, metadata in
        callWrapper(data, value, metadata)
      }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, CWaterUI.WuiArray_WuiDate.self)
  }
  guard let watcher = waterui_new_watcher_date_vec(data, call, drop) else {
    fatalError("Failed to create date array watcher")
  }
  return watcher
}
