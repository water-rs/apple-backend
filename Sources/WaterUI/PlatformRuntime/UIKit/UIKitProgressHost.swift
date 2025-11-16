#if canImport(UIKit)
import UIKit
import CWaterUI

@MainActor
final class UIKitProgressHost: UIView, WaterUILayoutMeasurable {
    private let stack = UIStackView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var watcher: WatcherGuard?

    private var labelView: PlatformView
    private var value: WuiComputed<Double>
    private var style: WuiProgressStyle

    var descriptor: PlatformViewDescriptor {
        PlatformViewDescriptor(typeId: WuiProgress.id, isSpacer: false)
    }

    init(label: PlatformView, value: WuiComputed<Double>, style: WuiProgressStyle) {
        self.labelView = label
        self.value = value
        self.style = style
        super.init(frame: .zero)
        configureStack()
        updateAppearance(for: value.value)
        startWatcher()
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
        return stack.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: horizontalPriority,
            verticalFittingPriority: verticalPriority
        )
    }

    func updateLabel(_ newLabel: PlatformView) {
        guard newLabel !== labelView else { return }
        stack.removeArrangedSubview(labelView)
        labelView.removeFromSuperview()
        newLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.insertArrangedSubview(newLabel, at: 0)
        labelView = newLabel
    }

    func updateValueSource(_ newValue: WuiComputed<Double>) {
        guard newValue !== value else { return }
        watcher = nil
        value = newValue
        updateAppearance(for: newValue.value)
        startWatcher()
    }

    func updateStyle(_ newStyle: WuiProgressStyle) {
        style = newStyle
        updateAppearance(for: value.value)
    }

    private func configureStack() {
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        labelView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(labelView)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true

        stack.addArrangedSubview(progressView)
        stack.addArrangedSubview(activityIndicator)
    }

    private func startWatcher() {
        watcher = value.watch { [weak self] newValue, metadata in
            guard let self else { return }
            let animated = metadata.getAnimation() != nil
            updateAppearance(for: newValue, animated: animated)
        }
    }

    private func updateAppearance(for value: Double, animated: Bool = false) {
        let isIndeterminate = value.isInfinite || style == WuiProgressStyle_Circular
        if isIndeterminate {
            progressView.isHidden = true
            activityIndicator.isHidden = false
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
            activityIndicator.isHidden = true
            progressView.isHidden = false
            let clamped = Float(min(max(value, 0.0), 1.0))
            if animated {
                UIView.animate(withDuration: 0.2) {
                    self.progressView.progress = clamped
                }
            } else {
                progressView.progress = clamped
            }
        }
    }
}
#endif
