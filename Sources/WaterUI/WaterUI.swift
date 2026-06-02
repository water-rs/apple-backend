import CWaterUI
import Foundation
import OSLog
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

// MARK: - WuiViewId

/// A view identifier using 128-bit value for O(1) lookups.
///
/// Uses the same 128-bit type ID from Rust:
/// - Normal build: Contains TypeId (guaranteed unique by Rust)
/// - Hot reload: Contains 128-bit FNV-1a hash of type_name (stable across dylib reloads)
///
/// Using 128-bit virtually eliminates collision risk (birthday paradox threshold: ~10^19).
struct WuiViewId: Hashable {
    /// Low 64 bits of the 128-bit type identifier
    let low: UInt64
    /// High 64 bits of the 128-bit type identifier
    let high: UInt64

    /// Extract view ID from the FFI WuiTypeId struct.
    @inline(__always)
    init(_ raw: CWaterUI.WuiTypeId) {
        self.low = raw.low
        self.high = raw.high
    }

    @inline(__always)
    static func == (lhs: WuiViewId, rhs: WuiViewId) -> Bool {
        // O(1) comparison of two 64-bit values
        lhs.low == rhs.low && lhs.high == rhs.high
    }

    @inline(__always)
    func hash(into hasher: inout Hasher) {
        hasher.combine(low)
        hasher.combine(high)
    }

    /// Convert to debug string (shows hex representation)
    func toString() -> String {
        String(format: "0x%016llx%016llx", high, low)
    }
}

// MARK: - WuiComponent Protocol

/// Protocol for all WaterUI components.
/// Components are platform views (UIView/NSView) identified by a static ID
/// that implement WaterUI's measurement protocol.
///
/// This protocol mirrors Rust's `SubView` trait:
/// - `sizeThatFits(_:)` → `size_that_fits(proposal)`
/// - `stretchAxis` → `stretch_axis()`
/// - `layoutPriority()` → `priority()`
@MainActor
protocol WuiComponent: PlatformView {
    /// Raw FFI identifier for this component type.
    /// Must be obtained via `waterui_*_id()` FFI function.
    /// Used for O(1) 128-bit value-based registry lookup.
    static var rawId: CWaterUI.WuiTypeId { get }

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

    /// Measures the view and returns the full layout packet.
    func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions
}

extension WuiComponent {
    var stretchAxis: WuiStretchAxis { .none }
    func layoutPriority() -> Int32 { 0 }
    func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
        WuiViewDimensions(size: sizeThatFits(proposal))
    }

    /// 128-bit view ID for O(1) registry lookup
    static var viewId: WuiViewId {
        WuiViewId(rawId)
    }
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

        func removeWatcher(_ watcher: OpaquePointer) {
            if let index = watchers.firstIndex(of: watcher) {
                watchers.remove(at: index)
                waterui_drop_watcher_resolved_color(watcher)
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
                    let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
                        .takeUnretainedValue()
                    return state.color
                },
                { ptr, watcher -> OpaquePointer? in
                    guard let ptr = ptr, let watcher = watcher else { return nil }
                    let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
                        .takeUnretainedValue()
                    _ = state.addWatcher(watcher)

                    final class WatcherGuardContext {
                        let statePtr: UnsafeMutableRawPointer
                        let watcher: OpaquePointer
                        init(statePtr: UnsafeMutableRawPointer, watcher: OpaquePointer) {
                            self.statePtr = statePtr
                            self.watcher = watcher
                        }
                    }

                    let context = WatcherGuardContext(
                        statePtr: UnsafeMutableRawPointer(mutating: ptr), watcher: watcher)
                    let contextPtr = Unmanaged.passRetained(context).toOpaque()

                    return waterui_new_watcher_guard(contextPtr) { rawPtr in
                        guard let rawPtr = rawPtr else { return }
                        let context = Unmanaged<WatcherGuardContext>.fromOpaque(rawPtr)
                            .takeRetainedValue()
                        let state = Unmanaged<State>.fromOpaque(context.statePtr)
                            .takeUnretainedValue()
                        state.removeWatcher(context.watcher)
                    }
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
            setValue(WuiResolvedColor.fromUIColor(color))
        }
    #elseif canImport(AppKit)
        func setValue(_ color: NSColor) {
            setValue(WuiResolvedColor.fromNSColor(color))
        }
    #endif
}

