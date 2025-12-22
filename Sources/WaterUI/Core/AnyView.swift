//
//  AnyView.swift
//
//
//  Created by Lexo Liu on 8/1/24.
//

import CWaterUI
import Foundation
import os

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// MARK: - Component Registry

/// Internal registry for component factories using pointer-based ID lookup
@MainActor
private var componentRegistry: [WuiViewId: (OpaquePointer, WuiEnvironment) -> any WuiComponent] =
    [:]

/// Set of metadata component IDs (components that wrap content but aren't "real" content themselves)
@MainActor
private var metadataComponentIds: Set<WuiViewId> = []

/// Internal flag to track if builtin components have been registered
@MainActor
private var builtinComponentsRegistered = false

/// Register a component type that conforms to WuiComponent.
@MainActor
private func registerComponent<T: WuiComponent>(_ type: T.Type) {
    let viewId = type.viewId
    componentRegistry[viewId] = { anyview, env in
        type.init(anyview: anyview, env: env)
    }
}

/// Register a metadata component type (wrappers that modify env/appearance but aren't content).
@MainActor
private func registerMetadataComponent<T: WuiComponent>(_ type: T.Type) {
    registerComponent(type)
    metadataComponentIds.insert(type.viewId)
}

// MARK: - Root Theme Controller

#if canImport(UIKit)
    typealias PlatformWindow = UIWindow
#elseif canImport(AppKit)
    typealias PlatformWindow = NSWindow
#endif

/// Controls the window's appearance based on the root component's environment theme.
@MainActor
final class RootThemeController {
    private var colorSchemeSignal: OpaquePointer?
    private var watcherGuard: WatcherGuard?
    private weak var view: PlatformView?
    private var currentScheme: WuiColorScheme?

    init(env: WuiEnvironment, view: PlatformView) {
        self.view = view
        setupColorSchemeWatcher(env: env)
    }

    private func setupColorSchemeWatcher(env: WuiEnvironment) {
        guard let signal = waterui_theme_color_scheme(env.inner) else {
            return
        }

        // Keep signal alive
        self.colorSchemeSignal = signal

        // Apply initial value
        let initial = waterui_read_computed_color_scheme(signal)
        applyColorScheme(initial)

        // Watch for changes
        let watcher = makeColorSchemeWatcher { [weak self] scheme, _ in
            self?.applyColorScheme(scheme)
        }

        if let guard_ = waterui_watch_computed_color_scheme(signal, watcher) {
            self.watcherGuard = WatcherGuard(guard_)
        } else {
            Logger.waterui.error("[RootThemeController] Failed to watch color scheme signal")
        }
    }

    private func applyColorScheme(_ scheme: WuiColorScheme) {
        currentScheme = scheme
        applyToWindow()
    }

    /// Called when the view is added to window
    func applyToWindow() {
        guard let scheme = currentScheme, let window = view?.window else {
            return
        }

        #if canImport(UIKit)
            let style: UIUserInterfaceStyle =
                switch scheme {
                case WuiColorScheme_Light: .light
                case WuiColorScheme_Dark: .dark
                default: .unspecified
                }
            window.overrideUserInterfaceStyle = style
        #elseif canImport(AppKit)
            let appearance: NSAppearance? =
                switch scheme {
                case WuiColorScheme_Light: NSAppearance(named: .aqua)
                case WuiColorScheme_Dark: NSAppearance(named: .darkAqua)
                default: nil
                }

            // Set appearance on window and all its content
            window.appearance = appearance
            window.contentView?.appearance = appearance

            // Force redraw
            window.contentView?.needsDisplay = true
            window.contentView?.needsLayout = true
            window.viewsNeedDisplay = true
        #endif
    }

    @MainActor deinit {
        if let signal = colorSchemeSignal {
            waterui_drop_computed_color_scheme(signal)
        }
    }
}

/// The current root theme controller (one per app)
@MainActor
private var rootThemeController: RootThemeController?

/// The environment of the root content component
@MainActor
private var pendingRootEnv: WuiEnvironment?

/// Marks the environment as the root content's env (for theme setup)
@MainActor
private func markAsRootContentEnv(_ env: WuiEnvironment) {
    // Only capture the first one
    if pendingRootEnv == nil {
        pendingRootEnv = env
        // Debug: check what color scheme this env has
        if let signal = waterui_theme_color_scheme(env.inner) {
            let scheme = waterui_read_computed_color_scheme(signal)
            waterui_drop_computed_color_scheme(signal)
        }
    }
}

