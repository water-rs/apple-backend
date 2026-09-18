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
    guard let axis = WuiStretchAxis(rawValue: ffi.rawValue) else {
      fatalError("Unsupported WaterUI stretch axis: \(ffi.rawValue)")
    }
    self = axis
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
public protocol WuiComponent: PlatformView {
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

  /// Receives the proposal the parent layout selected when it placed this
  /// view — the `proposal` field of the child's `WuiSubviewPlacement`.
  ///
  /// This is distinct from measurement: a layout probes a child under several
  /// proposals and only the selected one is delivered here. Containers store
  /// it to drive their own placement pass, transparent wrappers forward it to
  /// their content, and leaves ignore it. Components whose children are
  /// placed by native hosting (nav pages, table cells, constraint-hosted
  /// labels) leave the default: those children construct their own bounded
  /// offer at the boundary.
  func setPlacementProposal(_ proposal: WuiProposalSize)
}

extension WuiComponent {
  public var stretchAxis: WuiStretchAxis { .none }
  public func layoutPriority() -> Int32 { 0 }
  public func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    WuiViewDimensions(size: sizeThatFits(proposal))
  }
  public func setPlacementProposal(_ proposal: WuiProposalSize) {}

  /// 128-bit view ID for O(1) registry lookup
  static var viewId: WuiViewId {
    WuiViewId(rawId)
  }
}

// MARK: - Reactive Signal Infrastructure

private final class ReactiveWatcherGuardContext: @unchecked Sendable {
  private let remove: @Sendable () -> Void

  init(remove: @escaping @Sendable () -> Void) {
    self.remove = remove
  }

  func removeWatcher() {
    remove()
  }
}

private struct ReactiveWatcherPointer: @unchecked Sendable {
  let raw: OpaquePointer
}

private let dropReactiveWatcherGuardContext: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
  rawPtr in
  guard let rawPtr else {
    fatalError("Reactive watcher guard received a null context")
  }
  Unmanaged<ReactiveWatcherGuardContext>
    .fromOpaque(rawPtr)
    .takeRetainedValue()
    .removeWatcher()
}

private func makeReactiveWatcherGuard(
  remove: @escaping @Sendable () -> Void
) -> OpaquePointer {
  let context = ReactiveWatcherGuardContext(remove: remove)
  let contextPtr = Unmanaged.passRetained(context).toOpaque()
  guard let guardPtr = waterui_new_watcher_guard(contextPtr, dropReactiveWatcherGuardContext) else {
    _ = Unmanaged<ReactiveWatcherGuardContext>.fromOpaque(contextPtr).takeRetainedValue()
    fatalError("Failed to create a reactive watcher guard")
  }
  return guardPtr
}

/// The watcher bookkeeping every native-controlled signal repeats.
///
/// What differs per signal is its value and the three C symbols the ABI needs
/// as literal `@convention(c)` closures. Registering, notifying and releasing
/// watchers does not differ, and getting that dance wrong leaks a watcher or
/// releases one twice, so it lives here once.
final class ReactiveWatcherList<Value>: @unchecked Sendable {
  private let call: (OpaquePointer, Value) -> Void
  private let release: (OpaquePointer) -> Void
  private var watchers: [OpaquePointer] = []

  /// The value handed to every watcher registered from here on.
  var value: Value

  init(
    value: Value,
    call: @escaping (OpaquePointer, Value) -> Void,
    release: @escaping (OpaquePointer) -> Void
  ) {
    self.value = value
    self.call = call
    self.release = release
  }

  func addWatcher(_ watcher: OpaquePointer) {
    precondition(!watchers.contains(watcher), "Reactive watcher was registered twice")
    watchers.append(watcher)
  }

  func notifyWatchers() {
    for watcher in watchers {
      call(watcher, value)
    }
  }

  func removeWatcher(_ watcher: OpaquePointer) {
    guard let index = watchers.firstIndex(of: watcher) else {
      fatalError("Reactive watcher was released more than once")
    }
    watchers.remove(at: index)
    release(watcher)
  }

  func cleanup() {
    for watcher in watchers {
      release(watcher)
    }
    watchers.removeAll()
  }
}

/// A native-controlled reactive color signal.
/// This allows Swift to create and update color signals that notify WaterUI watchers.
@MainActor
final class ReactiveColorSignal {
  private typealias State = ReactiveWatcherList<WuiResolvedColor>

  private let state: State
  private let statePtr: UnsafeMutableRawPointer
  private var computedPtr: OpaquePointer?

  init(color: WuiResolvedColor) {
    self.state = State(
      value: color,
      call: { waterui_call_watcher_resolved_color($0, $1) },
      release: { waterui_drop_watcher_resolved_color($0) }
    )
    self.statePtr = Unmanaged.passRetained(state).toOpaque()
  }

  deinit {
    state.cleanup()
  }