/// A native-controlled reactive color scheme signal.
/// This allows Swift to create and update color scheme signals that notify WaterUI watchers.
@MainActor
final class ReactiveColorSchemeSignal {
    private final class State: @unchecked Sendable {
        var scheme: WuiColorScheme
        var watchers: [OpaquePointer] = []  // WuiWatcher_ColorScheme*

        init(scheme: WuiColorScheme) {
            self.scheme = scheme
        }

        func addWatcher(_ watcher: OpaquePointer) {
            watchers.append(watcher)
        }

        func notifyWatchers() {
            for watcher in watchers {
                waterui_call_watcher_color_scheme(watcher, scheme)
            }
        }

        func cleanup() {
            for watcher in watchers {
                waterui_drop_watcher_color_scheme(watcher)
            }
            watchers.removeAll()
        }
    }

    private var state: State
    private var statePtr: UnsafeMutableRawPointer
    private var computedPtr: OpaquePointer?

    init(scheme: WuiColorScheme) {
        self.state = State(scheme: scheme)
        self.statePtr = Unmanaged.passRetained(state).toOpaque()
    }

    deinit {
        state.cleanup()
    }

    func toComputed() -> OpaquePointer? {
        if computedPtr == nil {
            computedPtr = waterui_new_computed_color_scheme(
                statePtr,
                { ptr -> WuiColorScheme in
                    guard let ptr = ptr else { return WuiColorScheme_Light }
                    let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
                        .takeUnretainedValue()
                    return state.scheme
                },
                { ptr, watcher -> OpaquePointer? in
                    guard let ptr = ptr, let watcher = watcher else { return nil }
                    let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
                        .takeUnretainedValue()
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

    func setValue(_ scheme: WuiColorScheme) {
        state.scheme = scheme
        state.notifyWatchers()
    }
}

/// A native-controlled reactive font signal.
@MainActor
final class ReactiveFontSignal {
    private final class State: @unchecked Sendable {
        var size: Float
        var weight: WuiFontWeight
        var watchers: [OpaquePointer] = []  // WuiWatcher_ResolvedFont*

        init(size: Float, weight: WuiFontWeight) {
            self.size = size
            self.weight = weight
        }

        func resolvedFont() -> WuiResolvedFont {
            waterui_resolved_font_new(size, weight)
        }

        func addWatcher(_ watcher: OpaquePointer) {
            watchers.append(watcher)
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
        self.state = State(size: size, weight: weight)
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
                    guard let ptr = ptr else {
                        fatalError("ReactiveFontSignal get received a null state pointer")
                    }
                    let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
                        .takeUnretainedValue()
                    return state.resolvedFont()
                },
                { ptr, watcher -> OpaquePointer? in
                    guard let ptr = ptr else {
                        fatalError("ReactiveFontSignal watch received a null state pointer")
                    }
                    guard let watcher = watcher else {
                        fatalError("ReactiveFontSignal watch received a null watcher pointer")
                    }
                    let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
                        .takeUnretainedValue()
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
}

private struct WaterUIThemeConfiguration: Decodable {
    let background: String?
    let surface: String?
    let surfaceVariant: String?
    let border: String?
    let foreground: String?
    let mutedForeground: String?
    let accent: String?
    let accentForeground: String?

    private enum CodingKeys: String, CodingKey {
        case background
        case surface
        case surfaceVariant = "surface_variant"
        case border
        case foreground
        case mutedForeground = "muted_foreground"
        case accent
        case accentForeground = "accent_foreground"
    }

    static func load() -> WaterUIThemeConfiguration? {
        guard let url = Bundle.main.url(forResource: "WaterUITheme", withExtension: "json") else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(WaterUIThemeConfiguration.self, from: data)
        } catch {
            fatalError("WaterUI: failed to decode WaterUITheme.json: \(error)")
        }
    }

    #if canImport(UIKit)
        var backgroundColor: UIColor? { background.flatMap(Self.parseUIColor) }
        var surfaceColor: UIColor? { surface.flatMap(Self.parseUIColor) }
        var surfaceVariantColor: UIColor? { surfaceVariant.flatMap(Self.parseUIColor) }
        var borderColor: UIColor? { border.flatMap(Self.parseUIColor) }
        var foregroundColor: UIColor? { foreground.flatMap(Self.parseUIColor) }
        var mutedForegroundColor: UIColor? { mutedForeground.flatMap(Self.parseUIColor) }
        var accentColor: UIColor? { accent.flatMap(Self.parseUIColor) }
        var accentForegroundColor: UIColor? { accentForeground.flatMap(Self.parseUIColor) }

        private static func parseUIColor(_ value: String) -> UIColor? {
            guard let (red, green, blue) = parseHex(value) else { return nil }
            return UIColor(
                red: CGFloat(red) / 255.0,
                green: CGFloat(green) / 255.0,
                blue: CGFloat(blue) / 255.0,
                alpha: 1.0
            )
        }
    #elseif canImport(AppKit)
        var backgroundColor: NSColor? { background.flatMap(Self.parseNSColor) }
        var surfaceColor: NSColor? { surface.flatMap(Self.parseNSColor) }
        var surfaceVariantColor: NSColor? { surfaceVariant.flatMap(Self.parseNSColor) }
        var borderColor: NSColor? { border.flatMap(Self.parseNSColor) }
        var foregroundColor: NSColor? { foreground.flatMap(Self.parseNSColor) }
        var mutedForegroundColor: NSColor? { mutedForeground.flatMap(Self.parseNSColor) }
        var accentColor: NSColor? { accent.flatMap(Self.parseNSColor) }
        var accentForegroundColor: NSColor? { accentForeground.flatMap(Self.parseNSColor) }

        private static func parseNSColor(_ value: String) -> NSColor? {
            guard let (red, green, blue) = parseHex(value) else { return nil }
            return NSColor(
                calibratedRed: CGFloat(red) / 255.0,
                green: CGFloat(green) / 255.0,
                blue: CGFloat(blue) / 255.0,
                alpha: 1.0
            )
        }
    #endif

    private static func parseHex(_ value: String) -> (UInt8, UInt8, UInt8)? {
        let raw = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard raw.count == 6, let rgb = UInt32(raw, radix: 16) else {
            return nil
        }
        return (
            UInt8((rgb & 0xFF00_00) >> 16),
            UInt8((rgb & 0x00FF_00) >> 8),
            UInt8(rgb & 0x0000_FF)
        )
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
    // Reactive color scheme signal - can be updated when system appearance changes
    private var colorSchemeSignal: ReactiveColorSchemeSignal?

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
    private var observedColorSchemeSignal: OpaquePointer?
    private var observedColorSchemeWatcher: WatcherGuard?
    private let configuredTheme = WaterUIThemeConfiguration.load()

    public enum ColorScheme {
        case light
        case dark
    }

    init(env: WuiEnvironment, colorScheme: ColorScheme) {
        // Initial installation with reactive signals
        installReactiveTheme(env: env, colorScheme: colorScheme)
    }

    func bindToEnvironmentColorScheme(env: WuiEnvironment) {
        guard let signal = waterui_theme_color_scheme(env.inner) else {
            fatalError("WaterUI: failed to read root color scheme signal from the environment.")
        }

        if let observedColorSchemeSignal {
            waterui_drop_computed_color_scheme(observedColorSchemeSignal)
        }

        observedColorSchemeSignal = signal
        applyColors(for: Self.bridgeColorScheme(waterui_read_computed_color_scheme(signal)))

        let watcher = makeColorSchemeWatcher { [weak self] scheme, _ in
            self?.applyColors(for: Self.bridgeColorScheme(scheme))
        }
        guard let guardPtr = waterui_watch_computed_color_scheme(signal, watcher) else {
            fatalError("WaterUI: failed to watch root color scheme signal.")
        }
        observedColorSchemeWatcher = WatcherGuard(guardPtr)
    }

    /// First-time installation creates reactive signals and installs them
    private func installReactiveTheme(env: WuiEnvironment, colorScheme: ColorScheme) {
        let isDark = colorScheme == .dark

        // Install REACTIVE color scheme into root env as default.
        // This signal can be updated when system appearance changes.
        // Rust can override via .install(Theme::new().color_scheme(...)) in child env.
        // RootThemeController reads from first component's env (which may be overridden or not).
        let wuiScheme: WuiColorScheme = isDark ? WuiColorScheme_Dark : WuiColorScheme_Light
        colorSchemeSignal = ReactiveColorSchemeSignal(scheme: wuiScheme)
        if let computed = colorSchemeSignal?.toComputed() {
            waterui_theme_install_color_scheme(env.inner, computed)
        }

        // Create reactive color signals
        #if canImport(UIKit)
            let theme = configuredTheme
            backgroundSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_Background,
                color: theme?.backgroundColor ?? UIColor.systemBackground)
            surfaceSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_Surface,
                color: theme?.surfaceColor ?? UIColor.secondarySystemBackground)
            surfaceVariantSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_SurfaceVariant,
                color: theme?.surfaceVariantColor ?? UIColor.tertiarySystemBackground
            )
            borderSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_Border, color: theme?.borderColor ?? UIColor.separator)
            foregroundSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_Foreground, color: theme?.foregroundColor ?? UIColor.label)
            mutedForegroundSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_MutedForeground,
                color: theme?.mutedForegroundColor ?? UIColor.secondaryLabel)
            accentSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_Accent, color: theme?.accentColor ?? UIColor.tintColor)
            accentForegroundSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_AccentForeground,
                color: theme?.accentForegroundColor ?? UIColor.white)
        #elseif canImport(AppKit)
            let theme = configuredTheme
            backgroundSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_Background,
                color: theme?.backgroundColor ?? NSColor.windowBackgroundColor)
            surfaceSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_Surface,
                color: theme?.surfaceColor ?? NSColor.controlBackgroundColor)
            surfaceVariantSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_SurfaceVariant,
                color: theme?.surfaceVariantColor ?? NSColor.underPageBackgroundColor
            )
            borderSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_Border, color: theme?.borderColor ?? NSColor.separatorColor)
            foregroundSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_Foreground, color: theme?.foregroundColor ?? NSColor.labelColor)
            mutedForegroundSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_MutedForeground,
                color: theme?.mutedForegroundColor ?? NSColor.secondaryLabelColor)
            accentSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_Accent,
                color: theme?.accentColor ?? NSColor.controlAccentColor)
            accentForegroundSignal = createAndInstallColorSignal(
                env: env, slot: WuiColorSlot_AccentForeground,
                color: theme?.accentForegroundColor ?? NSColor.white)
        #endif

        // Install fonts (constant - don't change with appearance)
        installSystemFonts(env: env)

        installed = true
    }

    /// Updates the theme for a new color scheme by updating existing reactive signals
    func updateColorScheme(_ colorScheme: ColorScheme) {
        // Update color scheme signal
        let wuiScheme = Self.wuiColorScheme(colorScheme)
        colorSchemeSignal?.setValue(wuiScheme)
        applyColors(for: colorScheme)
    }

    private func applyColors(for colorScheme: ColorScheme) {
        // Update color signals with new system colors
        // The reactive system will automatically propagate these changes
        #if canImport(UIKit)
            let theme = configuredTheme
            backgroundSignal?.setValue(theme?.backgroundColor ?? UIColor.systemBackground)
            surfaceSignal?.setValue(theme?.surfaceColor ?? UIColor.secondarySystemBackground)
            surfaceVariantSignal?.setValue(theme?.surfaceVariantColor ?? UIColor.tertiarySystemBackground)
            borderSignal?.setValue(theme?.borderColor ?? UIColor.separator)
            foregroundSignal?.setValue(theme?.foregroundColor ?? UIColor.label)
            mutedForegroundSignal?.setValue(theme?.mutedForegroundColor ?? UIColor.secondaryLabel)
            accentSignal?.setValue(theme?.accentColor ?? UIColor.tintColor)
            accentForegroundSignal?.setValue(theme?.accentForegroundColor ?? UIColor.white)
        #elseif canImport(AppKit)
            let theme = configuredTheme
            let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
            guard let appearance = NSAppearance(named: appearanceName) else {
                fatalError("WaterUI: failed to create AppKit appearance '\(appearanceName.rawValue)'.")
            }
            appearance.performAsCurrentDrawingAppearance {
                backgroundSignal?.setValue(theme?.backgroundColor ?? NSColor.windowBackgroundColor)
                surfaceSignal?.setValue(theme?.surfaceColor ?? NSColor.controlBackgroundColor)
                surfaceVariantSignal?.setValue(theme?.surfaceVariantColor ?? NSColor.underPageBackgroundColor)
                borderSignal?.setValue(theme?.borderColor ?? NSColor.separatorColor)
                foregroundSignal?.setValue(theme?.foregroundColor ?? NSColor.labelColor)
                mutedForegroundSignal?.setValue(theme?.mutedForegroundColor ?? NSColor.secondaryLabelColor)
                accentSignal?.setValue(theme?.accentColor ?? NSColor.controlAccentColor)
                accentForegroundSignal?.setValue(theme?.accentForegroundColor ?? NSColor.white)
            }
        #endif
    }

    private static func wuiColorScheme(_ colorScheme: ColorScheme) -> WuiColorScheme {
        colorScheme == .dark ? WuiColorScheme_Dark : WuiColorScheme_Light
    }

    private static func bridgeColorScheme(_ colorScheme: WuiColorScheme) -> ColorScheme {
        switch colorScheme {
        case WuiColorScheme_Light:
            return .light
        case WuiColorScheme_Dark:
            return .dark
        default:
            fatalError("WaterUI: unknown WuiColorScheme value \(colorScheme)")
        }
    }

    @MainActor deinit {
        if let observedColorSchemeSignal {
            waterui_drop_computed_color_scheme(observedColorSchemeSignal)
        }
    }

    #if canImport(UIKit)
        private func createAndInstallColorSignal(
            env: WuiEnvironment, slot: WuiColorSlot, color: UIColor
        ) -> ReactiveColorSignal {
            let resolved = WuiResolvedColor.fromUIColor(color)

            let signal = ReactiveColorSignal(color: resolved)
            if let computed = signal.toComputed() {
                waterui_theme_install_color(env.inner, slot, computed)
            }
            return signal
        }
    #elseif canImport(AppKit)
        private func createAndInstallColorSignal(
            env: WuiEnvironment, slot: WuiColorSlot, color: NSColor
        ) -> ReactiveColorSignal {
            let resolved = WuiResolvedColor.fromNSColor(color)

            let signal = ReactiveColorSignal(color: resolved)
            if let computed = signal.toComputed() {
                waterui_theme_install_color(env.inner, slot, computed)
            }
            return signal
        }
    #endif

    private func installSystemFonts(env: WuiEnvironment) {
        #if canImport(UIKit)
            installFontSlot(
                env: env, slot: WuiFontSlot_Body, font: UIFont.preferredFont(forTextStyle: .body))
            installFontSlot(
                env: env, slot: WuiFontSlot_Title, font: UIFont.preferredFont(forTextStyle: .title1)
            )
            installFontSlot(
                env: env, slot: WuiFontSlot_Headline,
                font: UIFont.preferredFont(forTextStyle: .headline))
            installFontSlot(
                env: env, slot: WuiFontSlot_Subheadline,
                font: UIFont.preferredFont(forTextStyle: .subheadline))
            installFontSlot(
                env: env, slot: WuiFontSlot_Caption,
                font: UIFont.preferredFont(forTextStyle: .caption1))
            installFontSlot(
                env: env, slot: WuiFontSlot_Footnote,
                font: UIFont.preferredFont(forTextStyle: .footnote))
        #elseif canImport(AppKit)
            installFontSlot(
                env: env, slot: WuiFontSlot_Body,
                font: NSFont.systemFont(ofSize: NSFont.systemFontSize))
            installFontSlot(
                env: env, slot: WuiFontSlot_Title,
                font: NSFont.systemFont(ofSize: 28, weight: .bold))
            installFontSlot(
                env: env, slot: WuiFontSlot_Headline,
                font: NSFont.systemFont(ofSize: 17, weight: .semibold))
            installFontSlot(
                env: env, slot: WuiFontSlot_Subheadline, font: NSFont.systemFont(ofSize: 15))
            installFontSlot(
                env: env, slot: WuiFontSlot_Caption, font: NSFont.systemFont(ofSize: 12))
            installFontSlot(
                env: env, slot: WuiFontSlot_Footnote, font: NSFont.systemFont(ofSize: 13))
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
            let traits =
                font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
            let weightValue = traits?[.weight] as? CGFloat ?? UIFont.Weight.regular.rawValue
            return uiFontWeightToWuiFontWeight(weightValue)
        }

        private func uiFontWeightToWuiFontWeight(_ weight: CGFloat) -> WuiFontWeight {
            // UIFont.Weight ranges from -1.0 (ultra-light) to 1.0 (black), with 0.0 being regular
            switch weight {
            case ...(-0.8): return WuiFontWeight_Thin
            case (-0.8) ... (-0.6): return WuiFontWeight_UltraLight
            case (-0.6) ... (-0.4): return WuiFontWeight_Light
            case (-0.4) ... (0.0): return WuiFontWeight_Normal
            case (0.0) ... (0.23): return WuiFontWeight_Medium
            case (0.23) ... (0.3): return WuiFontWeight_SemiBold
            case (0.3) ... (0.5): return WuiFontWeight_Bold
            case (0.5) ... (0.8): return WuiFontWeight_UltraBold
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
            let traits =
                font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            let weightValue = traits?[.weight] as? CGFloat ?? NSFont.Weight.regular.rawValue
            return nsFontWeightToWuiFontWeight(weightValue)
        }

        private func nsFontWeightToWuiFontWeight(_ weight: CGFloat) -> WuiFontWeight {
            // NSFont.Weight ranges from -1.0 to 1.0, similar to UIFont.Weight
            switch weight {
            case ...(-0.8): return WuiFontWeight_Thin
            case (-0.8) ... (-0.6): return WuiFontWeight_UltraLight
            case (-0.6) ... (-0.4): return WuiFontWeight_Light
            case (-0.4) ... (0.0): return WuiFontWeight_Normal
            case (0.0) ... (0.23): return WuiFontWeight_Medium
            case (0.23) ... (0.3): return WuiFontWeight_SemiBold
            case (0.3) ... (0.5): return WuiFontWeight_Bold
            case (0.5) ... (0.8): return WuiFontWeight_UltraBold
            default: return WuiFontWeight_Black
            }
        }
    #endif
}

