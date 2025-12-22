import CWaterUI
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
private enum WuiDynamicRangeMode {
    case standard
    case high
}

@MainActor
private func applyDynamicRange(_ mode: WuiDynamicRangeMode, to layer: CALayer?) {
    guard let layer else { return }

    #if canImport(UIKit)
    if #available(iOS 26.0, tvOS 26.0, visionOS 26.0, watchOS 26.0, macCatalyst 26.0, *) {
        layer.preferredDynamicRange = (mode == .high) ? .high : .standard
    } else if #available(iOS 17.0, macCatalyst 17.0, *) {
        layer.wantsExtendedDynamicRangeContent = (mode == .high)
    }
    #elseif canImport(AppKit)
    if #available(macOS 26.0, *) {
        layer.preferredDynamicRange = (mode == .high) ? .high : .standard
    } else if #available(macOS 14.0, *) {
        layer.wantsExtendedDynamicRangeContent = (mode == .high)
    }
    #endif

    if let sublayers = layer.sublayers {
        for sublayer in sublayers {
            applyDynamicRange(mode, to: sublayer)
        }
    }
}

@MainActor
private func applyDynamicRange(_ mode: WuiDynamicRangeMode, to view: PlatformView) {
    #if canImport(AppKit)
    view.wantsLayer = true
    #endif
    applyDynamicRange(mode, to: view.layer)
}

/// Component for Metadata<StandardDynamicRange>.
@MainActor
final class WuiStandardDynamicRange: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_standard_dynamic_range_id() }

    private let contentView: any WuiComponent

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_standard_dynamic_range(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        applyDynamicRange(.standard, to: self)
        applyDynamicRange(.standard, to: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        contentView.sizeThatFits(proposal)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds
        applyDynamicRange(.standard, to: self)
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
        applyDynamicRange(.standard, to: self)
    }
    #endif
}

/// Component for Metadata<HighDynamicRange>.
@MainActor
final class WuiHighDynamicRange: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_high_dynamic_range_id() }

    private let contentView: any WuiComponent

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_high_dynamic_range(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        applyDynamicRange(.high, to: self)
        applyDynamicRange(.high, to: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        contentView.sizeThatFits(proposal)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds
        applyDynamicRange(.high, to: self)
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
        applyDynamicRange(.high, to: self)
    }
    #endif
}
