import AppKit
import CoreImage
let dir = CommandLine.arguments[1]
func save(_ img: NSImage, _ name: String) {
    let tiff = img.tiffRepresentation!; let rep = NSBitmapImageRep(data: tiff)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
}
// 1. text page
let page = NSImage(size: NSSize(width: 1200, height: 1600), flipped: true) { r in
    NSColor.white.setFill(); r.fill()
    let h: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 56)]
    let b: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28)]
    "Quarterly Report 2026".draw(at: NSPoint(x: 100, y: 100), withAttributes: h)
    let lines = ["Revenue grew 14% year over year, driven by strong demand", "in the Vision and Audio product lines. Operating margin", "improved to 31.5% on lower infrastructure costs.", "", "- Vision CLI shipped on August 27, 2026", "- Audio CLI entered private beta", "", "Contact: reports@example.com  +1 408 555 0100"]
    for (i, l) in lines.enumerated() { l.draw(at: NSPoint(x: 100, y: 220 + i * 50), withAttributes: b) }
    // QR
    let f = CIFilter(name: "CIQRCodeGenerator")!; f.setValue("https://koszek.com/vision".data(using: .utf8), forKey: "inputMessage")
    let qr = f.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let cg = CIContext().createCGImage(qr, from: qr.extent)!
    NSGraphicsContext.current!.cgContext.saveGState()
    NSGraphicsContext.current!.cgContext.translateBy(x: 800, y: 1400); NSGraphicsContext.current!.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current!.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: qr.extent.width, height: qr.extent.height))
    NSGraphicsContext.current!.cgContext.restoreGState()
    return true
}
save(page, "page.png")
// 2. photo of the page: gray background, page drawn with perspective (rotated/skewed)
let photo = NSImage(size: NSSize(width: 1600, height: 1400), flipped: true) { r in
    NSColor(calibratedWhite: 0.35, alpha: 1).setFill(); r.fill()
    let t = NSAffineTransform(); t.translateX(by: 350, yBy: 120); t.rotate(byDegrees: 6); t.scaleX(by: 0.7, yBy: 0.7); t.concat()
    page.draw(in: NSRect(x: 0, y: 0, width: 1200, height: 1600))
    return true
}
save(photo, "photo.png")
// 3. scene: sky/ground horizon tilted, a "sun" and colored blob for saliency
let scene = NSImage(size: NSSize(width: 1280, height: 720), flipped: true) { r in
    NSColor(calibratedRed: 0.4, green: 0.6, blue: 0.95, alpha: 1).setFill(); r.fill()
    let t = NSAffineTransform(); t.translateX(by: 640, yBy: 400); t.rotate(byDegrees: -5); t.concat()
    NSColor(calibratedRed: 0.3, green: 0.55, blue: 0.2, alpha: 1).setFill(); NSRect(x: -1200, y: 0, width: 2400, height: 800).fill()
    NSColor.orange.setFill(); NSBezierPath(ovalIn: NSRect(x: -400, y: -300, width: 120, height: 120)).fill()
    NSColor.red.setFill(); NSBezierPath(ovalIn: NSRect(x: 100, y: 50, width: 160, height: 220)).fill()
    return true
}
save(scene, "scene.png")
print("ok")
