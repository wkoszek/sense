import ArgumentParser
import AVFoundation
import CoreImage
import Foundation
import ImageIO

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show image/video metadata (dimensions, color, DPI, EXIF, codec…).")

    @Argument(help: "Image, PDF or video file(s).") var inputs: [String]
    @Flag(help: "Dump all metadata (EXIF/IPTC/XMP/GPS/TIFF).") var exif = false
    @Flag(help: "JSON output.") var json = false
    @Option(name: .long, help: "Extract embedded depth/disparity map to this image file.") var depth: String?

    static let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mts", "m2ts"]

    func run() async throws {
        var all: [[String: Any]] = []
        for p in inputs {
            let ext = URL(fileURLWithPath: p).pathExtension.lowercased()
            let d: [String: Any]
            if Info.videoExts.contains(ext) { d = try await videoInfo(p) }
            else if ext == "pdf" { d = try pdfInfo(p) }
            else { d = try imageInfo(p) }
            all.append(d)
            if !json { printInfo(d, path: p) }
        }
        if json { emitJSON(all.count == 1 ? all[0] : all) }
    }

    func imageInfo(_ p: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: p)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw VisionError("\(p): unrecognized image") }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0
        var d: [String: Any] = [
            "path": p, "type": (CGImageSourceGetType(src) as String?) ?? "?",
            "width": props[kCGImagePropertyPixelWidth as String] ?? 0,
            "height": props[kCGImagePropertyPixelHeight as String] ?? 0,
            "frames": CGImageSourceGetCount(src), "fileSize": size,
        ]
        if let v = props[kCGImagePropertyColorModel as String] { d["colorModel"] = v }
        if let v = props[kCGImagePropertyDepth as String] { d["bitDepth"] = v }
        if let v = props[kCGImagePropertyDPIWidth as String] { d["dpi"] = v }
        if let v = props[kCGImagePropertyOrientation as String] { d["orientation"] = v }
        if let v = props[kCGImagePropertyProfileName as String] { d["colorProfile"] = v }
        if let v = props[kCGImagePropertyHasAlpha as String] { d["hasAlpha"] = v }
        if let ex = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let v = ex[kCGImagePropertyExifDateTimeOriginal as String] { d["taken"] = v }
            if let v = ex[kCGImagePropertyExifLensModel as String] { d["lens"] = v }
            if let v = ex[kCGImagePropertyExifFNumber as String] { d["fNumber"] = v }
            if let v = ex[kCGImagePropertyExifExposureTime as String] { d["exposure"] = v }
            if let v = ex[kCGImagePropertyExifISOSpeedRatings as String] { d["iso"] = v }
        }
        if let t = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            if let v = t[kCGImagePropertyTIFFModel as String] { d["camera"] = v }
        }
        if let g = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           let lat = g[kCGImagePropertyGPSLatitude as String] as? Double, let lon = g[kCGImagePropertyGPSLongitude as String] as? Double {
            let ns = (g[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" ? -1.0 : 1.0
            let ew = (g[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" ? -1.0 : 1.0
            d["gps"] = ["lat": lat * ns, "lon": lon * ew]
        }
        let aux: [(String, CFString)] = [("depth", kCGImageAuxiliaryDataTypeDepth), ("disparity", kCGImageAuxiliaryDataTypeDisparity),
                                         ("portraitMatte", kCGImageAuxiliaryDataTypePortraitEffectsMatte), ("hdrGainMap", kCGImageAuxiliaryDataTypeHDRGainMap)]
        var auxTypes: [String] = []
        for (n, t) in aux where CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, t) != nil { auxTypes.append(n) }
        if !auxTypes.isEmpty { d["auxiliary"] = auxTypes }
        if exif { d["metadata"] = props }
        if let depth {
            try extractDepth(src, to: depth)
            d["depthWritten"] = depth
        }
        return d
    }

    func extractDepth(_ src: CGImageSource, to path: String) throws {
        for t in [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte] {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, t) as? [AnyHashable: Any] else { continue }
            let ci: CIImage
            if t == kCGImageAuxiliaryDataTypePortraitEffectsMatte {
                let m = try AVPortraitEffectsMatte(fromDictionaryRepresentation: info)
                ci = CIImage(cvPixelBuffer: m.mattingImage)
            } else {
                let dd = try AVDepthData(fromDictionaryRepresentation: info).converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
                let raw = CIImage(cvPixelBuffer: dd.depthDataMap)
                // normalize to 0..1 using min/max
                let f = CIFilter(name: "CIAreaMinMax")!
                f.setValue(raw, forKey: kCIInputImageKey)
                f.setValue(CIVector(cgRect: raw.extent), forKey: "inputExtent")
                var px = [Float](repeating: 0, count: 8)
                ciContext.render(f.outputImage!, toBitmap: &px, rowBytes: 32, bounds: CGRect(x: 0, y: 0, width: 2, height: 1), format: .RGBAf, colorSpace: nil)
                let lo = px[0], hi = px[4]
                let scale = hi > lo ? 1 / (hi - lo) : 1
                ci = raw.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: CGFloat(-lo * scale), y: CGFloat(-lo * scale), z: CGFloat(-lo * scale), w: 0),
                ])
            }
            try writeImage(try ci.render(), to: path)
            status("wrote \(path)")
            return
        }
        throw VisionError("no depth/disparity/matte data in image")
    }

    func pdfInfo(_ p: String) throws -> [String: Any] {
        guard let doc = CGPDFDocument(URL(fileURLWithPath: p) as CFURL) else { throw VisionError("\(p): bad PDF") }
        var d: [String: Any] = ["path": p, "type": "com.adobe.pdf", "pages": doc.numberOfPages]
        if let pg = doc.page(at: 1) {
            let b = pg.getBoxRect(.mediaBox)
            d["pageSize"] = ["w": r4(b.width), "h": r4(b.height), "unit": "pt"]
        }
        d["encrypted"] = doc.isEncrypted
        return d
    }

    func videoInfo(_ p: String) async throws -> [String: Any] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: p))
        let (duration, tracks) = try await asset.load(.duration, .tracks)
        var d: [String: Any] = ["path": p, "type": "video", "duration": r4(duration.seconds)]
        for t in tracks {
            let (size, fps, descs, bitrate) = try await t.load(.naturalSize, .nominalFrameRate, .formatDescriptions, .estimatedDataRate)
            var td: [String: Any] = ["mediaType": t.mediaType.rawValue, "bitrate": Int(bitrate)]
            if let fd = descs.first {
                let sub = CMFormatDescriptionGetMediaSubType(fd)
                td["codec"] = String(bytes: [UInt8(sub >> 24 & 0xff), UInt8(sub >> 16 & 0xff), UInt8(sub >> 8 & 0xff), UInt8(sub & 0xff)], encoding: .ascii)
            }
            if t.mediaType == .video {
                td["width"] = Int(size.width); td["height"] = Int(size.height); td["fps"] = r4(fps)
                td["frames"] = Int((Double(fps) * duration.seconds).rounded())
                d["video"] = td
            } else if t.mediaType == .audio {
                d["audio"] = td
            }
        }
        return d
    }

    func printInfo(_ d: [String: Any], path: String) {
        if inputs.count > 1 { print("== \(path)") }
        let order = ["type", "width", "height", "frames", "pages", "pageSize", "duration", "colorModel", "bitDepth", "hasAlpha", "colorProfile", "dpi",
                     "orientation", "fileSize", "camera", "lens", "taken", "fNumber", "exposure", "iso", "gps", "auxiliary", "video", "audio"]
        for k in order {
            guard let v = d[k] else { continue }
            print("\(k): \(fmt(v))")
        }
        if exif, let m = d["metadata"] { print("metadata: \(fmt(m))") }
    }

    func fmt(_ v: Any) -> String {
        guard v is [String: Any] || v is [Any] else { return "\(v)" }
        if let data = try? JSONSerialization.data(withJSONObject: sanitizeJSON(v), options: [.sortedKeys, .prettyPrinted]),
           let s = String(data: data, encoding: .utf8) { return s }
        return "\(v)"
    }
}
