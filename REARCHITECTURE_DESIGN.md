# Apple Backend Re-architecture Plan

This document proposes how to migrate the Apple backend away from an opaque SwiftUI-first model while keeping WaterUI's cross-platform guarantees. It turns the current SwiftUI implementation (described in `backends/apple/README.md`) into a thin compatibility layer on top of UIKit/AppKit/WatchKit primitives and the shared Rust layout engine (`components/layout/src/lib.rs`).

## Goals & Non-Goals

- **Goals**
  - Keep a single layout algorithm that executes in Rust after native measurement data is collected.
  - Share as much rendering code as possible between UIKit, AppKit, WatchKit, and future visionOS surfaces.
  - Preserve the existing FFI contracts for `WuiAnyView`, watchers, bindings, and computed values.
  - Retain SwiftUI-only components where they offer a clear benefit (currently `FixedContainer`, `Container`, `Text`, `Image`).
  - Make incremental rollout possible so that currently functional controls continue working while we port them.
- **Non-Goals**
  - Re-design the Rust view/component system.
  - Change WaterUI's application bootstrap (`waterui_init`, environment lifecycle).
  - Solve hot-reload, gestures, or accessibility beyond what already exists—those stay future work.

## Current State (Summary)

The backend renders every component as a SwiftUI view registered via `WuiAnyView`. Layout containers (`WuiLayoutContainer`, `WuiFixedContainer`) already call back into Rust for propose/measure/place logic, but those containers still host anonymous SwiftUI subviews. Controls like `Button`, `Toggle`, etc. are also pure SwiftUI (`Sources/WaterUI/*`). This makes the diff/rebuild life cycle tightly coupled to SwiftUI behaviours we cannot control.

## Target Architecture

### 1. Layering

```
Rust view tree ──> FFI (`CWaterUI`) ──> Swift registry (`AnyView.swift`)
                                     │
             ┌───────────────────────┴────────────────────────┐
             │                    PlatformRuntime             │
             │  (new) structured around UIKit/AppKit/WatchKit │
             └───────────────┬────────────────────────────────┘
                             │
       +---------------------+----------------------+
       | UIKitHostView / AppKitHostView / WatchHost |
       +---------------------+----------------------+
                             │
              minimal SwiftUI compatibility shim*
```

`PlatformRuntime` becomes the canonical renderer. SwiftUI remains only for:
1. `FixedContainer`/`Container` while we finish the host views.
2. `Text`/`Image` wrappers where SwiftUI gives us better typography/asset fidelity (can be revisited later).

Every other component becomes a native `UIView`/`NSView`/`WKInterfaceObject`. The SwiftUI compatibility shim embeds those host views when the app is still compiled with SwiftUI scenes. On watchOS we expose an `WKInterfaceController`-friendly API.

### 2. Layout Pipeline

1. **Native measurement phase**
   - Each host view implements `WaterUILayoutMeasurable` protocol that exposes:
     ```swift
     func intrinsicSize(for proposal: WuiProposalSize, env: WuiEnvironment) -> CGSize
     func flexibility() -> WuiFlex // intrinsic vs spacer metadata
     ```
   - UIKit/AppKit components compute their natural content size (auto-layout, `systemLayoutSizeFitting`, etc.).
2. **Bridge to Rust**
   - `PlatformRuntime` aggregates child metadata (`size`, `stretch`, `priority`) and calls the existing `waterui_layout_*` FFI helpers, mirroring what `RustLayout` currently does (`Sources/WaterUI/Layout/Layout.swift`).
   - Computed frames come back from Rust (`components/layout/src/lib.rs`) and are assigned to native subviews.
3. **Placement**
   - Host containers call `layoutSubtree()` (UIKit) or `layout()` (AppKit) using the rects provided by Rust.
4. **SwiftUI compatibility**
   - `RustLayout` remains during the transition but internally forwards to `PlatformRuntime` instead of running SwiftUI's `Layout` interface. Once UIKit/AppKit paths are stable we drop the SwiftUI `Layout` entirely.

