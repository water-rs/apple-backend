//
//  SwiftUIView.swift
//  
//
//  Created by Lexo Liu on 8/13/24.
//

import SwiftUI
import CWaterUI
@MainActor
struct WuiDynamic: View, WuiComponent {
    static let id: String = decodeViewIdentifier(waterui_dynamic_id())
    @State var view:WuiAnyView?
    var dynamic:OpaquePointer
    var env:WuiEnvironment
    
    init(dynamic:OpaquePointer,env:WuiEnvironment){
        self.dynamic=dynamic
        self.env=env
    }

    
    init(anyview: OpaquePointer,env:WuiEnvironment) {
        self.init(dynamic: waterui_force_as_dynamic(anyview), env: env)
    }
    
    
    var body: some View {
        VStack{
            view
        }.onAppear{
            let watcher = makeAnyViewWatcher(env: env) { new in
                view = new
            }
            waterui_dynamic_connect(dynamic, watcher)
        }
    }
}


@MainActor
func makeAnyViewWatcher(
    env: WuiEnvironment,
    _ f:@escaping (WuiAnyView)->Void
) -> OpaquePointer {
    @MainActor
    final class AnyViewWrapper {
        var inner: (WuiAnyView) -> Void
        var env: WuiEnvironment
        init(inner: @escaping (WuiAnyView) -> Void, env: WuiEnvironment) {
            self.inner = inner
            self.env = env
        }
    }

    let data = UnsafeMutableRawPointer(Unmanaged.passRetained(AnyViewWrapper(inner: f, env: env)).toOpaque())

    let call: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, OpaquePointer?) -> Void = { data, value, _ in
        let data = Unmanaged<AnyViewWrapper>.fromOpaque(data!).takeUnretainedValue()
        (data.inner)(WuiAnyView(anyview: value!, env: data.env))
    }

    let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
        _ = Unmanaged<AnyViewWrapper>.fromOpaque(data!).takeRetainedValue()
    }

    guard let watcher = waterui_new_watcher_any_view(data, call, drop) else {
        fatalError("Failed to create any-view watcher")
    }
    return watcher
}
