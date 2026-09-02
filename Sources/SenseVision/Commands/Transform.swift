import ArgumentParser
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

func lanczos(_ img: CIImage, scale: CGFloat) -> CIImage {
    let f = CIFilter.lanczosScaleTransform()
    f.inputImage = img
    f.scale = Float(scale)
    f.aspectRatio = 1
    return f.outputImage!
}

struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert between formats (png jpg heic tiff gif bmp webp pdf; reads RAW/DNG too). Metadata is not carried over.",
        discussion: "sense vision convert in.heic out.jpg -q 85 | sense vision convert in.pdf out_%03d.png --dpi 300 | sense vision convert *.jpg out.pdf")

    @Argument(help: "Input(s) followed by the output (last argument).") var paths: [String]
    @Option(name: .long, help: "PDF pages to use, e.g. '1-3,7'.") var pages: String?
    @Option(name: .long, help: "DPI for PDF rasterizing / output PDF page size.") var dpi: Double = 200
    @Option(name: .shortAndLong, help: "Lossy quality 0-100.") var quality: Int?
    @Option(name: .long, help: "Override output format.") var format: String?
    @Option(name: .long, help: "RAW exposure adjustment in EV (DNG/RAW inputs).") var rawExposure: Float?
    @Option(name: .long, help: "Flatten transparency onto this color (#rrggbb).") var background: String?

    func run() throws {
        guard paths.count >= 2 else { throw ValidationError("need at least one input and an output") }
        let out = paths.last!
        var images: [LoadedImage] = []
        for p in paths.dropLast() {
            if let rawExposure, let f = CIRAWFilter(imageURL: URL(fileURLWithPath: p)) {
                f.exposure = rawExposure
                guard let ci = f.outputImage else { throw VisionError("\(p): RAW decode failed") }
                images.append(LoadedImage(image: try ci.render(), source: p, page: nil, dpi: nil, properties: [:]))
            } else {
                images.append(contentsOf: try loadImages(p, pages: try PageSpec(pages), pdfDPI: dpi))
            }
        }
        var cgs = images.map(\.image)
        if let background {
            let bg = try parseColor(background)
            cgs = try cgs.map { try $0.ci.composited(over: CIImage(color: bg).cropped(to: $0.ci.extent)).render() }
        }
        try writeBatch(cgs, output: OutSpec(out, format: format, quality: quality.map { Double($0) / 100 }), sources: images, dpi: dpi)
    }
}

struct Resize: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resize", abstract: "Resize (Lanczos), keeping aspect unless --fit is exact.")

    @Argument var input: String
    @Argument var output: String
    @Option(name: .long, help: "Target width (keeps aspect).") var width: Int?
    @Option(name: .long, help: "Target height (keeps aspect).") var height: Int?
    @Option(name: .long, help: "Fit inside WxH (keeps aspect).") var fit: String?
    @Option(name: .long, help: "Longest edge at most N pixels.") var max: Int?
    @Option(name: .long, help: "Scale factor, e.g. 0.5.") var scale: Double?
    @Option(name: .shortAndLong) var quality: Int?

    func run() throws {
        let li = try loadImages(input).first1
        let w = Double(li.width), h = Double(li.height)
        var s: Double
        if let scale { s = scale }
        else if let width { s = Double(width) / w }
        else if let height { s = Double(height) / h }
        else if let max { s = Swift.min(1, Double(max) / Swift.max(w, h)) }
        else if let fit {
            let p = fit.lowercased().split(separator: "x").compactMap { Double($0) }
            guard p.count == 2 else { throw ValidationError("--fit WxH") }
            s = Swift.min(p[0] / w, p[1] / h)
        } else { throw ValidationError("give one of --width --height --fit --max --scale") }
        let out = try lanczos(li.image.ci, scale: CGFloat(s)).render()
        try writeImage(out, to: output, quality: quality.map { Double($0) / 100 })
        status("\(li.width)x\(li.height) -> \(out.width)x\(out.height)")
    }
}

struct Crop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "crop", abstract: "Crop to x,y,w,h, or --smart to an aspect ratio using saliency.")

    @Argument var input: String
    @Argument var output: String
    @Argument(help: "x,y,w,h in pixels (top-left origin).") var rect: String?
    @Option(name: .long, help: "Saliency-guided crop to aspect W:H (e.g. 1:1, 16:9).") var smart: String?
    @Option(name: .shortAndLong) var quality: Int?

    func run() throws {
        let li = try loadImages(input).first1
        let r: CGRect
        if let smart {
            let p = smart.split(separator: ":").compactMap { Double($0) }
            guard p.count == 2, p[1] > 0 else { throw ValidationError("--smart W:H") }
            let aspect = p[0] / p[1]
            let W = Double(li.width), H = Double(li.height)
            var cw = W, ch = W / aspect
            if ch > H { ch = H; cw = H * aspect }
            let req = VNGenerateAttentionBasedSaliencyImageRequest()
            try perform([req], on: li.image)
            var center = CGPoint(x: W / 2, y: H / 2)
            if let objs = req.results?.first?.salientObjects, !objs.isEmpty {
                let union = objs.map { $0.boundingBox.pixels(li.width, li.height) }.reduce(CGRect.null) { $0.union($1) }
                center = CGPoint(x: union.midX, y: union.midY)
            }
            let x = Swift.min(Swift.max(0, center.x - cw / 2), W - cw)
            let y = Swift.min(Swift.max(0, center.y - ch / 2), H - ch)
            r = CGRect(x: x, y: y, width: cw, height: ch)
        } else if let rect {
            r = try parseRect(rect)
        } else { throw ValidationError("give x,y,w,h or --smart") }
        guard let out = li.image.cropped(toPixels: r) else { throw VisionError("crop rect outside image") }
        try writeImage(out, to: output, quality: quality.map { Double($0) / 100 })
        status("crop \(Int(r.minX)),\(Int(r.minY)) \(out.width)x\(out.height)")
    }
}

struct Rotate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rotate", abstract: "Rotate by degrees (clockwise), or --auto to level the horizon.")

    @Argument var input: String
    @Argument var output: String
    @Argument(help: "Degrees clockwise (any value; 90/180/270 are lossless-ish).") var degrees: Double?
    @Flag(help: "Detect horizon and level the image.") var auto = false
    @Flag(help: "Flip horizontally.") var flipH = false
    @Flag(help: "Flip vertically.") var flipV = false
    @Option(name: .shortAndLong) var quality: Int?

    func run() throws {
        let li = try loadImages(input).first1
        var ci = li.image.ci
        var deg = degrees ?? 0
        if auto {
            let r = VNDetectHorizonRequest()
            try perform([r], on: li.image)
            guard let hz = r.results?.first else { throw VisionError("no horizon detected") }
            deg = -Double(hz.angle) * 180 / .pi
            status(String(format: "horizon %.2f°, rotating", -deg))
        }
        if deg != 0 {
            ci = ci.transformed(by: CGAffineTransform(rotationAngle: CGFloat(-deg * .pi / 180)))
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        }
        if flipH { ci = ci.oriented(.upMirrored) }
        if flipV { ci = ci.oriented(.downMirrored) }
        try writeImage(try ci.render(), to: output, quality: quality.map { Double($0) / 100 })
    }
}
