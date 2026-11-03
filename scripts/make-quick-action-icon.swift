// Draws the Quick Action's icon, a monochrome template of the app's symbol (the eight-slice wheel round the
// pomelo), as a vector PDF. Usage: swift scripts/make-quick-action-icon.swift App/QuickAction/QuickActionIcon.pdf
import CoreGraphics
import Foundation

let side: CGFloat = 18
let centre = CGPoint(x: side / 2, y: side / 2)
let inner: CGFloat = 3.6
let outer: CGFloat = 8.6
let gap: CGFloat = 1.1

/// An annular sector whose radial edges are pulled `gap / 2` toward the slice, so a gap has one width at every radius.
func slice(from a0: CGFloat, to a1: CGFloat) -> CGPath {
    let half = gap / 2
    func point(_ radius: CGFloat, _ angle: CGFloat, _ normal: CGPoint) -> CGPoint {
        let along = (radius * radius - half * half).squareRoot()
        return CGPoint(x: centre.x + along * cos(angle) + half * normal.x,
                       y: centre.y + along * sin(angle) + half * normal.y)
    }
    func angle(_ p: CGPoint) -> CGFloat { atan2(p.y - centre.y, p.x - centre.x) }
    let normal0 = CGPoint(x: -sin(a0), y: cos(a0))
    let normal1 = CGPoint(x: sin(a1), y: -cos(a1))
    let innerStart = point(inner, a0, normal0), outerStart = point(outer, a0, normal0)
    let outerEnd = point(outer, a1, normal1), innerEnd = point(inner, a1, normal1)
    let path = CGMutablePath()
    path.move(to: innerStart)
    path.addLine(to: outerStart)
    path.addArc(center: centre, radius: outer, startAngle: angle(outerStart), endAngle: angle(outerEnd), clockwise: false)
    path.addLine(to: innerEnd)
    path.addArc(center: centre, radius: inner, startAngle: angle(innerEnd), endAngle: angle(innerStart), clockwise: true)
    path.closeSubpath()
    return path
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-quick-action-icon.swift <output.pdf>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
var box = CGRect(x: 0, y: 0, width: side, height: side)
guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { exit(1) }
context.beginPDFPage(nil)
context.setFillColor(CGColor(gray: 0, alpha: 1))
for index in 0..<8 {
    let middle = CGFloat.pi / 2 - CGFloat(index) * CGFloat.pi / 4
    context.addPath(slice(from: middle - CGFloat.pi / 8, to: middle + CGFloat.pi / 8))
}
context.addEllipse(in: CGRect(x: centre.x - 1.6, y: centre.y - 1.95, width: 3.2, height: 3.9))
context.fillPath()
context.endPDFPage()
context.closePDF()
