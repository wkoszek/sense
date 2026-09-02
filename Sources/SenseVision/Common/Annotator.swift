import CoreGraphics
import CoreText
import Foundation

/// Draws over a copy of an image using pixel, top-left coordinates.
final class Annotator {
    let ctx: CGContext
    let width: Int
    let height: Int
    let lineWidth: CGFloat
    let fontSize: CGFloat

    static let palette: [String: CGColor] = [
        "faces": CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1),
        "landmarks": CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1),
        "bodies": CGColor(red: 0.2, green: 0.6, blue: 1, alpha: 1),
        "pose": CGColor(red: 0.3, green: 1, blue: 0.5, alpha: 1),
        "hands": CGColor(red: 1, green: 0.5, blue: 0, alpha: 1),
        "animals": CGColor(red: 0.8, green: 0.4, blue: 1, alpha: 1),
        "rects": CGColor(red: 0, green: 1, blue: 1, alpha: 1),
        "barcodes": CGColor(red: 1, green: 0, blue: 1, alpha: 1),
        "text": CGColor(red: 0.2, green: 1, blue: 0.2, alpha: 1),
        "ocr": CGColor(red: 0.2, green: 1, blue: 0.2, alpha: 1),
        "words": CGColor(red: 1, green: 1, blue: 0.2, alpha: 1),
        "horizon": CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        "contours": CGColor(red: 1, green: 0.3, blue: 0.6, alpha: 1),
        "saliency": CGColor(red: 1, green: 0.9, blue: 0, alpha: 1),
    ]

    static func color(_ kind: String) -> CGColor {
        palette[kind] ?? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // flip to top-left origin for drawing
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let m = CGFloat(max(width, height))
        lineWidth = max(1.5, m / 600)
        fontSize = max(10, m / 70)
        ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.round)
    }

    func rect(_ r: CGRect, color: CGColor, label: String? = nil) {
        ctx.setStrokeColor(color)
        ctx.stroke(r)
        if let label { text(label, at: CGPoint(x: r.minX, y: r.minY - 2), color: color) }
    }

    func quad(_ pts: [CGPoint], color: CGColor, label: String? = nil) {
        path(pts, closed: true, color: color)
        if let label, let p = pts.first { text(label, at: CGPoint(x: p.x, y: p.y - 2), color: color) }
    }

    func path(_ pts: [CGPoint], closed: Bool, color: CGColor, width: CGFloat? = nil) {
        guard pts.count > 1 else { return }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width ?? lineWidth)
        ctx.beginPath()
        ctx.move(to: pts[0])
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        if closed { ctx.closePath() }
        ctx.strokePath()
        ctx.setLineWidth(lineWidth)
    }

    func line(_ a: CGPoint, _ b: CGPoint, color: CGColor) {
        path([a, b], closed: false, color: color)
    }

    func point(_ p: CGPoint, color: CGColor, radius: CGFloat? = nil) {
        let r = radius ?? lineWidth * 2
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }

    func text(_ s: String, at p: CGPoint, color: CGColor) {
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        var y = p.y
        if y - bounds.height < 0 { y = p.y + bounds.height + 4 + lineWidth * 2 }
        // background pill
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: p.x, y: y - bounds.height - 2, width: bounds.width + 6, height: bounds.height + 2))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: p.x + 3, y: y - 2 + bounds.minY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    func fill(_ r: CGRect, color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(r)
    }

    func image() -> CGImage {
        ctx.makeImage()!
    }
}
