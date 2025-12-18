import CWaterUI
import CoreGraphics
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for FilledShape - a shape filled with a color.
///
/// This view fills all available space (like Color) and renders a shape
/// filled with the specified color.
@MainActor
final class WuiFilledShape: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_filled_shape_id() }

    private var pathCommands: [WuiPathCommand] = []
    private var fillColor: PlatformColor = .clear
    private let shapeLayer = CAShapeLayer()

    // FilledShape fills available space like Color
    var stretchAxis: WuiStretchAxis { .both }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let shape = waterui_force_as_filled_shape(anyview)

        // Store path commands
        let commandsSlice = shape.commands.vtable.slice(shape.commands.data)
        if let head = commandsSlice.head {
            self.pathCommands = Array(UnsafeBufferPointer(start: head, count: Int(commandsSlice.len)))
        }

        super.init(frame: .zero)

        // Resolve fill color
        if let fillPtr = shape.fill {
            let resolvedColor = waterui_resolve_color(fillPtr, env.inner)
            let color = waterui_read_computed_resolved_color(resolvedColor)
            waterui_drop_computed_resolved_color(resolvedColor)

            #if canImport(UIKit)
            fillColor = UIColor(
                red: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: CGFloat(color.opacity)
            )
            #elseif canImport(AppKit)
            fillColor = NSColor(
                calibratedRed: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: CGFloat(color.opacity)
            )
            #endif
        }

        #if canImport(UIKit)
        layer.addSublayer(shapeLayer)
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.addSublayer(shapeLayer)
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> Int32 { 0 }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Like Color, FilledShape fills available space
        // Use proposal if available, otherwise fallback to small size
        let width = CGFloat(proposal.width ?? 10.0)
        let height = CGFloat(proposal.height ?? 10.0)
        return CGSize(width: width, height: height)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        updateShape()
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        updateShape()
    }
    #endif

    private func updateShape() {
        guard !bounds.isEmpty else { return }

        shapeLayer.frame = bounds
        shapeLayer.path = buildPath(in: bounds).cgPath
        shapeLayer.fillColor = fillColor.cgColor
    }

    #if canImport(UIKit)
    private func buildPath(in bounds: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let width = bounds.width
        let height = bounds.height

        for cmd in pathCommands {
            switch cmd.tag {
            case WuiPathCommand_MoveTo:
                let point = denormalize(cmd.move_to.x, cmd.move_to.y, width: width, height: height)
                path.move(to: point)

            case WuiPathCommand_LineTo:
                let point = denormalize(cmd.line_to.x, cmd.line_to.y, width: width, height: height)
                path.addLine(to: point)

            case WuiPathCommand_QuadTo:
                let control = denormalize(cmd.quad_to.cx, cmd.quad_to.cy, width: width, height: height)
                let end = denormalize(cmd.quad_to.x, cmd.quad_to.y, width: width, height: height)
                path.addQuadCurve(to: end, controlPoint: control)

            case WuiPathCommand_CubicTo:
                let c1 = denormalize(cmd.cubic_to.c1x, cmd.cubic_to.c1y, width: width, height: height)
                let c2 = denormalize(cmd.cubic_to.c2x, cmd.cubic_to.c2y, width: width, height: height)
                let end = denormalize(cmd.cubic_to.x, cmd.cubic_to.y, width: width, height: height)
                path.addCurve(to: end, controlPoint1: c1, controlPoint2: c2)

            case WuiPathCommand_Arc:
                addArc(to: path, arc: cmd.arc, width: width, height: height)

            case WuiPathCommand_Close:
                path.close()

            default:
                break
            }
        }

        return path
    }
    #elseif canImport(AppKit)
    private func buildPath(in bounds: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        let width = bounds.width
        let height = bounds.height

        for cmd in pathCommands {
            switch cmd.tag {
            case WuiPathCommand_MoveTo:
                let point = denormalize(cmd.move_to.x, cmd.move_to.y, width: width, height: height)
                path.move(to: point)

            case WuiPathCommand_LineTo:
                let point = denormalize(cmd.line_to.x, cmd.line_to.y, width: width, height: height)
                path.line(to: point)

            case WuiPathCommand_QuadTo:
                let control = denormalize(cmd.quad_to.cx, cmd.quad_to.cy, width: width, height: height)
                let end = denormalize(cmd.quad_to.x, cmd.quad_to.y, width: width, height: height)
                // NSBezierPath doesn't have addQuadCurve, convert to cubic
                let current = path.currentPoint
                let c1 = CGPoint(
                    x: current.x + 2.0/3.0 * (control.x - current.x),
                    y: current.y + 2.0/3.0 * (control.y - current.y)
                )
                let c2 = CGPoint(
                    x: end.x + 2.0/3.0 * (control.x - end.x),
                    y: end.y + 2.0/3.0 * (control.y - end.y)
                )
                path.curve(to: end, controlPoint1: c1, controlPoint2: c2)

            case WuiPathCommand_CubicTo:
                let c1 = denormalize(cmd.cubic_to.c1x, cmd.cubic_to.c1y, width: width, height: height)
                let c2 = denormalize(cmd.cubic_to.c2x, cmd.cubic_to.c2y, width: width, height: height)
                let end = denormalize(cmd.cubic_to.x, cmd.cubic_to.y, width: width, height: height)
                path.curve(to: end, controlPoint1: c1, controlPoint2: c2)

            case WuiPathCommand_Arc:
                addArc(to: path, arc: cmd.arc, width: width, height: height)

            case WuiPathCommand_Close:
                path.close()

            default:
                break
            }
        }

        return path
    }
    #endif

    private func denormalize(_ x: Float, _ y: Float, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(x) * width, y: CGFloat(y) * height)
    }

    #if canImport(UIKit)
    private func addArc(to path: UIBezierPath, arc: WuiPathCommand_Arc_Body, width: CGFloat, height: CGFloat) {
        let cx = CGFloat(arc.cx) * width
        let cy = CGFloat(arc.cy) * height
        let rx = CGFloat(arc.rx) * width
        let ry = CGFloat(arc.ry) * height
        let startAngle = CGFloat(arc.start)
        let sweepAngle = CGFloat(arc.sweep)

        if abs(rx - ry) < 0.001 {
            // Circular arc
            let clockwise = sweepAngle < 0
            path.addArc(
                withCenter: CGPoint(x: cx, y: cy),
                radius: rx,
                startAngle: startAngle,
                endAngle: startAngle + sweepAngle,
                clockwise: clockwise
            )
        } else {
            // Elliptical arc - approximate with bezier curves
            addEllipticalArc(to: path, cx: cx, cy: cy, rx: rx, ry: ry, startAngle: startAngle, sweepAngle: sweepAngle)
        }
    }

    private func addEllipticalArc(to path: UIBezierPath, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, startAngle: CGFloat, sweepAngle: CGFloat) {
        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let segmentAngle = sweepAngle / CGFloat(segments)

        // Move to start point only if path is empty
        // Don't add line - trust that previous path commands positioned us correctly
        if path.isEmpty {
            let startX = cx + rx * cos(startAngle)
            let startY = cy + ry * sin(startAngle)
            path.move(to: CGPoint(x: startX, y: startY))
        }

        var currentAngle = startAngle

        for _ in 0..<segments {
            let endAngle = currentAngle + segmentAngle
            addEllipticalArcSegment(to: path, cx: cx, cy: cy, rx: rx, ry: ry, startAngle: currentAngle, endAngle: endAngle)
            currentAngle = endAngle
        }
    }

    private func addEllipticalArcSegment(to path: UIBezierPath, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, startAngle: CGFloat, endAngle: CGFloat) {
        let sweepAngle = endAngle - startAngle

        // Guard against degenerate segment
        guard abs(sweepAngle) > 0.0001 else { return }

        // Standard bezier approximation: k = 4/3 * tan(angle/4)
        let k = 4.0 / 3.0 * tan(sweepAngle / 4.0)

        // Start and end points
        let cosStart = cos(startAngle)
        let sinStart = sin(startAngle)
        let cosEnd = cos(endAngle)
        let sinEnd = sin(endAngle)

        let p0x = cx + rx * cosStart
        let p0y = cy + ry * sinStart
        let p3x = cx + rx * cosEnd
        let p3y = cy + ry * sinEnd

        // Control points using tangent direction
        let c1x = p0x - k * rx * sinStart
        let c1y = p0y + k * ry * cosStart
        let c2x = p3x + k * rx * sinEnd
        let c2y = p3y - k * ry * cosEnd

        // Guard against NaN/Inf coordinates
        guard c1x.isFinite && c1y.isFinite && c2x.isFinite && c2y.isFinite &&
              p3x.isFinite && p3y.isFinite else {
            path.addLine(to: CGPoint(x: p3x.isFinite ? p3x : cx, y: p3y.isFinite ? p3y : cy))
            return
        }

        path.addCurve(to: CGPoint(x: p3x, y: p3y), controlPoint1: CGPoint(x: c1x, y: c1y), controlPoint2: CGPoint(x: c2x, y: c2y))
    }
    #elseif canImport(AppKit)
    private func addArc(to path: NSBezierPath, arc: WuiPathCommand_Arc_Body, width: CGFloat, height: CGFloat) {
        let cx = CGFloat(arc.cx) * width
        let cy = CGFloat(arc.cy) * height
        let rx = CGFloat(arc.rx) * width
        let ry = CGFloat(arc.ry) * height
        let startAngle = CGFloat(arc.start)
        let sweepAngle = CGFloat(arc.sweep)

        if abs(rx - ry) < 0.001 {
            // Circular arc - NSBezierPath uses degrees
            let startDegrees = startAngle * 180.0 / .pi
            let endDegrees = (startAngle + sweepAngle) * 180.0 / .pi
            path.appendArc(
                withCenter: CGPoint(x: cx, y: cy),
                radius: rx,
                startAngle: startDegrees,
                endAngle: endDegrees,
                clockwise: sweepAngle < 0
            )
        } else {
            // Elliptical arc - approximate with bezier curves
            addEllipticalArc(to: path, cx: cx, cy: cy, rx: rx, ry: ry, startAngle: startAngle, sweepAngle: sweepAngle)
        }
    }

    private func addEllipticalArc(to path: NSBezierPath, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, startAngle: CGFloat, sweepAngle: CGFloat) {
        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let segmentAngle = sweepAngle / CGFloat(segments)

        // Move to start point only if path is empty
        // Don't add line - trust that previous path commands positioned us correctly
        if path.isEmpty {
            let startX = cx + rx * cos(startAngle)
            let startY = cy + ry * sin(startAngle)
            path.move(to: CGPoint(x: startX, y: startY))
        }

        var currentAngle = startAngle

        for _ in 0..<segments {
            let endAngle = currentAngle + segmentAngle
            addEllipticalArcSegment(to: path, cx: cx, cy: cy, rx: rx, ry: ry, startAngle: currentAngle, endAngle: endAngle)
            currentAngle = endAngle
        }
    }

    private func addEllipticalArcSegment(to path: NSBezierPath, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, startAngle: CGFloat, endAngle: CGFloat) {
        let sweepAngle = endAngle - startAngle

        // Guard against degenerate segment
        guard abs(sweepAngle) > 0.0001 else { return }

        // Standard bezier approximation: k = 4/3 * tan(angle/4)
        let k = 4.0 / 3.0 * tan(sweepAngle / 4.0)

        // Start and end points
        let cosStart = cos(startAngle)
        let sinStart = sin(startAngle)
        let cosEnd = cos(endAngle)
        let sinEnd = sin(endAngle)

        let p0x = cx + rx * cosStart
        let p0y = cy + ry * sinStart
        let p3x = cx + rx * cosEnd
        let p3y = cy + ry * sinEnd

        // Control points using tangent direction
        let c1x = p0x - k * rx * sinStart
        let c1y = p0y + k * ry * cosStart
        let c2x = p3x + k * rx * sinEnd
        let c2y = p3y - k * ry * cosEnd

        // Guard against NaN/Inf coordinates
        guard c1x.isFinite && c1y.isFinite && c2x.isFinite && c2y.isFinite &&
              p3x.isFinite && p3y.isFinite else {
            path.line(to: CGPoint(x: p3x.isFinite ? p3x : cx, y: p3y.isFinite ? p3y : cy))
            return
        }

        path.curve(to: CGPoint(x: p3x, y: p3y), controlPoint1: CGPoint(x: c1x, y: c1y), controlPoint2: CGPoint(x: c2x, y: c2y))
    }
    #endif
}