// MARK: - Root Context

/// Global environment pointer - waterui_init() must only be called once per process.
/// This is stored globally to survive window close/reopen cycles on macOS.
/// Internal access for window manager to use when creating new windows.
@MainActor
var globalEnvironment: WuiEnvironment?

/// Represents a window in the application.
@MainActor
public struct WuiWindowContext {
    /// The content view of the window.
    public let content: OpaquePointer
    /// Whether the window is closable.
    public let closable: Bool
    /// Whether the window is resizable.
    public let resizable: Bool
    /// Optional toolbar content (nil if none).
    public let toolbar: OpaquePointer?
    /// The visual style of the window.
    public let style: WuiWindowStyle
    /// The title binding.
    public let title: OpaquePointer?
    /// The frame binding.
    public let frame: OpaquePointer?
    /// The state binding.
    public let state: OpaquePointer?

    init(from window: WuiWindow) {
        self.content = window.content
        self.closable = window.closable
        self.resizable = window.resizable
        self.toolbar = window.toolbar
        self.style = window.style
        self.title = window.title
        self.frame = window.frame
        self.state = window.state
    }
}

@MainActor
public final class WuiRootContext {
    public let env: WuiEnvironment
    private let app: WuiApp
    private let mainWindow: WuiWindowContext
    var themeBridge: ThemeBridge?

