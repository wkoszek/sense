import ArgumentParser
import CoreGraphics
import Foundation
import Vision

enum Detector: String, CaseIterable, ExpressibleByArgument {
    case faces, landmarks, bodies, pose, hands, animals, rects, barcodes, text, horizon, contours, saliency

    static let defaults: [Detector] = [.faces, .rects, .text, .barcodes]
}

struct Detection {
    var kind: Detector
    var box: CGRect?                 // pixels
    var quad: [CGPoint]?             // pixels
    var quadObs: VNRectangleObservation?
    var confidence: Float
    var label: String?
    var points: [String: (CGPoint, Float)] = [:]   // named points (landmarks, pose, hands)
    var extra: [String: Any] = [:]
    var paths: [[CGPoint]] = []      // contours

    var dict: [String: Any] {
        var d: [String: Any] = ["kind": kind.rawValue, "confidence": r4(confidence)]
        if let box { d["bbox"] = box.dict }
        if let quad { d["quad"] = quad.map(\.dict) }
        if let label { d["label"] = label }
        if !points.isEmpty {
            d["points"] = points.mapValues { ["x": r4($0.0.x), "y": r4($0.0.y), "confidence": r4($0.1)] }
        }
        if !paths.isEmpty { d["paths"] = paths.map { $0.map(\.dict) } }
        for (k, v) in extra { d[k] = v }
        return d
    }
}

struct DetectSettings {
    var whats: [Detector]
    var minConfidence: Float = 0
    var maxRects = 10
}

func runDetectors(_ li: LoadedImage, _ s: DetectSettings) throws -> [Detection] {
    let w = li.width, h = li.height
    var requests: [(Detector, VNRequest)] = []
    for d in s.whats {
        let r: VNRequest
        switch d {
        case .faces: r = VNDetectFaceRectanglesRequest()
        case .landmarks: r = VNDetectFaceLandmarksRequest()
        case .bodies: r = VNDetectHumanRectanglesRequest()
        case .pose: r = VNDetectHumanBodyPoseRequest()
        case .hands: let hr = VNDetectHumanHandPoseRequest(); hr.maximumHandCount = 10; r = hr
        case .animals: r = VNRecognizeAnimalsRequest()
        case .rects:
            let rr = VNDetectRectanglesRequest()
            rr.maximumObservations = s.maxRects
            rr.minimumConfidence = max(0.3, s.minConfidence)
            rr.minimumSize = 0.05
            rr.quadratureTolerance = 30
            rr.minimumAspectRatio = 0.1
            r = rr
        case .barcodes: r = VNDetectBarcodesRequest()
        case .text: let tr = VNDetectTextRectanglesRequest(); tr.reportCharacterBoxes = false; r = tr
        case .horizon: r = VNDetectHorizonRequest()
        case .contours:
            let cr = VNDetectContoursRequest()
            cr.contrastAdjustment = 1.5
            cr.detectsDarkOnLight = true
            r = cr
        case .saliency: r = VNGenerateObjectnessBasedSaliencyImageRequest()
        }
        requests.append((d, r))
    }
    try perform(requests.map(\.1), on: li.image)

    var out: [Detection] = []
    for (kind, req) in requests {
        for res in req.results ?? [] {
            var det = Detection(kind: kind, box: nil, quad: nil, quadObs: nil, confidence: res.confidence, label: nil)
            if let rect = res as? VNRectangleObservation {
                det.box = rect.boundingBox.pixels(w, h)
                det.quad = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft].map { $0.pixels(w, h) }
                det.quadObs = rect
            } else if let obs = res as? VNDetectedObjectObservation {
                det.box = obs.boundingBox.pixels(w, h)
            }
            switch kind {
            case .faces, .landmarks:
                guard let f = res as? VNFaceObservation else { continue }
                if let roll = f.roll { det.extra["roll"] = r4(roll.doubleValue * 180 / .pi) }
                if let yaw = f.yaw { det.extra["yaw"] = r4(yaw.doubleValue * 180 / .pi) }
                if let pitch = f.pitch { det.extra["pitch"] = r4(pitch.doubleValue * 180 / .pi) }
                if kind == .landmarks, let lm = f.landmarks {
                    let regions: [(String, VNFaceLandmarkRegion2D?)] = [
                        ("faceContour", lm.faceContour), ("leftEye", lm.leftEye), ("rightEye", lm.rightEye),
                        ("leftEyebrow", lm.leftEyebrow), ("rightEyebrow", lm.rightEyebrow), ("nose", lm.nose),
                        ("noseCrest", lm.noseCrest), ("medianLine", lm.medianLine), ("outerLips", lm.outerLips),
                        ("innerLips", lm.innerLips), ("leftPupil", lm.leftPupil), ("rightPupil", lm.rightPupil),
                    ]
                    var regionDict: [String: Any] = [:]
                    for (name, region) in regions {
                        guard let region else { continue }
                        let pts = region.pointsInImage(imageSize: CGSize(width: w, height: h))
                            .map { CGPoint(x: $0.x, y: CGFloat(h) - $0.y) }
                        det.paths.append(pts)
                        regionDict[name] = pts.map(\.dict)
                    }
                    det.extra["landmarks"] = regionDict
                }
            case .pose:
                guard let p = res as? VNHumanBodyPoseObservation else { continue }
                for (name, pt) in (try? p.recognizedPoints(.all)) ?? [:] where pt.confidence > 0.1 {
                    det.points[name.rawValue.rawValue.replacingOccurrences(of: "VNHLKB", with: "")] = (pt.location.pixels(w, h), pt.confidence)
                }
                det.box = det.points.isEmpty ? nil : boundingBox(det.points.values.map(\.0))
            case .hands:
                guard let p = res as? VNHumanHandPoseObservation else { continue }
                for (name, pt) in (try? p.recognizedPoints(.all)) ?? [:] where pt.confidence > 0.1 {
                    det.points[name.rawValue.rawValue.replacingOccurrences(of: "VNHLK", with: "")] = (pt.location.pixels(w, h), pt.confidence)
                }
                det.label = p.chirality == .left ? "left" : p.chirality == .right ? "right" : "unknown"
                det.box = det.points.isEmpty ? nil : boundingBox(det.points.values.map(\.0))
            case .animals:
                guard let a = res as? VNRecognizedObjectObservation, let top = a.labels.first else { continue }
                det.label = top.identifier
                det.confidence = top.confidence
                det.extra["labels"] = a.labels.map { ["label": $0.identifier, "confidence": r4($0.confidence)] }
            case .barcodes:
                guard let b = res as? VNBarcodeObservation else { continue }
                det.label = b.payloadStringValue
                det.extra["symbology"] = b.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
                if let p = b.payloadStringValue { det.extra["payload"] = p }
            case .horizon:
                guard let hz = res as? VNHorizonObservation else { continue }
                det.extra["angle"] = r4(hz.angle * 180 / .pi)
                det.confidence = 1
            case .contours:
                guard let c = res as? VNContoursObservation else { continue }
                det.extra["count"] = c.contourCount
                det.extra["topLevel"] = c.topLevelContourCount
                func walk(_ contour: VNContour) {
                    let pts = contour.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)).pixels(w, h) }
                    if pts.count > 2 { det.paths.append(pts) }
                    for ch in contour.childContours { walk(ch) }
                }
                for tc in c.topLevelContours { walk(tc) }
                det.confidence = 1
            case .saliency:
                guard let sal = res as? VNSaliencyImageObservation else { continue }
                for so in sal.salientObjects ?? [] {
                    var d = Detection(kind: .saliency, box: so.boundingBox.pixels(w, h), quad: nil, quadObs: nil, confidence: so.confidence, label: nil)
                    d.quad = [so.topLeft, so.topRight, so.bottomRight, so.bottomLeft].map { $0.pixels(w, h) }
                    out.append(d)
                }
                continue
            default: break
            }
            if det.confidence < s.minConfidence { continue }
            out.append(det)
        }
    }
    return out
}

