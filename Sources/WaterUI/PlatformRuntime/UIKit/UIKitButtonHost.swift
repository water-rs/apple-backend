#if canImport(UIKit)
import UIKit

@MainActor
final class UIKitButtonHost: UIView, WaterUILayoutMeasurable {
    private let button: UIButton = .init(type: .system)
    private let labelContainer = UIView()
    private var action: Action
    private var labelView: PlatformView

    var descriptor: PlatformViewDescriptor {
        PlatformViewDescriptor(typeId: WuiButton.id, isSpacer: false)
    }

    init(label: PlatformView, action: Action) {
        self.action = action
        self.labelView = label
        super.init(frame: .zero)
        configureButton()
        embedLabel(label)
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
        return button.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: horizontalPriority,
            verticalFittingPriority: verticalPriority
        )
    }

    func updateLabel(_ newLabel: PlatformView) {
        guard labelView !== newLabel else { return }
        labelContainer.subviews.forEach { $0.removeFromSuperview() }
        labelView = newLabel
        embedLabel(newLabel)
    }

    private func configureButton() {
        button.translatesAutoresizingMaskIntoConstraints = false
        labelContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        button.addSubview(labelContainer)
        NSLayoutConstraint.activate([
            labelContainer.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 8),
            labelContainer.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
            labelContainer.topAnchor.constraint(equalTo: button.topAnchor, constant: 4),
            labelContainer.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -4)
        ])

        button.addTarget(self, action: #selector(didTap), for: .touchUpInside)
    }

    private func embedLabel(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        labelContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: labelContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: labelContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: labelContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: labelContainer.bottomAnchor)
        ])
    }

    @objc
    private func didTap() {
        action.call()
    }
}
#endif
