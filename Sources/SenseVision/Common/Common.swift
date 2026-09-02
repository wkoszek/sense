import ArgumentParser
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

// MARK: - Diagnostics / exit codes

enum Exit {
    static let ok: Int32 = 0
    static let error: Int32 = 1
    static let usage: Int32 = 2
    static let permission: Int32 = 3
    static let nothingFound: Int32 = 4
}

func warn(_ s: String) {
    FileHandle.standardError.write(("sense vision: " + s + "\n").data(using: .utf8)!)
}

func status(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func fail(_ msg: String, code: Int32 = Exit.error) -> Never {
    warn(msg)
    exit(code)
}

struct VisionError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

let ciContext = CIContext(options: [.cacheIntermediates: false])

// MARK: - Number formatting / JSON

func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
func r4(_ v: CGFloat) -> Double { r4(Double(v)) }
func r4(_ v: Float) -> Double { r4(Double(v)) }

func emitJSON(_ obj: Any, pretty: Bool = true) {
    var opts: JSONSerialization.WritingOptions = [.sortedKeys]
    if pretty { opts.insert(.prettyPrinted) }
    guard let d = try? JSONSerialization.data(withJSONObject: sanitizeJSON(obj), options: opts) else {
        fail("could not serialize JSON")
    }
    FileHandle.standardOutput.write(d)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

/// Make arbitrary CF/Foundation property-list-ish values JSON-safe.
func sanitizeJSON(_ v: Any) -> Any {
    switch v {
    case let d as [String: Any]:
        var out: [String: Any] = [:]
        for (k, x) in d { out[k] = sanitizeJSON(x) }
        return out
    case let d as [AnyHashable: Any]:
        var out: [String: Any] = [:]
        for (k, x) in d { out[String(describing: k)] = sanitizeJSON(x) }
        return out
    case let a as [Any]:
        return a.map(sanitizeJSON)
    case let data as Data:
        return data.count > 256 ? "<\(data.count) bytes>" : data.base64EncodedString()
    case let date as Date:
        return ISO8601DateFormatter().string(from: date)
    case let n as NSNumber:
        let d = n.doubleValue
        if d.isNaN || d.isInfinite { return NSNull() }
        return n
    case is String, is Bool, is Int, is Double, is NSNull:
        return v
    default:
        return String(describing: v)
    }
}

// MARK: - Geometry (Vision normalized, bottom-left → pixels, top-left)

extension CGRect {
    func pixels(_ w: Int, _ h: Int) -> CGRect {
        let W = CGFloat(w), H = CGFloat(h)
        return CGRect(x: minX * W, y: (1 - maxY) * H, width: width * W, height: height * H)
    }
    var dict: [String: Any] {
        ["x": Int(minX.rounded()), "y": Int(minY.rounded()),
         "w": Int(width.rounded()), "h": Int(height.rounded())]
    }
}

extension CGPoint {
    func pixels(_ w: Int, _ h: Int) -> CGPoint {
        CGPoint(x: x * CGFloat(w), y: (1 - y) * CGFloat(h))
    }
    var dict: [String: Any] { ["x": r4(x), "y": r4(y)] }
}

func quadDict(_ o: VNRectangleObservation, _ w: Int, _ h: Int) -> [[String: Any]] {
    [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { $0.pixels(w, h).dict }
}

// MARK: - Page spec

struct PageSpec {
    let pages: [Int]?  // 1-based, nil = all

    init(_ s: String?) throws {
        guard let s, !s.isEmpty else { pages = nil; return }
        var out: [Int] = []
        for part in s.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if let dash = p.firstIndex(of: "-"), dash != p.startIndex {
                guard let a = Int(p[..<dash]), let b = Int(p[p.index(after: dash)...]), a <= b else {
                    throw ValidationError("bad page range '\(p)'")
                }
                out.append(contentsOf: a...b)
            } else if let n = Int(p) {
                out.append(n)
            } else {
                throw ValidationError("bad page spec '\(p)'")
            }
        }
        pages = out
    }

    func indices(count: Int) -> [Int] {
        guard let pages else { return Array(0..<count) }
        return pages.filter { $0 >= 1 && $0 <= count }.map { $0 - 1 }
    }
}

// MARK: - Loaded image

struct LoadedImage {
    var image: CGImage
    var source: String
    var page: Int?          // 1-based when from PDF / multi-frame
    var dpi: Double?
    var properties: [String: Any]

    var width: Int { image.width }
    var height: Int { image.height }
    var label: String { page.map { "\(source)#\($0)" } ?? source }
}

func readStdinData() -> Data {
    FileHandle.standardInput.readDataToEndOfFile()
}

func renderPDFPage(_ page: PDFPage, dpi: Double) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let scale = dpi / 72.0
    let rot = page.rotation
    let swap = rot == 90 || rot == 270
    let w = Int((swap ? bounds.height : bounds.width) * scale)
    let h = Int((swap ? bounds.width : bounds.height) * scale)
    guard w > 0, h > 0,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)
    ctx.restoreGState()
    return ctx.makeImage()
}