/// Sets up the root theme controller when the view is added to window
@MainActor
func setupRootThemeController(for view: PlatformView) {
    guard rootThemeController == nil, let env = pendingRootEnv else { return }
    rootThemeController = RootThemeController(env: env, view: view)
}

/// Called when window becomes available to apply pending theme
@MainActor
func applyPendingRootTheme() {
    rootThemeController?.applyToWindow()
}

/// Resets the root theme controller (for hot reload).
@MainActor
public func resetRootThemeController() {
    rootThemeController = nil
    pendingRootEnv = nil
}

/// Register builtin components (called once on first WuiAnyView creation)
@MainActor
private func registerBuiltinComponentsIfNeeded() {
    guard !builtinComponentsRegistered else { return }
    builtinComponentsRegistered = true

    // Basic components
    registerComponent(WuiEmpty.self)
    registerComponent(WuiPlain.self)
    registerComponent(WuiText.self)
    registerComponent(WuiSpacer.self)
    registerComponent(WuiColorView.self)
    registerComponent(WuiFilledShape.self)

    // Interactive components
    registerComponent(WuiButton.self)
    // Note: Link uses Button with link style, not a separate native component
    registerComponent(WuiToggle.self)
    registerComponent(WuiSlider.self)
    registerComponent(WuiTextField.self)
    registerComponent(WuiSecureField.self)
    registerComponent(WuiStepper.self)
    registerComponent(WuiDatePicker.self)
    registerComponent(WuiColorPicker.self)
    registerComponent(WuiPicker.self)
    registerComponent(WuiProgress.self)
    registerComponent(WuiMenu.self)

    // Container components
    registerComponent(WuiFixedContainer.self)
    registerComponent(WuiContainer.self)
    registerComponent(WuiScroll.self)
    registerComponent(WuiList.self)
    registerComponent(WuiTable.self)
    // TODO: registerComponent(WuiNavigationView.self)

    // Dynamic components
    registerComponent(WuiDynamic.self)
    // TODO: registerComponent(WuiLazy.self)

    // Metadata components (wrappers that modify env/appearance)
    registerMetadataComponent(WuiWithEnv.self)
    registerMetadataComponent(WuiSecure.self)
    registerMetadataComponent(WuiStandardDynamicRange.self)
    registerMetadataComponent(WuiHighDynamicRange.self)
    registerMetadataComponent(WuiGesture.self)
    registerMetadataComponent(WuiLifeCycleHook.self)
    registerMetadataComponent(WuiOnEvent.self)
    registerMetadataComponent(WuiCursor.self)
    registerMetadataComponent(WuiBackground.self)
    registerMetadataComponent(WuiForeground.self)
    registerMetadataComponent(WuiShadow.self)
    registerMetadataComponent(WuiClipShape.self)
    registerMetadataComponent(WuiScale.self)
    registerMetadataComponent(WuiRotation.self)
    registerMetadataComponent(WuiOffset.self)
    registerMetadataComponent(WuiFocused.self)
    registerMetadataComponent(WuiIgnoreSafeArea.self)
    registerMetadataComponent(WuiRetain.self)
    registerMetadataComponent(WuiContextMenu.self)

    // Filter components
    registerMetadataComponent(WuiBlur.self)
    registerMetadataComponent(WuiBrightness.self)
    registerMetadataComponent(WuiSaturation.self)
    registerMetadataComponent(WuiContrast.self)
    registerMetadataComponent(WuiHueRotation.self)
    registerMetadataComponent(WuiGrayscale.self)
    registerMetadataComponent(WuiOpacity.self)

    // Media components
    registerComponent(WuiPhoto.self)
    registerComponent(WuiVideo.self)
    registerComponent(WuiVideoPlayer.self)
    // WuiMediaPicker removed - now uses Button wrapper in Rust

    // Navigation components
    registerComponent(WuiNavigationStack.self)
    registerComponent(WuiNavigationView.self)
    registerComponent(WuiTabs.self)

    // Renderer components
    // TODO: registerComponent(WuiRendererView.self)

    // GPU components
    registerComponent(WuiGpuSurface.self)

    // WebView component
    registerComponent(WuiWebViewComponent.self)
}

// MARK: - WuiAnyView

