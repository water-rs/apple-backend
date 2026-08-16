import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<Focused>.
///
/// Tracks and manages focus state for the wrapped view.
@MainActor
final class WuiFocused: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_focused_id() }

    private let contentView: any WuiComponent
    private var bindingController: WuiFocusedBindingController?

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_focused(anyview)
        let binding = WuiBinding<Bool>(metadata.value.binding)
        let contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        self.contentView = contentView

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        let focusTarget = contentView.requireSingleWuiFocusTarget()
        bindingController = WuiFocusedBindingController(
            container: self,
            focusTarget: focusTarget,
            binding: binding
        )
        bindingController?.syncRequestedFocusState()
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
    override func didMoveToWindow() {
        super.didMoveToWindow()
        bindingController?.syncRequestedFocusState()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds
    }
    #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bindingController?.syncRequestedFocusState()
    }

    override func layout() {
        super.layout()
        contentView.frame = bounds
    }
    #endif
}