  /// Gets the computed pointer for installation into WaterUI environment.
  func toComputed() -> OpaquePointer {
    if let computedPtr { return computedPtr }
    guard
      let computed = waterui_new_computed_resolved_color(
        statePtr,
        { ptr -> WuiResolvedColor in
          guard let ptr else {
            fatalError("ReactiveColorSignal get received a null state pointer")
          }
          return Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
            .takeUnretainedValue().value
        },
        { ptr, watcher -> OpaquePointer? in
          guard let ptr else {
            fatalError("ReactiveColorSignal watch received a null state pointer")
          }
          guard let watcher else {
            fatalError("ReactiveColorSignal watch received a null watcher pointer")
          }
          let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
            .takeUnretainedValue()
          let watcherPointer = ReactiveWatcherPointer(raw: watcher)
          state.addWatcher(watcherPointer.raw)
          return makeReactiveWatcherGuard { [state, watcherPointer] in
            state.removeWatcher(watcherPointer.raw)
          }
        },
        { ptr in
          guard let ptr else {
            fatalError("ReactiveColorSignal drop received a null state pointer")
          }
          Unmanaged<State>.fromOpaque(ptr).takeRetainedValue().cleanup()
        }
      )
    else {
      fatalError("ReactiveColorSignal failed to create its computed signal")
    }
    computedPtr = computed
    return computed
  }

  /// Updates the color and notifies all watchers.
  func setValue(_ color: WuiResolvedColor) {
    let current = state.value
    guard
      current.red != color.red || current.green != color.green
        || current.blue != color.blue || current.opacity != color.opacity
        || current.headroom != color.headroom
    else { return }
    state.value = color
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
  private typealias State = ReactiveWatcherList<WuiColorScheme>

  private let state: State
  private let statePtr: UnsafeMutableRawPointer
  private var computedPtr: OpaquePointer?

  init(scheme: WuiColorScheme) {
    self.state = State(
      value: scheme,
      call: { waterui_call_watcher_color_scheme($0, $1) },
      release: { waterui_drop_watcher_color_scheme($0) }
    )
    self.statePtr = Unmanaged.passRetained(state).toOpaque()
  }

  deinit {
    state.cleanup()
  }

  func toComputed() -> OpaquePointer {
    if let computedPtr { return computedPtr }
    guard
      let computed = waterui_new_computed_color_scheme(
        statePtr,
        { ptr -> WuiColorScheme in
          guard let ptr else {
            fatalError("ReactiveColorSchemeSignal get received a null state pointer")
          }
          return Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
            .takeUnretainedValue().value
        },
        { ptr, watcher -> OpaquePointer? in
          guard let ptr else {
            fatalError("ReactiveColorSchemeSignal watch received a null state pointer")
          }
          guard let watcher else {
            fatalError("ReactiveColorSchemeSignal watch received a null watcher pointer")
          }
          let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
            .takeUnretainedValue()
          let watcherPointer = ReactiveWatcherPointer(raw: watcher)
          state.addWatcher(watcherPointer.raw)
          return makeReactiveWatcherGuard { [state, watcherPointer] in
            state.removeWatcher(watcherPointer.raw)
          }
        },
        { ptr in
          guard let ptr else {
            fatalError("ReactiveColorSchemeSignal drop received a null state pointer")
          }
          Unmanaged<State>.fromOpaque(ptr).takeRetainedValue().cleanup()
        }
      )
    else {
      fatalError("ReactiveColorSchemeSignal failed to create its computed signal")
    }
    computedPtr = computed
    return computed
  }

  func setValue(_ scheme: WuiColorScheme) {
    guard state.value.rawValue != scheme.rawValue else { return }
    state.value = scheme
    state.notifyWatchers()
  }
}

/// The wire form of a natively published font: the face's own metrics,
/// since the platform font object itself cannot cross the FFI boundary.
private func wuiReactiveResolvedFont(
  size: Float, weight: WuiFontWeight, lineHeight: Float
) -> CWaterUI.WuiResolvedFont {
  var font = waterui_resolved_font_new(size, weight)
  font.line_height = lineHeight
  return font
}

/// A native-controlled reactive font signal.
@MainActor
final class ReactiveFontSignal {
  /// A font is published as size plus weight plus the face's line pitch and
  /// resolved at notify time, the same way the environment resolves one.
  ///
  /// `lineHeight` is the face's full line pitch — `lineHeight + leading` —
  /// because the resolved-font wire form carries no platform font object:
  /// shipping only size and weight makes the reader rebuild a leading-less
  /// `systemFont`, and every text loses the text style's inter-line leading.
  struct Spec {
    var size: Float
    var weight: WuiFontWeight
    var lineHeight: Float
  }

  private typealias State = ReactiveWatcherList<Spec>

  private let state: State
  private let statePtr: UnsafeMutableRawPointer
  private var computedPtr: OpaquePointer?

  init(size: Float, weight: WuiFontWeight, lineHeight: Float) {
    self.state = State(
      value: Spec(size: size, weight: weight, lineHeight: lineHeight),
      call: {
        waterui_call_watcher_resolved_font(
          $0, wuiReactiveResolvedFont(size: $1.size, weight: $1.weight, lineHeight: $1.lineHeight))
      },
      release: { waterui_drop_watcher_resolved_font($0) }
    )
    self.statePtr = Unmanaged.passRetained(state).toOpaque()
  }

