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

    #if canImport(UIKit)
    private let datePicker = UIDatePicker()
    private let secondsLabel = UILabel()
    private let secondsStepper = UIStepper()
    #elseif canImport(AppKit)
    private let datePicker = NSDatePicker()
    #endif

    private var labelView: WuiAnyView
    private var binding: WuiBinding<CWaterUI.WuiDateTime>
    private var bindingWatcher: WatcherGuard?
    private var isSyncingFromBinding = false
    private let pickerType: CWaterUI.WuiDatePickerType

    private let spacing: CGFloat = 8.0
    private let calendar = Calendar(identifier: .gregorian)

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiDatePicker: CWaterUI.WuiDatePicker = waterui_force_as_date_picker(anyview)
        let labelView = WuiAnyView(anyview: ffiDatePicker.label.view, env: env)
        let binding = WuiBinding<CWaterUI.WuiDateTime>(ffiDatePicker.value)
        self.init(label: labelView, binding: binding, pickerType: ffiDatePicker.ty, range: ffiDatePicker.range)
    }

    init(
        label: WuiAnyView,
        binding: WuiBinding<CWaterUI.WuiDateTime>,
        pickerType: CWaterUI.WuiDatePickerType,
        range: CWaterUI.WuiRange_WuiDateTime
    ) {
        self.labelView = label
        self.binding = binding
        self.pickerType = pickerType
        super.init(frame: .zero)
        configureSubviews()
        configureDatePicker(range: range)
        startBindingWatcher()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        #if canImport(UIKit)
        let pickerSize = datePicker.intrinsicContentSize
        let secondsWidth: CGFloat = showsSeconds ? 84.0 : 0.0
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

    private func configureSubviews() {
        labelView.translatesAutoresizingMaskIntoConstraints = false
        datePicker.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelView)
        addSubview(datePicker)

        #if canImport(UIKit)
        secondsLabel.translatesAutoresizingMaskIntoConstraints = false
        secondsStepper.translatesAutoresizingMaskIntoConstraints = false
        secondsLabel.font = .monospacedDigitSystemFont(ofSize: 13.0, weight: .regular)
        secondsLabel.textAlignment = .right
        secondsStepper.minimumValue = 0
        secondsStepper.maximumValue = 59
        secondsStepper.stepValue = 1
        secondsStepper.addTarget(self, action: #selector(secondsChanged), for: .valueChanged)
        addSubview(secondsLabel)
        addSubview(secondsStepper)
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
                secondsLabel.leadingAnchor.constraint(equalTo: datePicker.trailingAnchor, constant: spacing),
                secondsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                secondsStepper.leadingAnchor.constraint(equalTo: secondsLabel.trailingAnchor, constant: 6),
                secondsStepper.trailingAnchor.constraint(equalTo: trailingAnchor),
                secondsStepper.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        } else {
            constraints += [
                datePicker.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        }
        #elseif canImport(AppKit)
        constraints += [
            datePicker.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        #endif

        NSLayoutConstraint.activate(constraints)

        #if canImport(UIKit)
        secondsLabel.isHidden = !showsSeconds
        secondsStepper.isHidden = !showsSeconds
        #endif
    }

    #if canImport(UIKit)
    private var showsSeconds: Bool {
        switch pickerType {
        case WuiDatePickerType_HourMinuteAndSecond, WuiDatePickerType_DateHourMinuteAndSecond:
            true
        default:
            false
        }
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
            datePicker.datePickerMode = .dateAndTime
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
            datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
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
        updateSecondsControls(seconds: Int(value.second))
        #elseif canImport(AppKit)
        datePicker.dateValue = date
        #endif
    }

    #if canImport(UIKit)
    private func updateSecondsControls(seconds: Int) {
        guard showsSeconds else { return }
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

    private func mergedValue(from pickerDate: Date, current: CWaterUI.WuiDateTime) -> CWaterUI.WuiDateTime {
        let pickerComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: pickerDate)
        let currentComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: wuiDateTimeToDate(current)
        )

        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int

        switch pickerType {
        case WuiDatePickerType_Date:
            year = pickerComponents.year ?? currentComponents.year ?? 2000
            month = pickerComponents.month ?? currentComponents.month ?? 1
            day = pickerComponents.day ?? currentComponents.day ?? 1
            hour = currentComponents.hour ?? 0
            minute = currentComponents.minute ?? 0
            second = currentComponents.second ?? 0
        case WuiDatePickerType_HourAndMinute:
            year = currentComponents.year ?? 2000
            month = currentComponents.month ?? 1
            day = currentComponents.day ?? 1
            hour = pickerComponents.hour ?? currentComponents.hour ?? 0
            minute = pickerComponents.minute ?? currentComponents.minute ?? 0
            second = currentComponents.second ?? 0
        case WuiDatePickerType_HourMinuteAndSecond:
            year = currentComponents.year ?? 2000
            month = currentComponents.month ?? 1
            day = currentComponents.day ?? 1
            hour = pickerComponents.hour ?? currentComponents.hour ?? 0
            minute = pickerComponents.minute ?? currentComponents.minute ?? 0
            #if canImport(UIKit)
            second = Int(secondsStepper.value)
            #elseif canImport(AppKit)
            second = pickerComponents.second ?? currentComponents.second ?? 0
            #endif
        case WuiDatePickerType_DateHourAndMinute:
            year = pickerComponents.year ?? currentComponents.year ?? 2000
            month = pickerComponents.month ?? currentComponents.month ?? 1
            day = pickerComponents.day ?? currentComponents.day ?? 1
            hour = pickerComponents.hour ?? currentComponents.hour ?? 0
            minute = pickerComponents.minute ?? currentComponents.minute ?? 0
            second = currentComponents.second ?? 0
        case WuiDatePickerType_DateHourMinuteAndSecond:
            year = pickerComponents.year ?? currentComponents.year ?? 2000
            month = pickerComponents.month ?? currentComponents.month ?? 1
            day = pickerComponents.day ?? currentComponents.day ?? 1
            hour = pickerComponents.hour ?? currentComponents.hour ?? 0
            minute = pickerComponents.minute ?? currentComponents.minute ?? 0
            #if canImport(UIKit)
            second = Int(secondsStepper.value)
            #elseif canImport(AppKit)
            second = pickerComponents.second ?? currentComponents.second ?? 0
            #endif
        default:
            year = pickerComponents.year ?? currentComponents.year ?? 2000
            month = pickerComponents.month ?? currentComponents.month ?? 1
            day = pickerComponents.day ?? currentComponents.day ?? 1
            hour = pickerComponents.hour ?? currentComponents.hour ?? 0
            minute = pickerComponents.minute ?? currentComponents.minute ?? 0
            second = pickerComponents.second ?? currentComponents.second ?? 0
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
        (
            wuiDateTime.year == -9999
                && wuiDateTime.month == 1
                && wuiDateTime.day == 1
                && wuiDateTime.hour == 0
                && wuiDateTime.minute == 0
                && wuiDateTime.second == 0
        )
            || (
                wuiDateTime.year == 9999
                    && wuiDateTime.month == 12
                    && wuiDateTime.day == 31
                    && wuiDateTime.hour == 23
                    && wuiDateTime.minute == 59
                    && wuiDateTime.second == 59
            )
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