#if canImport(UIKit)
    /// The entry point for WaterUI views from Rust.
    /// Resolves an opaque FFI pointer into a concrete WuiComponent at initialization time.
    @MainActor
    public final class WuiAnyView: UIView, WuiComponent {
        public static var rawId: CWaterUI.WuiTypeId { waterui_anyview_id() }

        /// The resolved inner component - never nil after initialization
        private let inner: any WuiComponent
        private var lastAutoLayoutWidth: CGFloat = 0

        public var stretchAxis: WuiStretchAxis {
            inner.stretchAxis
        }

        /// Creates a WuiAnyView by resolving an opaque FFI pointer to a concrete component.
        /// This is the public interface for creating WaterUI views from Rust pointers.
        public init(anyview: OpaquePointer, env: WuiEnvironment) {
            registerBuiltinComponentsIfNeeded()
            self.inner = Self.resolve(anyview: anyview, env: env)
            super.init(frame: .zero)

            // Allow content to draw outside bounds (needed for ignore_safe_area)
            clipsToBounds = false

            // Embed the resolved view using manual frame layout (not AutoLayout)
            // This is critical: WaterUI uses Rust layout engine, not AutoLayout
            inner.translatesAutoresizingMaskIntoConstraints = true
            addSubview(inner)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        public func layoutPriority() -> Int32 {
            inner.layoutPriority()
        }

        public func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
            inner.sizeThatFits(proposal)
        }

        /// Returns intrinsic content size for UIKit Auto Layout integration.
        /// This allows WaterUI views to participate in Auto Layout constraints.
        override public var intrinsicContentSize: CGSize {
            var intrinsic = sizeThatFits(WuiProposalSize())

            // When the host constrains our width via Auto Layout, keep the natural (content) width
            // but recompute height using the current width so multiline content can wrap correctly.
            guard !translatesAutoresizingMaskIntoConstraints, bounds.width > 0 else {
                return applyStretchAxisToIntrinsicSize(intrinsic)
            }

            let constrained = sizeThatFits(WuiProposalSize(width: Float(bounds.width), height: nil))
            intrinsic.height = constrained.height
            return applyStretchAxisToIntrinsicSize(intrinsic)
        }

        override public func sizeThatFits(_ size: CGSize) -> CGSize {
            sizeThatFits(WuiProposalSize(size: size))
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            // Manually size inner view to fill bounds and trigger nested layout
            inner.frame = bounds
            inner.setNeedsLayout()
            inner.layoutIfNeeded()

            // If the host constrains our width via Auto Layout, re-measure with that width so
            // multiline text (and other width-dependent layouts) can grow vertically.
            if !translatesAutoresizingMaskIntoConstraints, bounds.width > 0,
                bounds.width != lastAutoLayoutWidth
            {
                lastAutoLayoutWidth = bounds.width
                invalidateIntrinsicContentSize()
            }
        }

        private func applyStretchAxisToIntrinsicSize(_ size: CGSize) -> CGSize {
            switch stretchAxis {
            case .none:
                return size
            case .horizontal:
                return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
            case .vertical:
                return CGSize(width: size.width, height: UIView.noIntrinsicMetric)
            case .both, .mainAxis, .crossAxis:
                return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
            }
        }

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                setupRootThemeController(for: self)
                applyPendingRootTheme()
            }
        }

        // MARK: - Internal Resolution

        internal static func resolve(anyview: OpaquePointer, env: WuiEnvironment)
            -> any WuiComponent
        {
            guard let sanitized = sanitize(anyview) else {
                fatalError("Invalid anyview pointer")
            }

            let viewId = WuiViewId(waterui_view_id(sanitized))

            // Look up registered component factory - O(1) pointer-based lookup
            if let factory = componentRegistry[viewId] {
                // If this is the first non-metadata component, capture its env for root theme
                if !metadataComponentIds.contains(viewId) {
                    markAsRootContentEnv(env)
                }
                return factory(sanitized, env)
            }

            if let next = waterui_view_body(sanitized, env.inner) {
                return resolve(anyview: next, env: env)
            }

            fatalError("Unsupported component type: \(viewId.toString())")
        }

        private static func sanitize(_ pointer: OpaquePointer?) -> OpaquePointer? {
            guard let pointer else { return nil }
            let raw = UInt(bitPattern: pointer)
            if raw <= 0x1000 { return nil }
            return pointer
        }
    }

