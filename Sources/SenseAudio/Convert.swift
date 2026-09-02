import AVFoundation
import Foundation

private func convertUsage() -> Never {
    errPrint("""
    usage: sense audio convert <in> <out> [options]
      output format from <out> extension: wav aiff caf m4a aac flac mp3

    options:
      -r, --rate <hz>        resample
      -c, --channels <n>     remix channel count
      -b, --bitrate <bps>    encoder bitrate for aac/m4a (e.g. 128000 or 128k)
    """)
    exit(2)
}

private func parseBitrate(_ s: String) -> Int? {
    if s.lowercased().hasSuffix("k"), let v = Int(s.dropLast()) { return v * 1000 }
    return Int(s)
}

func cmdConvert(_ args: [String]) {
    var paths: [String] = []
    var rate: Double?
    var channels: AVAudioChannelCount?
    var bitrate: Int?
    let p = ArgList(args)
    while let a = p.next() {
        switch a {
        case "-r", "--rate": rate = p.doubleValue(a)
        case "-c", "--channels": channels = AVAudioChannelCount(p.intValue(a))
        case "-b", "--bitrate":
            let v = p.value(a)
            guard let b = parseBitrate(v) else { fail("convert: bad bitrate '\(v)'", code: 2) }
            bitrate = b
        case "-h", "--help": convertUsage()
        default:
            if a.hasPrefix("-") && a != "-" { fail("convert: unknown option \(a)", code: 2) }
            paths.append(a)
        }
    }
    guard paths.count == 2 else { convertUsage() }
    let (inPath, outPath) = (paths[0], paths[1])

    let src = openInput(inPath)
    let srcFmt = src.processingFormat
    let dstRate = rate ?? srcFmt.sampleRate
    let dstCh = channels ?? srcFmt.channelCount

    var converter: AVAudioConverter?
    var procFmt = srcFmt
    if dstRate != srcFmt.sampleRate || dstCh != srcFmt.channelCount {
        guard let t = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: dstRate,
                                    channels: dstCh, interleaved: false) else { fail("bad target format") }
        procFmt = t
        converter = AVAudioConverter(from: srcFmt, to: t)
        guard converter != nil else { fail("cannot convert to \(Int(dstRate)) Hz/\(dstCh)ch") }
    }

    let out = OutputFile(outPath)
    var writer: AVAudioFile? = makeWriter(out, format: procFmt, bitrate: bitrate)

    guard let buf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: 65536) else { fail("buffer allocation failed") }
    while readChunk(src, into: buf) {
        let outBuf = converter.flatMap { convertPCM($0, buf, to: procFmt) } ?? (converter == nil ? buf : nil)
        if let outBuf {
            do { try writer!.write(from: outBuf) } catch { fail("write failed: \(error.localizedDescription)") }
        }
    }
    if let c = converter {
        while let tail = convertPCM(c, nil, to: procFmt) {
            do { try writer!.write(from: tail) } catch { fail("write failed: \(error.localizedDescription)") }
        }
    }
    writer = nil // close
    out.finalize()

    let secs = Double(src.length) / srcFmt.sampleRate
    errPrint("\(programName): wrote \(outPath) (\(String(format: "%.1f", secs))s, \(Int(dstRate)) Hz, \(dstCh) ch)")
}
