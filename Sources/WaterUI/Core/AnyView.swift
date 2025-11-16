//
//  AnyView.swift
//
//
//  Created by Lexo Liu on 8/1/24.
//

import CWaterUI
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
struct Render {
    var map: [String: any WuiComponent.Type]

    init() {
        self.map = [:]
    }

    init(_ components: [any WuiComponent.Type]) {
        self.init()
        for component in components {
            self.map[component.id] = component
        }
    }

    static var main: Render {
        .init([
            WuiEmptyView.self,
            WuiText.self,
            WuiPlain.self,
            WuiButton.self,
            WuiColorView.self,
            // Stack components will be added here when Rust FFI is implemented:
            WuiTextField.self,
            WuiStepper.self,
            // WaterUI.Spacer.self,
            WuiProgress.self,
            // WaterUI.Toggle.self,
            // WaterUI.NavigationView.self,
            WuiDynamic.self,
            // WaterUI.WithEnv.self,
            // WaterUI.NavigationLink.self,
            WuiScrollView.self,
            WuiLayoutContainer.self,
            WuiFixedContainer.self,
            WuiList.self,
            WuiTable.self,
            WuiToggle.self,
            WuiSpacer.self,
            WuiRendererView.self,
            //WuiPicker.self,
            //WaterUI.BackgroundColor.self,
            //WaterUI.Rectangle.self,
            //  WaterUI.ForegroundColor.self,
            WuiSlider.self,
            WuiLazy.self,
            WuiList.self,
            WuiListItem.self,

                // WaterUI.ColorPicker.self,
                // WaterUI.Icon.self
        ])
    }

    mutating func register(_ component: any WuiComponent.Type) {
        self.map[component.id] = component
    }

    func render(anyview: OpaquePointer, env: WuiEnvironment) -> SwiftUI.AnyView {
        let id = decodeViewIdentifier(waterui_view_id(anyview))
        if let ty = map[id] {
            let component = ty.init(anyview: anyview, env: env) as (any View)
            return SwiftUI.AnyView(component)
        } else {

            let next = waterui_view_body(anyview, env.inner)
            return SwiftUI.AnyView(render(anyview: next!, env: env))
        }
    }
}

@MainActor
public struct WuiAnyView: View, Identifiable {
    public var id = UUID()
    private let env: WuiEnvironment
    public let typeId: String
    private let handle: WuiAnyViewHandle
    #if canImport(SwiftUI)
    private var renderedView: SwiftUI.AnyView {
        handle.render(using: env)
    }
    #endif

    init(anyview: OpaquePointer, env: WuiEnvironment) {
        self.env = env
        self.typeId = decodeViewIdentifier(waterui_view_id(anyview))
        self.handle = WuiAnyViewHandle(pointer: anyview)
    }

    public var body: some View {
        #if canImport(SwiftUI)
        AnyView(renderedView).id(id)
        #else
        AnyView(EmptyView()).id(id)
        #endif
    }

    #if canImport(UIKit)
    func makePlatformView() -> PlatformView {
        guard let pointer = handle.takePointer() else {
            return UIView()
        }
        return PlatformRenderer.shared.makeView(anyview: pointer, env: env, typeId: typeId)
    }
    #endif
}

@MainActor
private final class WuiAnyViewHandle {
    private var pointer: OpaquePointer?
    #if canImport(SwiftUI)
    private var cachedView: SwiftUI.AnyView?
    #endif

    init(pointer: OpaquePointer?) {
        self.pointer = pointer
    }

    func takePointer() -> OpaquePointer? {
        defer { pointer = nil }
        return pointer
    }

    #if canImport(SwiftUI)
    func render(using env: WuiEnvironment) -> SwiftUI.AnyView {
        if let cachedView {
            return cachedView
        }
        guard let pointer = takePointer() else {
            let placeholder = SwiftUI.AnyView(EmptyView())
            cachedView = placeholder
            return placeholder
        }
        let rendered = Render.main.render(anyview: pointer, env: env)
        cachedView = rendered
        return rendered
    }
    #endif
}
