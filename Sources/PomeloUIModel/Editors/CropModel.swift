// The Crop editor's rectangle (P27): the ratio it keeps, its handles and nudges, and what the footer says. It works
// in whole pixels of the upright picture and hands the engines a `UnitRect` of the same rectangle (global
// constraints, Coordinates). The rules it shares with the engines are PomeloCore's `CropEdit`. No AppKit.
import CoreGraphics
import Foundation
import PomeloCore

public enum CropRatio: String, Codable, Sendable, CaseIterable {
    case free, square, fourThree, sixteenNine, original

    public var title: String {
        switch self {
        case .free: "Free"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        case .original: "Original"
        }
    }

    /// Ratios with a long side, which the flip button turns between landscape and portrait.
    public var canFlip: Bool { self == .fourThree || self == .sixteenNine }

    /// Width over height, in pixels; nil for free.
    func aspect(portrait: Bool, source: CGSize) -> Double? {
        let landscape: Double? = switch self {
        case .free: nil
        case .square: 1
        case .fourThree: 4.0 / 3
        case .sixteenNine: 16.0 / 9
        case .original: source.height > 0 ? Double(source.width / source.height) : 1
        }
        guard let landscape else { return nil }
        return canFlip && portrait ? 1 / landscape : landscape
    }
}

public enum CropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, body

    var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
    var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
}

public struct CropModel: Equatable, Sendable {
    public static let minimumPixels = CropEdit.minimumSide

    /// The upright picture's size.
    public let pixelSize: CGSize
    public private(set) var ratio: CropRatio
    /// Starts as the picture's own orientation; `flip` turns 4:3 and 16:9.
    public private(set) var isPortrait: Bool
    /// Whole pixels, always inside the picture and at least the minimum on each side.
    private var box: CGRect

    public init(pixelSize: CGSize, ratio: CropRatio = .free) {
        let size = CGSize(width: max(1, pixelSize.width.rounded()), height: max(1, pixelSize.height.rounded()))
        self.pixelSize = size
        self.ratio = .free
        isPortrait = size.height > size.width
        box = CGRect(origin: .zero, size: size)
        setRatio(ratio)
    }

    public var rect: UnitRect {
        UnitRect(x: box.minX / pixelSize.width, y: box.minY / pixelSize.height,
                 width: box.width / pixelSize.width, height: box.height / pixelSize.height)
    }

    /// "3000 × 3000".
    public var readout: String {
        "\(Int(box.width)) \u{00D7} \(Int(box.height))"
    }

    public var blocker: String? {
        CropEdit.keepsEverything(rect, width: Int(pixelSize.width), height: Int(pixelSize.height))
            ? CropEdit.wholeImageReason : nil
    }

    public var spec: EditSpec? {
        blocker == nil ? .crop(rect) : nil
    }

    /// The handles to show: with a fixed ratio an edge alone would break it, so only the corners and the body.
    public func handles() -> [CropHandle] {
        aspect == nil ? CropHandle.allCases : CropHandle.allCases.filter { $0.isCorner || $0 == .body }
    }

    /// The largest rectangle of `ratio` centred on the current one's centre, inside the picture.
    public mutating func setRatio(_ ratio: CropRatio) {
        self.ratio = ratio
        guard let aspect else { return }
        let centre = CGPoint(x: box.midX, y: box.midY)
        let halfWidth = min(centre.x, pixelSize.width - centre.x)
        let halfHeight = min(centre.y, pixelSize.height - centre.y)
        let width = min(2 * halfWidth, 2 * halfHeight * aspect)
        box = fitted(width: width, aspect: aspect, around: centre)
    }

    public mutating func flip() {
        guard ratio.canFlip else { return }
        isPortrait.toggle()
        setRatio(ratio)
    }

    /// Moves `handle` by `delta`, in fractions of the picture's size. With a fixed ratio a corner keeps it, pivoting
    /// on the opposite corner.
    public mutating func drag(_ handle: CropHandle, by delta: CGSize) {
        let dx = delta.width * pixelSize.width
        let dy = delta.height * pixelSize.height
        guard dx.isFinite, dy.isFinite else { return }
        if handle == .body {
            move(dx: dx, dy: dy)
        } else if let aspect {
            if handle.isCorner { resizeCorner(handle, dx: dx, dy: dy, aspect: aspect) }
        } else {
            resizeFree(handle, dx: dx, dy: dy)
        }
    }