  deinit {
    state.cleanup()
  }

  func toComputed() -> OpaquePointer {
    if let computedPtr { return computedPtr }
    guard
      let computed = waterui_new_computed_resolved_font(
        statePtr,
        { ptr -> WuiResolvedFont in
          guard let ptr else {
            fatalError("ReactiveFontSignal get received a null state pointer")
          }
          let spec = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
            .takeUnretainedValue().value
          return wuiReactiveResolvedFont(
            size: spec.size, weight: spec.weight, lineHeight: spec.lineHeight)
        },
        { ptr, watcher -> OpaquePointer? in
          guard let ptr else {
            fatalError("ReactiveFontSignal watch received a null state pointer")
          }
          guard let watcher else {
            fatalError("ReactiveFontSignal watch received a null watcher pointer")
          }
          let state = Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
            .takeUnretainedValue()
          let watcherPointer = ReactiveWatcherPointer(raw: watcher)
          state.addWatcher(watcherPointer.raw)
          return makeReactiveWatcherGuard { [state, watcherPointer] in
            state.removeWatcher(watcherPointer.raw)
          }
        },
        { ptr in
          guard let ptr else {
            fatalError("ReactiveFontSignal drop received a null state pointer")
          }
          Unmanaged<State>.fromOpaque(ptr).takeRetainedValue().cleanup()
        }
      )
    else {
      fatalError("ReactiveFontSignal failed to create its computed signal")
    }
    computedPtr = computed
    return computed
  }

  #if canImport(UIKit)
    func setValue(size: Float, weight: WuiFontWeight, lineHeight: Float) {
      let current = state.value
      guard
        current.size != size || current.weight.rawValue != weight.rawValue
          || current.lineHeight != lineHeight
      else { return }
      state.value = Spec(size: size, weight: weight, lineHeight: lineHeight)
      state.notifyWatchers()
    }
  #endif
}

// MARK: - Theme Bridge

/// Observes system appearance changes and updates theme reactively.
///
/// This class uses `ReactiveColorSignal` to create signals that can be updated
/// when system appearance changes, triggering automatic UI updates through
/// WaterUI's reactive system.
@MainActor
public final class ThemeBridge {
  #if canImport(UIKit)
    private struct ColorSignalEntry {
      let signal: ReactiveColorSignal
      let resolve: @MainActor () -> UIColor
    }

    private struct FontSignalEntry {
      let textStyle: UIFont.TextStyle
      let signal: ReactiveFontSignal
    }

    private var fontSignalEntries: [FontSignalEntry] = []
    private var contentSizeCategoryObserver: NSObjectProtocol?
  #elseif canImport(AppKit)
    private struct ColorSignalEntry {
      let signal: ReactiveColorSignal
      let resolve: @MainActor () -> NSColor
    }

    private var fontSignals: [ReactiveFontSignal] = []
  #endif

  private let colorSchemeSignal: ReactiveColorSchemeSignal
  private let colorSignalEntries: [ColorSignalEntry]
  private var observedColorScheme: WuiComputedObservation<WuiColorScheme>?

  public enum ColorScheme {
    case light
    case dark
  }

  init(env: WuiEnvironment, colorScheme: ColorScheme) {
    let schemeSignal = ReactiveColorSchemeSignal(scheme: Self.wuiColorScheme(colorScheme))
    waterui_theme_install_color_scheme(env.inner, schemeSignal.toComputed())
    colorSchemeSignal = schemeSignal
    colorSignalEntries = Self.makeColorSignalEntries(env: env)
    installSystemFonts(env: env)
  }

  func bindToEnvironmentColorScheme(env: WuiEnvironment) {
    guard let signal = waterui_theme_color_scheme(env.inner) else {
      fatalError("WaterUI: failed to read root color scheme signal from the environment.")
    }

    observedColorScheme = nil
    let observation = WuiComputedObservation(WuiComputed<WuiColorScheme>(signal)) {
      [weak self] scheme, _ in
      self?.applyColors(for: Self.bridgeColorScheme(scheme))
    }
    observedColorScheme = observation
    applyColors(for: Self.bridgeColorScheme(observation.value))
  }

  /// Updates the theme for a new color scheme by updating existing reactive signals
  func updateColorScheme(_ colorScheme: ColorScheme) {
    let previousActiveScheme = observedColorScheme?.value
    colorSchemeSignal.setValue(Self.wuiColorScheme(colorScheme))
    let activeScheme = observedColorScheme?.value ?? Self.wuiColorScheme(colorScheme)
    if previousActiveScheme?.rawValue == activeScheme.rawValue {
      applyColors(for: Self.bridgeColorScheme(activeScheme))
    }
  }

