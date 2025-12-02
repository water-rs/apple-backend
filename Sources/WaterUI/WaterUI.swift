import CWaterUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - WuiStretchAxis

/// Defines how a view stretches to fill available space.
/// Mirrors Rust's `StretchAxis` enum from the layout engine.
public enum WuiStretchAxis: UInt32 {
    /// Content-sized: uses intrinsic size, never stretches
    case none = 0
    /// Expands width only, uses intrinsic height (e.g., TextField, Slider)
    case horizontal = 1
    /// Expands height only, uses intrinsic width
    case vertical = 2
    /// Greedy: fills all available space in both directions (e.g., Color)
    case both = 3
    /// Expands along parent stack's main axis (e.g., Spacer)
    /// In VStack: expands vertically. In HStack: expands horizontally.
    case mainAxis = 4
    /// Expands along parent stack's cross axis (e.g., Divider)
    /// In VStack: expands horizontally. In HStack: expands vertically.
    case crossAxis = 5

    /// Convert to the C FFI enum type
    var ffiValue: CWaterUI.WuiStretchAxis {
        CWaterUI.WuiStretchAxis(rawValue: self.rawValue)
    }

    /// Initialize from C FFI enum type
    init(_ ffi: CWaterUI.WuiStretchAxis) {
        self = WuiStretchAxis(rawValue: ffi.rawValue) ?? .none
    }
}

// MARK: - WuiComponent Protocol

/// Protocol for all WaterUI components.
/// Components are platform views (UIView/NSView) identified by a static ID string
/// that implement WaterUI's measurement protocol.
///
/// This protocol mirrors Rust's `SubView` trait:
/// - `sizeThatFits(_:)` → `size_that_fits(proposal)`
/// - `stretchAxis` → `stretch_axis()`
/// - `layoutPriority()` → `priority()`
@MainActor
protocol WuiComponent: PlatformView {
    /// Static identifier for this component type (e.g., "Text", "Button")
    /// Must be obtained via `waterui_*_id()` FFI function
    static var id: String { get }

    /// Creates an instance from an FFI anyview pointer and environment.
    /// This is called by PlatformRenderer when resolving views.
    init(anyview: OpaquePointer, env: WuiEnvironment)

    /// Which axis (or axes) this view stretches to fill available space.
    /// Default: `.none` (content-sized)
    var stretchAxis: WuiStretchAxis { get }

    /// Layout priority for this view. Higher priority views get space first.
    /// Default: 0
    func layoutPriority() -> Int32

    /// Measures the view given a size proposal.
    /// - Parameter proposal: The proposed size from the layout engine
    /// - Returns: The size this view wants to be
    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize
}

extension WuiComponent {
    var stretchAxis: WuiStretchAxis { .none }
    func layoutPriority() -> Int32 { 0 }

    static func decodeId(_ raw: CWaterUI.WuiStr) -> String {
        decodeViewIdentifier(raw)
    }
}

@inline(__always)
func decodeViewIdentifier(_ raw: CWaterUI.WuiStr) -> String {
    WuiStr(raw).toString()
}

// MARK: - Reactive Signal Infrastructure

/// A native-controlled reactive color signal.
/// This allows Swift to create and update color signals that notify WaterUI watchers.
@MainActor
final class ReactiveColorSignal {
    /// Boxed state holding the current color and watcher list
    private final class State: @unchecked Sendable {
        var color: WuiResolvedColor
        var watchers: [OpaquePointer] = []  // WuiWatcher_ResolvedColor*
        var nextWatcherIndex: Int = 0

        init(color: WuiResolvedColor) {
            self.color = color
        }

        func addWatcher(_ watcher: OpaquePointer) -> Int {
            let index = nextWatcherIndex
            nextWatcherIndex += 1
            watchers.append(watcher)
            return index
        }

        func notifyWatchers() {
            for watcher in watchers {
                waterui_call_watcher_resolved_color(watcher, color)
            }
        }

        func cleanup() {
            for watcher in watchers {
                waterui_drop_watcher_resolved_color(watcher)
            }
            watchers.removeAll()
        }
    }

    private var state: State
    private var statePtr: UnsafeMutableRawPointer
    private var computedPtr: OpaquePointer?

    init(color: WuiResolvedColor) {
        self.state = State(color: color)
        self.statePtr = Unmanaged.passRetained(state).toOpaque()
    }

    deinit {
        state.cleanup()
    }

