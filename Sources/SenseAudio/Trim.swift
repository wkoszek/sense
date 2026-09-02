import AVFoundation
import Foundation

private func trimUsage() -> Never {
    errPrint("""
    usage: sense audio trim <in> <out> --from <time> [--to <time>]
           sense audio trim <in> <out> --silence [--threshold <db>] [--min-silence <secs>]

    options:
          --from <time>           start (seconds or mm:ss; default 0)
          --to <time>             end (default: end of file)
          --silence               strip leading/trailing silence instead
          --threshold <db>        silence threshold in dBFS (default -40)
          --min-silence <secs>    minimum silence length (default 0.2)
    """)
    exit(2)
}

func cmdTrim(_ args: [String]) {
    var paths: [String] = []
    var from: Double?
    var to: Double?
    var stripSilence = false
    var threshold = -40.0
    var minSilence = 0.2
    let p = ArgList(args)
    while let a = p.next() {
        switch a {
        case "--from": from = p.timeValue(a)
        case "--to": to = p.timeValue(a)
        case "--silence": stripSilence = true
        case "--threshold": threshold = p.doubleValue(a)
        case "--min-silence": minSilence = p.doubleValue(a)
        case "-h", "--help": trimUsage()
        default:
            if a.hasPrefix("-") { fail("trim: unknown option \(a)", code: 2) }
            paths.append(a)
        }
    }
    guard paths.count == 2 else { trimUsage() }
    if !stripSilence && from == nil && to == nil { trimUsage() }
    let (inPath, outPath) = (paths[0], paths[1])

    let src = openInput(inPath)
    let sr = src.processingFormat.sampleRate
    let total = Double(src.length) / sr

    var startT = from ?? 0
    var endT = to ?? total
    if stripSilence {
        let sil = detectSilences(src, thresholdDB: threshold, minDuration: minSilence)
        if let first = sil.first, first.start <= 0.05 { startT = first.end }
        if let last = sil.last, last.end >= total - 0.05 { endT = last.start }
    }
    guard endT > startT else { fail("empty range: \(prettyTime(startT)) - \(prettyTime(endT))") }

    let out = OutputFile(outPath)
    var writer: AVAudioFile? = makeWriter(out, format: src.processingFormat)
    copyFrames(src, from: AVAudioFramePosition(startT * sr), to: AVAudioFramePosition(endT * sr), into: writer!)
    writer = nil
    out.finalize()
    errPrint("\(programName): wrote \(outPath) (\(prettyTime(startT)) - \(prettyTime(endT)), \(String(format: "%.2f", endT - startT))s)")
}
