// WuiSvg.swift
// SVG component - renders SVG path data using native vector graphics
//
// # Layout Behavior
// Svg is content-sized using intrinsic dimensions from width/height.
// If dimensions are unspecified (0), falls back to 24x24 default.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .none (content-sized, does not expand)
// // - sizeThatFits: Returns intrinsic size based on width/height
// // - Priority: 0 (default)

import CWaterUI
import CoreGraphics
import os

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "WuiSvg")

@MainActor
final class WuiSvg: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_svg_id() }

    private let shapeLayer = CAShapeLayer()
    private let intrinsicWidth: CGFloat
    private let intrinsicHeight: CGFloat
    private var colorComputed: WuiComputed<WuiResolvedColor>?
    private var originalPath: CGPath?

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiSvg: CWaterUI.WuiSvg = waterui_force_as_svg(anyview)
        let content = WuiStr(ffiSvg.content).toString()
        let width = CGFloat(ffiSvg.width)
        let height = CGFloat(ffiSvg.height)

        // Get tint color if specified
        var resolvedColor: WuiComputed<WuiResolvedColor>? = nil
        if let colorPtr = ffiSvg.tint {
            let wuiColor = WuiColor(colorPtr)
            resolvedColor = wuiColor.resolve(in: env)
        }

        self.init(pathData: content, width: width, height: height, tint: resolvedColor)
    }

    // MARK: - Designated Init

    private init(pathData: String, width: CGFloat, height: CGFloat, tint: WuiComputed<WuiResolvedColor>?) {
        // Use specified dimensions or fall back to 24x24 (standard icon size)
        self.intrinsicWidth = width > 0 ? width : 24
        self.intrinsicHeight = height > 0 ? height : 24
        self.colorComputed = tint

        super.init(frame: CGRect(x: 0, y: 0, width: intrinsicWidth, height: intrinsicHeight))

        #if canImport(UIKit)
        layer.addSublayer(shapeLayer)
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.addSublayer(shapeLayer)
        #endif

        // Parse SVG path data and create CGPath
        if let path = parseSvgPath(pathData) {
            self.originalPath = path
            shapeLayer.path = path
        } else {
            logger.warning("Failed to parse SVG path data: \(pathData.prefix(50), privacy: .public)...")
        }

        // Apply tint color or default to label color
        if let tint = tint {
            applyColor(tint.value)
        } else {
            #if canImport(UIKit)
            shapeLayer.fillColor = UIColor.label.cgColor
            #elseif canImport(AppKit)
            shapeLayer.fillColor = NSColor.labelColor.cgColor
            #endif
        }

        shapeLayer.strokeColor = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyColor(_ color: WuiResolvedColor) {
        #if canImport(UIKit)
        shapeLayer.fillColor = color.toUIColor().cgColor
        #elseif canImport(AppKit)
        shapeLayer.fillColor = color.toNSColor().cgColor
        #endif
    }

    // MARK: - Layout

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        updateShapeLayerFrame()
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        updateShapeLayerFrame()
    }
    #endif

    private func updateShapeLayerFrame() {
        shapeLayer.frame = bounds

        // Scale the path to fit the bounds while maintaining aspect ratio
        guard let originalPath = self.originalPath else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        let scaleX = bounds.width / intrinsicWidth
        let scaleY = bounds.height / intrinsicHeight
        let scale = min(scaleX, scaleY)

        // Center the scaled path
        let scaledWidth = intrinsicWidth * scale
        let scaledHeight = intrinsicHeight * scale
        let offsetX = (bounds.width - scaledWidth) / 2
        let offsetY = (bounds.height - scaledHeight) / 2

        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: offsetX, y: offsetY)
        transform = transform.scaledBy(x: scale, y: scale)

        // Apply transform to original path (not the current layer path)
        let mutablePath = CGMutablePath()
        mutablePath.addPath(originalPath, transform: transform)
        shapeLayer.path = mutablePath
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Return intrinsic size, respecting aspect ratio if only one dimension is constrained
        var width = intrinsicWidth
        var height = intrinsicHeight

        if let proposedWidth = proposal.width, let proposedHeight = proposal.height {
            // Both constrained: fit within bounds maintaining aspect ratio
            let scaleX = CGFloat(proposedWidth) / intrinsicWidth
            let scaleY = CGFloat(proposedHeight) / intrinsicHeight
            let scale = min(scaleX, scaleY)
            width = intrinsicWidth * scale
            height = intrinsicHeight * scale
        } else if let proposedWidth = proposal.width {
            // Only width constrained: scale proportionally
            let scale = CGFloat(proposedWidth) / intrinsicWidth
            width = CGFloat(proposedWidth)
            height = intrinsicHeight * scale
        } else if let proposedHeight = proposal.height {
            // Only height constrained: scale proportionally
            let scale = CGFloat(proposedHeight) / intrinsicHeight
            width = intrinsicWidth * scale
            height = CGFloat(proposedHeight)
        }

        return CGSize(width: width, height: height)
    }

    // MARK: - SVG Path Parsing

    /// Parses SVG path data (d attribute) into a CGPath.
    private func parseSvgPath(_ pathData: String) -> CGPath? {
        let path = CGMutablePath()
        var currentPoint = CGPoint.zero
        var lastControlPoint: CGPoint? = nil
        var lastCommand: Character = " "

        let scanner = Scanner(string: pathData)
        scanner.charactersToBeSkipped = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))

        while !scanner.isAtEnd {
            let startLocation = scanner.currentIndex

            // Try to scan a command character
            var command: Character = lastCommand
            if let scannedCommand = scanCommand(scanner) {
                command = scannedCommand
                lastCommand = command
            }

            // Parse based on command
            switch command {
            case "M": // moveto absolute
                if let point = scanPoint(scanner) {
                    path.move(to: point)
                    currentPoint = point
                    lastCommand = "L" // Subsequent coordinates are lineto
                }
            case "m": // moveto relative
                if let point = scanPoint(scanner) {
                    let newPoint = CGPoint(x: currentPoint.x + point.x, y: currentPoint.y + point.y)
                    path.move(to: newPoint)
                    currentPoint = newPoint
                    lastCommand = "l"
                }
            case "L": // lineto absolute
                if let point = scanPoint(scanner) {
                    path.addLine(to: point)
                    currentPoint = point
                }
            case "l": // lineto relative
                if let point = scanPoint(scanner) {
                    let newPoint = CGPoint(x: currentPoint.x + point.x, y: currentPoint.y + point.y)
                    path.addLine(to: newPoint)
                    currentPoint = newPoint
                }
            case "H": // horizontal lineto absolute
                if let x = scanNumber(scanner) {
                    let point = CGPoint(x: x, y: currentPoint.y)
                    path.addLine(to: point)
                    currentPoint = point
                }
            case "h": // horizontal lineto relative
                if let dx = scanNumber(scanner) {
                    let point = CGPoint(x: currentPoint.x + dx, y: currentPoint.y)
                    path.addLine(to: point)
                    currentPoint = point
                }
            case "V": // vertical lineto absolute
                if let y = scanNumber(scanner) {
                    let point = CGPoint(x: currentPoint.x, y: y)
                    path.addLine(to: point)
                    currentPoint = point
                }
            case "v": // vertical lineto relative
                if let dy = scanNumber(scanner) {
                    let point = CGPoint(x: currentPoint.x, y: currentPoint.y + dy)
                    path.addLine(to: point)
                    currentPoint = point
                }
            case "C": // curveto absolute
                if let cp1 = scanPoint(scanner),
                   let cp2 = scanPoint(scanner),
                   let end = scanPoint(scanner) {
                    path.addCurve(to: end, control1: cp1, control2: cp2)
                    currentPoint = end
                    lastControlPoint = cp2
                }
            case "c": // curveto relative
                if let cp1 = scanPoint(scanner),
                   let cp2 = scanPoint(scanner),
                   let end = scanPoint(scanner) {
                    let absCP1 = CGPoint(x: currentPoint.x + cp1.x, y: currentPoint.y + cp1.y)
                    let absCP2 = CGPoint(x: currentPoint.x + cp2.x, y: currentPoint.y + cp2.y)
                    let absEnd = CGPoint(x: currentPoint.x + end.x, y: currentPoint.y + end.y)
                    path.addCurve(to: absEnd, control1: absCP1, control2: absCP2)
                    lastControlPoint = absCP2
                    currentPoint = absEnd
                }
            case "S": // smooth curveto absolute
                if let cp2 = scanPoint(scanner),
                   let end = scanPoint(scanner) {
                    let cp1 = reflectControlPoint(lastControlPoint, currentPoint: currentPoint)
                    path.addCurve(to: end, control1: cp1, control2: cp2)
                    currentPoint = end
                    lastControlPoint = cp2
                }
            case "s": // smooth curveto relative
                if let cp2 = scanPoint(scanner),
                   let end = scanPoint(scanner) {
                    let cp1 = reflectControlPoint(lastControlPoint, currentPoint: currentPoint)
                    let absCP2 = CGPoint(x: currentPoint.x + cp2.x, y: currentPoint.y + cp2.y)
                    let absEnd = CGPoint(x: currentPoint.x + end.x, y: currentPoint.y + end.y)
                    path.addCurve(to: absEnd, control1: cp1, control2: absCP2)
                    lastControlPoint = absCP2
                    currentPoint = absEnd
                }
            case "Q": // quadratic curveto absolute
                if let cp = scanPoint(scanner),
                   let end = scanPoint(scanner) {
                    path.addQuadCurve(to: end, control: cp)
                    currentPoint = end
                    lastControlPoint = cp
                }
            case "q": // quadratic curveto relative
                if let cp = scanPoint(scanner),
                   let end = scanPoint(scanner) {
                    let absCP = CGPoint(x: currentPoint.x + cp.x, y: currentPoint.y + cp.y)
                    let absEnd = CGPoint(x: currentPoint.x + end.x, y: currentPoint.y + end.y)
                    path.addQuadCurve(to: absEnd, control: absCP)
                    lastControlPoint = absCP
                    currentPoint = absEnd
                }
            case "T": // smooth quadratic curveto absolute
                if let end = scanPoint(scanner) {
                    let cp = reflectControlPoint(lastControlPoint, currentPoint: currentPoint)
                    path.addQuadCurve(to: end, control: cp)
                    lastControlPoint = cp
                    currentPoint = end
                }
            case "t": // smooth quadratic curveto relative
                if let end = scanPoint(scanner) {
                    let cp = reflectControlPoint(lastControlPoint, currentPoint: currentPoint)
                    let absEnd = CGPoint(x: currentPoint.x + end.x, y: currentPoint.y + end.y)
                    path.addQuadCurve(to: absEnd, control: cp)
                    lastControlPoint = cp
                    currentPoint = absEnd
                }
            case "A", "a": // arc
                // Arc parsing is complex; simplified implementation
                if let result = scanArc(scanner, isRelative: command == "a", currentPoint: currentPoint) {
                    addArc(to: path, rx: result.rx, ry: result.ry, angle: result.angle,
                           largeArc: result.largeArc, sweep: result.sweep, end: result.end, from: currentPoint)
                    currentPoint = result.end
                }
            case "Z", "z": // closepath
                path.closeSubpath()
            default:
                // Skip unknown commands
                break
            }

            // Reset control point for non-curve commands
            if !["C", "c", "S", "s", "Q", "q", "T", "t"].contains(String(command)) {
                lastControlPoint = nil
            }

            // Safety: if we haven't made progress, skip one character to avoid infinite loop
            if scanner.currentIndex == startLocation && !scanner.isAtEnd {
                scanner.currentIndex = pathData.index(after: scanner.currentIndex)
            }
        }

        return path.isEmpty ? nil : path
    }

    private func scanCommand(_ scanner: Scanner) -> Character? {
        let commands = CharacterSet(charactersIn: "MmZzLlHhVvCcSsQqTtAa")
        if let scanned = scanner.scanCharacters(from: commands), let char = scanned.first {
            return char
        }
        return nil
    }

    private func scanNumber(_ scanner: Scanner) -> CGFloat? {
        if let value = scanner.scanDouble() {
            return CGFloat(value)
        }
        return nil
    }

    private func scanPoint(_ scanner: Scanner) -> CGPoint? {
        guard let x = scanNumber(scanner),
              let y = scanNumber(scanner) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    private func reflectControlPoint(_ controlPoint: CGPoint?, currentPoint: CGPoint) -> CGPoint {
        guard let cp = controlPoint else { return currentPoint }
        return CGPoint(x: 2 * currentPoint.x - cp.x, y: 2 * currentPoint.y - cp.y)
    }

    private struct ArcParams {
        let rx: CGFloat
        let ry: CGFloat
        let angle: CGFloat
        let largeArc: Bool
        let sweep: Bool
        let end: CGPoint
    }

    private func scanArc(_ scanner: Scanner, isRelative: Bool, currentPoint: CGPoint) -> ArcParams? {
        guard let rx = scanNumber(scanner),
              let ry = scanNumber(scanner),
              let angle = scanNumber(scanner),
              let largeArcFlag = scanNumber(scanner),
              let sweepFlag = scanNumber(scanner),
              let x = scanNumber(scanner),
              let y = scanNumber(scanner) else {
            return nil
        }

        var endPoint = CGPoint(x: x, y: y)
        if isRelative {
            endPoint = CGPoint(x: currentPoint.x + x, y: currentPoint.y + y)
        }

        return ArcParams(
            rx: rx, ry: ry, angle: angle,
            largeArc: largeArcFlag != 0,
            sweep: sweepFlag != 0,
            end: endPoint
        )
    }

    private func addArc(to path: CGMutablePath, rx: CGFloat, ry: CGFloat, angle: CGFloat,
                        largeArc: Bool, sweep: Bool, end: CGPoint, from start: CGPoint) {
        // Simplified arc: approximate with bezier curves
        // For proper SVG arc, would need full elliptical arc conversion
        // This is a basic implementation that handles common cases

        guard rx > 0 && ry > 0 else {
            path.addLine(to: end)
            return
        }

        // For simple cases, approximate arc with quadratic curve through midpoint
        let midX = (start.x + end.x) / 2
        let midY = (start.y + end.y) / 2

        // Simple curve approximation
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dist = sqrt(dx * dx + dy * dy)

        if dist < 0.001 {
            return
        }

        // Perpendicular offset for control point
        let perpX = -dy / dist
        let perpY = dx / dist

        let arcHeight = min(rx, ry) * (largeArc ? 0.8 : 0.4)
        let direction: CGFloat = sweep ? 1 : -1

        let controlX = midX + perpX * arcHeight * direction
        let controlY = midY + perpY * arcHeight * direction

        path.addQuadCurve(to: end, control: CGPoint(x: controlX, y: controlY))
    }
}
