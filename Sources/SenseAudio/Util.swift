import AVFoundation
import Foundation

import SenseCore

/// Prefix for diagnostics; matches how the user invoked us.
let programName = "sense audio"

func errPrint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func errWrite(_ s: String) {
    FileHandle.standardError.write(s.data(using: .utf8)!)
}

func fail(_ msg: String, code: Int32 = 1) -> Never {
    errPrint("\(programName): \(msg)")
    exit(code)
}

// MARK: - Signals

var gInterrupted: sig_atomic_t = 0

func installSigint() {
    signal(SIGINT) { _ in gInterrupted = 1 }
}

// MARK: - Argument scanning

final class ArgList {
    private let a: [String]
    private var i = 0
    init(_ args: [String]) { a = args }
    func next() -> String? {
        guard i < a.count else { return nil }
        defer { i += 1 }
        return a[i]
    }
    func value(_ flag: String) -> String {
        guard i < a.count else { fail("\(flag) requires an argument", code: 2) }
        defer { i += 1 }
        return a[i]
    }
    func doubleValue(_ flag: String) -> Double {
        let v = value(flag)
        guard let d = Double(v) else { fail("\(flag): '\(v)' is not a number", code: 2) }
        return d
    }
    func intValue(_ flag: String) -> Int {
        let v = value(flag)
        guard let n = Int(v) else { fail("\(flag): '\(v)' is not an integer", code: 2) }
        return n
    }
    func timeValue(_ flag: String) -> Double {
        let v = value(flag)
        guard let t = parseTime(v) else { fail("\(flag): bad time '\(v)' (use seconds, mm:ss, or h:mm:ss)", code: 2) }
        return t
    }
}

// MARK: - Time

/// "83", "83.5", "1:23", "1:23.5", "1:02:03" -> seconds
func parseTime(_ s: String) -> Double? {
    let parts = s.split(separator: ":")
    guard !parts.isEmpty, parts.count <= 3 else { return nil }
    var secs = 0.0
    for p in parts {
        guard let v = Double(p), v >= 0 else { return nil }
        secs = secs * 60 + v
    }
    return secs
}

/// 75.132 -> "00:01:15,132" (srt sep ",") or "00:01:15.132" (vtt sep ".")
func hms(_ t: Double, sep: String) -> String {
    let ms = Int(((t - floor(t)) * 1000).rounded())
    let s = Int(t)
    return String(format: "%02d:%02d:%02d%@%03d", s / 3600, (s / 60) % 60, s % 60, sep, ms)
}

func prettyTime(_ t: Double) -> String {
    String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}

// MARK: - External tools (MP3 encoding)

func which(_ tool: String) -> String? {
    let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin"]
    for dir in dirs {
        let p = "\(dir)/\(tool)"
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

func runTool(_ cmd: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd[0])
    p.arguments = Array(cmd.dropFirst())
    do { try p.run() } catch { fail("cannot run \(cmd[0]): \(error.localizedDescription)") }
    p.waitUntilExit()
    if p.terminationStatus != 0 { fail("\(cmd[0]) failed with status \(p.terminationStatus)") }
}

func encodeMP3(wav: String, to mp3: String) {
    if let lame = which("lame") {
        runTool([lame, "--quiet", "-V", "2", wav, mp3])
    } else if let ff = which("ffmpeg") {
        runTool([ff, "-loglevel", "error", "-y", "-i", wav, "-codec:a", "libmp3lame", "-q:a", "2", mp3])
    } else {
        fail("Apple provides no MP3 encoder; install `lame` or `ffmpeg` (brew install lame), or use .m4a/.wav")
    }
}

func tempFilePath(ext: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("audio-\(getpid())-\(UInt32.random(in: 0..<1_000_000)).\(ext)").path
}

func pathExt(_ p: String) -> String { (p as NSString).pathExtension.lowercased() }

// MARK: - JSON

func printJSON(_ obj: Any) {
    guard JSONSerialization.isValidJSONObject(obj),
          let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    else { fail("cannot encode JSON") }
    print(String(data: d, encoding: .utf8)!)
}

// MARK: - Permissions

func ensureMicAccess() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return
    case .notDetermined:
        errPrint("\(programName): waiting for the Microphone permission dialog (click Allow)…")
        let sema = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { g in granted = g; sema.signal() }
        sema.wait()
        if !granted { fail("microphone access denied", code: 3) }
    default:
        fail("microphone access denied (System Settings > Privacy & Security > Microphone)", code: 3)
    }
}
