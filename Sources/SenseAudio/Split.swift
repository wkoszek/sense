import AVFoundation
import Foundation

private func splitUsage() -> Never {
    errPrint("""
    usage: sense audio split <in> <pattern> --on-silence [options]
           sense audio split <in> <pattern> --every <time>

      <pattern> like out_%03d.wav (a %d-style index; or _NNN is inserted before the extension)

    options:
          --on-silence            split at detected silences
          --every <time>          fixed-length chunks (seconds or mm:ss)
          --threshold <db>        silence threshold in dBFS (default -40)
          --min-silence <secs>    minimum silence length to split at (default 0.5)
    """)
    exit(2)
}

private func segmentPath(_ pattern: String, _ i: Int) -> String {
    if pattern.contains("%") { return String(format: pattern, i) }
    let ns = pattern as NSString
    let ext = ns.pathExtension
    let base = ns.deletingPathExtension
    return ext.isEmpty ? String(format: "%@_%03d", base, i) : String(format: "%@_%03d.%@", base, i, ext)
}

func cmdSplit(_ args: [String]) {
    var paths: [String] = []
    var onSilence = false
    var every: Double?
    var threshold = -40.0
    var minSilence = 0.5
    let p = ArgList(args)
    while let a = p.next() {
        switch a {
        case "--on-silence": onSilence = true
        case "--every": every = p.timeValue(a)
        case "--threshold": threshold = p.doubleValue(a)
        case "--min-silence": minSilence = p.doubleValue(a)
        case "-h", "--help": splitUsage()
        default:
            if a.hasPrefix("-") { fail("split: unknown option \(a)", code: 2) }
            paths.append(a)
        }
    }
    guard paths.count == 2, onSilence != (every != nil) else { splitUsage() }
    let (inPath, pattern) = (paths[0], paths[1])

    let src = openInput(inPath)
    let sr = src.processingFormat.sampleRate
    let total = Double(src.length) / sr

    var cuts: [Double] = []
    if let e = every {
        guard e > 0 else { fail("--every must be > 0", code: 2) }
        var t = e
        while t < total { cuts.append(t); t += e }
    } else {
        cuts = detectSilences(src, thresholdDB: threshold, minDuration: minSilence)
            .map { ($0.start + $0.end) / 2 }
            .filter { $0 > 0.05 && $0 < total - 0.05 }
        if cuts.isEmpty {
            fail("no silences >= \(minSilence)s below \(threshold) dB found; nothing to split")
        }
    }

    let bounds = [0.0] + cuts + [total]
    for i in 0..<(bounds.count - 1) {
        let (a, b) = (bounds[i], bounds[i + 1])
        let path = segmentPath(pattern, i)
        let out = OutputFile(path)
        var writer: AVAudioFile? = makeWriter(out, format: src.processingFormat)
        copyFrames(src, from: AVAudioFramePosition(a * sr), to: AVAudioFramePosition(b * sr), into: writer!)
        writer = nil
        out.finalize()
        errPrint("\(programName): wrote \(path) (\(prettyTime(a)) - \(prettyTime(b)))")
        print(path)
    }
}
