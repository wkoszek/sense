import ArgumentParser
import CoreImage
import Foundation
import Vision

func rgbaBytes(_ img: CGImage) -> [UInt8] {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return buf
}

struct Diff: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Compare two images: changed-pixel ratio, PSNR, perceptual distance; optional heatmap. Exit 1 if over --threshold.")

    @Argument var a: String
    @Argument var b: String
    @Option(name: .shortAndLong, help: "Write a visual diff (heatmap) here.") var output: String?
    @Option(name: .long, help: "Fail (exit 1) if changed-pixel fraction exceeds this (0-1).") var threshold: Double?
    @Option(name: .long, help: "Per-channel tolerance (0-255) before a pixel counts as changed.") var tolerance: Int = 16
    @Flag(help: "JSON output.") var json = false

    func run() throws {
        let ia = try loadImages(a).first1.image
        var ib = try loadImages(b).first1.image
        if ia.width != ib.width || ia.height != ib.height {
            warn("sizes differ (\(ia.width)x\(ia.height) vs \(ib.width)x\(ib.height)); resizing B to A")
            ib = try ib.ci.transformed(by: CGAffineTransform(scaleX: CGFloat(ia.width) / CGFloat(ib.width), y: CGFloat(ia.height) / CGFloat(ib.height))).render()
        }
        let pa = rgbaBytes(ia), pb = rgbaBytes(ib)
        let n = ia.width * ia.height
        var changed = 0
        var mse: Double = 0
        var maxDiff = 0
        var heat = [UInt8](repeating: 0, count: n * 4)
        for i in 0..<n {
            var pixelMax = 0
            for c in 0..<3 {
                let d = abs(Int(pa[i * 4 + c]) - Int(pb[i * 4 + c]))
                pixelMax = max(pixelMax, d)
                mse += Double(d * d)
            }
            maxDiff = max(maxDiff, pixelMax)
            if pixelMax > tolerance { changed += 1 }
            let v = UInt8(min(255, pixelMax * 3))
            heat[i * 4] = v; heat[i * 4 + 1] = UInt8(max(0, Int(pa[i * 4 + 1]) / 4)); heat[i * 4 + 2] = UInt8(max(0, Int(pa[i * 4 + 2]) / 4)); heat[i * 4 + 3] = 255
        }
        mse /= Double(n * 3)
        let psnr = mse == 0 ? Double.infinity : 10 * log10(255 * 255 / mse)
        let fraction = Double(changed) / Double(n)
        let fp = try distance(try featurePrint(ia), try featurePrint(ib))

        if let output {
            let ctx = CGContext(data: nil, width: ia.width, height: ia.height, bitsPerComponent: 8, bytesPerRow: ia.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            heat.withUnsafeBytes { ctx.data!.copyMemory(from: $0.baseAddress!, byteCount: n * 4) }
            try writeImage(ctx.makeImage()!, to: output)
        }
        if json {
            emitJSON(["changedFraction": r4(fraction), "changedPixels": changed, "psnr": psnr.isInfinite ? "inf" : r4(psnr),
                      "maxChannelDiff": maxDiff, "featureDistance": r4(fp), "width": ia.width, "height": ia.height])
        } else {
            print(String(format: "changed: %.2f%% (%d px)\tpsnr: %@\tmax: %d\tperceptual: %.2f",
                         fraction * 100, changed, psnr.isInfinite ? "inf" : String(format: "%.1f dB", psnr), maxDiff, fp))
        }
        if let threshold, fraction > threshold { throw ExitCode(Exit.error) }
    }
}

struct Align: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "align",
        abstract: "Register MOVING onto REFERENCE (translational) and write the aligned image.")

    @Argument var reference: String
    @Argument var moving: String
    @Option(name: .shortAndLong) var output: String?
    @Flag(help: "JSON output of the transform.") var json = false

    func run() throws {
        let ref = try loadImages(reference).first1.image
        let mov = try loadImages(moving).first1.image
        let req = VNTranslationalImageRegistrationRequest(targetedCGImage: mov, options: [:])
        try perform([req], on: ref)
        guard let obs = req.results?.first else { throw VisionError("registration failed") }
        let t = obs.alignmentTransform
        if json { emitJSON(["tx": r4(t.tx), "ty": r4(-t.ty)]) } else { status(String(format: "shift dx=%.1f dy=%.1f", t.tx, -t.ty)) }
        if let output {
            let aligned = mov.ci.transformed(by: t).cropped(to: ref.ci.extent)
            let bg = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: ref.ci.extent)
            try writeImage(try aligned.composited(over: bg).render(), to: output)
        }
    }
}