func loadFromImageSource(_ src: CGImageSource, name: String, pages: PageSpec) throws -> [LoadedImage] {
    let count = CGImageSourceGetCount(src)
    guard count > 0 else { throw VisionError("\(name): no images found") }
    var out: [LoadedImage] = []
    for i in pages.indices(count: count) {
        let props = (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]) ?? [:]
        guard var cg = CGImageSourceCreateImageAtIndex(src, i, nil) else {
            throw VisionError("\(name): cannot decode image \(i + 1)")
        }
        let orient = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        if orient != 1 {
            let ci = CIImage(cgImage: cg).oriented(forExifOrientation: orient)
            if let fixed = ciContext.createCGImage(ci, from: ci.extent) { cg = fixed }
        }
        let dpi = (props[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue
        out.append(LoadedImage(image: cg, source: name, page: count > 1 ? i + 1 : nil, dpi: dpi, properties: props))
    }
    return out
}

func loadFromPDF(_ doc: PDFDocument, name: String, pages: PageSpec, dpi: Double) throws -> [LoadedImage] {
    var out: [LoadedImage] = []
    for i in pages.indices(count: doc.pageCount) {
        guard let page = doc.page(at: i), let cg = renderPDFPage(page, dpi: dpi) else {
            throw VisionError("\(name): cannot render page \(i + 1)")
        }
        out.append(LoadedImage(image: cg, source: name, page: i + 1, dpi: dpi, properties: [:]))
    }
    return out
}

func isPDFData(_ d: Data) -> Bool {
    d.count > 4 && d[d.startIndex] == 0x25 && d[d.startIndex + 1] == 0x50 && d[d.startIndex + 2] == 0x44
}

func loadImages(_ path: String, pages: PageSpec = try! PageSpec(nil), pdfDPI: Double = 200) throws -> [LoadedImage] {
    if path == "-" {
        let data = readStdinData()
        guard !data.isEmpty else { throw VisionError("stdin: empty input") }
        if isPDFData(data) {
            guard let doc = PDFDocument(data: data) else { throw VisionError("stdin: bad PDF") }
            return try loadFromPDF(doc, name: "stdin", pages: pages, dpi: pdfDPI)
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw VisionError("stdin: unrecognized image data")
        }
        return try loadFromImageSource(src, name: "stdin", pages: pages)
    }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else { throw VisionError("\(path): no such file") }
    if url.pathExtension.lowercased() == "pdf" {
        guard let doc = PDFDocument(url: url) else { throw VisionError("\(path): bad PDF") }
        return try loadFromPDF(doc, name: path, pages: pages, dpi: pdfDPI)
    }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw VisionError("\(path): unrecognized image format")
    }
    return try loadFromImageSource(src, name: path, pages: pages)
}

// MARK: - Shared argument groups

struct InputOptions: ParsableArguments {
    @Argument(help: "Image or PDF file(s); '-' reads stdin.")
    var inputs: [String]

    @Option(name: .long, help: "PDF pages to use, e.g. '1-3,7' (default: all).")
    var pages: String?

    @Option(name: .long, help: "DPI used when rasterizing PDF pages.")
    var dpi: Double = 200

    func load() throws -> [LoadedImage] {
        let spec = try PageSpec(pages)
        var out: [LoadedImage] = []
        for p in inputs { out.append(contentsOf: try loadImages(p, pages: spec, pdfDPI: dpi)) }
        return out
    }
}

struct SingleInputOptions: ParsableArguments {
    @Argument(help: "Image or PDF file; '-' reads stdin.")
    var input: String

    @Option(name: .long, help: "PDF pages to use, e.g. '1-3,7' (default: all).")
    var pages: String?

    @Option(name: .long, help: "DPI used when rasterizing PDF pages.")
    var dpi: Double = 200

    func load() throws -> [LoadedImage] {
        try loadImages(input, pages: try PageSpec(pages), pdfDPI: dpi)
    }
}

struct OutputOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Output file (format from extension; %d/%03d for batches). Default: stdout PNG.")
    var output: String?

    @Option(name: .long, help: "Override output format: png jpg heic tiff gif bmp webp pdf.")
    var format: String?

    @Option(name: .shortAndLong, help: "Lossy quality 0-100 (jpg/heic/webp).")
    var quality: Int?

    var qualityFraction: Double? { quality.map { Double($0) / 100 } }
}

// MARK: - Output encoding

