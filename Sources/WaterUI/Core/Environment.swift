//
//  Environment.swift
//
//
//  Created by Lexo Liu on 7/31/24.
//

import CWaterUI

@MainActor
public class WuiEnvironment {
    var inner: OpaquePointer
    init(_ inner: OpaquePointer) {
        self.inner = inner
    }

    /// The disabled state in force at this point in the view tree.
    ///
    /// Disabled state is a scoped subtree attribute installed by `.disabled(...)`,
    /// not a field on any control's configuration: every interactive control
    /// reads it from the environment it is already handed, the same way it reads
    /// a theme color. The signal reads `false` when no enclosing scope disables
    /// the subtree.
    var disabled: WuiComputed<Bool> {
        guard let signal = waterui_env_disabled(inner) else {
            fatalError("waterui_env_disabled must always return a signal")
        }
        return WuiComputed<Bool>(signal)
    }

    @MainActor deinit{
        waterui_drop_env(inner)
    }
}