#elseif canImport(AppKit)
    /// The entry point for WaterUI views from Rust.
    /// Resolves an opaque FFI pointer into a concrete WuiComponent at initialization time.
    @MainActor
    public final class WuiAnyView: NSView, WuiComponent {
        public static var rawId: CWaterUI.WuiTypeId { waterui_anyview_id() }

        /// The resolved inner component - never nil after initialization
        private let inner: any WuiComponent
        private var lastAutoLayoutWidth: CGFloat = 0

        public var stretchAxis: WuiStretchAxis {
            inner.stretchAxis
        }

        /// Creates a WuiAnyView by resolving an opaque FFI pointer to a concrete component.
        /// This is the public interface for creating WaterUI views from Rust pointers.
        public init(anyview: OpaquePointer, env: WuiEnvironment) {
            registerBuiltinComponentsIfNeeded()
            self.inner = Self.resolve(anyview: anyview, env: env)
            super.init(frame: .zero)

            // Embed the resolved view using manual frame layout (not AutoLayout)
            // This is critical: WaterUI uses Rust layout engine, not AutoLayout
            inner.translatesAutoresizingMaskIntoConstraints = true
            addSubview(inner)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        public func layoutPriority() -> Int32 {
            inner.layoutPriority()
        }

        public func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
            inner.sizeThatFits(proposal)
        }

        /// Returns intrinsic content size for AppKit Auto Layout integration.
        /// This allows WaterUI views to participate in Auto Layout constraints.
        override public var intrinsicContentSize: NSSize {
            var intrinsic = sizeThatFits(WuiProposalSize())

            // When the host constrains our width via Auto Layout, keep the natural (content) width
            // but recompute height using the current width so multiline content can wrap correctly.
            guard !translatesAutoresizingMaskIntoConstraints, bounds.width > 0 else {
                return applyStretchAxisToIntrinsicSize(intrinsic)
            }

            let constrained = sizeThatFits(WuiProposalSize(width: Float(bounds.width), height: nil))
            intrinsic.height = constrained.height
            return applyStretchAxisToIntrinsicSize(intrinsic)
        }

        override public var isFlipped: Bool { true }

        public func sizeThatFits(_ size: NSSize) -> NSSize {
            sizeThatFits(WuiProposalSize(size: size))
        }

        override public func layout() {
            super.layout()
            // Manually size inner view to fill bounds
            inner.frame = bounds

            // If the host constrains our width via Auto Layout, re-measure with that width so
            // multiline text (and other width-dependent layouts) can grow vertically.
            if !translatesAutoresizingMaskIntoConstraints, bounds.width > 0,
                bounds.width != lastAutoLayoutWidth
            {
                lastAutoLayoutWidth = bounds.width
                invalidateIntrinsicContentSize()
            }
        }

        private func applyStretchAxisToIntrinsicSize(_ size: NSSize) -> NSSize {
            switch stretchAxis {
            case .none:
                return size
            case .horizontal:
                return NSSize(width: NSView.noIntrinsicMetric, height: size.height)
            case .vertical:
                return NSSize(width: size.width, height: NSView.noIntrinsicMetric)
            case .both, .mainAxis, .crossAxis:
                return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
            }
        }

        override public func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                setupRootThemeController(for: self)
                applyPendingRootTheme()
            }
        }

        // MARK: - Internal Resolution

        internal static func resolve(anyview: OpaquePointer, env: WuiEnvironment)
            -> any WuiComponent
        {
            guard let sanitized = sanitize(anyview) else {
                fatalError("Invalid anyview pointer")
            }

            let viewId = WuiViewId(waterui_view_id(sanitized))

            // Look up registered component factory - O(1) pointer-based lookup
            if let factory = componentRegistry[viewId] {
                // If this is the first non-metadata component, capture its env for root theme
                if !metadataComponentIds.contains(viewId) {
                    markAsRootContentEnv(env)
                }
                return factory(sanitized, env)
            }

            if let next = waterui_view_body(sanitized, env.inner) {
                return resolve(anyview: next, env: env)
            }

            fatalError("Unsupported component type: \(viewId.toString())")
        }

        private static func sanitize(_ pointer: OpaquePointer?) -> OpaquePointer? {
            guard let pointer else { return nil }
            let raw = UInt(bitPattern: pointer)
            if raw <= 0x1000 { return nil }
            return pointer
        }
    }
#endif
