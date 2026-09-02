import AVFoundation
import Foundation

private func gainUsage() -> Never {
    errPrint("""
    usage: sense audio gain <in> <out> --normalize [--db <dbfs>]
           sense audio gain <in> <out> --db <delta>

      --normalize        scale so the peak hits the target (default -1 dBFS)
      --db <n>           with --normalize: target peak in dBFS (e.g. -3)
                         alone: plain gain change in dB (e.g. -6 or +4)
    """)
    exit(2)
}

func cmdGain(_ args: [String]) {
    var paths: [String] = []
    var normalize = false
    var db: Double?
    let p = ArgList(args)
    while let a = p.next() {
        switch a {
        case "--normalize": normalize = true
        case "--db": db = p.doubleValue(a)
        case "-h", "--help": gainUsage()
        default:
            if a.hasPrefix("-") && Double(a) == nil { fail("gain: unknown option \(a)", code: 2) }
            paths.append(a)
        }
    }
    guard paths.count == 2, normalize || db != nil else { gainUsage() }
    let (inPath, outPath) = (paths[0], paths[1])

    let src = openInput(inPath)
    let fmt = src.processingFormat
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 65536) else { fail("buffer allocation failed") }

    var scale: Float
    if normalize {
        var peak: Float = 0
        while readChunk(src, into: buf) {
            guard let ch = buf.floatChannelData else { fail("unexpected buffer format") }
            for c in 0..<Int(fmt.channelCount) {
                let ptr = ch[c]
                for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ptr[i])) }
            }
        }
        guard peak > 0 else { fail("input is pure silence; nothing to normalize") }
        let target = pow(10, Float(db ?? -1) / 20)
        scale = target / peak
        src.framePosition = 0
    } else {
        scale = pow(10, Float(db!) / 20)
    }

    let out = OutputFile(outPath)
    var writer: AVAudioFile? = makeWriter(out, format: fmt)
    var clipped = 0
    while readChunk(src, into: buf) {
        guard let ch = buf.floatChannelData else { fail("unexpected buffer format") }
        for c in 0..<Int(fmt.channelCount) {
            let ptr = ch[c]
            for i in 0..<Int(buf.frameLength) {
                var v = ptr[i] * scale
                if v > 1 { v = 1; clipped += 1 } else if v < -1 { v = -1; clipped += 1 }
                ptr[i] = v
            }
        }
        do { try writer!.write(from: buf) } catch { fail("write failed: \(error.localizedDescription)") }
    }
    writer = nil
    out.finalize()
    if clipped > 0 { errPrint("\(programName): warning: \(clipped) samples clipped") }
    errPrint("\(programName): wrote \(outPath) (gain \(String(format: "%+.1f", 20 * log10(Double(scale)))) dB)")
}
