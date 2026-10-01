//
//  Environment.swift
//
//
//  Created by Lexo Liu on 7/31/24.
//

@_exported import CWaterUI

@MainActor
public class WuiEnvironment {
    /// The environment's opaque `WuiEnv` handle for C-ABI seam calls from
    /// sibling modules (CEF's `waterui_apple_make_gpu_surface_view`).
    public var pointer: OpaquePointer { inner }

    var inner: OpaquePointer
    init(_ inner: OpaquePointer) {
        self.inner = inner
    }

    @MainActor deinit{
        waterui_drop_env(inner)
    }
}
