// WuiDatePicker.swift
// DatePicker component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// DatePicker sizes itself to fit its content and never stretches to fill extra space.
// In a stack, it takes only the space it needs.

import CWaterUI
import os.log

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "WuiDatePicker")

@MainActor
final class WuiDatePicker: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_date_picker_id() }

    #if canImport(UIKit)
    private let datePicker = UIDatePicker()
    #elseif canImport(AppKit)
    private let datePicker = NSDatePicker()
    #endif

    private var labelView: WuiAnyView
    private var binding: WuiBinding<CWaterUI.WuiDate>
    private var bindingWatcher: WatcherGuard?
    private var isSyncingFromBinding = false

    private let spacing: CGFloat = 8.0
    private let calendar = Calendar(identifier: .gregorian)

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiDatePicker: CWaterUI.WuiDatePicker = waterui_force_as_date_picker(anyview)
        let labelView = WuiAnyView(anyview: ffiDatePicker.label, env: env)
        let binding = WuiBinding<CWaterUI.WuiDate>(ffiDatePicker.value)
        let pickerType = ffiDatePicker.ty
        let range = ffiDatePicker.range
        self.init(label: labelView, binding: binding, pickerType: pickerType, range: range)
    }

    // MARK: - Designated Init

    init(label: WuiAnyView, binding: WuiBinding<CWaterUI.WuiDate>, pickerType: CWaterUI.WuiDatePickerType, range: CWaterUI.WuiRange_WuiDate) {
        self.labelView = label
        self.binding = binding
        super.init(frame: .zero)
        configureSubviews()
        configureDatePicker(pickerType: pickerType, range: range)
        startBindingWatcher()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        #if canImport(UIKit)
        let pickerSize = datePicker.intrinsicContentSize
        #elseif canImport(AppKit)
        let pickerSize = datePicker.intrinsicContentSize
        #endif
        let hasLabel = labelSize.width > 0 && labelSize.height > 0

        var totalWidth: CGFloat = pickerSize.width
        var maxHeight: CGFloat = pickerSize.height

        if hasLabel {
            totalWidth += spacing + labelSize.width
            maxHeight = max(maxHeight, labelSize.height)
        }

        return CGSize(width: totalWidth, height: maxHeight)
    }

    // MARK: - Layout

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif

    // MARK: - Configuration

    private func configureSubviews() {
        labelView.translatesAutoresizingMaskIntoConstraints = false
        datePicker.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelView)
        addSubview(datePicker)

        #if canImport(UIKit)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        #elseif canImport(AppKit)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        #endif

        NSLayoutConstraint.activate([
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelView.centerYAnchor.constraint(equalTo: centerYAnchor),

            datePicker.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: spacing),
            datePicker.trailingAnchor.constraint(equalTo: trailingAnchor),
            datePicker.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func configureDatePicker(pickerType: CWaterUI.WuiDatePickerType, range: CWaterUI.WuiRange_WuiDate) {
        // Set date picker mode based on type
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

        // Set min/max dates
        datePicker.minimumDate = wuiDateToDate(range.start)
        datePicker.maximumDate = wuiDateToDate(range.end)

        // Set initial value
        datePicker.date = wuiDateToDate(binding.value)

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

        // Set min/max dates
        datePicker.minDate = wuiDateToDate(range.start)
        datePicker.maxDate = wuiDateToDate(range.end)

        // Set initial value
        datePicker.dateValue = wuiDateToDate(binding.value)

        datePicker.target = self
        datePicker.action = #selector(dateChanged)
        #endif
    }

    private func startBindingWatcher() {
        bindingWatcher = binding.watch { [weak self] newValue, _ in
            guard let self, !isSyncingFromBinding else { return }
            isSyncingFromBinding = true
            let date = wuiDateToDate(newValue)
            #if canImport(UIKit)
            datePicker.date = date
            #elseif canImport(AppKit)
            datePicker.dateValue = date
            #endif
            isSyncingFromBinding = false
        }
    }

    @objc private func dateChanged() {
        guard !isSyncingFromBinding else { return }
        #if canImport(UIKit)
        let date = datePicker.date
        #elseif canImport(AppKit)
        let date = datePicker.dateValue
        #endif
        binding.value = dateToWuiDate(date)
    }

    // MARK: - Date Conversion

    private func wuiDateToDate(_ wuiDate: CWaterUI.WuiDate) -> Date {
        var components = DateComponents()
        components.year = Int(wuiDate.year)
        components.month = Int(wuiDate.month)
        components.day = Int(wuiDate.day)
        return calendar.date(from: components) ?? Date()
    }

    private func dateToWuiDate(_ date: Date) -> CWaterUI.WuiDate {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return CWaterUI.WuiDate(
            year: Int32(components.year ?? 2000),
            month: UInt8(components.month ?? 1),
            day: UInt8(components.day ?? 1)
        )
    }
}
