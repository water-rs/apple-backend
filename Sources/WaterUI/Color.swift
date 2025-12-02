//
//  Color.swift
//  waterui-swift
//
//  Created by Lexo Liu on 10/21/24.
//
import CWaterUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif


@MainActor
class WuiColor {
    var inner: OpaquePointer
    init(_ inner: OpaquePointer) {
        self.inner = inner
    }

    func resolve(in env: WuiEnvironment) -> WuiComputed<WuiResolvedColor> {
        let computed = waterui_resolve_color(inner, env.inner)
        return WuiComputed(computed!)
    }

    @MainActor deinit {
        waterui_drop_color(inner)
    }
}

#if canImport(UIKit)
extension WuiResolvedColor {
    func toUIColor() -> UIColor {
        UIColor(
            red: CGFloat(self.red),
            green: CGFloat(self.green),
            blue: CGFloat(self.blue),
            alpha: CGFloat(self.opacity)
        )
    }
}
#elseif canImport(AppKit)
extension WuiResolvedColor {
    func toNSColor() -> NSColor {
        NSColor(
            red: CGFloat(self.red),
            green: CGFloat(self.green),
            blue: CGFloat(self.blue),
            alpha: CGFloat(self.opacity)
        )
    }
}
#endif
