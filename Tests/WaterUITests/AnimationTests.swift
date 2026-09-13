import CWaterUI
import CoreGraphics
import Testing

@testable import WaterUI

@MainActor
struct AnimationTests {
  @Test func noneParses() {
    var animation = CWaterUI.WuiAnimation()
    animation.tag = WuiAnimation_None
    guard case .none = parseAnimation(animation) else {
      Issue.record("expected .none")
      return
    }
    #expect(shouldAnimate(.none) == false)
  }

  @Test func bezierParsesDurationAndControlPoints() {
    var animation = CWaterUI.WuiAnimation()
    animation.tag = WuiAnimation_Bezier
    animation.bezier = WuiAnimation_Bezier_Body(
      duration_ms: 250,
      x1: 0.25,
      y1: 0.1,
      x2: 0.5,
      y2: 1.0
    )
    guard case .bezier(let duration, let x1, let y1, let x2, let y2) = parseAnimation(animation)
    else {
      Issue.record("expected .bezier")
      return
    }
    #expect(duration == 0.25)
    // The C body fields are Float; compare through the same float round-trip.
    #expect(x1 == CGFloat(Float(0.25)))
    #expect(y1 == CGFloat(Float(0.1)))
    #expect(x2 == CGFloat(Float(0.5)))
    #expect(y2 == CGFloat(Float(1.0)))
    #expect(shouldAnimate(.bezier(duration: duration, x1: x1, y1: y1, x2: x2, y2: y2)))
  }

  @Test func springParsesStiffnessAndDamping() {
    var animation = CWaterUI.WuiAnimation()
    animation.tag = WuiAnimation_Spring
    animation.spring = WuiAnimation_Spring_Body(stiffness: 180, damping: 12)
    guard case .spring(let stiffness, let damping) = parseAnimation(animation) else {
      Issue.record("expected .spring")
      return
    }
    #expect(stiffness == 180)
    #expect(damping == 12)
  }
}