  private func applyColors(for colorScheme: ColorScheme) {
    #if canImport(UIKit)
      let traits = UITraitCollection(
        userInterfaceStyle: colorScheme == .dark ? .dark : .light
      )
      for entry in colorSignalEntries {
        entry.signal.setValue(entry.resolve().resolvedColor(with: traits))
      }
    #elseif canImport(AppKit)
      let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
      guard let appearance = NSAppearance(named: appearanceName) else {
        fatalError("WaterUI: failed to create AppKit appearance '\(appearanceName.rawValue)'.")
      }
      appearance.performAsCurrentDrawingAppearance {
        for entry in colorSignalEntries {
          entry.signal.setValue(entry.resolve())
        }
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
    #if canImport(UIKit)
      if let contentSizeCategoryObserver {
        NotificationCenter.default.removeObserver(contentSizeCategoryObserver)
      }
    #endif
    observedColorScheme = nil
  }

  #if canImport(UIKit)
    private static func makeColorSignalEntries(env: WuiEnvironment) -> [ColorSignalEntry] {
      [
        installColorSignal(env: env, slot: WuiColorSlot_Background) {
          UIColor.systemBackground
        },
        installColorSignal(env: env, slot: WuiColorSlot_Surface) {
          UIColor.secondarySystemBackground
        },
        installColorSignal(env: env, slot: WuiColorSlot_SurfaceVariant) {
          // Mirrors the AppKit mapping: `tertiarySystemBackground` is pure
          // white in light mode — identical to the Background slot — so an
          // "alternate surface" filled with it is invisible. The system fill
          // is the color intended for input fields and shape fills.
          UIColor.tertiarySystemFill
        },
        installColorSignal(env: env, slot: WuiColorSlot_Border) { UIColor.separator },
        installColorSignal(env: env, slot: WuiColorSlot_Foreground) { UIColor.label },
        installColorSignal(env: env, slot: WuiColorSlot_MutedForeground) {
          UIColor.secondaryLabel
        },
        installColorSignal(env: env, slot: WuiColorSlot_Accent) { Self.appAccentColor() },
        installColorSignal(env: env, slot: WuiColorSlot_AccentForeground) { UIColor.white },
        installColorSignal(env: env, slot: WuiColorSlot_AccentContainer) {
          Self.appAccentColor().withAlphaComponent(0.16)
        },
        installColorSignal(env: env, slot: WuiColorSlot_Tertiary) { UIColor.systemPurple },
        installColorSignal(env: env, slot: WuiColorSlot_TertiaryContainer) {
          UIColor.systemPurple.withAlphaComponent(0.16)
        },
        // UIKit has no semantic "selection fill": a selected row is tinted with
        // the app's accent, and its content is drawn in the same on-accent color
        // the accent pair uses.
        installColorSignal(env: env, slot: WuiColorSlot_SelectionContainer) {
          Self.appAccentColor()
        },
        installColorSignal(env: env, slot: WuiColorSlot_SelectionForeground) { UIColor.white },
        // White on systemRed is what UIKit draws for destructive fills.
        installColorSignal(env: env, slot: WuiColorSlot_Error) { UIColor.systemRed },
        installColorSignal(env: env, slot: WuiColorSlot_ErrorForeground) { UIColor.white },
      ]
    }

    /// The app's asset-catalog accent, the same source SwiftUI resolves for
    /// its default tint. Without an asset catalog SwiftUI falls back to the
    /// system accent, while `UIColor.tintColor` resolves to the display-P3
    /// global tint — a different nominal blue — so the fallback states
    /// `systemBlue` itself.
    private static func appAccentColor() -> UIColor {
      UIColor(named: "AccentColor") ?? .systemBlue
    }

    private static func installColorSignal(
      env: WuiEnvironment,
      slot: WuiColorSlot,
      resolve: @escaping @MainActor () -> UIColor
    ) -> ColorSignalEntry {
      let signal = ReactiveColorSignal(color: WuiResolvedColor.fromUIColor(resolve()))
      waterui_theme_install_color(env.inner, slot, signal.toComputed())
      return ColorSignalEntry(signal: signal, resolve: resolve)
    }
  #elseif canImport(AppKit)
    private static func makeColorSignalEntries(env: WuiEnvironment) -> [ColorSignalEntry] {
      [
        installColorSignal(env: env, slot: WuiColorSlot_Background) {
          NSColor.windowBackgroundColor
        },
        installColorSignal(env: env, slot: WuiColorSlot_Surface) {
          NSColor.controlBackgroundColor
        },
        installColorSignal(env: env, slot: WuiColorSlot_SurfaceVariant) {
          // `underPageBackgroundColor` is the dark document-canvas color (58.8%
          // gray at 90% opacity in light mode) and reads as a black block on a
          // light UI. `tertiarySystemFill` is AppKit's fill for input fields
          // and search bars, adapting correctly to both appearances.
          NSColor.tertiarySystemFill
        },
        installColorSignal(env: env, slot: WuiColorSlot_Border) { NSColor.separatorColor },
        installColorSignal(env: env, slot: WuiColorSlot_Foreground) { NSColor.labelColor },
        installColorSignal(env: env, slot: WuiColorSlot_MutedForeground) {
          NSColor.secondaryLabelColor
        },
        installColorSignal(env: env, slot: WuiColorSlot_Accent) {
          NSColor.controlAccentColor
        },
        installColorSignal(env: env, slot: WuiColorSlot_AccentForeground) {
          // The semantic "text on accent" color: flips to black under accent
          // colors and contrast settings where a constant white would fail.
          NSColor.alternateSelectedControlTextColor
        },
        installColorSignal(env: env, slot: WuiColorSlot_AccentContainer) {
          NSColor.controlAccentColor.withAlphaComponent(0.16)
        },
        installColorSignal(env: env, slot: WuiColorSlot_Tertiary) { NSColor.systemPurple },
        installColorSignal(env: env, slot: WuiColorSlot_TertiaryContainer) {
          NSColor.systemPurple.withAlphaComponent(0.16)
        },
        installColorSignal(env: env, slot: WuiColorSlot_SelectionContainer) {
          // AppKit's own emphasized selection fill, the color a focused table
          // paints behind a selected row.
          NSColor.selectedContentBackgroundColor
        },
        installColorSignal(env: env, slot: WuiColorSlot_SelectionForeground) {
          // The matching content color for that fill — the same semantic color
          // the accent pair uses, so a selected row's labels are unchanged.
          NSColor.alternateSelectedControlTextColor
        },
        // White on systemRed is what AppKit draws for destructive fills.
        installColorSignal(env: env, slot: WuiColorSlot_Error) { NSColor.systemRed },
        installColorSignal(env: env, slot: WuiColorSlot_ErrorForeground) { NSColor.white },
      ]
    }

    private static func installColorSignal(
      env: WuiEnvironment,
      slot: WuiColorSlot,
      resolve: @escaping @MainActor () -> NSColor
    ) -> ColorSignalEntry {
      let signal = ReactiveColorSignal(color: WuiResolvedColor.fromNSColor(resolve()))
      waterui_theme_install_color(env.inner, slot, signal.toComputed())
      return ColorSignalEntry(signal: signal, resolve: resolve)
    }
  #endif

  private func installSystemFonts(env: WuiEnvironment) {
    #if canImport(UIKit)
      let slots: [(WuiFontSlot, UIFont.TextStyle)] = [
        (WuiFontSlot_Body, .body),
        (WuiFontSlot_Title, .title1),
        (WuiFontSlot_Headline, .headline),
        (WuiFontSlot_Subheadline, .subheadline),
        (WuiFontSlot_Caption, .caption1),
        (WuiFontSlot_Footnote, .footnote),
      ]
      fontSignalEntries = slots.map { slot, textStyle in
        let signal = installFontSlot(
          env: env,
          slot: slot,
          font: UIFont.preferredFont(forTextStyle: textStyle)
        )
        return FontSignalEntry(textStyle: textStyle, signal: signal)
      }
      contentSizeCategoryObserver = NotificationCenter.default.addObserver(
        forName: UIContentSizeCategory.didChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.updatePreferredFonts()
        }
      }
    #elseif canImport(AppKit)
      let slots: [(WuiFontSlot, NSFont.TextStyle)] = [
        (WuiFontSlot_Body, .body),
        (WuiFontSlot_Title, .title1),
        (WuiFontSlot_Headline, .headline),
        (WuiFontSlot_Subheadline, .subheadline),
        (WuiFontSlot_Caption, .caption1),
        (WuiFontSlot_Footnote, .footnote),
      ]
      fontSignals = slots.map { slot, textStyle in
        installFontSlot(
          env: env,
          slot: slot,
          font: NSFont.preferredFont(forTextStyle: textStyle, options: [:])
        )
      }
    #endif
  }