    /// The root platform view
    #if canImport(UIKit)
        public private(set) lazy var rootView: UIView = {
            WuiAnyView(anyview: mainWindow.content, env: env)
        }()
    #elseif canImport(AppKit)
        public private(set) lazy var rootView: NSView = {
            WuiAnyView(anyview: mainWindow.content, env: env)
        }()
    #endif

    /// The main window configuration
    public var window: WuiWindowContext {
        mainWindow
    }

    public init() {
        // 1. Create environment (waterui_init) - only once per process
        // IMPORTANT: We use a raw pointer here because waterui_app() takes ownership.
        // We must NOT wrap it in WuiEnvironment until after waterui_app() returns,
        // otherwise we'd have an invalid pointer when WuiEnvironment tries to drop.
        let initEnvPtr: OpaquePointer
        let isFirstInit: Bool
        if let existing = globalEnvironment {
            // Hot reload / subsequent init - reuse existing valid environment
            initEnvPtr = existing.inner
            isFirstInit = false
        } else {
            // First time - create new environment
            initEnvPtr = waterui_init()
            // Install services into the raw pointer (before ownership transfers)
            installWebViewController(env: initEnvPtr)
            installWindowManager(env: initEnvPtr)
            installViewRenderer(env: initEnvPtr)
            isFirstInit = true
        }

        // 2. Detect system color scheme
        #if canImport(UIKit)
            let systemScheme: ThemeBridge.ColorScheme =
                UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        #elseif canImport(AppKit)
            let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
            let systemScheme: ThemeBridge.ColorScheme =
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        #endif

        // 3. Install system theme (colors, fonts, AND color scheme) into env
        // This must be done BEFORE calling waterui_app so user code sees the theme
        // Use a temporary WuiEnvironment wrapper for ThemeBridge API compatibility
        let tempEnv = WuiEnvironment(initEnvPtr)
        self.themeBridge = ThemeBridge(env: tempEnv, colorScheme: systemScheme)

        // 4. Create the app by calling waterui_app(env)
        // The user's app(env) receives the environment with theme installed,
        // creates App::new(content, env), and returns App { windows, env }
        // Native takes ownership of the environment and gets it back in the App.
        // IMPORTANT: After this call, initEnvPtr is invalid - ownership transferred to Rust.
        self.app = waterui_app(initEnvPtr)

        // Prevent tempEnv from dropping the now-invalid pointer
        // by replacing its inner with the valid app.env
        tempEnv.inner = app.env

        // 5. Use the environment returned from the app for rendering
        // (App::new injects FullScreenOverlayManager into it)
        // Reuse tempEnv since it now has the valid pointer
        self.env = tempEnv

        // 6. Update globalEnvironment to point to the valid environment
        // This is critical - the original initEnvPtr is now owned by Rust
        if isFirstInit {
            globalEnvironment = self.env
        }

        // 7. Extract main window (first window in array)
        let windowSlice = app.windows.vtable.slice(app.windows.data)
        guard windowSlice.len > 0, let windowsPtr = windowSlice.head else {
            fatalError("waterui_app() returned App with no windows")
        }
        self.mainWindow = WuiWindowContext(from: windowsPtr.pointee)
        self.themeBridge?.bindToEnvironmentColorScheme(env: self.env)
    }

