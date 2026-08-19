import CWaterUI
import CoreGraphics

enum WuiShapePath {
    static func commands(from array: WuiArray_WuiPathCommand) -> [WuiPathCommand] {
        let slice = array.vtable.slice(array.data)
        guard let head = slice.head else {
            return []
        }
        return Array(UnsafeBufferPointer(start: head, count: Int(slice.len)))
    }

    /// Builds the shape's path from its structured kind, in point space.
    ///
    /// The command list is in unit space, so a corner drawn from it stretches
    /// with the rect's aspect ratio — a rounded rectangle wider than tall gets
    /// flat elliptical corners. The kind carries what the commands cannot: a
    /// corner radius as a fraction of the *shorter* side, applied uniformly in
    /// points. Only a custom path falls back to the unit-space commands.
    static func makePath(
        kind: WuiShapeKind, commands: [WuiPathCommand], in bounds: CGRect
    ) -> CGPath {
        let shorter = min(bounds.width, bounds.height)
        switch kind.tag {
        case 0:  // Rect
            return CGPath(rect: bounds, transform: nil)
        case 1:  // Circle: centered, diameter is the shorter side
            let rect = CGRect(
                x: bounds.midX - shorter / 2,
                y: bounds.midY - shorter / 2,
                width: shorter,
                height: shorter
            )
            return CGPath(ellipseIn: rect, transform: nil)
        case 2:  // Ellipse
            return CGPath(ellipseIn: bounds, transform: nil)
        case 3:  // Rounded rect, uniform normalized radius
            let radius = min(CGFloat(kind.top_left) * shorter, shorter / 2)
            return CGPath(
                roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case 4:  // Uneven rounded rect, per-corner normalized radii
            return unevenRoundedRect(kind: kind, in: bounds)
        case 5:  // Capsule
            let radius = shorter / 2
            return CGPath(
                roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case 6:  // Custom path: only the commands describe it
            return makePath(commands: commands, in: bounds)
        default:
            fatalError("unknown WaterUI shape kind tag \(kind.tag)")
        }
    }

    private static func unevenRoundedRect(kind: WuiShapeKind, in bounds: CGRect) -> CGPath {
        let shorter = min(bounds.width, bounds.height)
        let limit = shorter / 2
        let tl = min(CGFloat(kind.top_left) * shorter, limit)
        let tr = min(CGFloat(kind.top_right) * shorter, limit)
        let br = min(CGFloat(kind.bottom_right) * shorter, limit)
        let bl = min(CGFloat(kind.bottom_left) * shorter, limit)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX + tl, y: bounds.minY))
        path.addArc(
            tangent1End: CGPoint(x: bounds.maxX, y: bounds.minY),
            tangent2End: CGPoint(x: bounds.maxX, y: bounds.maxY), radius: tr)
        path.addArc(
            tangent1End: CGPoint(x: bounds.maxX, y: bounds.maxY),
            tangent2End: CGPoint(x: bounds.minX, y: bounds.maxY), radius: br)
        path.addArc(
            tangent1End: CGPoint(x: bounds.minX, y: bounds.maxY),
            tangent2End: CGPoint(x: bounds.minX, y: bounds.minY), radius: bl)
        path.addArc(
            tangent1End: CGPoint(x: bounds.minX, y: bounds.minY),
            tangent2End: CGPoint(x: bounds.maxX, y: bounds.minY), radius: tl)
        path.closeSubpath()
        return path
    }

    static func makePath(commands: [WuiPathCommand], in bounds: CGRect) -> CGPath {
        let path = CGMutablePath()
        let width = bounds.width
        let height = bounds.height

        for command in commands {
            switch command.tag {
            case WuiPathCommand_MoveTo:
                path.move(to: denormalize(command.move_to.x, command.move_to.y, width: width, height: height))

            case WuiPathCommand_LineTo:
                path.addLine(to: denormalize(command.line_to.x, command.line_to.y, width: width, height: height))

            case WuiPathCommand_QuadTo:
                path.addQuadCurve(
                    to: denormalize(command.quad_to.x, command.quad_to.y, width: width, height: height),
                    control: denormalize(command.quad_to.cx, command.quad_to.cy, width: width, height: height)
                )

            case WuiPathCommand_CubicTo:
                path.addCurve(
                    to: denormalize(command.cubic_to.x, command.cubic_to.y, width: width, height: height),
                    control1: denormalize(command.cubic_to.c1x, command.cubic_to.c1y, width: width, height: height),
                    control2: denormalize(command.cubic_to.c2x, command.cubic_to.c2y, width: width, height: height)
                )

            case WuiPathCommand_Arc:
                addArc(to: path, arc: command.arc, width: width, height: height)

            case WuiPathCommand_Close:
                path.closeSubpath()

            default:
                fatalError("unknown WaterUI path command tag \(command.tag)")
            }
        }

        return path
    }

    private static func denormalize(_ x: Float, _ y: Float, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(x) * width, y: CGFloat(y) * height)
    }

    private static func addArc(
        to path: CGMutablePath,
        arc: WuiPathCommand_Arc_Body,
        width: CGFloat,
        height: CGFloat
    ) {
        let cx = CGFloat(arc.cx) * width
        let cy = CGFloat(arc.cy) * height
        let rx = CGFloat(arc.rx) * width
        let ry = CGFloat(arc.ry) * height
        let start = CGFloat(arc.start)
        let sweep = CGFloat(arc.sweep)

        if abs(sweep) >= .pi * 2.0 - 0.0001 {
            path.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2.0, height: ry * 2.0))
            return
        }

        var transform = CGAffineTransform(translationX: cx, y: cy)
        transform = transform.scaledBy(x: rx, y: ry)
        path.addArc(
            center: .zero,
            radius: 1.0,
            startAngle: start,
            endAngle: start + sweep,
            clockwise: sweep < 0.0,
            transform: transform
        )
    }
}
