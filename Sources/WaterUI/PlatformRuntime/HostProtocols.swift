import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

/// Describes the minimal data the native runtime needs for a child view when
/// talking to the Rust layout engine.
struct PlatformViewDescriptor: Equatable {
    let typeId: String
    let isSpacer: Bool

    init(typeId: String, isSpacer: Bool) {
        self.typeId = typeId
        self.isSpacer = isSpacer
    }
}

/// Protocol adopted by native views (UIView/NSView/etc.) that can measure
/// themselves using WaterUI's proposal semantics.
protocol WaterUILayoutMeasurable: AnyObject {
    var descriptor: PlatformViewDescriptor { get }
    func layoutPriority() -> UInt8
    func measure(in proposal: WuiProposalSize) -> CGSize
}

/// A host container that arranges native child views using the shared Rust layout engine.
protocol WaterUIPlatformHost: AnyObject {
    associatedtype NativeContainer

    var container: NativeContainer { get }
    var layoutBridge: NativeLayoutBridge { get }

    func setChildren(_ children: [WaterUILayoutMeasurable])
    func performNativeLayout(bounds: CGRect)
}
