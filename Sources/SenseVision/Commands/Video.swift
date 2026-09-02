import ArgumentParser
import AVFoundation
import CoreGraphics
import Foundation
import Vision

struct VideoFrames {
    let asset: AVURLAsset
    let duration: Double
    let generator: AVAssetImageGenerator

    init(_ path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else { throw VisionError("\(path): no such file") }
        asset = AVURLAsset(url: URL(fileURLWithPath: path))
        duration = try await asset.load(.duration).seconds
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
    }

    func frame(at t: Double) async throws -> CGImage {
        guard t >= 0, t <= duration else { throw VisionError(String(format: "time %.2fs is outside the movie (duration %.2fs)", t, duration)) }
        let tt = min(t, max(0, duration - 0.05))
        return try await generator.image(at: CMTime(seconds: tt, preferredTimescale: 600)).image
    }

    func times(fps: Double, from: Double = 0, to: Double? = nil) -> [Double] {
        let end = min(to ?? duration, duration)
        guard fps > 0 else { return [] }
        return stride(from: from, to: end, by: 1 / fps).map { $0 }
    }
}

struct Video: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video",
        abstract: "Frame-level ops on movies: frames, thumb, ocr, detect, scenes, contact sheet.",
        subcommands: [VideoFrame.self, VideoThumb.self, VideoOCR.self, VideoDetect.self, VideoScenes.self, VideoContact.self])
}

struct VideoFrame: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "frames", abstract: "Extract frames at a rate.")
    @Argument var input: String
    @Option(name: .shortAndLong, help: "Output template, e.g. f_%05d.jpg") var output: String
    @Option(name: .long, help: "Frames per second to sample.") var fps: Double = 1
    @Option(name: .long, help: "Start time (SS or MM:SS).") var from: String?
    @Option(name: .long, help: "End time.") var to: String?
    @Option(name: .shortAndLong) var quality: Int?

    func run() async throws {
        let v = try await VideoFrames(input)
        var i = 0
        for t in v.times(fps: fps, from: try from.map(parseTime) ?? 0, to: try to.map(parseTime)) {
            i += 1
            try writeImage(try await v.frame(at: t), to: outputPath(output, index: i), quality: quality.map { Double($0) / 100 })
        }
        status("wrote \(i) frames")
    }
}

struct VideoThumb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "thumb", abstract: "Single frame at a time.")
    @Argument var input: String
    @Option(name: .shortAndLong) var output: String?
    @Option(name: .long, help: "Time (SS or MM:SS); default: 10% in.") var at: String?
    @Option(name: .shortAndLong) var quality: Int?

    func run() async throws {
        let v = try await VideoFrames(input)
        let t = try at.map(parseTime) ?? v.duration * 0.1
        try writeImage(try await v.frame(at: t), to: output, quality: quality.map { Double($0) / 100 })
    }
}

struct VideoOCR: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ocr", abstract: "Timestamped OCR of sampled frames (great for screen recordings).")
    @Argument var input: String
    @Option(name: .long) var fps: Double = 1
    @Option(name: .long, parsing: .upToNextOption) var lang: [String] = []
    @Flag(help: "Only print when the text changes.") var changes = false
    @Flag(help: "SRT subtitle output.") var srt = false
    @Flag(help: "JSON output.") var json = false

    func run() async throws {
        let v = try await VideoFrames(input)
        var s = OCRSettings()
        s.languages = lang
        var last = ""
        var entries: [(Double, String)] = []
        for t in v.times(fps: fps) {
            let cg = try await v.frame(at: t)
            let r = try recognizeText(LoadedImage(image: cg, source: input, page: nil, dpi: nil, properties: [:]), s)
            let text = r.lines.map(\.text).joined(separator: "\n")
            if (changes || srt) && text == last { continue }
            last = text
            entries.append((t, text))
            if !srt && !json {
                print("[\(fmtTime(t))]")
                if !text.isEmpty { print(text) }
            }
        }
        if json {
            emitJSON(entries.map { ["time": r4($0.0), "text": $0.1] })
        } else if srt {
            for (i, e) in entries.enumerated() where !e.1.isEmpty {
                let end = i + 1 < entries.count ? entries[i + 1].0 : v.duration
                print("\(i + 1)\n\(fmtTime(e.0, srt: true)) --> \(fmtTime(end, srt: true))\n\(e.1)\n")
            }
        }
    }
}