### 3. Component Rewrite Strategy

| Phase | Scope | Notes |
| --- | --- | --- |
| Phase A | Infrastructure | Create `PlatformRuntime`, host view abstractions, shared layout bridge, measurement protocol, and a UIKit demo scene. |
| Phase B | Controls | Port Button, Toggle, Slider, TextField, Progress, Label, etc. to UIKit/AppKit implementations. WatchKit uses analogous objects. |
| Phase C | Containers | Introduce native stack/list/scroll containers that reuse the Rust layout engine. Once parity is proven, retire SwiftUI `RustLayout`. |
| Phase D | Media & Graphics | Bind `CALayer`/`NSView` surfaces directly for `Image`, `Color`, `Graphics`. SwiftUI `Text`/`Image` remain optional. |
| Phase E | Cleanup | Remove unused SwiftUI dependencies, audit watchers, and verify the platform matrices (iOS, macOS, watchOS, visionOS). |

Each phase should ship behind build flags so we can fall back to the SwiftUI view if regressions appear.

### 4. Surviving SwiftUI Views

- `FixedContainer` / `Container`: stay SwiftUI temporarily to validate the host layout.
- `Text`: still provides unmatched rich text rendering; UIKit/AppKit text renderers can be swapped in later.
- `Image`: keep SwiftUI-backed `Image` while reworking the media stack.

Every other component registers both the SwiftUI and UIKit/AppKit factories during transition; runtime configuration selects the native path once ready.

### 5. Reactivity & Watchers

Bindings (`Sources/WaterUI/Reactive/Binding.swift`) and computed values stay intact. Host views expose setters that the watcher pipeline calls when `Binding` updates. UIKit/AppKit components must:
- Subscribe to `Binding`/`Computed` changes using the same watcher infrastructure SwiftUI uses today.
- Forward user events back into the Rust environment through the existing callback FFI (`waterui_emit_event` et al.).

### 6. WatchKit & visionOS

- WatchKit: wrap `PlatformRuntime` in an `ObservableObject` feeding `WKInterfaceObjectRepresentable`. Layout is precomputed on iPhone/rust and mirrored to watch.
- visionOS: use the UIKit host path (SceneKit-compatible) with platform compilation flags; only the windowing bootstrap differs.

## Implementation Details

1. **Module layout**
   - `Sources/WaterUI/PlatformRuntime/`
     - `HostView.swift`: protocols shared between UIKit/AppKit/WatchKit.
     - `UIKitHostView.swift`, `AppKitHostView.swift`, `WatchHost.swift`.
     - `NativeLayoutBridge.swift`: wraps the FFI `waterui_layout_*` helpers.
2. **FFI adjustments**
   - None initially; reuse the existing layout + component IDs. Later, consider exporting a "native measurement only" container to skip SwiftUI entirely.
3. **Testing hooks**
   - Add snapshot/debug surfaces in `demo/` to render both SwiftUI and UIKit implementations side-by-side.
   - Keep unit tests around `components/layout/src/lib.rs` untouched; we only change the caller.

## Risks & Mitigations

- **SwiftUI interop bugs:** keep SwiftUI implementations behind flags during rollout.
- **Layout drift:** add assertions comparing SwiftUI vs native layout during dual-render builds.
- **WatchKit limitations:** start with a reduced control set; fall back to SwiftUI for missing pieces.
- **Team code familiarity:** document host view lifecycle and measurement protocol thoroughly; align with `README.md`.

## Next Steps

1. Scaffold `PlatformRuntime` module and minimal `UIKitHostView`.
2. Move `RustLayout` logic into `NativeLayoutBridge`.
3. Re-implement a simple component (e.g., `Button`) in UIKit to validate bindings/events.
4. Expand coverage component-by-component following the phase table.

This roadmap should give us more predictable diffing/rebuild behaviour and a clearer mental model of how WaterUI talks to Apple toolkits, while still leveraging SwiftUI where it shines.