func outputPath(_ template: String, index: Int) -> String {
    guard template.contains("%") else { return template }
    return String(format: template, index)
}

func utType(forFormat f: String) -> UTType? {
    switch f.lowercased() {
    case "png": return .png
    case "jpg", "jpeg": return .jpeg
    case "heic", "heif": return .heic
    case "tif", "tiff": return .tiff
    case "gif": return .gif
    case "bmp": return .bmp
    case "webp": return .webP
    case "pdf": return .pdf
    default: return nil
    }
}

func encode(_ image: CGImage, type: UTType, quality: Double?, dpi: Double? = nil) throws -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
        throw VisionError("cannot encode as \(type.identifier)" + (type == .webP ? " (WebP encoding is not supported by ImageIO on this macOS; use cwebp)" : ""))
    }
    var props: [String: Any] = [:]
    if let quality { props[kCGImageDestinationLossyCompressionQuality as String] = quality }
    if let dpi {
        props[kCGImagePropertyDPIWidth as String] = dpi
        props[kCGImagePropertyDPIHeight as String] = dpi
    }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw VisionError("encoding as \(type.identifier) failed" + (type == .webP ? " (WebP encoding is not supported by ImageIO on this macOS; use cwebp)" : ""))
    }
    return data as Data
}

func writePDF(images: [CGImage], to path: String, dpi: Double = 72, textLayer: ((CGContext, Int, CGSize) -> Void)? = nil) throws {
    let url = URL(fileURLWithPath: path)
    guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { throw VisionError("cannot create PDF \(path)") }
    for (i, img) in images.enumerated() {
        let scale = 72.0 / dpi
        var box = CGRect(x: 0, y: 0, width: Double(img.width) * scale, height: Double(img.height) * scale)
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary)
        ctx.draw(img, in: box)
        textLayer?(ctx, i, box.size)
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

/// Write one image. `path == nil` or "-" → stdout (refused on a TTY).
func writeImage(_ image: CGImage, to path: String?, format: String? = nil, quality: Double? = nil, dpi: Double? = nil) throws {
    let toStdout = path == nil || path == "-"
    let ext = format ?? (toStdout ? "png" : URL(fileURLWithPath: path!).pathExtension)
    guard let type = utType(forFormat: ext) else { throw VisionError("unknown output format '\(ext)'") }
    if type == .pdf {
        if toStdout {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sense-\(UUID().uuidString).pdf")
            try writePDF(images: [image], to: tmp.path, dpi: dpi ?? 72)
            FileHandle.standardOutput.write(try Data(contentsOf: tmp))
            try? FileManager.default.removeItem(at: tmp)
        } else {
            try writePDF(images: [image], to: path!, dpi: dpi ?? 72)
        }
        return
    }
    let data = try encode(image, type: type, quality: quality, dpi: dpi)
    if toStdout {
        if isatty(1) != 0 { fail("refusing to write binary image to a terminal; use -o FILE or pipe", code: Exit.usage) }
        FileHandle.standardOutput.write(data)
    } else {
        try data.write(to: URL(fileURLWithPath: path!))
    }
}

/// Write a batch: `-o` may be a template (%d), a directory, or a single file (only for one image).
func writeBatch(_ images: [CGImage], output: OutSpec, sources: [LoadedImage]? = nil, suffix: String = "", dpi: Double? = nil) throws {
    guard let out = output.output, out != "-" else {
        guard images.count == 1 else { throw VisionError("multiple outputs need -o with %d or a directory") }
        try writeImage(images[0], to: nil, format: output.format, quality: output.quality, dpi: dpi)
        return
    }
    var isDir: ObjCBool = false
    let dirExists = FileManager.default.fileExists(atPath: out, isDirectory: &isDir) && isDir.boolValue
    if images.count == 1 && !dirExists {
        try writeImage(images[0], to: outputPath(out, index: 1), format: output.format, quality: output.quality, dpi: dpi)
        return
    }
    if utType(forFormat: output.format ?? URL(fileURLWithPath: out).pathExtension) == .pdf && !out.contains("%") {
        try writePDF(images: images, to: out, dpi: dpi ?? 72)
        return
    }
    for (i, img) in images.enumerated() {
        let path: String
        if dirExists {
            let base = sources.map { URL(fileURLWithPath: $0[i].source).deletingPathExtension().lastPathComponent } ?? "out"
            let pg = sources?[i].page.map { "-p\($0)" } ?? ""
            let ext = output.format ?? "png"
            path = (out as NSString).appendingPathComponent("\(base)\(pg)\(suffix).\(ext)")
        } else if out.contains("%") {
            path = outputPath(out, index: i + 1)
        } else {
            throw VisionError("\(images.count) outputs but -o '\(out)' has no %d and is not a directory")
        }
        try writeImage(img, to: path, format: output.format, quality: output.quality, dpi: dpi)
        status("wrote \(path)")
    }
}

// MARK: - CoreImage helpers

extension CGImage {
    var ci: CIImage { CIImage(cgImage: self) }
    var size: CGSize { CGSize(width: width, height: height) }

    func cropped(toPixels r: CGRect) -> CGImage? {
        let clipped = r.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard !clipped.isEmpty else { return nil }
        return cropping(to: clipped)
    }
}

extension CIImage {
    func render() throws -> CGImage {
        guard let cg = ciContext.createCGImage(self, from: extent.integral) else { throw VisionError("render failed") }
        return cg
    }
}

func parseColor(_ s: String) throws -> CIColor {
    var hex = s.trimmingCharacters(in: .whitespaces)
    let named: [String: String] = ["white": "#ffffff", "black": "#000000", "red": "#ff0000", "green": "#00ff00",
                                   "blue": "#0000ff", "transparent": "#00000000"]
    if let n = named[hex.lowercased()] { hex = n }
    guard hex.hasPrefix("#"), hex.count == 7 || hex.count == 9, let v = UInt64(hex.dropFirst(), radix: 16) else {
        throw ValidationError("bad color '\(s)' (use #rrggbb, #rrggbbaa or a name)")
    }
    if hex.count == 7 {
        return CIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255)
    }
    return CIColor(red: CGFloat((v >> 24) & 0xff) / 255, green: CGFloat((v >> 16) & 0xff) / 255,
                   blue: CGFloat((v >> 8) & 0xff) / 255, alpha: CGFloat(v & 0xff) / 255)
}