    /// One pixel per step, or ten when `coarse`.
    public mutating func nudge(_ handle: CropHandle, dx: Int, dy: Int, coarse: Bool) {
        let step = coarse ? 10.0 : 1.0
        drag(handle, by: CGSize(width: Double(dx) * step / pixelSize.width, height: Double(dy) * step / pixelSize.height))
    }

    // MARK: Private

    private var aspect: Double? { ratio.aspect(portrait: isPortrait, source: pixelSize) }

    private var minimumWidth: CGFloat { min(CGFloat(Self.minimumPixels), pixelSize.width) }
    private var minimumHeight: CGFloat { min(CGFloat(Self.minimumPixels), pixelSize.height) }

    private mutating func move(dx: CGFloat, dy: CGFloat) {
        box.origin.x = min(max(0, (box.minX + dx).rounded()), pixelSize.width - box.width)
        box.origin.y = min(max(0, (box.minY + dy).rounded()), pixelSize.height - box.height)
    }

    private mutating func resizeFree(_ handle: CropHandle, dx: CGFloat, dy: CGFloat) {
        var (left, top, right, bottom) = (box.minX, box.minY, box.maxX, box.maxY)
        if handle.movesLeft { left = min(max(0, (left + dx).rounded()), right - minimumWidth) }
        if handle.movesRight { right = max(min(pixelSize.width, (right + dx).rounded()), left + minimumWidth) }
        if handle.movesTop { top = min(max(0, (top + dy).rounded()), bottom - minimumHeight) }
        if handle.movesBottom { bottom = max(min(pixelSize.height, (bottom + dy).rounded()), top + minimumHeight) }
        box = CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The side that changed more, relative to its length, drives the other, so a sideways drag of a corner still
    /// resizes.
    private mutating func resizeCorner(_ handle: CropHandle, dx: CGFloat, dy: CGFloat, aspect: Double) {
        let anchor = CGPoint(x: handle.movesLeft ? box.maxX : box.minX, y: handle.movesTop ? box.maxY : box.minY)
        let proposedWidth = box.width + (handle.movesLeft ? -dx : dx)
        let proposedHeight = box.height + (handle.movesTop ? -dy : dy)
        let widthChange = abs(proposedWidth - box.width) / box.width
        let heightChange = abs(proposedHeight - box.height) / box.height
        var width = widthChange >= heightChange ? proposedWidth : proposedHeight * aspect
        let roomWidth = handle.movesLeft ? anchor.x : pixelSize.width - anchor.x
        let roomHeight = handle.movesTop ? anchor.y : pixelSize.height - anchor.y
        width = min(width, roomWidth, roomHeight * aspect)
        width = max(width, minimumWidth, minimumHeight * aspect)
        let size = wholeSize(width: width, aspect: aspect)
        box = CGRect(x: handle.movesLeft ? anchor.x - size.width : anchor.x,
                     y: handle.movesTop ? anchor.y - size.height : anchor.y,
                     width: size.width, height: size.height)
        keepInside()
    }

    /// A rectangle `width` wide of `aspect` centred on `centre`, in whole pixels and inside the picture.
    private func fitted(width: CGFloat, aspect: Double, around centre: CGPoint) -> CGRect {
        let floor = max(minimumWidth, minimumHeight * aspect)
        let size = wholeSize(width: max(width, floor), aspect: aspect)
        var fitted = CGRect(x: (centre.x - size.width / 2).rounded(), y: (centre.y - size.height / 2).rounded(),
                            width: size.width, height: size.height)
        fitted.origin.x = min(max(0, fitted.minX), pixelSize.width - fitted.width)
        fitted.origin.y = min(max(0, fitted.minY), pixelSize.height - fitted.height)
        return fitted
    }

    /// Whole pixels within the picture; the ratio holds to within a pixel.
    private func wholeSize(width: CGFloat, aspect: Double) -> CGSize {
        let height = min(pixelSize.height, max(minimumHeight, (width / aspect).rounded()))
        return CGSize(width: min(pixelSize.width, max(minimumWidth, width.rounded())), height: height)
    }

    private mutating func keepInside() {
        box.size.width = min(box.width, pixelSize.width)
        box.size.height = min(box.height, pixelSize.height)
        box.origin.x = min(max(0, box.minX), pixelSize.width - box.width)
        box.origin.y = min(max(0, box.minY), pixelSize.height - box.height)
    }
}