    /// Updates the theme for a new color scheme.
    /// Uses reactive signals so WaterUI views automatically update.
    public func updateColorScheme(_ colorScheme: ThemeBridge.ColorScheme) {
        themeBridge?.updateColorScheme(colorScheme)
    }
}

// MARK: - Public UIKit Root View Controller

#if canImport(UIKit)
    /// A custom view that fills the entire window but still propagates safe area insets to children.
    /// This allows ScrollView to receive correct safe area insets for content adjustment.
    @MainActor
    private final class FullScreenView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            // Force frame to fill entire window
            if let window = window {
                frame = window.bounds
            }
        }

        // Propagate actual safe area insets from window to children
        override var safeAreaInsets: UIEdgeInsets {
            window?.safeAreaInsets ?? super.safeAreaInsets
        }

        // Allow touches to reach content that extends into safe area (e.g., via IgnoreSafeArea)
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let result = super.hitTest(point, with: event)
            // If no hit in subviews, check if point is in any subview's extended frame
            if result == self {
                for subview in subviews.reversed() {
                    let convertedPoint = convert(point, to: subview)
                    if let hit = subview.hitTest(convertedPoint, with: event) {
                        return hit
                    }
                }
            }
            return result
        }
    }

    /// A UIKit view controller that hosts the WaterUI root view.
    @MainActor
    public final class WaterUIViewController: UIViewController {
        private let context: WuiRootContext

        public init() {
            self.context = WuiRootContext()
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        public override func loadView() {
            // Use a custom view that fills the window but propagates safe area insets
            view = FullScreenView()
            view.backgroundColor = .systemBackground
        }

        public override func viewDidLoad() {
            super.viewDidLoad()

            let rootView = context.rootView
            // Use manual frame-based layout, not AutoLayout
            rootView.translatesAutoresizingMaskIntoConstraints = true
            view.addSubview(rootView)
        }

        public override func viewWillLayoutSubviews() {
            super.viewWillLayoutSubviews()
            // Force view to fill the entire window
            if let window = view.window {
                view.frame = window.bounds
            }
        }

        public override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()

            let safeInsets = view.safeAreaInsets
            let safeFrame = CGRect(
                x: safeInsets.left,
                y: safeInsets.top,
                width: view.bounds.width - safeInsets.left - safeInsets.right,
                height: view.bounds.height - safeInsets.top - safeInsets.bottom
            )

            let usesSafeArea = shouldApplySafeArea(to: context.rootView)
            context.rootView.frame = usesSafeArea ? safeFrame : view.bounds
            context.rootView.setNeedsLayout()
            context.rootView.layoutIfNeeded()
        }

        private func shouldApplySafeArea(to rootView: UIView) -> Bool {
            guard let contentView = primaryContentView(from: rootView) else {
                return true
            }
            return !isScrollableRootView(contentView)
        }

        private func primaryContentView(from rootView: UIView) -> UIView? {
            guard let inner = rootView.subviews.first else { return nil }
            guard !inner.subviews.isEmpty else { return inner }
            // App::new wraps content + overlay in a ZStack; use the main content layer.
            return inner.subviews.first
        }

        private func isScrollableRootView(_ view: UIView) -> Bool {
            var current: UIView? = view
            while let node = current {
                if node is WuiScroll || node is WuiList {
                    return true
                }
                let children = node.subviews
                if children.count == 1 {
                    current = children.first
                    continue
                }
                return false
            }
            return false
        }

        public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?)
        {
            super.traitCollectionDidChange(previousTraitCollection)

            if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
                let colorScheme: ThemeBridge.ColorScheme =
                    traitCollection.userInterfaceStyle == .dark ? .dark : .light
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

        public override init(frame frameRect: NSRect) {
            self.context = WuiRootContext()
            super.init(frame: frameRect)
            setupView()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupView() {
            wantsLayer = true
            // Don't set static backgroundColor - let it follow window appearance

            let rootView = context.rootView
            // Use manual frame-based layout, not AutoLayout
            rootView.translatesAutoresizingMaskIntoConstraints = true
            addSubview(rootView)

            // Note: We don't observe system appearance changes here.
            // Color scheme is controlled by Rust via .install(Theme::new().color_scheme(...))
            // and applied to window by RootThemeController.
        }

        public override var isFlipped: Bool { true }

        public override func layout() {
            super.layout()

            // Manually size root view to fill bounds and trigger layout
            context.rootView.frame = bounds
            context.rootView.needsLayout = true
            context.rootView.layoutSubtreeIfNeeded()
        }

        public override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            // Don't interfere with user's color scheme setting.
            // RootThemeController handles applying the user's color scheme to the window.
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

        public func updateUIViewController(
            _ uiViewController: WaterUIViewController, context: Context
        ) {
            // No updates needed - WaterUI handles its own reactivity
        }
    }
#endif

extension Logger {
    static let waterui = Logger(subsystem: "dev.waterui", category: "WaterUI")
}