    /// Gets the computed pointer for installation into WaterUI environment.
    func toComputed() -> OpaquePointer? {
        if computedPtr == nil {
            computedPtr = waterui_new_computed_resolved_color(
                statePtr,
                { ptr -> WuiResolvedColor in
                    guard let ptr = ptr else { return WuiResolvedColor() }
                    let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr)).takeUnretainedValue()
                    return state.color
                },
                { ptr, watcher -> OpaquePointer? in
                    guard let ptr = ptr, let watcher = watcher else { return nil }
                    let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr)).takeUnretainedValue()
                    _ = state.addWatcher(watcher)
                    return waterui_new_watcher_guard(nil) { _ in }
                },
                { ptr in
                    guard let ptr = ptr else { return }
                    let state = Unmanaged<State>.fromOpaque(ptr).takeRetainedValue()
                    state.cleanup()
                }
            )
        }
        return computedPtr
    }

    /// Updates the color and notifies all watchers.
    func setValue(_ color: WuiResolvedColor) {
        state.color = color
        state.notifyWatchers()
    }

    /// Convenience to set from platform color
    #if canImport(UIKit)
    func setValue(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        setValue(WuiResolvedColor(red: Float(r), green: Float(g), blue: Float(b), opacity: Float(a), headroom: 0.0))
    }
    #elseif canImport(AppKit)
    func setValue(_ color: NSColor) {
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        setValue(WuiResolvedColor(red: Float(r), green: Float(g), blue: Float(b), opacity: Float(a), headroom: 0.0))
    }
    #endif
}

/// A native-controlled reactive font signal.
@MainActor
final class ReactiveFontSignal {
    private final class State: @unchecked Sendable {
        var font: WuiResolvedFont
        var watchers: [OpaquePointer] = []  // WuiWatcher_ResolvedFont*

        init(font: WuiResolvedFont) {
            self.font = font
        }

        func addWatcher(_ watcher: OpaquePointer) {
            watchers.append(watcher)
        }

        func notifyWatchers() {
            for watcher in watchers {
                waterui_call_watcher_resolved_font(watcher, font)
            }
        }

        func cleanup() {
            for watcher in watchers {
                waterui_drop_watcher_resolved_font(watcher)
            }
            watchers.removeAll()
        }
    }

    private var state: State
    private var statePtr: UnsafeMutableRawPointer
    private var computedPtr: OpaquePointer?

    init(size: Float, weight: WuiFontWeight) {
        self.state = State(font: WuiResolvedFont(size: size, weight: weight))
        self.statePtr = Unmanaged.passRetained(state).toOpaque()
    }

    deinit {
        state.cleanup()
    }

    func toComputed() -> OpaquePointer? {
        if computedPtr == nil {
            computedPtr = waterui_new_computed_resolved_font(
                statePtr,
                { ptr -> WuiResolvedFont in
                    guard let ptr = ptr else { return WuiResolvedFont() }
                    let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr)).takeUnretainedValue()
                    return state.font
                },
                { ptr, watcher -> OpaquePointer? in
                    guard let ptr = ptr, let watcher = watcher else { return nil }
                    let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr)).takeUnretainedValue()
                    state.addWatcher(watcher)
                    return waterui_new_watcher_guard(nil) { _ in }
                },
                { ptr in
                    guard let ptr = ptr else { return }
                    let state = Unmanaged<State>.fromOpaque(ptr).takeRetainedValue()
                    state.cleanup()
                }
            )
        }
        return computedPtr
    }

    func setValue(size: Float, weight: WuiFontWeight) {
        state.font = WuiResolvedFont(size: size, weight: weight)
        state.notifyWatchers()
    }
}

// MARK: - Theme Bridge

/// Observes system appearance changes and updates theme reactively.
///
/// This class uses `ReactiveColorSignal` to create signals that can be updated
/// when system appearance changes, triggering automatic UI updates through
/// WaterUI's reactive system.
@MainActor
public final class ThemeBridge {
    // Reactive color signals - stored so we can update them
    private var backgroundSignal: ReactiveColorSignal?
    private var surfaceSignal: ReactiveColorSignal?
    private var surfaceVariantSignal: ReactiveColorSignal?
    private var borderSignal: ReactiveColorSignal?
    private var foregroundSignal: ReactiveColorSignal?
    private var mutedForegroundSignal: ReactiveColorSignal?
    private var accentSignal: ReactiveColorSignal?
    private var accentForegroundSignal: ReactiveColorSignal?

