import CWaterUI
import SwiftUI

@MainActor
protocol WuiComponent: View {
    static var id: String { get }
    init(anyview: OpaquePointer, env: WuiEnvironment)
}

extension WuiComponent {
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
    #if os(iOS) || os(tvOS) || os(watchOS)
    func setValue(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        setValue(WuiResolvedColor(red: Float(r), green: Float(g), blue: Float(b), opacity: Float(a), headroom: 0.0))
    }
    #elseif os(macOS)
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
final class ThemeBridge: ObservableObject {
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
        #if os(iOS) || os(tvOS)
        backgroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Background, color: UIColor.systemBackground)
        surfaceSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Surface, color: UIColor.secondarySystemBackground)
        surfaceVariantSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_SurfaceVariant, color: UIColor.tertiarySystemBackground)
        borderSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Border, color: UIColor.separator)
        foregroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Foreground, color: UIColor.label)
        mutedForegroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_MutedForeground, color: UIColor.secondaryLabel)
        accentSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Accent, color: UIColor.tintColor)
        accentForegroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_AccentForeground, color: UIColor.white)
        #elseif os(macOS)
        backgroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Background, color: NSColor.windowBackgroundColor)
        surfaceSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Surface, color: NSColor.controlBackgroundColor)
        surfaceVariantSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_SurfaceVariant, color: NSColor.underPageBackgroundColor)
        borderSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Border, color: NSColor.separatorColor)
        foregroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Foreground, color: NSColor.labelColor)
        mutedForegroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_MutedForeground, color: NSColor.secondaryLabelColor)
        accentSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Accent, color: NSColor.controlAccentColor)
        accentForegroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_AccentForeground, color: NSColor.white)
        #elseif os(watchOS)
        backgroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Background, color: isDark ? UIColor.black : UIColor.white)
        foregroundSignal = createAndInstallColorSignal(env: env, slot: WuiColorSlot_Foreground, color: isDark ? UIColor.white : UIColor.black)
        #endif
        
        // Install fonts (constant - don't change with appearance)
        installSystemFonts(env: env)
        
        installed = true
    }
    
    /// Updates the theme for a new color scheme by updating existing reactive signals
    func updateColorScheme(_ colorScheme: ColorScheme) {
        let isDark = colorScheme == .dark
        
        // Update color signals with new system colors
        // The reactive system will automatically propagate these changes
        #if os(iOS) || os(tvOS)
        backgroundSignal?.setValue(UIColor.systemBackground)
        surfaceSignal?.setValue(UIColor.secondarySystemBackground)
        surfaceVariantSignal?.setValue(UIColor.tertiarySystemBackground)
        borderSignal?.setValue(UIColor.separator)
        foregroundSignal?.setValue(UIColor.label)
        mutedForegroundSignal?.setValue(UIColor.secondaryLabel)
        accentSignal?.setValue(UIColor.tintColor)
        accentForegroundSignal?.setValue(UIColor.white)
        #elseif os(macOS)
        backgroundSignal?.setValue(NSColor.windowBackgroundColor)
        surfaceSignal?.setValue(NSColor.controlBackgroundColor)
        surfaceVariantSignal?.setValue(NSColor.underPageBackgroundColor)
        borderSignal?.setValue(NSColor.separatorColor)
        foregroundSignal?.setValue(NSColor.labelColor)
        mutedForegroundSignal?.setValue(NSColor.secondaryLabelColor)
        accentSignal?.setValue(NSColor.controlAccentColor)
        accentForegroundSignal?.setValue(NSColor.white)
        #elseif os(watchOS)
        backgroundSignal?.setValue(isDark ? UIColor.black : UIColor.white)
        foregroundSignal?.setValue(isDark ? UIColor.white : UIColor.black)
        #endif
    }
    
    #if os(iOS) || os(tvOS) || os(watchOS)
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
    #elseif os(macOS)
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
        #if os(iOS) || os(tvOS)
        installFontSlot(env: env, slot: WuiFontSlot_Body, font: UIFont.preferredFont(forTextStyle: .body))
        installFontSlot(env: env, slot: WuiFontSlot_Title, font: UIFont.preferredFont(forTextStyle: .title1))
        installFontSlot(env: env, slot: WuiFontSlot_Headline, font: UIFont.preferredFont(forTextStyle: .headline))
        installFontSlot(env: env, slot: WuiFontSlot_Subheadline, font: UIFont.preferredFont(forTextStyle: .subheadline))
        installFontSlot(env: env, slot: WuiFontSlot_Caption, font: UIFont.preferredFont(forTextStyle: .caption1))
        installFontSlot(env: env, slot: WuiFontSlot_Footnote, font: UIFont.preferredFont(forTextStyle: .footnote))
        #elseif os(macOS)
        installFontSlot(env: env, slot: WuiFontSlot_Body, font: NSFont.systemFont(ofSize: NSFont.systemFontSize))
        installFontSlot(env: env, slot: WuiFontSlot_Title, font: NSFont.systemFont(ofSize: 28, weight: .bold))
        installFontSlot(env: env, slot: WuiFontSlot_Headline, font: NSFont.systemFont(ofSize: 17, weight: .semibold))
        installFontSlot(env: env, slot: WuiFontSlot_Subheadline, font: NSFont.systemFont(ofSize: 15))
        installFontSlot(env: env, slot: WuiFontSlot_Caption, font: NSFont.systemFont(ofSize: 12))
        installFontSlot(env: env, slot: WuiFontSlot_Footnote, font: NSFont.systemFont(ofSize: 13))
        #elseif os(watchOS)
        installFontSlot(env: env, slot: WuiFontSlot_Body, font: UIFont.preferredFont(forTextStyle: .body))
        installFontSlot(env: env, slot: WuiFontSlot_Title, font: UIFont.preferredFont(forTextStyle: .headline))
        installFontSlot(env: env, slot: WuiFontSlot_Caption, font: UIFont.preferredFont(forTextStyle: .caption1))
        #endif
    }
    
    #if os(iOS) || os(tvOS) || os(watchOS)
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
    #elseif os(macOS)
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
final class WuiRootContext: ObservableObject {
    let env: WuiEnvironment
    let rootView: WuiAnyView
    var themeBridge: ThemeBridge?

    init(colorScheme: ColorScheme) {
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
        self.rootView = WuiAnyView(anyview: mainView, env: environment)
    }
    
    /// Updates the theme for a new color scheme.
    /// Uses reactive signals so WaterUI views automatically update.
    func updateColorScheme(_ colorScheme: ColorScheme) {
        themeBridge?.updateColorScheme(colorScheme)
    }

    deinit {
        // `WuiAnyView` owns the underlying pointer and will drop it on deinit.
    }
}

// MARK: - Public App View

public struct App: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var context: WuiRootContext
    
    public init() {
        // Initialize with light scheme, will update on appear
        _context = StateObject(wrappedValue: WuiRootContext(colorScheme: .light))
    }

    public var body: some View {
        GeometryReader { proxy in
            context.rootView
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .topLeading
                )
        }
        .onChange(of: colorScheme) { oldValue, newValue in
            context.updateColorScheme(newValue)
        }
        .onAppear {
            context.updateColorScheme(colorScheme)
        }
    }
}
