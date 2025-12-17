// WuiNavigationView.swift
// Navigation view component with navigation bar
//
// # Layout Behavior
// NavigationView stretches to fill available space (greedy).
// Contains a navigation bar and content area.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiNavigationView: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_navigation_view_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private var titleLabel: PlatformLabel
    private var contentView: WuiAnyView
    private let env: WuiEnvironment

    // Reactive watchers
    private var colorWatcher: WatcherGuard?
    private var hiddenWatcher: WatcherGuard?

    // Bar configuration
    private var barColor: WuiComputed<WuiResolvedColor>?
    private var barHidden: WuiComputed<Bool>?

    // Navigation support
    private var hasNavigationController: Bool = false

    #if canImport(UIKit)
    private let navBarHeight: CGFloat = 44.0
    private let navBarView: UIView = UIView()
    private var backButton: UIButton?
    #elseif canImport(AppKit)
    private let navBarHeight: CGFloat = 38.0
    private let navBarView: NSView = NSView()
    private var backButton: NSButton?
    #endif

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiNav: CWaterUI.WuiNavigationView = waterui_force_as_navigation_view(anyview)
        self.init(ffiNav: ffiNav, env: env)
    }

    /// Initialize from FFI struct directly (used by NavigationStack when pushing)
    convenience init(ffiNav: CWaterUI.WuiNavigationView, env: WuiEnvironment) {
        let contentView = WuiAnyView(anyview: ffiNav.content, env: env)

        // Extract bar configuration - read title from computed styled string
        var titleString = ""
        if let contentPtr = ffiNav.bar.title.content {
            let titleContent = WuiComputed<WuiStyledStr>(contentPtr)
            titleString = titleContent.value.toString()
        }

        // Check if we're inside a navigation stack
        let hasNavController = waterui_env_has_navigation_controller(env.inner)

        self.init(
            title: titleString,
            content: contentView,
            colorPtr: ffiNav.bar.color,
            hiddenPtr: ffiNav.bar.hidden,
            env: env,
            hasNavigationController: hasNavController
        )
    }

    // MARK: - Designated Init

    init(
        title: String,
        content: WuiAnyView,
        colorPtr: OpaquePointer?,
        hiddenPtr: OpaquePointer?,
        env: WuiEnvironment,
        hasNavigationController: Bool
    ) {
        self.contentView = content
        self.env = env
        self.hasNavigationController = hasNavigationController

        #if canImport(UIKit)
        self.titleLabel = UILabel()
        #elseif canImport(AppKit)
        self.titleLabel = NSTextField(labelWithString: "")
        #endif

        super.init(frame: .zero)

        configureNavBar(title: title)
        configureContent()
        setupColorWatcher(colorPtr: colorPtr)
        setupHiddenWatcher(hiddenPtr: hiddenPtr)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configureNavBar(title: String) {
        // When inside a NavigationStack, native navigation chrome handles the bar.
        // - iOS: UINavigationController provides native nav bar with back button and swipe gesture
        // - macOS: Window toolbar provides back button
        // Hide the custom nav bar entirely in both cases.
        if hasNavigationController {
            navBarView.isHidden = true
            return
        }

        navBarView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(navBarView)

        #if canImport(UIKit)
        navBarView.backgroundColor = .systemBackground
        titleLabel.text = title
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textAlignment = .center
        #elseif canImport(AppKit)
        navBarView.wantsLayer = true
        navBarView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        titleLabel.stringValue = title
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.alignment = .center
        titleLabel.isBordered = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false

        // Add back button if NOT inside navigation stack (standalone NavigationView)
        // When inside NavigationStack, the toolbar provides back button
        let button = NSButton(title: "< Back", target: self, action: #selector(backButtonTapped))
        button.bezelStyle = .inline
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = true
        navBarView.addSubview(button)
        self.backButton = button
        #endif

        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        navBarView.addSubview(titleLabel)

        // Add bottom border
        #if canImport(UIKit)
        let border = UIView()
        border.backgroundColor = .separator
        border.translatesAutoresizingMaskIntoConstraints = true
        navBarView.addSubview(border)
        #elseif canImport(AppKit)
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor.separatorColor.cgColor
        border.translatesAutoresizingMaskIntoConstraints = true
        navBarView.addSubview(border)
        #endif
    }

    @objc private func backButtonTapped() {
        waterui_navigation_pop(env.inner)
    }

    private func configureContent() {
        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)
    }

    private func setupColorWatcher(colorPtr: OpaquePointer?) {
        guard let colorPtr = colorPtr else { return }

        // Read the Color from Computed<Color>, then resolve it to get Computed<ResolvedColor>
        let color = WuiColor(waterui_read_computed_color(colorPtr)!)
        let resolved = color.resolve(in: env)
        self.barColor = resolved

        applyBarColor(resolved.value)

        colorWatcher = resolved.watch { [weak self] color, metadata in
            guard let self = self else { return }
            withPlatformAnimation(metadata) {
                self.applyBarColor(color)
            }
        }
    }

    private func setupHiddenWatcher(hiddenPtr: OpaquePointer?) {
        guard let hiddenPtr = hiddenPtr else { return }

        let hidden = WuiComputed<Bool>(hiddenPtr)
        self.barHidden = hidden

        applyBarHidden(hidden.value)

        hiddenWatcher = hidden.watch { [weak self] hidden, _ in
            self?.applyBarHidden(hidden)
        }
    }

    private func applyBarColor(_ color: WuiResolvedColor) {
        #if canImport(UIKit)
        navBarView.backgroundColor = color.toUIColor()
        #elseif canImport(AppKit)
        navBarView.layer?.backgroundColor = color.toNSColor().cgColor
        #endif
    }

    private func applyBarHidden(_ hidden: Bool) {
        navBarView.isHidden = hidden
        #if canImport(UIKit)
        setNeedsLayout()
        layoutIfNeeded()
        #elseif canImport(AppKit)
        needsLayout = true
        #endif
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // NavigationView takes all available space
        let width = proposal.width.map { CGFloat($0) } ?? 320
        let height = proposal.height.map { CGFloat($0) } ?? 480
        return CGSize(width: width, height: height)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        performLayout()
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        performLayout()
    }
    #endif

    private func performLayout() {
        let barHeight = navBarView.isHidden ? 0 : navBarHeight

        // Position nav bar at top
        navBarView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)

        // Position back button on the left
        if let backButton = backButton {
            let buttonSize = backButton.sizeThatFits(CGSize(width: 100, height: barHeight))
            backButton.frame = CGRect(
                x: 12,
                y: (barHeight - buttonSize.height) / 2,
                width: buttonSize.width,
                height: buttonSize.height
            )
        }

        // Center title in nav bar
        let titleSize = titleLabel.sizeThatFits(CGSize(width: bounds.width - 150, height: barHeight))
        titleLabel.frame = CGRect(
            x: (bounds.width - titleSize.width) / 2,
            y: (barHeight - titleSize.height) / 2,
            width: titleSize.width,
            height: titleSize.height
        )

        // Position border at bottom of nav bar
        if let border = navBarView.subviews.last, border !== titleLabel && border !== backButton {
            border.frame = CGRect(x: 0, y: barHeight - 1, width: bounds.width, height: 1)
        }

        // Position content below nav bar
        let contentY = barHeight
        let contentHeight = bounds.height - barHeight
        contentView.frame = CGRect(x: 0, y: contentY, width: bounds.width, height: contentHeight)
    }
}