    // Track if initial installation is done
    private var installed = false

    public enum ColorScheme {
        case light
        case dark
    }

    init(env: WuiEnvironment, colorScheme: ColorScheme) {
        // Initial installation with reactive signals
        installReactiveTheme(env: env, colorScheme: colorScheme)
    }

    /// First-time installation creates reactive signals and installs them
    private func installReactiveTheme(env: WuiEnvironment, colorScheme: ColorScheme) {
        let isDark = colorScheme == .dark

        // Install color scheme (constant for now)
        let wuiScheme: WuiColorScheme = isDark ? WuiColorScheme_Dark : WuiColorScheme_Light
        if let signal = waterui_computed_color_scheme_constant(wuiScheme) {
            waterui_theme_install_color_scheme(env.inner, signal)
        }

        // Create reactive color signals
        #if canImport(UIKit)
        backgroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Background, color: UIColor.systemBackground)
        surfaceSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Surface, color: UIColor.secondarySystemBackground)
        surfaceVariantSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_SurfaceVariant, color: UIColor.tertiarySystemBackground)
        borderSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Border, color: UIColor.separator)
        foregroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Foreground, color: UIColor.label)
        mutedForegroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_MutedForeground, color: UIColor.secondaryLabel)
        accentSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Accent, color: UIColor.tintColor)
        accentForegroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_AccentForeground, color: UIColor.white)
        #elseif canImport(AppKit)
        backgroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Background, color: NSColor.windowBackgroundColor)
        surfaceSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Surface, color: NSColor.controlBackgroundColor)
        surfaceVariantSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_SurfaceVariant, color: NSColor.underPageBackgroundColor)
        borderSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Border, color: NSColor.separatorColor)
        foregroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Foreground, color: NSColor.labelColor)
        mutedForegroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_MutedForeground, color: NSColor.secondaryLabelColor)
        accentSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Accent, color: NSColor.controlAccentColor)
        accentForegroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_AccentForeground, color: NSColor.white)
        #endif

        // Install fonts (constant - don't change with appearance)
        installSystemFonts(env: env)

        installed = true
    }

    /// Updates the theme for a new color scheme by updating existing reactive signals
    func updateColorScheme(_ colorScheme: ColorScheme) {
        // Update color signals with new system colors
        // The reactive system will automatically propagate these changes
        #if canImport(UIKit)
        backgroundSignal?.setValue(UIColor.systemBackground)
        surfaceSignal?.setValue(UIColor.secondarySystemBackground)
        surfaceVariantSignal?.setValue(UIColor.tertiarySystemBackground)
        borderSignal?.setValue(UIColor.separator)
        foregroundSignal?.setValue(UIColor.label)
        mutedForegroundSignal?.setValue(UIColor.secondaryLabel)
        accentSignal?.setValue(UIColor.tintColor)
        accentForegroundSignal?.setValue(UIColor.white)
        #elseif canImport(AppKit)
        backgroundSignal?.setValue(NSColor.windowBackgroundColor)
        surfaceSignal?.setValue(NSColor.controlBackgroundColor)
        surfaceVariantSignal?.setValue(NSColor.underPageBackgroundColor)
        borderSignal?.setValue(NSColor.separatorColor)
        foregroundSignal?.setValue(NSColor.labelColor)
        mutedForegroundSignal?.setValue(NSColor.secondaryLabelColor)
        accentSignal?.setValue(NSColor.controlAccentColor)
        accentForegroundSignal?.setValue(NSColor.white)
        #endif
    }

    #if canImport(UIKit)
    private func createAndInstallColorSignal(env: WuiEnvironment, slot: WuiColorSlot, color: UIColor) -> ReactiveColorSignal {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let resolved = WuiResolvedColor(red: Float(r), green: Float(g), blue: Float(b), opacity: Float(a), headroom: 0.0)

        let signal = ReactiveColorSignal(color: resolved)
        if let computed = signal.toComputed() {
            waterui_theme_install_color(env.inner, slot, computed)
        }
        return signal
    }
    #elseif canImport(AppKit)
    private func createAndInstallColorSignal(env: WuiEnvironment, slot: WuiColorSlot, color: NSColor) -> ReactiveColorSignal {
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let resolved = WuiResolvedColor(red: Float(r), green: Float(g), blue: Float(b), opacity: Float(a), headroom: 0.0)

        let signal = ReactiveColorSignal(color: resolved)
        if let computed = signal.toComputed() {
            waterui_theme_install_color(env.inner, slot, computed)
        }
        return signal
    }
    #endif

    private func installSystemFonts(env: WuiEnvironment) {
        #if canImport(UIKit)
        installFontSlot(env: env, slot: WuiFontSlot_Body, font: UIFont.preferredFont(forTextStyle: .body))
        installFontSlot(env: env, slot: WuiFontSlot_Title, font: UIFont.preferredFont(forTextStyle: .title1))
        installFontSlot(env: env, slot: WuiFontSlot_Headline, font: UIFont.preferredFont(forTextStyle: .headline))
        installFontSlot(env: env, slot: WuiFontSlot_Subheadline, font: UIFont.preferredFont(forTextStyle: .subheadline))
        installFontSlot(env: env, slot: WuiFontSlot_Caption, font: UIFont.preferredFont(forTextStyle: .caption1))
        installFontSlot(env: env, slot: WuiFontSlot_Footnote, font: UIFont.preferredFont(forTextStyle: .footnote))
        #elseif canImport(AppKit)
        installFontSlot(env: env, slot: WuiFontSlot_Body, font: NSFont.systemFont(ofSize: NSFont.systemFontSize))
        installFontSlot(env: env, slot: WuiFontSlot_Title, font: NSFont.systemFont(ofSize: 28, weight: .bold))
        installFontSlot(env: env, slot: WuiFontSlot_Headline, font: NSFont.systemFont(ofSize: 17, weight: .semibold))
        installFontSlot(env: env, slot: WuiFontSlot_Subheadline, font: NSFont.systemFont(ofSize: 15))
        installFontSlot(env: env, slot: WuiFontSlot_Caption, font: NSFont.systemFont(ofSize: 12))
        installFontSlot(env: env, slot: WuiFontSlot_Footnote, font: NSFont.systemFont(ofSize: 13))
        #endif
    }

    #if canImport(UIKit)
    private func installFontSlot(env: WuiEnvironment, slot: WuiFontSlot, font: UIFont) {
        let weight = fontWeight(font)
        let signal = ReactiveFontSignal(size: Float(font.pointSize), weight: weight)
        if let computed = signal.toComputed() {
            waterui_theme_install_font(env.inner, slot, computed)
        }
    }

    private func fontWeight(_ font: UIFont) -> WuiFontWeight {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let weightValue = traits?[.weight] as? CGFloat ?? UIFont.Weight.regular.rawValue
        return uiFontWeightToWuiFontWeight(weightValue)
    }

    private func uiFontWeightToWuiFontWeight(_ weight: CGFloat) -> WuiFontWeight {
        // UIFont.Weight ranges from -1.0 (ultra-light) to 1.0 (black), with 0.0 being regular
        switch weight {
        case ...(-0.8): return WuiFontWeight_Thin
        case (-0.8)...(-0.6): return WuiFontWeight_UltraLight
        case (-0.6)...(-0.4): return WuiFontWeight_Light
        case (-0.4)...(0.0): return WuiFontWeight_Normal
        case (0.0)...(0.23): return WuiFontWeight_Medium
        case (0.23)...(0.3): return WuiFontWeight_SemiBold
        case (0.3)...(0.5): return WuiFontWeight_Bold
        case (0.5)...(0.8): return WuiFontWeight_UltraBold
        default: return WuiFontWeight_Black
        }
    }
    #elseif canImport(AppKit)
    private func installFontSlot(env: WuiEnvironment, slot: WuiFontSlot, font: NSFont) {
        let weight = fontWeight(font)
        let signal = ReactiveFontSignal(size: Float(font.pointSize), weight: weight)
        if let computed = signal.toComputed() {
            waterui_theme_install_font(env.inner, slot, computed)
        }
    }

    private func fontWeight(_ font: NSFont) -> WuiFontWeight {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weightValue = traits?[.weight] as? CGFloat ?? NSFont.Weight.regular.rawValue
        return nsFontWeightToWuiFontWeight(weightValue)
    }

    private func nsFontWeightToWuiFontWeight(_ weight: CGFloat) -> WuiFontWeight {
        // NSFont.Weight ranges from -1.0 to 1.0, similar to UIFont.Weight
        switch weight {
        case ...(-0.8): return WuiFontWeight_Thin
        case (-0.8)...(-0.6): return WuiFontWeight_UltraLight
        case (-0.6)...(-0.4): return WuiFontWeight_Light
        case (-0.4)...(0.0): return WuiFontWeight_Normal
        case (0.0)...(0.23): return WuiFontWeight_Medium
        case (0.23)...(0.3): return WuiFontWeight_SemiBold
        case (0.3)...(0.5): return WuiFontWeight_Bold
        case (0.5)...(0.8): return WuiFontWeight_UltraBold
        default: return WuiFontWeight_Black
        }
    }
    #endif
}

