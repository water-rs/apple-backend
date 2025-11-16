#if canImport(UIKit)
import UIKit
import CWaterUI

@MainActor
final class UIKitTextHost: UIView, WaterUILayoutMeasurable {
    private let label = UILabel()
    private var content: WuiComputed<WuiStyledStr>
    private var env: WuiEnvironment
    private var watcher: WatcherGuard?

    var descriptor: PlatformViewDescriptor {
        PlatformViewDescriptor(typeId: WuiText.id, isSpacer: false)
    }

    init(content: WuiComputed<WuiStyledStr>, env: WuiEnvironment) {
        self.content = content
        self.env = env
        super.init(frame: .zero)
        configureLabel()
        applyText(content.value)
        startWatching()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> UInt8 { 0 }

    func measure(in proposal: WuiProposalSize) -> CGSize {
        let targetWidth = proposal.width.map { CGFloat($0) } ?? UIView.noIntrinsicMetric
        let targetHeight = proposal.height.map { CGFloat($0) } ?? UIView.noIntrinsicMetric
        let fittingSize = CGSize(
            width: targetWidth == UIView.noIntrinsicMetric ? UIView.layoutFittingCompressedSize.width : targetWidth,
            height: targetHeight == UIView.noIntrinsicMetric ? UIView.layoutFittingCompressedSize.height : targetHeight
        )
        let horizontalPriority: UILayoutPriority =
            targetWidth == UIView.noIntrinsicMetric ? .fittingSizeLevel : .required
        let verticalPriority: UILayoutPriority =
            targetHeight == UIView.noIntrinsicMetric ? .fittingSizeLevel : .required
        return label.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: horizontalPriority,
            verticalFittingPriority: verticalPriority
        )
    }

    private func configureLabel() {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func startWatching() {
        watcher = content.watch { [weak self] value, metadata in
            guard let self else { return }
            if metadata.getAnimation() != nil {
                UIView.transition(
                    with: label,
                    duration: 0.15,
                    options: .transitionCrossDissolve,
                    animations: { self.applyText(value) }
                )
            } else {
                self.applyText(value)
            }
        }
    }

    private func applyText(_ styled: WuiStyledStr) {
        let attributed = NSAttributedString(styled.toAttributedString(env: env))
        label.attributedText = attributed
    }
}
#endif
