import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<LifeCycleHook>.
///
/// Handles lifecycle events (appear/disappear) for the wrapped view.
/// The handler is called once and then consumed (one-time handler).
@MainActor
final class WuiLifeCycleHook: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_lifecycle_hook_id() }

    private let contentView: any WuiComponent
    private let env: WuiEnvironment
    private let lifecycle: WuiLifeCycle
    private var handlerPtr: OpaquePointer?
    private var hasCalledHandler = false

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_lifecycle_hook(anyview)

        self.env = env
        self.lifecycle = metadata.value.lifecycle
        self.handlerPtr = metadata.value.handler

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    #if canImport(UIKit)
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            handleAppear()
        } else {
            handleDisappear()
        }
    }
    #elseif canImport(AppKit)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            handleAppear()
        } else {
            handleDisappear()
        }
    }
    #endif

    private func handleAppear() {
        guard !hasCalledHandler else { return }
        if lifecycle == WuiLifeCycle_Appear, let handler = handlerPtr {
            hasCalledHandler = true
            waterui_call_lifecycle_hook(handler, env.inner)
            handlerPtr = nil
        }
    }

    private func handleDisappear() {
        guard !hasCalledHandler else { return }
        if lifecycle == WuiLifeCycle_Disappear, let handler = handlerPtr {
            hasCalledHandler = true
            waterui_call_lifecycle_hook(handler, env.inner)
            handlerPtr = nil
        }
    }

    @MainActor deinit {
        // If handler was never called, drop it to avoid memory leak
        if let handler = handlerPtr, !hasCalledHandler {
            waterui_drop_lifecycle_hook(handler)
        }
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