func boundingBox(_ pts: [CGPoint]) -> CGRect {
    guard let f = pts.first else { return .zero }
    var minX = f.x, minY = f.y, maxX = f.x, maxY = f.y
    for p in pts { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

let poseBones: [(String, String)] = [
    ("Nose", "Neck"), ("Neck", "LeftShoulder"), ("Neck", "RightShoulder"),
    ("LeftShoulder", "LeftElbow"), ("LeftElbow", "LeftWrist"),
    ("RightShoulder", "RightElbow"), ("RightElbow", "RightWrist"),
    ("Neck", "Root"), ("Root", "LeftHip"), ("Root", "RightHip"),
    ("LeftHip", "LeftKnee"), ("LeftKnee", "LeftAnkle"),
    ("RightHip", "RightKnee"), ("RightKnee", "RightAnkle"),
    ("Nose", "LeftEye"), ("Nose", "RightEye"), ("LeftEye", "LeftEar"), ("RightEye", "RightEar"),
]

let handBones: [(String, String)] = {
    var b: [(String, String)] = []
    for finger in ["Thumb", "Index", "Middle", "Ring", "Little"] {
        let chain: [String]
        switch finger {
        case "Thumb": chain = ["Wrist", "ThumbCMC", "ThumbMP", "ThumbIP", "ThumbTip"]
        case "Index": chain = ["Wrist", "IndexMCP", "IndexPIP", "IndexDIP", "IndexTip"]
        case "Middle": chain = ["Wrist", "MiddleMCP", "MiddlePIP", "MiddleDIP", "MiddleTip"]
        case "Ring": chain = ["Wrist", "RingMCP", "RingPIP", "RingDIP", "RingTip"]
        default: chain = ["Wrist", "LittleMCP", "LittlePIP", "LittleDIP", "LittleTip"]
        }
        for i in 0..<(chain.count - 1) { b.append((chain[i], chain[i + 1])) }
    }
    return b
}()

func annotate(_ li: LoadedImage, _ dets: [Detection]) -> CGImage {
    let a = Annotator(li.image)
    for d in dets {
        let c = Annotator.color(d.kind.rawValue)
        var label = d.label ?? d.kind.rawValue
        if d.confidence < 1 { label += String(format: " %.0f%%", d.confidence * 100) }
        switch d.kind {
        case .pose, .hands:
            let bones = d.kind == .pose ? poseBones : handBones
            for (x, y) in bones {
                if let p = d.points[x], let q = d.points[y] { a.line(p.0, q.0, color: c) }
            }
            for (_, p) in d.points { a.point(p.0, color: c) }
            if let b = d.box { a.text(label, at: CGPoint(x: b.minX, y: b.minY - 2), color: c) }
        case .landmarks:
            if let q = d.quad { a.quad(q, color: c) }
            for path in d.paths { a.path(path, closed: false, color: c, width: a.lineWidth * 0.7) }
        case .contours:
            for path in d.paths { a.path(path, closed: true, color: c, width: a.lineWidth * 0.5) }
        case .horizon:
            let angle = (d.extra["angle"] as? Double ?? 0) * .pi / 180
            let cx = CGFloat(li.width) / 2, cy = CGFloat(li.height) / 2
            let dx = CGFloat(li.width) * cos(angle), dy = CGFloat(li.width) * sin(angle)
            a.line(CGPoint(x: cx - dx, y: cy - dy), CGPoint(x: cx + dx, y: cy + dy), color: c)
            a.text(String(format: "horizon %.1f°", angle * 180 / .pi), at: CGPoint(x: 10, y: 30), color: c)
        default:
            if let q = d.quad, d.kind == .rects || d.kind == .barcodes || d.kind == .text {
                a.quad(q, color: c, label: d.kind == .text ? nil : label)
            } else if let b = d.box {
                a.rect(b, color: c, label: label)
            }
        }
    }
    return a.image()
}

struct Detect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detect",
        abstract: "Find things: faces, landmarks, bodies, pose, hands, animals, rects, barcodes, text, horizon, contours, saliency.")

    @OptionGroup var input: InputOptions

    @Option(name: .long, parsing: .upToNextOption,
            help: "Detector(s): \(Detector.allCases.map(\.rawValue).joined(separator: " ")) (default: faces rects text barcodes).")
    var what: [Detector] = Detector.defaults

    @Option(name: .long, help: "Drop results below this confidence (0-1).") var minConf: Float = 0
    @Flag(help: "JSON output.") var json = false
    @Flag(help: "Exit 4 if nothing was found.") var strict = false
    @Option(name: .long, help: "Write a copy of the input with detections drawn.") var annotate: String?
    @Option(name: .long, help: "Write one crop per detection (template with %d or a directory). Rects are perspective-corrected.") var crop: String?

    func run() throws {
        let images = try input.load()
        var all: [(LoadedImage, [Detection])] = []
        for li in images {
            status("detect \(what.map(\.rawValue).joined(separator: ",")) in \(li.label)")
            all.append((li, try runDetectors(li, DetectSettings(whats: what, minConfidence: minConf))))
        }
        let total = all.reduce(0) { $0 + $1.1.count }

        if let annotate {
            try writeBatch(all.map { VisionCommand.annotateImage($0.0, $0.1) }, output: OutSpec(annotate), sources: all.map(\.0), suffix: "-detect")
        }
        if let crop {
            var crops: [CGImage] = []
            for (li, dets) in all {
                for d in dets {
                    if let q = d.quadObs, d.kind == .rects {
                        crops.append(try perspectiveCorrect(li.image, quad: q))
                    } else if let b = d.box, let c = li.image.cropped(toPixels: b.insetBy(dx: -b.width * 0.05, dy: -b.height * 0.05)) {
                        crops.append(c)
                    }
                }
            }
            if crops.isEmpty { warn("nothing to crop") } else {
                try writeBatch(crops, output: OutSpec(crop))
            }
        }

        if json {
            emitJSON(all.map { li, dets -> [String: Any] in
                ["source": li.source, "page": li.page as Any, "width": li.width, "height": li.height,
                 "detections": dets.map(\.dict)]
            })
        } else if annotate == nil || total > 0 {
            for (li, dets) in all {
                if all.count > 1 { print("== \(li.label)") }
                for d in dets {
                    var parts = [d.kind.rawValue]
                    if let b = d.box { parts.append("\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))") }
                    parts.append(String(format: "%.2f", d.confidence))
                    if let l = d.label { parts.append(l) }
                    if let a = d.extra["angle"] { parts.append("angle=\(a)") }
                    if let s = d.extra["symbology"] { parts.append("\(s)") }
                    if let n = d.extra["count"] { parts.append("contours=\(n)") }
                    if !d.points.isEmpty { parts.append("points=\(d.points.count)") }
                    print(parts.joined(separator: "\t"))
                }
            }
        }
        if strict && total == 0 { throw ExitCode(Exit.nothingFound) }
    }
}

extension VisionCommand {
    static func annotateImage(_ li: LoadedImage, _ d: [Detection]) -> CGImage { annotate(li, d) }
}
