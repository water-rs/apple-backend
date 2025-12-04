import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Retain>.
///
/// This component keeps a retained value alive for the lifetime of the view.
/// The retained value is opaque - we just need to hold onto it and drop it when disposed.
@MainActor
final class WuiRetain: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_retain_id() }

    private let contentView: any WuiComponent
    private var retainedValue: WuiRetainValue?

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_retain(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        // Keep the retained value alive
        self.retainedValue = WuiRetainValue(metadata.value)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)
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
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
    }
    #endif
}

/// Wrapper to hold the retained value and drop it on deinit.
private final class WuiRetainValue {
    private let value: CWaterUI.WuiRetain

    init(_ value: CWaterUI.WuiRetain) {
        self.value = value
    }

    deinit {
        waterui_drop_retain(value)
    }
}
