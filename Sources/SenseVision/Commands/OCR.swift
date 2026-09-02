import ArgumentParser
import CoreGraphics
import CoreText
import Foundation
import Vision

struct OCRLine {
    var text: String
    var confidence: Float
    var box: CGRect          // pixels, top-left
    var quad: [CGPoint]      // pixels, top-left
    var candidates: [String]
    var words: [OCRWord]
    var normalized: CGRect   // Vision normalized (for PDF layer)
}

struct OCRWord {
    var text: String
    var box: CGRect
}

struct OCRResult {
    var image: LoadedImage
    var lines: [OCRLine]
}

struct OCRSettings {
    var languages: [String] = []
    var fast = false
    var correction = true
    var autoLanguage = true
    var customWords: [String] = []
    var roi: CGRect? = nil       // pixels
    var minConfidence: Float = 0
    var words = false
    var minHeight: Float = 0
}

func recognizeText(_ li: LoadedImage, _ s: OCRSettings) throws -> OCRResult {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = s.fast ? .fast : .accurate
    req.usesLanguageCorrection = s.correction
    if !s.languages.isEmpty { req.recognitionLanguages = s.languages }
    if s.autoLanguage && s.languages.isEmpty { req.automaticallyDetectsLanguage = true }
    if !s.customWords.isEmpty { req.customWords = s.customWords }
    if let roi = s.roi { req.regionOfInterest = normalizedROI(roi, li.width, li.height) }
    if s.minHeight > 0 { req.minimumTextHeight = s.minHeight }
    try perform([req], on: li.image)
    var lines: [OCRLine] = []
    for o in req.results ?? [] {
        let cands = o.topCandidates(3)
        guard let top = cands.first, top.confidence >= s.minConfidence else { continue }
        var words: [OCRWord] = []
        if s.words {
            let str = top.string
            var idx = str.startIndex
            while idx < str.endIndex {
                while idx < str.endIndex, str[idx].isWhitespace { idx = str.index(after: idx) }
                guard idx < str.endIndex else { break }
                var end = idx
                while end < str.endIndex, !str[end].isWhitespace { end = str.index(after: end) }
                if let r = try? top.boundingBox(for: idx..<end) {
                    words.append(OCRWord(text: String(str[idx..<end]), box: r.boundingBox.pixels(li.width, li.height)))
                }
                idx = end
            }
        }
        lines.append(OCRLine(
            text: top.string, confidence: top.confidence,
            box: o.boundingBox.pixels(li.width, li.height),
            quad: [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { $0.pixels(li.width, li.height) },
            candidates: cands.map(\.string), words: words, normalized: o.boundingBox))
    }
    return OCRResult(image: li, lines: lines)
}

/// Group lines into paragraphs by vertical gap; mark large lines as headings.
func markdown(from lines: [OCRLine]) -> String {
    guard !lines.isEmpty else { return "" }
    let heights = lines.map(\.box.height).sorted()
    let median = heights[heights.count / 2]
    var out: [String] = []
    var para: [String] = []
    var prev: OCRLine?
    func flush() {
        if !para.isEmpty { out.append(para.joined(separator: " ")); para = [] }
    }
    for l in lines {
        let isHeading = l.box.height > median * 1.5
        if let p = prev {
            let gap = l.box.minY - p.box.maxY
            let newCol = l.box.minY < p.box.minY - median  // jumped up: new column/block
            if gap > median * 1.2 || newCol || isHeading { flush() }
        }
        if isHeading {
            flush()
            out.append("## " + l.text)
        } else if l.text.range(of: #"^[-•*·▪◦]\s"#, options: .regularExpression) != nil {
            flush()
            let item = "- " + l.text.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if let last = out.last, last.hasPrefix("- ") { out[out.count - 1] = last + "\n" + item } else { out.append(item) }
        } else {
            para.append(l.text)
        }
        prev = l
    }
    flush()
    return out.joined(separator: "\n\n")
}

func hocr(_ results: [OCRResult]) -> String {
    var s = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
    <html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/>
    <meta name="ocr-system" content="sense vision (Apple Vision)"/>
    <meta name="ocr-capabilities" content="ocr_page ocr_line ocrx_word"/></head><body>

    """
    func esc(_ t: String) -> String {
        t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    func bbox(_ r: CGRect) -> String { "bbox \(Int(r.minX)) \(Int(r.minY)) \(Int(r.maxX)) \(Int(r.maxY))" }
    for (pi, r) in results.enumerated() {
        s += "<div class='ocr_page' id='page_\(pi + 1)' title='image \"\(esc(r.image.source))\"; bbox 0 0 \(r.image.width) \(r.image.height); ppageno \(pi)'>\n"
        for (li, l) in r.lines.enumerated() {
            s += " <span class='ocr_line' id='line_\(pi + 1)_\(li + 1)' title='\(bbox(l.box))'>"
            if l.words.isEmpty {
                s += "<span class='ocrx_word' title='\(bbox(l.box)); x_wconf \(Int(l.confidence * 100))'>\(esc(l.text))</span>"
            } else {
                s += l.words.map { "<span class='ocrx_word' title='\(bbox($0.box)); x_wconf \(Int(l.confidence * 100))'>\(esc($0.text))</span>" }.joined(separator: " ")
            }
            s += "</span>\n"
        }
        s += "</div>\n"
    }
    return s + "</body></html>\n"
}

func tsv(_ results: [OCRResult]) -> String {
    var s = "page\tline\tword\tleft\ttop\twidth\theight\tconf\ttext\n"
    for (pi, r) in results.enumerated() {
        for (li, l) in r.lines.enumerated() {
            if l.words.isEmpty {
                s += "\(pi + 1)\t\(li + 1)\t0\t\(Int(l.box.minX))\t\(Int(l.box.minY))\t\(Int(l.box.width))\t\(Int(l.box.height))\t\(Int(l.confidence * 100))\t\(l.text)\n"
            } else {
                for (wi, w) in l.words.enumerated() {
                    s += "\(pi + 1)\t\(li + 1)\t\(wi + 1)\t\(Int(w.box.minX))\t\(Int(w.box.minY))\t\(Int(w.box.width))\t\(Int(w.box.height))\t\(Int(l.confidence * 100))\t\(w.text)\n"
                }
            }
        }
    }
    return s
}

/// Draw invisible text over a PDF page so it becomes searchable/selectable.
func drawTextLayer(_ ctx: CGContext, lines: [OCRLine], pageSize: CGSize) {
    ctx.saveGState()
    ctx.setTextDrawingMode(.invisible)
    for l in lines {
        let box = CGRect(x: l.normalized.minX * pageSize.width, y: l.normalized.minY * pageSize.height,
                         width: l.normalized.width * pageSize.width, height: l.normalized.height * pageSize.height)
        let fontSize = max(1, box.height * 0.85)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: l.text, attributes: [.font: font]))
        let natural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let sx = natural > 0 ? box.width / natural : 1
        ctx.textMatrix = CGAffineTransform(scaleX: sx, y: 1)
        ctx.textPosition = CGPoint(x: box.minX, y: box.minY + box.height * 0.2)
        CTLineDraw(line, ctx)
    }
    ctx.restoreGState()
}

struct OCR: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ocr",
        abstract: "Recognize text (on-device, same engine as Live Text).",
        discussion: """
            Default output is plain text in reading order, one recognized line per line; \
            multiple inputs/pages are separated by a form feed (\\f).
            """)

    @OptionGroup var input: InputOptions

    @Option(name: .long, parsing: .upToNextOption, help: "Recognition language(s), e.g. en-US pl-PL.")
    var lang: [String] = []

    @Flag(help: "Use the fast (non-ML) recognizer.") var fast = false
    @Flag(name: .customLong("no-correction"), help: "Disable language correction.") var noCorrection = false
    @Option(name: .long, help: "File with custom vocabulary words, one per line.") var customWords: String?
    @Option(name: .long, help: "Only recognize inside rect x,y,w,h (pixels).") var roi: String?
    @Option(name: .long, help: "Drop lines with confidence below this (0-1).") var minConf: Float = 0
    @Option(name: .long, help: "Minimum text height as fraction of image height.") var minHeight: Float = 0

    @Flag(help: "JSON output (lines with boxes, confidence, candidates).") var json = false
    @Flag(help: "Include word-level boxes (JSON/hOCR/TSV) or annotate words.") var words = false
    @Flag(help: "hOCR XML output.") var hocr = false
    @Flag(help: "Tab-separated output (page, line, word, box, conf, text).") var tsv = false
    @Flag(help: "Reconstruct paragraphs/headings as Markdown.") var md = false
    @Flag(help: "Exit 4 if nothing was recognized.") var strict = false
    @Flag(help: "List supported recognition languages and exit.") var langs = false

    @Option(name: .long, help: "Write a copy of the input with recognized boxes drawn.") var annotate: String?
    @Option(name: .shortAndLong, help: "Write a searchable PDF (image + invisible text layer).") var output: String?

    func run() throws {
        if langs {
            let r = VNRecognizeTextRequest()
            r.recognitionLevel = fast ? .fast : .accurate
            for l in try r.supportedRecognitionLanguages() { print(l) }
            return
        }
        var s = OCRSettings()
        s.languages = lang
        s.fast = fast
        s.correction = !noCorrection
        s.roi = try roi.map(parseRect)
        s.minConfidence = minConf
        s.minHeight = minHeight
        s.words = words || hocr || tsv
        if let customWords {
            s.customWords = try String(contentsOfFile: customWords, encoding: .utf8)
                .split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.isEmpty }
        }

        let images = try input.load()
        var results: [OCRResult] = []
        for li in images {
            status("ocr \(li.label) (\(li.width)x\(li.height))")
            results.append(try recognizeText(li, s))
        }
        let total = results.reduce(0) { $0 + $1.lines.count }

        if let annotate {
            var outs: [CGImage] = []
            for r in results {
                let a = Annotator(r.image.image)
                for l in r.lines {
                    if words { for w in l.words { a.rect(w.box, color: Annotator.color("words")) } }
                    a.quad(l.quad, color: Annotator.color("ocr"))
                }
                outs.append(a.image())
            }
            try writeBatch(outs, output: OutSpec(annotate), sources: results.map(\.image), suffix: "-ocr")
        }

        if let output {
            let ext = URL(fileURLWithPath: output).pathExtension.lowercased()
            guard ext == "pdf" else { throw ValidationError("-o must be a .pdf (searchable PDF); use --annotate for images") }
            try writePDF(images: results.map(\.image.image), to: output, dpi: images.first?.dpi ?? input.dpi) { ctx, i, size in
                drawTextLayer(ctx, lines: results[i].lines, pageSize: size)
            }
            status("wrote \(output) (\(total) lines)")
        }

        if json {
            emitJSON(results.map { r -> [String: Any] in
                ["source": r.image.source, "page": r.image.page as Any, "width": r.image.width, "height": r.image.height,
                 "lines": r.lines.map { l -> [String: Any] in
                    var d: [String: Any] = ["text": l.text, "confidence": r4(l.confidence), "bbox": l.box.dict,
                                            "quad": l.quad.map(\.dict), "candidates": l.candidates]
                    if !l.words.isEmpty { d["words"] = l.words.map { ["text": $0.text, "bbox": $0.box.dict] } }
                    return d
                 }]
            })
        } else if hocr {
            print(VisionCommand.hocrText(results), terminator: "")
        } else if tsv {
            print(VisionCommand.tsvText(results), terminator: "")
        } else if output == nil || md {
            let chunks = results.map { md ? markdown(from: $0.lines) : $0.lines.map(\.text).joined(separator: "\n") }
            print(chunks.joined(separator: "\n\u{0C}\n"))
        }
        if strict && total == 0 { throw ExitCode(Exit.nothingFound) }
    }
}

extension VisionCommand {
    static func hocrText(_ r: [OCRResult]) -> String { hocr(r) }
    static func tsvText(_ r: [OCRResult]) -> String { tsv(r) }
}
