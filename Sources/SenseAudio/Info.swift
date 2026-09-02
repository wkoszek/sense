import AudioToolbox
import AVFoundation
import Foundation

private func infoUsage() -> Never {
    errPrint("""
    usage: sense audio info <file> [options]
      --json                  machine-readable output
      --silences              also print detected silence ranges
      --threshold <db>        silence threshold in dBFS (default -40)
      --min-silence <secs>    minimum silence length to report (default 0.4)
    """)
    exit(2)
}

private func fourCC(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
        return String(bytes: bytes, encoding: .ascii) ?? String(v)
    }
    return String(v)
}

private func formatName(_ id: UInt32) -> String {
    switch id {
    case kAudioFormatLinearPCM: return "PCM"
    case kAudioFormatMPEG4AAC: return "AAC"
    case kAudioFormatMPEGLayer3: return "MP3"
    case kAudioFormatAppleLossless: return "Apple Lossless"
    case kAudioFormatFLAC: return "FLAC"
    case kAudioFormatOpus: return "Opus"
    case kAudioFormatAppleIMA4: return "IMA4"
    default: return fourCC(id)
    }
}

func cmdInfo(_ args: [String]) {
    var path: String?
    var json = false
    var silences = false
    var threshold = -40.0
    var minSilence = 0.4
    let p = ArgList(args)
    while let a = p.next() {
        switch a {
        case "--json": json = true
        case "--silences": silences = true
        case "--threshold": threshold = p.doubleValue(a)
        case "--min-silence": minSilence = p.doubleValue(a)
        case "-h", "--help": infoUsage()
        default:
            if a.hasPrefix("-") { fail("info: unknown option \(a)", code: 2) }
            if path != nil { fail("info: only one file", code: 2) }
            path = a
        }
    }
    guard let path else { infoUsage() }
    let url = URL(fileURLWithPath: path)

    var af: AudioFileID?
    guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &af) == noErr, let af else {
        fail("cannot open \(path)")
    }
    defer { AudioFileClose(af) }

    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    AudioFileGetProperty(af, kAudioFilePropertyDataFormat, &size, &asbd)

    var duration: Float64 = 0
    size = UInt32(MemoryLayout<Float64>.size)
    AudioFileGetProperty(af, kAudioFilePropertyEstimatedDuration, &size, &duration)

    var bitRate: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    AudioFileGetProperty(af, kAudioFilePropertyBitRate, &size, &bitRate)

    var infoDict: CFDictionary?
    size = UInt32(MemoryLayout<CFDictionary?>.size)
    _ = withUnsafeMutablePointer(to: &infoDict) { ptr in
        AudioFileGetProperty(af, kAudioFilePropertyInfoDictionary, &size, ptr)
    }
    let tags = (infoDict as? [String: Any]) ?? [:]

    let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil

    var silenceRanges: [Silence] = []
    if silences {
        silenceRanges = detectSilences(openInput(path), thresholdDB: threshold, minDuration: minSilence)
    }

    if json {
        var obj: [String: Any] = [
            "file": path,
            "format": formatName(asbd.mFormatID),
            "format_id": fourCC(asbd.mFormatID),
            "duration": duration,
            "sample_rate": asbd.mSampleRate,
            "channels": Int(asbd.mChannelsPerFrame),
            "bit_rate": Int(bitRate),
            "tags": tags.mapValues { "\($0)" },
        ]
        if asbd.mBitsPerChannel > 0 { obj["bits_per_sample"] = Int(asbd.mBitsPerChannel) }
        if let fs = fileSize { obj["file_size"] = fs }
        if silences {
            obj["silences"] = silenceRanges.map { ["start": $0.start, "end": $0.end, "duration": $0.duration] }
        }
        printJSON(obj)
        return
    }

    print("file:        \(path)")
    print("format:      \(formatName(asbd.mFormatID))")
    print("duration:    \(String(format: "%.2f", duration)) s (\(prettyTime(duration)))")
    print("sample rate: \(Int(asbd.mSampleRate)) Hz")
    print("channels:    \(asbd.mChannelsPerFrame)")
    if asbd.mBitsPerChannel > 0 { print("bits:        \(asbd.mBitsPerChannel)") }
    if bitRate > 0 { print("bit rate:    \(bitRate) b/s") }
    if let fs = fileSize { print("file size:   \(fs) bytes") }
    if !tags.isEmpty {
        print("tags:")
        for (k, v) in tags.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
    }
    if silences {
        if silenceRanges.isEmpty {
            print("silences:    none (threshold \(threshold) dB, min \(minSilence)s)")
        } else {
            print("silences (threshold \(threshold) dB, min \(minSilence)s):")
            for s in silenceRanges {
                print("  \(prettyTime(s.start)) - \(prettyTime(s.end))  (\(String(format: "%.2f", s.duration))s)")
            }
        }
    }
}
