import ArgumentParser
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Vision

func scaledMask(_ mask: CIImage, to size: CGSize) -> CIImage {
    mask.transformed(by: CGAffineTransform(scaleX: size.width / mask.extent.width, y: size.height / mask.extent.height))
}

func compose(_ image: CIImage, mask: CIImage, background: CIImage) -> CIImage {
    let f = CIFilter.blendWithMask()
    f.inputImage = image
    f.backgroundImage = background
    f.maskImage = scaledMask(mask, to: image.extent.size)
    return f.outputImage!.cropped(to: image.extent)
}

struct Segment: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "segment",
        abstract: "Cut out the foreground subject(s) or people; write cutouts or masks.")

    @OptionGroup var input: SingleInputOptions
    @OptionGroup var output: OutputOptions

    @Flag(help: "Use the person segmentation model instead of generic foreground instances.") var person = false
    @Flag(help: "Write the mask (8-bit, white = foreground) instead of a cutout.") var mask = false
    @Flag(help: "Write one cutout per foreground instance (-o needs %d or a directory).") var instances = false
    @Option(name: .long, help: "Pick only the instance under pixel point x,y (Live Text 'lift subject').") var at: String?
    @Option(name: .long, help: "Background color (#rrggbb, name); default transparent.") var bg: String?
    @Option(name: .long, help: "Keep the background but blur it by this radius (portrait mode).") var blurBg: Double?
    @Flag(help: "JSON summary (instance count, bounding boxes).") var json = false

    func run() throws {
        let li = try input.load().first1
        let handler = VNImageRequestHandler(cgImage: li.image, options: [:])
        let src = li.image.ci
        var masks: [CIImage] = []
        var summary: [[String: Any]] = []

        if person {
            let req = VNGeneratePersonSegmentationRequest()
            req.qualityLevel = .accurate
            req.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try handler.perform([req])
            guard let pb = req.results?.first?.pixelBuffer else { throw VisionError("no person mask produced") }
            masks = [CIImage(cvPixelBuffer: pb)]
        } else {
            let req = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([req])
            guard let obs = req.results?.first, !obs.allInstances.isEmpty else {
                warn("no foreground instances found")
                throw ExitCode(Exit.nothingFound)
            }
            var sets: [IndexSet] = []
            if let at {
                let p = try parsePoint(at)
                let labels = obs.instanceMask
                CVPixelBufferLockBaseAddress(labels, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
                let mw = CVPixelBufferGetWidth(labels), mh = CVPixelBufferGetHeight(labels)
                let x = Int(p.x / CGFloat(li.width) * CGFloat(mw)), y = Int(p.y / CGFloat(li.height) * CGFloat(mh))
                guard x >= 0, y >= 0, x < mw, y < mh, let base = CVPixelBufferGetBaseAddress(labels) else { throw VisionError("point outside image") }
                let row = CVPixelBufferGetBytesPerRow(labels)
                let label = Int(base.assumingMemoryBound(to: UInt8.self)[y * row + x])
                guard label != 0 else { warn("no instance at \(at)"); throw ExitCode(Exit.nothingFound) }
                sets = [IndexSet(integer: label)]
            } else if instances {
                sets = obs.allInstances.map { IndexSet(integer: $0) }
            } else {
                sets = [obs.allInstances]
            }
            for s in sets {
                let pb = try obs.generateScaledMaskForImage(forInstances: s, from: handler)
                masks.append(CIImage(cvPixelBuffer: pb))
            }
            summary = sets.map { ["instances": Array($0)] }
        }

        var outs: [CGImage] = []
        for m in masks {
            if mask {
                outs.append(try scaledMask(m, to: src.extent.size).cropped(to: src.extent).render())
                continue
            }
            let background: CIImage
            if let blurBg {
                background = src.clampedToExtent().applyingGaussianBlur(sigma: blurBg).cropped(to: src.extent)
            } else if let bg {
                background = CIImage(color: try parseColor(bg)).cropped(to: src.extent)
            } else {
                background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: src.extent)
            }
            outs.append(try compose(src, mask: m, background: background).render())
        }
        if json { emitJSON(["source": li.source, "count": outs.count, "instances": summary]) }
        var o = output.spec
        if o.output == nil && o.format == nil { o.format = "png" }
        try writeBatch(outs, output: o, suffix: "-cut")
    }
}