// MARK: - Root Context

@MainActor
public final class WuiRootContext {
    public let env: WuiEnvironment
    private let rootViewPointer: OpaquePointer
    var themeBridge: ThemeBridge?

    /// The root platform view
    #if canImport(UIKit)
    public private(set) lazy var rootView: UIView = {
        WuiAnyView(anyview: rootViewPointer, env: env)
    }()
    #elseif canImport(AppKit)
    public private(set) lazy var rootView: NSView = {
        WuiAnyView(anyview: rootViewPointer, env: env)
    }()
    #endif

    public init(colorScheme: ThemeBridge.ColorScheme = .light) {
        // 1. Create environment (waterui_init)
        let environment = WuiEnvironment(waterui_init())
        self.env = environment

        // 2. Install theme BEFORE waterui_main
        // Theme uses reactive signals that can be updated later
        self.themeBridge = ThemeBridge(env: environment, colorScheme: colorScheme)

        // 3. Create the main view (waterui_main)
        guard let mainView = waterui_main() else {
            fatalError("waterui_main() returned nil")
        }
        self.rootViewPointer = mainView
    }

    /// Updates the theme for a new color scheme.
    /// Uses reactive signals so WaterUI views automatically update.
    public func updateColorScheme(_ colorScheme: ThemeBridge.ColorScheme) {
        themeBridge?.updateColorScheme(colorScheme)
    }
}