func parseRect(_ s: String) throws -> CGRect {
    let p = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard p.count == 4 else { throw ValidationError("rect must be x,y,w,h") }
    return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
}

func parsePoint(_ s: String) throws -> CGPoint {
    let p = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard p.count == 2 else { throw ValidationError("point must be x,y") }
    return CGPoint(x: p[0], y: p[1])
}

/// Pixel top-left rect → Vision normalized bottom-left rect.
func normalizedROI(_ r: CGRect, _ w: Int, _ h: Int) -> CGRect {
    let W = CGFloat(w), H = CGFloat(h)
    return CGRect(x: r.minX / W, y: 1 - (r.maxY / H), width: r.width / W, height: r.height / H)
}

func parseTime(_ s: String) throws -> Double {
    if let d = Double(s) { return d }
    let parts = s.split(separator: ":").map { Double($0) }
    guard parts.allSatisfy({ $0 != nil }), !parts.isEmpty else { throw ValidationError("bad time '\(s)' (use SS, MM:SS or HH:MM:SS)") }
    return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
}

func fmtTime(_ t: Double, srt: Bool = false) -> String {
    let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60, ms = Int((t - floor(t)) * 1000)
    if srt { return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms) }
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

// MARK: - Vision helpers

func perform(_ requests: [VNRequest], on image: CGImage) throws {
    try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)
}

func perspectiveCorrect(_ image: CGImage, quad o: VNRectangleObservation) throws -> CGImage {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let f = CIFilter(name: "CIPerspectiveCorrection")!
    f.setValue(image.ci, forKey: kCIInputImageKey)
    f.setValue(CIVector(cgPoint: CGPoint(x: o.topLeft.x * w, y: o.topLeft.y * h)), forKey: "inputTopLeft")
    f.setValue(CIVector(cgPoint: CGPoint(x: o.topRight.x * w, y: o.topRight.y * h)), forKey: "inputTopRight")
    f.setValue(CIVector(cgPoint: CGPoint(x: o.bottomLeft.x * w, y: o.bottomLeft.y * h)), forKey: "inputBottomLeft")
    f.setValue(CIVector(cgPoint: CGPoint(x: o.bottomRight.x * w, y: o.bottomRight.y * h)), forKey: "inputBottomRight")
    guard let out = f.outputImage else { throw VisionError("perspective correction failed") }
    return try out.render()
}

func confirm(_ prompt: String) -> Bool {
    FileHandle.standardError.write("\(prompt) [y/N] ".data(using: .utf8)!)
    guard let line = readLine() else { return false }
    return line.lowercased().hasPrefix("y")
}

extension Array where Element == LoadedImage {
    var first1: LoadedImage {
        guard let f = first else { fail("no input image") }
        return f
    }
}

/// Plain (non-parsed) output description; what writeBatch actually consumes.
struct OutSpec {
    var output: String?
    var format: String?
    var quality: Double?
    init(_ output: String?, format: String? = nil, quality: Double? = nil) {
        self.output = output; self.format = format; self.quality = quality
    }
}

extension OutputOptions {
    var spec: OutSpec { OutSpec(output, format: format, quality: qualityFraction) }
}