  #if canImport(UIKit)
    private func installFontSlot(
      env: WuiEnvironment,
      slot: WuiFontSlot,
      font: UIFont
    ) -> ReactiveFontSignal {
      let weight = fontWeight(font)
      let signal = ReactiveFontSignal(
        size: Float(font.pointSize),
        weight: weight,
        lineHeight: Float(font.naturalLinePitch)
      )
      waterui_theme_install_font(env.inner, slot, signal.toComputed())
      return signal
    }

    private func updatePreferredFonts() {
      for entry in fontSignalEntries {
        let font = UIFont.preferredFont(forTextStyle: entry.textStyle)
        entry.signal.setValue(
          size: Float(font.pointSize),
          weight: fontWeight(font),
          lineHeight: Float(font.naturalLinePitch)
        )
      }
    }

    private func fontWeight(_ font: UIFont) -> WuiFontWeight {
      let traits =
        font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
      let weightValue = traits?[.weight] as? CGFloat ?? UIFont.Weight.regular.rawValue
      return uiFontWeightToWuiFontWeight(weightValue)
    }

    private func uiFontWeightToWuiFontWeight(_ weight: CGFloat) -> WuiFontWeight {
      // The canonical trait constants are float32-rounded — semibold is
      // 0.30000001192092896 — so closed-interval bucketing on the decimal
      // points misclassifies every named weight that lands an epsilon
      // above its boundary (`.headline`'s semibold reads as Bold). Snap
      // to the nearest canonical weight instead.
      let canonical: [(UIFont.Weight, WuiFontWeight)] = [
        (.ultraLight, WuiFontWeight_UltraLight),
        (.thin, WuiFontWeight_Thin),
        (.light, WuiFontWeight_Light),
        (.regular, WuiFontWeight_Normal),
        (.medium, WuiFontWeight_Medium),
        (.semibold, WuiFontWeight_SemiBold),
        (.bold, WuiFontWeight_Bold),
        (.heavy, WuiFontWeight_UltraBold),
        (.black, WuiFontWeight_Black),
      ]
      return canonical.min { abs($0.0.rawValue - weight) < abs($1.0.rawValue - weight) }!.1
    }
  #elseif canImport(AppKit)
    private func installFontSlot(
      env: WuiEnvironment,
      slot: WuiFontSlot,
      font: NSFont
    ) -> ReactiveFontSignal {
      let weight = fontWeight(font)
      let signal = ReactiveFontSignal(
        size: Float(font.pointSize),
        weight: weight,
        lineHeight: Float(font.naturalLinePitch)
      )
      waterui_theme_install_font(env.inner, slot, signal.toComputed())
      return signal
    }