struct VideoDetect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "detect", abstract: "Run detectors on sampled frames; NDJSON stream.")
    @Argument var input: String
    @Option(name: .long) var fps: Double = 1
    @Option(name: .long, parsing: .upToNextOption) var what: [Detector] = [.faces]
    @Option(name: .long) var minConf: Float = 0
    @Option(name: .long, help: "Write annotated frames (template with %d).") var annotate: String?

    func run() async throws {
        let v = try await VideoFrames(input)
        var i = 0
        for t in v.times(fps: fps) {
            i += 1
            let li = LoadedImage(image: try await v.frame(at: t), source: input, page: nil, dpi: nil, properties: [:])
            let dets = try runDetectors(li, DetectSettings(whats: what, minConfidence: minConf))
            emitJSON(["time": r4(t), "frame": i, "detections": dets.map(\.dict)], pretty: false)
            if let annotate { try writeImage(VisionCommand.annotateImage(li, dets), to: outputPath(annotate, index: i)) }
        }
    }
}

struct VideoScenes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scenes", abstract: "Detect scene cuts via perceptual distance between sampled frames.")
    @Argument var input: String
    @Option(name: .long) var fps: Double = 2
    @Option(name: .long, help: "Feature-print distance that counts as a cut.") var threshold: Float = 0.6
    @Flag var json = false

    func run() async throws {
        let v = try await VideoFrames(input)
        var prev: VNFeaturePrintObservation?
        var cuts: [(Double, Float)] = []
        for t in v.times(fps: fps) {
            let fp = try featurePrint(try await v.frame(at: t))
            if let p = prev {
                let d = try distance(p, fp)
                if d > threshold { cuts.append((t, d)) }
            }
            prev = fp
        }
        if json { emitJSON(cuts.map { ["time": r4($0.0), "distance": r4($0.1)] }) }
        else { for (t, d) in cuts { print(String(format: "%@\t%.1f", fmtTime(t), d)) } }
    }
}

struct VideoContact: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "contact", abstract: "Contact sheet of evenly spaced frames.")
    @Argument var input: String
    @Option(name: .shortAndLong) var output: String?
    @Option(name: .long) var cols: Int = 5
    @Option(name: .long) var rows: Int = 4
    @Option(name: .long, help: "Thumbnail width in pixels.") var width: Int = 320

    func run() async throws {
        let v = try await VideoFrames(input)
        let n = cols * rows
        let first = try await v.frame(at: 0)
        let scale = Double(width) / Double(first.width)
        let tw = width, th = Int(Double(first.height) * scale)
        let ctx = CGContext(data: nil, width: tw * cols, height: th * rows, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: tw * cols, height: th * rows))
        for i in 0..<n {
            let t = v.duration * (Double(i) + 0.5) / Double(n)
            let f = try await v.frame(at: t)
            let x = (i % cols) * tw, y = (rows - 1 - i / cols) * th
            ctx.draw(f, in: CGRect(x: x, y: y, width: tw, height: th))
        }
        let a = Annotator(ctx.makeImage()!)
        for i in 0..<n {
            let t = v.duration * (Double(i) + 0.5) / Double(n)
            a.text(fmtTime(t), at: CGPoint(x: (i % cols) * tw + 4, y: (i / cols) * th + Int(a.fontSize) + 4), color: CGColor(gray: 1, alpha: 0.8))
        }
        try writeImage(a.image(), to: output, quality: 0.85)
    }
}
