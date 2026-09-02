import ArgumentParser
import CoreML
import Foundation
import Vision

struct Classify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "classify",
        abstract: "Classify image content (Apple's built-in ~1300-label taxonomy, or any CoreML classifier).")

    @OptionGroup var input: InputOptions
    @Option(name: .long, help: "Keep only the top N labels.") var top: Int = 10
    @Option(name: .long, help: "Drop labels below this confidence (0-1).") var minConf: Float = 0.1
    @Option(name: .long, help: "Path to a CoreML classifier (.mlmodel/.mlpackage/.mlmodelc).") var model: String?
    @Flag(help: "JSON output.") var json = false
    @Flag(help: "Print the built-in label taxonomy and exit.") var labels = false

    func run() throws {
        if labels {
            for id in try VNClassifyImageRequest().supportedIdentifiers() { print(id) }
            return
        }
        var coreml: VNCoreMLModel?
        if let model {
            var url = URL(fileURLWithPath: model)
            if url.pathExtension != "mlmodelc" {
                status("compiling \(model)…")
                url = try MLModel.compileModel(at: url)
            }
            coreml = try VNCoreMLModel(for: try MLModel(contentsOf: url))
        }
        var out: [[String: Any]] = []
        for li in try input.load() {
            let req: VNRequest = coreml.map { VNCoreMLRequest(model: $0) } ?? VNClassifyImageRequest()
            try perform([req], on: li.image)
            let obs = (req.results as? [VNClassificationObservation] ?? [])
                .filter { $0.confidence >= minConf }
                .sorted { $0.confidence > $1.confidence }
                .prefix(top)
            if json {
                out.append(["source": li.source, "page": li.page as Any,
                            "labels": obs.map { ["label": $0.identifier, "confidence": r4($0.confidence)] }])
            } else {
                if input.inputs.count > 1 || li.page != nil { print("== \(li.label)") }
                for o in obs { print(String(format: "%.3f\t%@", o.confidence, o.identifier)) }
            }
        }
        if json { emitJSON(out) }
    }
}

struct Aesthetics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aesthetics",
        abstract: "Score image aesthetics (0..1) and flag utility images (screenshots, receipts…). macOS 15+.")

    @OptionGroup var input: InputOptions
    @Flag(help: "JSON output.") var json = false
    @Flag(help: "Sort by score, best first.") var sort = false

    func run() async throws {
        var rows: [(LoadedImage, Float, Bool)] = []
        for li in try input.load() {
            let req = CalculateImageAestheticsScoresRequest()
            let obs = try await req.perform(on: li.image)
            rows.append((li, obs.overallScore, obs.isUtility))
        }
        if sort { rows.sort { $0.1 > $1.1 } }
        if json {
            emitJSON(rows.map { ["source": $0.0.source, "page": $0.0.page as Any, "score": r4($0.1), "utility": $0.2] })
        } else {
            for (li, s, u) in rows { print(String(format: "%.3f\t%@\t%@", s, u ? "utility" : "photo", li.label)) }
        }
    }
}