    private func fontWeight(_ font: NSFont) -> WuiFontWeight {
      let traits =
        font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
      let weightValue = traits?[.weight] as? CGFloat ?? NSFont.Weight.regular.rawValue
      return nsFontWeightToWuiFontWeight(weightValue)
    }

    private func nsFontWeightToWuiFontWeight(_ weight: CGFloat) -> WuiFontWeight {
      // The canonical trait constants are float32-rounded — semibold is
      // 0.30000001192092896 — so closed-interval bucketing on the decimal
      // points misclassifies every named weight that lands an epsilon
      // above its boundary. Snap to the nearest canonical weight instead.
      let canonical: [(NSFont.Weight, WuiFontWeight)] = [
        (.ultraLight, WuiFontWeight_UltraLight),
        (.thin, WuiFontWeight_Thin),
        (.light, WuiFontWeight_Light),
        (.regular, WuiFontWeight_Normal),
        (.medium, WuiFontWeight_Medium),
        (.semibold, WuiFontWeight_SemiBold),
        (.bold, WuiFontWeight_Bold),
        (.heavy, WuiFontWeight_UltraBold),
        (.black, WuiFontWeight_Black),
      ]
      return canonical.min { abs($0.0.rawValue - weight) < abs($1.0.rawValue - weight) }!.1
    }
  #endif
}

// MARK: - Root Context

@MainActor
final class WuiNativeServices: @unchecked Sendable {
  weak var environment: WuiEnvironment?

