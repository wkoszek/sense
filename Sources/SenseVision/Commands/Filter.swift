import ArgumentParser
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

func applyCIFilter(_ name: String, to img: CIImage, params: [String: String]) throws -> CIImage {
    guard let f = CIFilter(name: name) else { throw ValidationError("unknown CIFilter '\(name)' (see --list)") }
    f.setDefaults()
    if f.inputKeys.contains(kCIInputImageKey) { f.setValue(img, forKey: kCIInputImageKey) }
    let attrs = f.attributes
    for (k, v) in params {
        let key = k.hasPrefix("input") ? k : "input" + k.prefix(1).uppercased() + k.dropFirst()
        let cls = (attrs[key] as? [String: Any])?[kCIAttributeClass] as? String
        switch cls {
        case "NSNumber": f.setValue(Double(v) ?? 0, forKey: key)
        case "CIVector":
            let nums = v.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
            f.setValue(CIVector(values: nums, count: nums.count), forKey: key)
        case "CIColor": f.setValue(try parseColor(v), forKey: key)
        case "CIImage": f.setValue(try loadImages(v).first1.image.ci, forKey: key)
        case "NSString": f.setValue(v, forKey: key)
        default: f.setValue(Double(v) ?? v, forKey: key)
        }
    }
    guard let out = f.outputImage else { throw VisionError("\(name) produced no output") }
    return out.cropped(to: out.extent.isInfinite ? img.extent : out.extent)
}

struct Filter: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filter",
        abstract: "CoreImage one-liners: blur, sharpen, grayscale, exposure, auto-enhance, redaction, or any CIFilter by name.")

    @Argument var input: String?
    @Argument var output: String?
    @Flag(help: "Convert to grayscale.") var grayscale = false
    @Flag(help: "Invert colors.") var invert = false
    @Option(name: .long, help: "Gaussian blur radius.") var blur: Double?
    @Option(name: .long, help: "Sharpen amount (0-2).") var sharpen: Double?
    @Option(name: .long, help: "Exposure in EV.") var exposure: Double?
    @Option(name: .long, help: "Contrast multiplier (1 = unchanged).") var contrast: Double?
    @Option(name: .long, help: "Saturation multiplier (1 = unchanged, 0 = gray).") var saturation: Double?
    @Option(name: .long, help: "Brightness offset (-1..1).") var brightness: Double?
    @Flag(help: "Auto-enhance (CoreImage autoAdjustmentFilters).") var enhance = false
    @Option(name: .long, help: "Apply a CIFilter by name (repeatable).") var ci: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "Parameters for --ci as key=value (e.g. radius=20 angle=0.5 color=#ff0000).") var param: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "Redact detected regions: faces text barcodes bodies (repeatable).") var redact: [Detector] = []
    @Flag(help: "Pixelate instead of black-fill when redacting.") var redactBlur = false
    @Option(name: .shortAndLong) var quality: Int?
    @Flag(help: "List all CIFilter names with their parameters and exit.") var list = false

    func run() throws {
        if list {
            for name in CIFilter.filterNames(inCategory: nil).sorted() {
                guard let f = CIFilter(name: name) else { continue }
                let keys = f.inputKeys.filter { $0 != kCIInputImageKey }.map { k -> String in
                    let a = f.attributes[k] as? [String: Any]
                    let cls = (a?[kCIAttributeClass] as? String) ?? "?"
                    let dflt = a?[kCIAttributeDefault].map { " = \($0)" } ?? ""
                    return "\(k):\(cls)\(dflt)"
                }
                print("\(name)  \(keys.joined(separator: "  "))")
            }
            return
        }
        guard let input, let output else { throw ValidationError("need INPUT and OUTPUT") }
        let li = try loadImages(input).first1
        var img = li.image.ci
        let extent = img.extent

        if enhance {
            for f in img.autoAdjustmentFilters(options: [.redEye: false]) {
                f.setValue(img, forKey: kCIInputImageKey)
                if let o = f.outputImage { img = o }
            }
        }
        if grayscale || saturation != nil || contrast != nil || brightness != nil {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.saturation = Float(grayscale ? 0 : (saturation ?? 1))
            f.contrast = Float(contrast ?? 1)
            f.brightness = Float(brightness ?? 0)
            img = f.outputImage!
        }
        if let exposure { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure]) }
        if let blur { img = img.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: extent) }
        if let sharpen { img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: sharpen]) }
        if invert { img = img.applyingFilter("CIColorInvert") }

        var params: [String: String] = [:]
        for p in param {
            guard let eq = p.firstIndex(of: "=") else { throw ValidationError("--param key=value") }
            params[String(p[..<eq])] = String(p[p.index(after: eq)...])
        }
        for name in ci { img = try applyCIFilter(name, to: img, params: params) }

        if !redact.isEmpty {
            let dets = try runDetectors(li, DetectSettings(whats: redact))
            var count = 0
            for d in dets {
                guard let b = d.box else { continue }
                let r = b.insetBy(dx: -b.width * 0.1, dy: -b.height * 0.1)
                // CI coordinates: bottom-left origin
                let ciRect = CGRect(x: r.minX, y: extent.height - r.maxY, width: r.width, height: r.height).intersection(extent)
                let patch: CIImage
                if redactBlur {
                    patch = img.cropped(to: ciRect).clampedToExtent()
                        .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, ciRect.width / 8), kCIInputCenterKey: CIVector(x: ciRect.midX, y: ciRect.midY)])
                        .cropped(to: ciRect)
                } else {
                    patch = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: ciRect)
                }
                img = patch.composited(over: img)
                count += 1
            }
            status("redacted \(count) region(s)")
        }
        try writeImage(try img.cropped(to: extent).render(), to: output, quality: quality.map { Double($0) / 100 })
    }
}