// MARK: - Public UIKit Root View Controller

#if canImport(UIKit)
/// A UIKit view controller that hosts the WaterUI root view.
@MainActor
public final class WaterUIViewController: UIViewController {
    private let context: WuiRootContext

    public init() {
        self.context = WuiRootContext(colorScheme: .light)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        let rootView = context.rootView
        rootView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootView)

        NSLayoutConstraint.activate([
            rootView.topAnchor.constraint(equalTo: view.topAnchor),
            rootView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()

        // Measure and layout the root view
        if let component = context.rootView as? (any WuiComponent) {
            let proposal = WuiProposalSize(size: view.bounds.size)
            _ = component.sizeThatFits(proposal)
        }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
            let colorScheme: ThemeBridge.ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
            context.updateColorScheme(colorScheme)
        }
    }
}
#endif

// MARK: - Public AppKit Root View

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
/// An AppKit view that hosts the WaterUI root view.
@MainActor
public final class WaterUIView: NSView {
    private let context: WuiRootContext
    private nonisolated(unsafe) var appearanceObserver: (any NSObjectProtocol)?

    public override init(frame frameRect: NSRect) {
        self.context = WuiRootContext(colorScheme: .light)
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let rootView = context.rootView
        rootView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootView)

        NSLayoutConstraint.activate([
            rootView.topAnchor.constraint(equalTo: topAnchor),
            rootView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Observe appearance changes
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateColorScheme()
            }
        }
    }

    private func updateColorScheme() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        context.updateColorScheme(isDark ? .dark : .light)
    }

    public override func layout() {
        super.layout()

        // Measure and layout the root view
        if let component = context.rootView as? (any WuiComponent) {
            let proposal = WuiProposalSize(size: bounds.size)
            _ = component.sizeThatFits(proposal)
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorScheme()
    }

    deinit {
        if let observer = appearanceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
#endif

// MARK: - SwiftUI Integration

/// A SwiftUI view that hosts the WaterUI root view.
/// This provides backward compatibility for SwiftUI-based host apps.
#if os(macOS)
public struct App: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> WaterUIView {
        WaterUIView(frame: .zero)
    }

    public func updateNSView(_ nsView: WaterUIView, context: Context) {
        // No updates needed - WaterUI handles its own reactivity
    }
}
#else
public struct App: UIViewControllerRepresentable {
    public init() {}

    public func makeUIViewController(context: Context) -> WaterUIViewController {
        WaterUIViewController()
    }

    public func updateUIViewController(_ uiViewController: WaterUIViewController, context: Context) {
        // No updates needed - WaterUI handles its own reactivity
    }
}
#endif
