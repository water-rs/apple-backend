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
