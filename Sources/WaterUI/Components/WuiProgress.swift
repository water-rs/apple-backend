// WuiProgress.swift
// Progress indicator component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Linear progress expands horizontally to fill available width (fixed height).
// Circular progress is content-sized (fixed spinner dimensions).
// Use frame modifiers to constrain size if needed.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .horizontal for linear, .none for circular
// // - sizeThatFits: Linear returns proposed width (min 50pt); Circular returns spinner size
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiProgress: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_progress_id() }

    private(set) var stretchAxis: WuiStretchAxis

    #if canImport(UIKit)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    #elseif canImport(AppKit)
    private let progressIndicator = NSProgressIndicator()
    #endif
    private var watcher: WatcherGuard?

    private var labelView: WuiAnyView
    private var value: WuiComputed<Double>
    private var style: WuiProgressStyle

    // Layout constants
    private let verticalSpacing: CGFloat = 6.0

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiProgress: CWaterUI.WuiProgress = waterui_force_as_progress(anyview)
        let labelView = WuiAnyView(anyview: ffiProgress.label, env: env)
        let value = WuiComputed<Double>(ffiProgress.value)
        self.init(stretchAxis: stretchAxis, label: labelView, value: value, style: ffiProgress.style)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, label: WuiAnyView, value: WuiComputed<Double>, style: WuiProgressStyle) {
        self.stretchAxis = stretchAxis
        self.labelView = label
        self.value = value
        self.style = style
        super.init(frame: .zero)
        configureSubviews()
        updateAppearance(for: value.value)
        startWatcher()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Per LAYOUT_SPEC.md:
        // - Linear ProgressView: axis-expanding (width expands, height intrinsic)
        // - Circular ProgressView: fixed size (platform-native spinner)

        let isCircular = style == WuiProgressStyle_Circular

        if isCircular {
            #if canImport(UIKit)
            let spinnerSize = activityIndicator.intrinsicContentSize
            return CGSize(
                width: proposal.width.map { CGFloat($0) } ?? spinnerSize.width,
                height: proposal.height.map { CGFloat($0) } ?? spinnerSize.height
            )
            #elseif canImport(AppKit)
            let spinnerSize = CGSize(width: 20, height: 20)
            return CGSize(
                width: proposal.width.map { CGFloat($0) } ?? spinnerSize.width,
                height: proposal.height.map { CGFloat($0) } ?? spinnerSize.height
            )
            #endif
        }

        // Linear progress: axis-expanding on width per LAYOUT_SPEC.md
        // It uses isStretch: true to expand, so here we report MINIMUM usable size
        let labelSize = labelView.sizeThatFits(WuiProposalSize())

        #if canImport(UIKit)
        let progressHeight = progressView.intrinsicContentSize.height
        #elseif canImport(AppKit)
        let progressHeight = progressIndicator.intrinsicContentSize.height
        #endif

        // Intrinsic height: label height + spacing + progress bar height
        let intrinsicHeight = labelSize.height + verticalSpacing + progressHeight

        // For width: report MINIMUM usable size
        // The minimum width ensures label fits and progress bar is visible
        let minProgressWidth: CGFloat = 50.0
        let minWidth = max(labelSize.width, minProgressWidth)

        // When width is proposed, use it (but not less than minimum)
        // When None, return minimum - isStretch:true will expand it to fill remaining space
        let width = proposal.width.map { max(CGFloat($0), minWidth) } ?? minWidth
        let height = proposal.height.map { CGFloat($0) } ?? intrinsicHeight

        return CGSize(width: width, height: max(height, intrinsicHeight))
    }

    // MARK: - Layout

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        performLayout()
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
        performLayout()
    }

    override var isFlipped: Bool { true }
    #endif

    /// Shared layout logic for both UIKit and AppKit
    private func performLayout() {
        let boundsWidth = bounds.width
        let boundsHeight = bounds.height

        let isCircular = style == WuiProgressStyle_Circular

        if isCircular {
            // Circular: center the spinner, hide label and linear progress
            #if canImport(UIKit)
            let spinnerSize = activityIndicator.intrinsicContentSize
            activityIndicator.frame = CGRect(
                x: (boundsWidth - spinnerSize.width) / 2,
                y: (boundsHeight - spinnerSize.height) / 2,
                width: spinnerSize.width,
                height: spinnerSize.height
            )
            progressView.frame = .zero
            labelView.frame = .zero
            #elseif canImport(AppKit)
            let spinnerSize = CGSize(width: 20, height: 20)
            progressIndicator.frame = CGRect(
                x: (boundsWidth - spinnerSize.width) / 2,
                y: (boundsHeight - spinnerSize.height) / 2,
                width: spinnerSize.width,
                height: spinnerSize.height
            )
            labelView.frame = .zero
            #endif
            return
        }

        // Linear progress: label at top, progress bar below
        let labelSize = labelView.sizeThatFits(WuiProposalSize())

        #if canImport(UIKit)
        let progressHeight = progressView.intrinsicContentSize.height
        #elseif canImport(AppKit)
        let progressHeight = progressIndicator.intrinsicContentSize.height
        #endif

        // Layout label at top
        labelView.frame = CGRect(
            x: 0,
            y: 0,
            width: labelSize.width,
            height: labelSize.height
        )

        // Layout progress bar below label
        let progressY = labelSize.height + verticalSpacing
        #if canImport(UIKit)
        progressView.frame = CGRect(
            x: 0,
            y: progressY,
            width: boundsWidth,
            height: progressHeight
        )
        activityIndicator.frame = .zero
        #elseif canImport(AppKit)
        progressIndicator.frame = CGRect(
            x: 0,
            y: progressY,
            width: boundsWidth,
            height: progressHeight
        )
        #endif
    }

    // MARK: - Update Methods

    func updateLabel(_ newLabel: WuiAnyView) {
        guard newLabel !== labelView else { return }
        labelView.removeFromSuperview()
        addSubview(newLabel)
        labelView = newLabel
        setNeedsLayoutCompat()
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
        setNeedsLayoutCompat()
    }

    // MARK: - Configuration

    private func configureSubviews() {
        // Manual frame layout - just add subviews, performLayout() will position them
        addSubview(labelView)

        #if canImport(UIKit)
        activityIndicator.hidesWhenStopped = true
        addSubview(progressView)
        addSubview(activityIndicator)
        #elseif canImport(AppKit)
        addSubview(progressIndicator)
        #endif
    }

    private func startWatcher() {
        watcher = value.watch { [weak self] newValue, metadata in
            guard let self else { return }
            let animated = metadata.getAnimation() != nil
            updateAppearance(for: newValue, animated: animated)
        }
    }

    private func setNeedsLayoutCompat() {
        #if canImport(UIKit)
        setNeedsLayout()
        #elseif canImport(AppKit)
        needsLayout = true
        #endif
    }

    private func updateAppearance(for value: Double, animated: Bool = false) {
        let isIndeterminate = value.isInfinite || style == WuiProgressStyle_Circular

        #if canImport(UIKit)
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
        #elseif canImport(AppKit)
        if isIndeterminate {
            progressIndicator.style = .spinning
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
            progressIndicator.style = .bar
            progressIndicator.isIndeterminate = false
            progressIndicator.minValue = 0.0
            progressIndicator.maxValue = 1.0
            let clamped = min(max(value, 0.0), 1.0)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.allowsImplicitAnimation = true
                    progressIndicator.doubleValue = clamped
                }
            } else {
                progressIndicator.doubleValue = clamped
            }
        }
        #endif
    }
}
