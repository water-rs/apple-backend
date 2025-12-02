import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

/// A host container that arranges native child views using the shared Rust layout engine.
@MainActor
protocol WaterUIPlatformHost: AnyObject {
    #if canImport(UIKit)
    associatedtype NativeContainer: UIView
    #elseif canImport(AppKit)
    associatedtype NativeContainer: NSView
    #endif

    var container: NativeContainer { get }
    var layoutBridge: NativeLayoutBridge { get }

    func setChildren(_ children: [any WuiComponent])
    func performNativeLayout(bounds: CGRect)
}
