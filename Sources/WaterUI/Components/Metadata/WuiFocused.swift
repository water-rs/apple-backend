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
    private let binding: WuiBinding<Bool>
    private var focusWatcher: WatcherGuard?

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_focused(anyview)

        self.binding = WuiBinding<Bool>(metadata.value.binding)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Watch for focus changes from the binding
        focusWatcher = binding.watch { [weak self] isFocused, _ in
            guard let self else { return }
            self.handleFocusChange(isFocused)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func handleFocusChange(_ shouldFocus: Bool) {
        #if canImport(UIKit)
        if shouldFocus {
            // Find the first responder-capable subview and make it first responder
            if let firstResponder = findFirstResponder(in: contentView) {
                firstResponder.becomeFirstResponder()
            }
        } else {
            endEditing(true)
        }
        #elseif canImport(AppKit)
        if shouldFocus {
            if let firstResponder = findFirstResponder(in: contentView) {
                window?.makeFirstResponder(firstResponder)
            }
        } else {
            window?.makeFirstResponder(nil)
        }
        #endif
    }

    #if canImport(UIKit)
    private func findFirstResponder(in view: UIView) -> UIView? {
        if view.canBecomeFirstResponder {
            return view
        }
        for subview in view.subviews {
            if let responder = findFirstResponder(in: subview) {
                return responder
            }
        }
        return nil
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            binding.set(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            binding.set(false)
        }
        return result
    }
    #elseif canImport(AppKit)
    private func findFirstResponder(in view: NSView) -> NSView? {
        if view.acceptsFirstResponder {
            return view
        }
        for subview in view.subviews {
            if let responder = findFirstResponder(in: subview) {
                return responder
            }
        }
        return nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            binding.set(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            binding.set(false)
        }
        return result
    }
    #endif

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