  #if os(macOS)
    let windowManager = WindowManagerImpl()
  #endif
}

@MainActor
func retainWuiNativeServices(_ services: WuiNativeServices) -> UnsafeMutableRawPointer {
  Unmanaged.passRetained(services).toOpaque()
}

private struct WuiOwnedNativeServicesContext: @unchecked Sendable {
  let pointer: UnsafeMutableRawPointer
}

let dropWuiNativeServices: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
  guard let context else {
    fatalError("WaterUI native services received a null owned context")
  }
  precondition(Thread.isMainThread, "WaterUI native services must be dropped on the UI executor")
  let ownedContext = WuiOwnedNativeServicesContext(pointer: context)
  MainActor.assumeIsolated {
    Unmanaged<WuiNativeServices>.fromOpaque(ownedContext.pointer).release()
  }
}

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
  private let themeBridge: ThemeBridge
  private var menuBarTree: WuiMenuTree?
  private var localeObserver: NSObjectProtocol?

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

  public init() async {
    guard let initEnvPtr = waterui_init() else {
      fatalError("waterui_init returned a null environment")
    }
    Self.installSystemLocale(into: initEnvPtr)
    let env = WuiEnvironment(initEnvPtr)
    // A build without WaterUI's `gpu` feature exports no GPU runtime symbols
    // and has nothing to install one for.
    #if !WATERUI_NO_GPU
      let gpuRuntime = await createWuiGpuRuntime()
      waterui_env_install_gpu_runtime(initEnvPtr, gpuRuntime)
    #endif
    let nativeServices = WuiNativeServices()
    nativeServices.environment = env
    #if WATERUI_WEBVIEW
      installWebViewController(env: initEnvPtr)
    #endif
    installWindowManager(env: initEnvPtr, services: nativeServices)
    installViewRenderer(env: initEnvPtr, services: nativeServices)

    // 2. Detect system color scheme
    #if canImport(UIKit)
      let systemScheme: ThemeBridge.ColorScheme =
        UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
    #elseif canImport(AppKit)
      let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
      let systemScheme: ThemeBridge.ColorScheme =
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    #endif

    let themeBridge = ThemeBridge(env: env, colorScheme: systemScheme)

    // 4. Create the app by calling waterui_app(env)
    // The user's app(env) receives the environment with theme installed,
    // creates App::new(content, env), and returns App { windows, env }
    // Native takes ownership of the environment and gets it back in the App.
    // IMPORTANT: After this call, initEnvPtr is invalid - ownership transferred to Rust.
    let app = waterui_app(initEnvPtr)

    // Prevent the wrapper from dropping the transferred pointer
    // by replacing its inner with the valid app.env
    env.inner = app.env

    // 7. Extract main window (first window in array)
    let windowSlice = app.windows.vtable.slice(app.windows.data)
    guard windowSlice.len > 0, let windowsPtr = windowSlice.head else {
      fatalError("waterui_app() returned App with no windows")
    }
    self.env = env
    self.app = app
    self.mainWindow = WuiWindowContext(from: windowsPtr.pointee)
    self.themeBridge = themeBridge
    themeBridge.bindToEnvironmentColorScheme(env: env)
    localeObserver = NotificationCenter.default.addObserver(
      forName: NSLocale.currentLocaleDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.updateSystemLocale()
      }
    }
    installMenuBar()
  }

  @MainActor deinit {
    if let localeObserver {
      NotificationCenter.default.removeObserver(localeObserver)
    }
  }

  private static func installSystemLocale(into env: OpaquePointer) {
    guard let localeTag = Locale.preferredLanguages.first else {
      fatalError("Apple platforms must provide at least one preferred BCP-47 language tag")
    }
    localeTag.withCString { tag in
      waterui_env_install_locale_tag(env, tag)
    }
  }

  private func updateSystemLocale() {
    Self.installSystemLocale(into: env.inner)
  }

  private func installMenuBar() {
    guard let menuBar = app.menu_bar else {
      fatalError("waterui_app() returned a null menu bar collection")
    }
    menuBarTree = WuiMenuTree(consuming: menuBar) { [weak self] _ in
      self?.menuBarDidChange()
    }
    menuBarDidChange()
  }

  private func menuBarDidChange() {
    guard let menuBarTree else {
      fatalError("WaterUI menu bar changed before its semantic tree was installed")
    }
    #if canImport(UIKit)
      UIMenuSystem.main.setNeedsRebuild()
    #elseif canImport(AppKit)
      let menu = WaterUIMainMenu.create()
      appendAppKitMenuBarItems(
        menuBarTree.nodes,
        to: menu,
        target: self,
        action: #selector(applicationMenuItemClicked(_:))
      )
      NSApp.mainMenu = menu
    #endif
  }

  #if canImport(UIKit)
    fileprivate func buildApplicationMenus(with builder: UIMenuBuilder) {
      guard let menuBarTree else {
        fatalError(
          "WaterUI application menus were requested before their semantic tree was installed")
      }
      let menus = buildUIKitSystemMenus(
        from: menuBarTree.nodes,
        handler: { [weak self] command in
          guard let self else { return }
          waterui_call_shared_action(command.action, self.env.inner)
        }
      )
      for menu in menus {
        if builder.menu(for: menu.identifier) == nil {
          builder.insertChild(menu, atEndOfMenu: .root)
        } else {
          builder.replace(menu: menu.identifier, with: menu)
        }
      }
    }
  #elseif canImport(AppKit)
    @objc private func applicationMenuItemClicked(_ sender: NSMenuItem) {
      guard let action = sender.representedObject as? MenuActionRef else {
        fatalError("WaterUI application menu item has no semantic action")
      }
      waterui_call_shared_action(action.command.action, env.inner)
    }
  #endif

  /// Updates the theme for a new color scheme.
  /// Uses reactive signals so WaterUI views automatically update.
  public func updateColorScheme(_ colorScheme: ThemeBridge.ColorScheme) {
    themeBridge.updateColorScheme(colorScheme)
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
    private var context: WuiRootContext?
    private var startupTask: Task<Void, Never>?
    private var backgroundObservation: WuiComputedObservation<WuiResolvedColor>?
    private var accentObservation: WuiComputedObservation<WuiResolvedColor>?

    public init() {
      super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
      // Use a custom view that fills the window but propagates safe area insets
      view = FullScreenView()
    }

    public override func viewDidLoad() {
      super.viewDidLoad()
      registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
        (controller: WaterUIViewController, _: UITraitCollection) in
        controller.updateColorSchemeFromTraits()
      }
      startupTask = Task { @MainActor [weak self] in
        let context = await WuiRootContext()
        guard let self, !Task.isCancelled else { return }
        self.context = context
        self.install(context)
      }
    }

    private func install(_ context: WuiRootContext) {
      let background = WuiComputedObservation(
        themeColor: WuiColorSlot_Background,
        env: context.env
      ) { [weak self] color, _ in
        self?.view.backgroundColor = color.toUIColor()
      }
      backgroundObservation = background
      view.backgroundColor = background.value.toUIColor()

      let accent = WuiComputedObservation(
        themeColor: WuiColorSlot_Accent,
        env: context.env
      ) { [weak self] color, _ in
        self?.view.tintColor = color.toUIColor()
      }
      accentObservation = accent
      view.tintColor = accent.value.toUIColor()

      let rootView = context.rootView
      // Use manual frame-based layout, not AutoLayout
      rootView.translatesAutoresizingMaskIntoConstraints = true
      view.addSubview(rootView)
      // Below anything the application installs, so a view with a context menu
      // of its own still wins the gesture.
      WuiInspector.installGesture(on: view, env: context.env)
      view.setNeedsLayout()
    }

    public override func buildMenu(with builder: UIMenuBuilder) {
      super.buildMenu(with: builder)
      context?.buildApplicationMenus(with: builder)
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
      guard let context else { return }

      // The root lays itself out against the window's safe area
      // (`wuiContentFrame`): the window's overlay stack and every stack
      // below it place their content inside it and extend the scroll
      // surfaces and chrome containers that touch its edges, so the insets
      // are applied natively and no layer pads itself again.
      context.rootView.frame = wuiContentFrame(of: context.rootView, in: view)
      context.rootView.setNeedsLayout()
      context.rootView.layoutIfNeeded()
    }

    private func updateColorSchemeFromTraits() {
      let colorScheme: ThemeBridge.ColorScheme =
        traitCollection.userInterfaceStyle == .dark ? .dark : .light
      context?.updateColorScheme(colorScheme)
    }

    @MainActor deinit {
      startupTask?.cancel()
    }
  }
