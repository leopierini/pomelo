// Draws Pomelo's app icon with CoreGraphics and writes an AppIcon.appiconset with ImageIO (no other framework).
// Usage: swift scripts/make-app-icon.swift <appiconset folder>
// Deterministic: the same run gives the same bytes (no timestamps, no metadata in the PNGs).
import CoreGraphics
import Foundation
import ImageIO

let canvas: CGFloat = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ])!
}

func gradient(_ top: UInt32, _ bottom: UInt32) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
}

let bodyTop: UInt32 = 0x2B2D42
let bodyBottom: UInt32 = 0x15161F

/// Fills `rect` top to bottom with the gradient, clipped to the context's current path.
func fillClipped(_ context: CGContext, _ gradient: CGGradient, in rect: CGRect) {
    context.saveGState()
    context.clip()
    context.drawLinearGradient(
        gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    context.restoreGState()
}

/// An annular sector between two radial edges, each pulled `gap / 2` toward the slice so the gap between
/// neighbours has the same width at every radius.
func slicePath(centre: CGPoint, inner: CGFloat, outer: CGFloat, from a0: CGFloat, to a1: CGFloat, gap: CGFloat) -> CGPath {
    let half = gap / 2
    func point(radius: CGFloat, angle: CGFloat, normal: CGPoint) -> CGPoint {
        let along = (radius * radius - half * half).squareRoot()
        return CGPoint(
            x: centre.x + along * cos(angle) + half * normal.x, y: centre.y + along * sin(angle) + half * normal.y)
    }
    let normal0 = CGPoint(x: -sin(a0), y: cos(a0))
    let normal1 = CGPoint(x: sin(a1), y: -cos(a1))
    let innerStart = point(radius: inner, angle: a0, normal: normal0)
    let outerStart = point(radius: outer, angle: a0, normal: normal0)
    let outerEnd = point(radius: outer, angle: a1, normal: normal1)
    let innerEnd = point(radius: inner, angle: a1, normal: normal1)
    func angle(_ p: CGPoint) -> CGFloat { atan2(p.y - centre.y, p.x - centre.x) }

    let path = CGMutablePath()
    path.move(to: innerStart)
    path.addLine(to: outerStart)
    path.addArc(center: centre, radius: outer, startAngle: angle(outerStart), endAngle: angle(outerEnd), clockwise: false)
    path.addLine(to: innerEnd)
    path.addArc(center: centre, radius: inner, startAngle: angle(innerEnd), endAngle: angle(innerStart), clockwise: true)
    path.closeSubpath()
    return path
}

func drawIcon(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / canvas
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let small = pixels <= 32
    let gap: CGFloat = small ? 2 / scale : 6

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 24 * scale, color: color(0x000000, alpha: 0.3))
    context.addPath(bodyPath)
    context.setFillColor(color(bodyBottom))
    context.fillPath()
    context.restoreGState()
    context.addPath(bodyPath)
    fillClipped(context, gradient(bodyTop, bodyBottom), in: body)

    let centre = CGPoint(x: 512, y: 512)
    let hubRadius: CGFloat = 116
    let orange = gradient(0xFFB347, 0xFF7A1A)
    for index in 0..<8 {
        let middle = CGFloat.pi / 2 - CGFloat(index) * CGFloat.pi / 4
        let path = slicePath(
            centre: centre, inner: hubRadius - 6, outer: 300, from: middle - CGFloat.pi / 8, to: middle + CGFloat.pi / 8,
            gap: gap)
        context.addPath(path)
        if index == 0 {
            fillClipped(context, orange, in: path.boundingBox)
        } else {
            context.setFillColor(color(0xE9E9EF, alpha: 0.92))
            context.fillPath()
        }
    }

    context.setFillColor(color(bodyBottom))
    context.fillEllipse(in: CGRect(x: centre.x - hubRadius, y: centre.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2))

    let oval = CGRect(x: centre.x - 38, y: centre.y - 46, width: 76, height: 92)
    context.addEllipse(in: oval)
    fillClipped(context, orange, in: oval)

    if !small {
        // Tilted so the tip points up and to the right, away from the oval.
        context.saveGState()
        context.translateBy(x: oval.midX + 20, y: oval.maxY - 4)
        context.rotate(by: 30 * CGFloat.pi / 180)
        context.setFillColor(color(0x3DBE6E))
        context.fillEllipse(in: CGRect(x: -17, y: -9, width: 34, height: 18))
        context.restoreGState()
    }

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-app-icon.swift <appiconset folder>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try writePNG(drawIcon(pixels: points * factor), to: folder.appendingPathComponent(name))
        entries.append(
            """
                {
                  "filename" : "\(name)",
                  "idiom" : "mac",
                  "scale" : "\(factor)x",
                  "size" : "\(points)x\(points)"
                }
            """)
    }
}
let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
