import ArgumentParser
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

func largestRectangle(_ image: CGImage, minConfidence: Float = 0.5) throws -> VNRectangleObservation? {
    let r = VNDetectRectanglesRequest()
    r.maximumObservations = 5
    r.minimumConfidence = minConfidence
    r.minimumSize = 0.2
    r.quadratureTolerance = 30
    r.minimumAspectRatio = 0.3
    try perform([r], on: image)
    return r.results?.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
}

func documentCleanup(_ img: CIImage, bw: Bool) -> CIImage {
    if bw {
        let gray = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.1])
        // adaptive-ish: Otsu threshold on the whole page
        let f = CIFilter(name: "CIColorThresholdOtsu")!
        f.setValue(gray, forKey: kCIInputImageKey)
        return f.outputImage ?? gray
    }
    let f = CIFilter.documentEnhancer()
    f.inputImage = img
    f.amount = 1.0
    return f.outputImage ?? img
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Document scanner: find the page, deskew/perspective-correct, clean up; optional searchable PDF.")

    @OptionGroup var input: InputOptions
    @OptionGroup var output: OutputOptions

    @Flag(help: "Black & white (Otsu threshold) 'photocopy' output.") var bw = false
    @Flag(name: .customLong("no-enhance"), help: "Skip the document enhancer (white balance/contrast).") var noEnhance = false
    @Flag(help: "Do not crop; only clean up.") var noCrop = false
    @Flag(help: "Add an OCR text layer (PDF output only).") var ocr = false
    @Option(name: .long, parsing: .upToNextOption, help: "OCR language(s).") var lang: [String] = []
    @Option(name: .long, help: "Minimum rectangle confidence (0-1).") var minConf: Float = 0.5

    func run() throws {
        let images = try input.load()
        var pages: [CGImage] = []
        for li in images {
            var cg = li.image
            if !noCrop {
                if let q = try largestRectangle(cg, minConfidence: minConf) {
                    status("\(li.label): page found \(Int(q.boundingBox.width * 100))% x \(Int(q.boundingBox.height * 100))%, correcting perspective")
                    cg = try perspectiveCorrect(cg, quad: q)
                } else {
                    warn("\(li.label): no page rectangle found, keeping full image")
                }
            }
            var ci = cg.ci
            if bw || !noEnhance { ci = documentCleanup(ci, bw: bw) }
            pages.append(try ci.render())
        }

        let isPDF = utType(forFormat: output.format ?? URL(fileURLWithPath: output.output ?? "").pathExtension) == .pdf
        if isPDF, let out = output.output, !out.contains("%") {
            var ocrLines: [[OCRLine]] = []
            if ocr {
                var s = OCRSettings()
                s.languages = lang
                for (i, p) in pages.enumerated() {
                    let li = LoadedImage(image: p, source: images[i].source, page: images[i].page, dpi: nil, properties: [:])
                    ocrLines.append(try recognizeText(li, s).lines)
                }
            }
            try writePDF(images: pages, to: out, dpi: images.first?.dpi ?? 200) { ctx, i, size in
                if ocr { drawTextLayer(ctx, lines: ocrLines[i], pageSize: size) }
            }
            status("wrote \(out) (\(pages.count) page\(pages.count == 1 ? "" : "s")\(ocr ? ", searchable" : ""))")
            return
        }
        if ocr { warn("--ocr only applies to PDF output; ignoring") }
        try writeBatch(pages, output: output.spec, sources: images, suffix: "-scan")
    }
}
