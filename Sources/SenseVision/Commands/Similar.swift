import ArgumentParser
import Foundation
import Vision

func featurePrint(_ image: CGImage) throws -> VNFeaturePrintObservation {
    let r = VNGenerateImageFeaturePrintRequest()
    try perform([r], on: image)
    guard let f = r.results?.first else { throw VisionError("no feature print") }
    return f
}

func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) throws -> Float {
    var d: Float = 0
    try a.computeDistance(&d, to: b)
    return d
}

func expandInputs(_ paths: [String]) -> [String] {
    let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "dng", "cr2", "nef", "arw", "raf", "pdf"]
    var out: [String] = []
    for p in paths {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
            if let e = FileManager.default.enumerator(atPath: p) {
                for case let f as String in e where exts.contains((f as NSString).pathExtension.lowercased()) {
                    out.append((p as NSString).appendingPathComponent(f))
                }
            }
        } else {
            out.append(p)
        }
    }
    return out
}

struct Similar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "similar",
        abstract: "Compare images by perceptual feature print (0 = identical, <0.3 near-duplicate, >1 clearly different).")

    @Argument(help: "Query image.") var query: String
    @Argument(help: "Candidate image(s) or directories.") var candidates: [String]
    @Option(name: .long, help: "Only print the N closest.") var top: Int?
    @Flag(help: "JSON output.") var json = false

    func run() throws {
        let q = try featurePrint(try loadImages(query).first1.image)
        var rows: [(String, Float)] = []
        for c in expandInputs(candidates) {
            do {
                let f = try featurePrint(try loadImages(c).first1.image)
                rows.append((c, try distance(q, f)))
            } catch { warn("\(c): \(error)") }
        }
        rows.sort { $0.1 < $1.1 }
        if let top { rows = Array(rows.prefix(top)) }
        if json { emitJSON(rows.map { ["path": $0.0, "distance": r4($0.1)] }) }
        else { for (p, d) in rows { print(String(format: "%.3f\t%@", d, p)) } }
    }
}

struct Embed: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "embed",
        abstract: "Print the raw feature-print vector (JSON array of floats).")

    @OptionGroup var input: InputOptions

    func run() throws {
        var out: [[String: Any]] = []
        for li in try input.load() {
            let f = try featurePrint(li.image)
            var floats: [Float] = []
            if f.elementType == .float {
                floats = f.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } else {
                floats = f.data.withUnsafeBytes { $0.bindMemory(to: Double.self).map { Float($0) } }
            }
            out.append(["source": li.source, "page": li.page as Any, "dim": floats.count, "vector": floats.map { Double($0) }])
        }
        emitJSON(out, pretty: false)
    }
}

struct Dedupe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dedupe",
        abstract: "Group near-duplicate images in files/directories; optionally delete all but one per group.")

    @Argument(help: "Image files or directories.") var paths: [String]
    @Option(name: .long, help: "Max feature-print distance to count as duplicate.") var threshold: Float = 0.3
    @Flag(name: .customLong("delete-dupes"), help: "Delete duplicates (keeps one per group).") var deleteDupes = false
    @Option(name: .long, help: "Which file to keep: largest | first | newest.") var keep: String = "largest"
    @Flag(name: .shortAndLong, help: "Do not ask before deleting.") var yes = false
    @Flag(help: "JSON output.") var json = false

    func run() throws {
        let files = expandInputs(paths)
        var prints: [(String, VNFeaturePrintObservation)] = []
        for f in files {
            do { prints.append((f, try featurePrint(try loadImages(f).first1.image))) } catch { warn("\(f): \(error)") }
        }
        status("computed \(prints.count) feature prints, comparing…")
        var parent = Array(0..<prints.count)
        func find(_ i: Int) -> Int { parent[i] == i ? i : { parent[i] = find(parent[i]); return parent[i] }() }
        for i in 0..<prints.count {
            for j in (i + 1)..<max(i + 1, prints.count) {
                if (try? distance(prints[i].1, prints[j].1)) ?? .infinity <= threshold {
                    parent[find(i)] = find(j)
                }
            }
        }
        var groups: [Int: [String]] = [:]
        for i in 0..<prints.count { groups[find(i), default: []].append(prints[i].0) }
        let dupGroups = groups.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }

        func attr(_ p: String) -> [FileAttributeKey: Any] { (try? FileManager.default.attributesOfItem(atPath: p)) ?? [:] }
        func keeper(_ g: [String]) -> String {
            switch keep {
            case "first": return g.sorted()[0]
            case "newest": return g.max { (attr($0)[.modificationDate] as? Date ?? .distantPast) < (attr($1)[.modificationDate] as? Date ?? .distantPast) }!
            default: return g.max { (attr($0)[.size] as? Int ?? 0) < (attr($1)[.size] as? Int ?? 0) }!
            }
        }

        if json {
            emitJSON(dupGroups.map { ["keep": keeper($0), "files": $0] })
        } else {
            for g in dupGroups {
                let k = keeper(g)
                print("group (\(g.count)):")
                for f in g { print("  \(f == k ? "keep  " : "dupe  ")\(f)") }
            }
            status("\(dupGroups.count) duplicate group(s) among \(prints.count) images")
        }
        if deleteDupes && !dupGroups.isEmpty {
            let victims = dupGroups.flatMap { g in g.filter { $0 != keeper(g) } }
            if !yes && !confirm("delete \(victims.count) file(s)?") { status("aborted"); return }
            for v in victims {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: v), resultingItemURL: nil)
                status("trashed \(v)")
            }
        }
    }
}
