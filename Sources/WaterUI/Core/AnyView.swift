//
//  AnyView.swift
//
//
//  Created by Lexo Liu on 8/1/24.
//

import CWaterUI
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Component Registry

/// Internal registry for component factories
@MainActor
private var componentRegistry: [String: (OpaquePointer, WuiEnvironment) -> any WuiComponent] = [:]

/// Internal flag to track if builtin components have been registered
@MainActor
private var builtinComponentsRegistered = false

/// Register a component type that conforms to WuiComponent.
@MainActor
private func registerComponent<T: WuiComponent>(_ type: T.Type) {
    componentRegistry[type.id] = { anyview, env in
        type.init(anyview: anyview, env: env)
    }
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
    registerComponent(WuiDivider.self)
    registerComponent(WuiColorView.self)

    // Interactive components
    registerComponent(WuiButton.self)
    // TODO: registerComponent(WuiLink.self)
    registerComponent(WuiToggle.self)
    registerComponent(WuiSlider.self)
    registerComponent(WuiTextField.self)
    registerComponent(WuiStepper.self)
    // TODO: registerComponent(WuiColorPicker.self)
    // TODO: registerComponent(WuiPicker.self)
    registerComponent(WuiProgress.self)

    // Container components
    registerComponent(WuiFixedContainer.self)
    registerComponent(WuiContainer.self)
    registerComponent(WuiScroll.self)
    // TODO: registerComponent(WuiList.self)
    // TODO: registerComponent(WuiListItem.self)
    // TODO: registerComponent(WuiTable.self)
    // TODO: registerComponent(WuiTableColumn.self)
    // TODO: registerComponent(WuiNavigationView.self)

    // Dynamic components
    registerComponent(WuiDynamic.self)
    // TODO: registerComponent(WuiLazy.self)

    // Media components
    // TODO: registerComponent(WuiPhoto.self)
    // TODO: registerComponent(WuiVideoPlayer.self)
    // TODO: registerComponent(WuiLivePhoto.self)
    // TODO: registerComponent(WuiLivePhotoSource.self)

    // Renderer components
    // TODO: registerComponent(WuiRendererView.self)
}

// MARK: - WuiAnyView

#if canImport(UIKit)
/// The entry point for WaterUI views from Rust.
/// Resolves an opaque FFI pointer into a concrete WuiComponent at initialization time.
@MainActor
public final class WuiAnyView: UIView, WuiComponent {
    public static var id: String {
        decodeViewIdentifier(waterui_anyview_id())
    }

    /// The resolved inner component - never nil after initialization
    private let inner: any WuiComponent

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

    override public func layoutSubviews() {
        super.layoutSubviews()
        // Manually size inner view to fill bounds
        inner.frame = bounds
    }

    // MARK: - Private Resolution

    private static func resolve(anyview: OpaquePointer, env: WuiEnvironment) -> any WuiComponent {
        guard let sanitized = sanitize(anyview) else {
            fatalError("Invalid anyview pointer")
        }

        let typeId = decodeIdentifier(for: sanitized)

        // Look up registered component factory
        if let typeId, let factory = componentRegistry[typeId] {
            return factory(sanitized, env)
        }

        if let next = waterui_view_body(sanitized, env.inner) {
            return resolve(anyview: next, env: env)
        }

        fatalError("Unsupported component type: \(typeId ?? "unknown")")
    }

    private static func sanitize(_ pointer: OpaquePointer?) -> OpaquePointer? {
        guard let pointer else { return nil }
        let raw = UInt(bitPattern: pointer)
        if raw <= 0x1000 { return nil }
        return pointer
    }

    private static func decodeIdentifier(for pointer: OpaquePointer) -> String? {
        let str = waterui_view_id(pointer)
        return WuiStr(str).toString()
    }
}

#elseif canImport(AppKit)
/// The entry point for WaterUI views from Rust.
/// Resolves an opaque FFI pointer into a concrete WuiComponent at initialization time.
@MainActor
public final class WuiAnyView: NSView, WuiComponent {
    public static var id: String {
        decodeViewIdentifier(waterui_anyview_id())
    }

    /// The resolved inner component - never nil after initialization
    private let inner: any WuiComponent

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

    override public var isFlipped: Bool { true }

    override public func layout() {
        super.layout()
        // Manually size inner view to fill bounds
        inner.frame = bounds
    }

    // MARK: - Private Resolution

    private static func resolve(anyview: OpaquePointer, env: WuiEnvironment) -> any WuiComponent {
        guard let sanitized = sanitize(anyview) else {
            fatalError("Invalid anyview pointer")
        }

        let typeId = decodeIdentifier(for: sanitized)

        // Look up registered component factory
        if let typeId, let factory = componentRegistry[typeId] {
            return factory(sanitized, env)
        }

        if let next = waterui_view_body(sanitized, env.inner) {
            return resolve(anyview: next, env: env)
        }

        fatalError("Unsupported component type: \(typeId ?? "unknown")")
    }

    private static func sanitize(_ pointer: OpaquePointer?) -> OpaquePointer? {
        guard let pointer else { return nil }
        let raw = UInt(bitPattern: pointer)
        if raw <= 0x1000 { return nil }
        return pointer
    }

    private static func decodeIdentifier(for pointer: OpaquePointer) -> String? {
        let str = waterui_view_id(pointer)
        return WuiStr(str).toString()
    }
}
#endif
