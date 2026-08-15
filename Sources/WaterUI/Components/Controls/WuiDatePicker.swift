// WuiDatePicker.swift
// DatePicker component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// DatePicker sizes itself to fit its content and never stretches to fill extra space.
// In a stack, it takes only the space it needs.

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiDatePicker: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_date_picker_id() }

  private struct NativeDateComponents {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int

    init(calendar: Calendar, date: Date) {
      let components = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .second],
        from: date
      )
      guard
        let year = components.year,
        let month = components.month,
        let day = components.day,
        let hour = components.hour,
        let minute = components.minute,
        let second = components.second
      else {
        fatalError("Gregorian calendar failed to resolve DatePicker components")
      }
      self.year = year
      self.month = month
      self.day = day
      self.hour = hour
      self.minute = minute
      self.second = second
    }
  }

  #if canImport(UIKit)
    private let datePicker = UIDatePicker()
    private let secondsLabel = UILabel()
    private let secondsStepper = UIStepper()
    private var secondsFontObservation: WuiComputedObservation<WuiResolvedFontValue>?
    private var secondsForegroundObservation: WuiComputedObservation<WuiResolvedColor>?
  #elseif canImport(AppKit)
    private let datePicker = NSDatePicker()
  #endif

  private var labelView: WuiAnyView
  private var binding: WuiBinding<CWaterUI.WuiDateTime>
  private var bindingWatcher: WatcherGuard?
  private var bodyFontObservation: WuiComputedObservation<WuiResolvedFontValue>?
  private var isSyncingFromBinding = false
  private let pickerType: CWaterUI.WuiDatePickerType
  private var accessibility: WuiControlAccessibility?

  private let spacing: CGFloat = 8.0
  private let calendar = Calendar(identifier: .gregorian)

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffiDatePicker: CWaterUI.WuiDatePicker = waterui_force_as_date_picker(anyview)
    let labelView = WuiAnyView(anyview: ffiDatePicker.label.view, env: env)
    let binding = WuiBinding<CWaterUI.WuiDateTime>(ffiDatePicker.value)
    self.init(
      label: labelView,
      binding: binding,
      pickerType: ffiDatePicker.ty,
      range: ffiDatePicker.range,
      semanticLabel: ffiDatePicker.label,
      env: env
    )
  }

  init(
    label: WuiAnyView,
    binding: WuiBinding<CWaterUI.WuiDateTime>,
    pickerType: CWaterUI.WuiDatePickerType,
    range: CWaterUI.WuiRange_WuiDateTime,
    semanticLabel: CWaterUI.WuiLabel,
    env: WuiEnvironment
  ) {
    self.labelView = label
    self.binding = binding
    self.pickerType = pickerType
    super.init(frame: .zero)
    configureSubviews(env: env)
    startBindingWatcher()
    configureDatePicker(range: range)
    #if canImport(UIKit)
      accessibility = WuiControlAccessibility(
        consuming: semanticLabel,
        target: datePicker,
        additionalTargets: showsSeconds ? [secondsStepper] : [],
        visualLabel: label
      )
    #elseif canImport(AppKit)
      accessibility = WuiControlAccessibility(
        consuming: semanticLabel,
        target: datePicker,
        visualLabel: label
      )
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    let labelSize = labelView.sizeThatFits(WuiProposalSize())
    #if canImport(UIKit)
      let pickerSize = datePicker.intrinsicContentSize
      let secondsWidth: CGFloat =
        showsSeconds
        ? spacing + secondsLabel.intrinsicContentSize.width + spacing
          + secondsStepper.intrinsicContentSize.width
        : 0.0
    #elseif canImport(AppKit)
      let pickerSize = datePicker.intrinsicContentSize
      let secondsWidth: CGFloat = 0.0
    #endif
    let hasLabel = labelSize.width > 0 && labelSize.height > 0

    var totalWidth: CGFloat = pickerSize.width + secondsWidth
    var maxHeight: CGFloat = pickerSize.height

    if hasLabel {
      totalWidth += spacing + labelSize.width
      maxHeight = max(maxHeight, labelSize.height)
    }

    return CGSize(width: totalWidth, height: maxHeight)
  }

  #if canImport(AppKit)
    override var isFlipped: Bool { true }
  #endif

  private func configureSubviews(env: WuiEnvironment) {
    labelView.translatesAutoresizingMaskIntoConstraints = false
    datePicker.translatesAutoresizingMaskIntoConstraints = false

    addSubview(labelView)
    addSubview(datePicker)

    #if canImport(AppKit)
      // The text-field-and-stepper picker renders themed text; its control
      // font must track the body slot like every other text control.
      bodyFontObservation = .bodyFont(env: env) { [weak self] font in
        guard let self else { return }
        datePicker.font = font.toPlatformFont()
        invalidateLayoutHierarchy()
      }
    #endif

    #if canImport(UIKit)
      if showsSeconds {
        secondsLabel.translatesAutoresizingMaskIntoConstraints = false
        secondsStepper.translatesAutoresizingMaskIntoConstraints = false
        secondsLabel.textAlignment = .right
        secondsStepper.minimumValue = 0
        secondsStepper.maximumValue = 59
        secondsStepper.stepValue = 1
        secondsStepper.addTarget(self, action: #selector(secondsChanged), for: .valueChanged)
        addSubview(secondsLabel)
        addSubview(secondsStepper)
        installSecondsTheme(env: env)
      }
    #endif

    #if canImport(UIKit)
      labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
      labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    #elseif canImport(AppKit)
      labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
      labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    #endif

    var constraints = [
      labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
      labelView.centerYAnchor.constraint(equalTo: centerYAnchor),
      datePicker.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: spacing),
      datePicker.centerYAnchor.constraint(equalTo: centerYAnchor),
    ]

    #if canImport(UIKit)
      if showsSeconds {
        constraints += [
          secondsLabel.leadingAnchor.constraint(
            equalTo: datePicker.trailingAnchor, constant: spacing),
          secondsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
          secondsStepper.leadingAnchor.constraint(
            equalTo: secondsLabel.trailingAnchor, constant: spacing),
          secondsStepper.trailingAnchor.constraint(equalTo: trailingAnchor),
          secondsStepper.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
      } else {
        constraints += [
          datePicker.trailingAnchor.constraint(equalTo: trailingAnchor)
        ]
      }
    #elseif canImport(AppKit)
      constraints += [
        datePicker.trailingAnchor.constraint(equalTo: trailingAnchor)
      ]
    #endif

    NSLayoutConstraint.activate(constraints)

  }

  #if canImport(UIKit)
    private var showsSeconds: Bool {
      switch pickerType {
      case WuiDatePickerType_HourMinuteAndSecond, WuiDatePickerType_DateHourMinuteAndSecond:
        true
      case WuiDatePickerType_Date, WuiDatePickerType_HourAndMinute,
        WuiDatePickerType_DateHourAndMinute:
        false
      default:
        fatalError("Unsupported WaterUI date picker type: \(pickerType.rawValue)")
      }
    }

    private func installSecondsTheme(env: WuiEnvironment) {
      let fontObservation = WuiComputedObservation(
        themeFont: WuiFontSlot_Body,
        env: env
      ) { [weak self] font, _ in
        self?.applySecondsFont(font)
      }
      let foregroundObservation = WuiComputedObservation(
        themeColor: WuiColorSlot_Foreground,
        env: env
      ) { [weak self] color, _ in
        self?.secondsLabel.textColor = color.toUIColor()
      }
      secondsFontObservation = fontObservation
      secondsForegroundObservation = foregroundObservation
      applySecondsFont(fontObservation.value)
      secondsLabel.textColor = foregroundObservation.value.toUIColor()
    }

    private func applySecondsFont(_ font: WuiResolvedFontValue) {
      secondsLabel.font = .monospacedDigitSystemFont(
        ofSize: CGFloat(font.size),
        weight: font.weight.toUIFontWeight()
      )
      invalidateIntrinsicContentSize()
      setNeedsLayout()
    }
  #endif

  private func configureDatePicker(range: CWaterUI.WuiRange_WuiDateTime) {
    #if canImport(UIKit)
      datePicker.preferredDatePickerStyle = .compact
      switch pickerType {
      case WuiDatePickerType_Date:
        datePicker.datePickerMode = .date
      case WuiDatePickerType_HourAndMinute, WuiDatePickerType_HourMinuteAndSecond:
        datePicker.datePickerMode = .time
      case WuiDatePickerType_DateHourAndMinute, WuiDatePickerType_DateHourMinuteAndSecond:
        datePicker.datePickerMode = .dateAndTime
      default:
        fatalError("Unsupported WaterUI date picker type: \(pickerType.rawValue)")
      }
      datePicker.minimumDate = nativeRangeBound(range.start)
      datePicker.maximumDate = nativeRangeBound(range.end)
      syncControls(with: binding.value)
      datePicker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)

    #elseif canImport(AppKit)
      datePicker.datePickerStyle = .textFieldAndStepper
      switch pickerType {
      case WuiDatePickerType_Date:
        datePicker.datePickerElements = .yearMonthDay
      case WuiDatePickerType_HourAndMinute:
        datePicker.datePickerElements = .hourMinute
      case WuiDatePickerType_HourMinuteAndSecond:
        datePicker.datePickerElements = .hourMinuteSecond
      case WuiDatePickerType_DateHourAndMinute:
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
      case WuiDatePickerType_DateHourMinuteAndSecond:
        datePicker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
      default:
        fatalError("Unsupported WaterUI date picker type: \(pickerType.rawValue)")
      }
      datePicker.minDate = nativeRangeBound(range.start)
      datePicker.maxDate = nativeRangeBound(range.end)
      syncControls(with: binding.value)
      datePicker.target = self
      datePicker.action = #selector(dateChanged)
    #endif
  }

  private func startBindingWatcher() {
    bindingWatcher = binding.watch { [weak self] newValue, _ in
      guard let self, !isSyncingFromBinding else { return }
      isSyncingFromBinding = true
      syncControls(with: newValue)
      isSyncingFromBinding = false
    }
  }

  private func syncControls(with value: CWaterUI.WuiDateTime) {
    let date = wuiDateTimeToDate(value)
    #if canImport(UIKit)
      datePicker.date = date
      if showsSeconds {
        updateSecondsControls(seconds: Int(value.second))
      }
    #elseif canImport(AppKit)
      datePicker.dateValue = date
    #endif
  }

  #if canImport(UIKit)
    private func updateSecondsControls(seconds: Int) {
      secondsStepper.value = Double(seconds)
      secondsLabel.text = String(format: ":%02d", seconds)
    }
  #endif

  @objc private func dateChanged() {
    guard !isSyncingFromBinding else { return }
    updateBindingFromControls()
  }

  #if canImport(UIKit)
    @objc private func secondsChanged() {
      guard !isSyncingFromBinding else { return }
      updateSecondsControls(seconds: Int(secondsStepper.value))
      updateBindingFromControls()
    }
  #endif

  private func updateBindingFromControls() {
    let current = binding.value
    #if canImport(UIKit)
      let pickerDate = datePicker.date
    #elseif canImport(AppKit)
      let pickerDate = datePicker.dateValue
    #endif
    binding.value = mergedValue(from: pickerDate, current: current)
  }

  private func mergedValue(from pickerDate: Date, current: CWaterUI.WuiDateTime)
    -> CWaterUI.WuiDateTime
  {
    let picker = NativeDateComponents(calendar: calendar, date: pickerDate)
    var year = Int(current.year)
    var month = Int(current.month)
    var day = Int(current.day)
    var hour = Int(current.hour)
    var minute = Int(current.minute)
    var second = Int(current.second)

    switch pickerType {
    case WuiDatePickerType_Date:
      year = picker.year
      month = picker.month
      day = picker.day
    case WuiDatePickerType_HourAndMinute:
      hour = picker.hour
      minute = picker.minute
    case WuiDatePickerType_HourMinuteAndSecond:
      hour = picker.hour
      minute = picker.minute
      #if canImport(UIKit)
        second = Int(secondsStepper.value)
      #elseif canImport(AppKit)
        second = picker.second
      #endif
    case WuiDatePickerType_DateHourAndMinute:
      year = picker.year
      month = picker.month
      day = picker.day
      hour = picker.hour
      minute = picker.minute
    case WuiDatePickerType_DateHourMinuteAndSecond:
      year = picker.year
      month = picker.month
      day = picker.day
      hour = picker.hour
      minute = picker.minute
      #if canImport(UIKit)
        second = Int(secondsStepper.value)
      #elseif canImport(AppKit)
        second = picker.second
      #endif
    default:
      fatalError("Unsupported WaterUI date picker type: \(pickerType.rawValue)")
    }

    return CWaterUI.WuiDateTime(
      year: Int32(year),
      month: UInt8(month),
      day: UInt8(day),
      hour: UInt8(hour),
      minute: UInt8(minute),
      second: UInt8(second)
    )
  }

  private func nativeRangeBound(_ wuiDateTime: CWaterUI.WuiDateTime) -> Date? {
    if isJiffFullRangeBound(wuiDateTime) {
      return nil
    }
    return wuiDateTimeToDate(wuiDateTime)
  }

  private func isJiffFullRangeBound(_ wuiDateTime: CWaterUI.WuiDateTime) -> Bool {
    (wuiDateTime.year == -9999
      && wuiDateTime.month == 1
      && wuiDateTime.day == 1
      && wuiDateTime.hour == 0
      && wuiDateTime.minute == 0
      && wuiDateTime.second == 0)
      || (wuiDateTime.year == 9999
        && wuiDateTime.month == 12
        && wuiDateTime.day == 31
        && wuiDateTime.hour == 23
        && wuiDateTime.minute == 59
        && wuiDateTime.second == 59)
  }

  private func wuiDateTimeToDate(_ wuiDateTime: CWaterUI.WuiDateTime) -> Date {
    var components = DateComponents()
    components.year = Int(wuiDateTime.year)
    components.month = Int(wuiDateTime.month)
    components.day = Int(wuiDateTime.day)
    components.hour = Int(wuiDateTime.hour)
    components.minute = Int(wuiDateTime.minute)
    components.second = Int(wuiDateTime.second)
    guard let date = calendar.date(from: components) else {
      fatalError(
        "WaterUI DatePicker cannot represent date-time \(wuiDateTime.year)-\(wuiDateTime.month)-\(wuiDateTime.day) \(wuiDateTime.hour):\(wuiDateTime.minute):\(wuiDateTime.second)"
      )
    }
    return date
  }
}