#endif

// MARK: - Public AppKit Root View

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  /// An AppKit view that hosts the WaterUI root view.
  @MainActor
  public final class WaterUIView: NSView {
    private var context: WuiRootContext?
    private var startupTask: Task<Void, Never>?
    private var backgroundObservation: WuiComputedObservation<WuiResolvedColor>?
    private var rootWindowBinding: WuiRootWindowBinding?

    public override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      startupTask = Task { @MainActor [weak self] in
        let context = await WuiRootContext()
        guard let self, !Task.isCancelled else { return }
        self.context = context
        self.setupView(context)
      }
    }

    /// Hands this view's window to the main window that declared it.
    ///
    /// The two arrive in either order — a host may put this view in a window
    /// before the runtime has started, or start it before the view is placed —
    /// so both paths ask, and the first one to find the pair does the binding.
    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      bindRootWindowIfReady()
    }

    private func bindRootWindowIfReady() {
      guard rootWindowBinding == nil, let context, let window else { return }
      rootWindowBinding = bindRootWindow(window, to: context.window, env: context.env)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    private func setupView(_ context: WuiRootContext) {
      let background = WuiComputedObservation(
        themeColor: WuiColorSlot_Background,
        env: context.env
      ) { [weak self] color, _ in
        self?.layer?.backgroundColor = color.toNSColor().cgColor
      }
      backgroundObservation = background
      layer?.backgroundColor = background.value.toNSColor().cgColor

      let rootView = context.rootView
      // Use manual frame-based layout, not AutoLayout
      rootView.translatesAutoresizingMaskIntoConstraints = true
      addSubview(rootView)
      needsLayout = true
      bindRootWindowIfReady()
    }

    /// A secondary click that no view claimed offers to inspect the element.
    ///
    /// The responder chain brings it here only when nothing above wanted it, so
    /// a view with its own context menu still wins, and no other event is
    /// affected — which a gesture recognizer on this view could not promise.
    public override func rightMouseDown(with event: NSEvent) {
      guard let context else {
        super.rightMouseDown(with: event)
        return
      }
      WuiInspector.presentMenu(for: event, in: self, env: context.env)
    }

    nonisolated public override var isFlipped: Bool { true }

    public override func layout() {
      super.layout()
      guard let context else { return }

      // With a toolbar the window supplies full-size content, so the toolbar's
      // height reaches this view as its top safe-area inset. The root lays
      // itself out against it (`wuiContentFrame`): a leaf is placed below the
      // toolbar, and a stack or chrome container takes the whole view and
      // insets its own content, extending the scroll surfaces and chrome
      // that touch its edges, so the insets are applied natively and no
      // layer pads itself again — the same rule the iOS root applies.
      context.rootView.frame = wuiContentFrame(of: context.rootView, in: self)
      context.rootView.needsLayout = true
      context.rootView.layoutSubtreeIfNeeded()
    }

    public override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      let appearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
      context?.updateColorScheme(appearance == .darkAqua ? .dark : .light)
    }

    @MainActor deinit {
      startupTask?.cancel()
    }
  }
#endif

// MARK: - SwiftUI Integration

/// A SwiftUI view that hosts the WaterUI root view.
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
  /// GPU surfaces, view effects, filters, and the Metal capture pipeline.
  static let graphics = Logger(subsystem: "dev.waterui", category: "Graphics")
}
