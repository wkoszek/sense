import AVFoundation
import Foundation

// MARK: - Levels

/// RMS level of channel 0 in dBFS (expects float32 buffers, which taps and
/// AVAudioFile.processingFormat always deliver).
func bufferDB(_ buf: AVAudioPCMBuffer) -> Double {
    guard let data = buf.floatChannelData, buf.frameLength > 0 else { return -120 }
    let n = Int(buf.frameLength)
    var sum = 0.0
    let p = data[0]
    for i in 0..<n {
        let v = Double(p[i])
        sum += v * v
    }
    let rms = (sum / Double(n)).squareRoot()
    return rms > 0 ? 20 * log10(rms) : -120
}

func drawMeter(_ db: Double) {
    let floorDB = -60.0
    let frac = max(0, min(1, (db - floorDB) / -floorDB))
    let width = 30
    let filled = Int(frac * Double(width))
    let bar = String(repeating: "#", count: filled) + String(repeating: " ", count: width - filled)
    errWrite(String(format: "\r[%@] %6.1f dB", bar, max(db, floorDB)))
}

// MARK: - Output files (mp3 via lame/ffmpeg detour)

struct OutputFile {
    let userPath: String
    let writePath: String
    let isMP3: Bool

    init(_ path: String) {
        userPath = path
        isMP3 = pathExt(path) == "mp3"
        writePath = isMP3 ? tempFilePath(ext: "wav") : path
    }

    var writeExt: String { isMP3 ? "wav" : pathExt(userPath) }

    func finalize() {
        if isMP3 {
            encodeMP3(wav: writePath, to: userPath)
            try? FileManager.default.removeItem(atPath: writePath)
        }
    }
}

func fileSettings(ext: String, sampleRate: Double, channels: AVAudioChannelCount, bitrate: Int? = nil) -> [String: Any]? {
    switch ext {
    case "wav", "caf":
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    case "aiff", "aif":
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
    case "m4a", "aac", "mp4":
        var s: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        if let b = bitrate { s[AVEncoderBitRateKey] = b }
        else { s[AVEncoderAudioQualityKey] = AVAudioQuality.max.rawValue }
        return s
    case "flac":
        return [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
    default:
        return nil
    }
}

func makeWriter(_ out: OutputFile, format: AVAudioFormat, bitrate: Int? = nil) -> AVAudioFile {
    guard let settings = fileSettings(ext: out.writeExt, sampleRate: format.sampleRate,
                                      channels: format.channelCount, bitrate: bitrate) else {
        fail("unsupported output extension .\(pathExt(out.userPath)) (use wav/aiff/caf/m4a/flac/mp3)")
    }
    do {
        return try AVAudioFile(forWriting: URL(fileURLWithPath: out.writePath), settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    } catch {
        fail("cannot create \(out.userPath): \(error.localizedDescription)")
    }
}

func openInput(_ path: String) -> AVAudioFile {
    do { return try AVAudioFile(forReading: URL(fileURLWithPath: path)) }
    catch { fail("cannot open \(path): \(error.localizedDescription)") }
}

/// Read the next chunk; returns false at EOF. (AVAudioFile.read throws when
/// framePosition is already at the end instead of returning 0 frames.)
func readChunk(_ file: AVAudioFile, into buf: AVAudioPCMBuffer, frames: AVAudioFrameCount? = nil) -> Bool {
    if file.framePosition >= file.length { return false }
    do {
        if let n = frames { try file.read(into: buf, frameCount: n) }
        else { try file.read(into: buf) }
    } catch { fail("read failed: \(error.localizedDescription)") }
    return buf.frameLength > 0
}

// MARK: - Sample-rate / channel conversion

/// Convert one buffer; pass input=nil to flush the converter's tail.
func convertPCM(_ converter: AVAudioConverter, _ input: AVAudioPCMBuffer?, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / converter.inputFormat.sampleRate
    let inFrames = input.map { Double($0.frameLength) } ?? 0
    let cap = AVAudioFrameCount(inFrames * ratio) + 512
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
    var fed = false
    var convErr: NSError?
    let status = converter.convert(to: out, error: &convErr) { _, st in
        if let input, !fed {
            fed = true
            st.pointee = .haveData
            return input
        }
        st.pointee = input == nil ? .endOfStream : .noDataNow
        return nil
    }
    if status == .error {
        fail("conversion failed: \(convErr?.localizedDescription ?? "unknown error")")
    }
    return out.frameLength > 0 ? out : nil
}

// MARK: - Frame copying (trim/split)

func copyFrames(_ src: AVAudioFile, from: AVAudioFramePosition, to end: AVAudioFramePosition, into dst: AVAudioFile) {
    let fmt = src.processingFormat
    let cap: AVAudioFrameCount = 65536
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { fail("buffer allocation failed") }
    let start = max(0, from)
    let stop = min(end, src.length)
    src.framePosition = start
    var remaining = max(0, stop - start)
    while remaining > 0 {
        let n = AVAudioFrameCount(min(Int64(cap), remaining))
        if !readChunk(src, into: buf, frames: n) { break }
        do { try dst.write(from: buf) }
        catch { fail("write failed: \(error.localizedDescription)") }
        remaining -= Int64(buf.frameLength)
    }
}

// MARK: - Silence detection

struct Silence {
    let start: Double
    let end: Double
    var duration: Double { end - start }
}

func detectSilences(_ file: AVAudioFile, thresholdDB: Double, minDuration: Double) -> [Silence] {
    let fmt = file.processingFormat
    let win: AVAudioFrameCount = 2048
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: win) else { fail("buffer allocation failed") }
    file.framePosition = 0
    var result: [Silence] = []
    var silStart: Double?
    var pos = 0.0
    while readChunk(file, into: buf, frames: win) {
        let t = pos / fmt.sampleRate
        if bufferDB(buf) < thresholdDB {
            if silStart == nil { silStart = t }
        } else if let s = silStart {
            if t - s >= minDuration { result.append(Silence(start: s, end: t)) }
            silStart = nil
        }
        pos += Double(buf.frameLength)
    }
    if let s = silStart {
        let end = Double(file.length) / fmt.sampleRate
        if end - s >= minDuration { result.append(Silence(start: s, end: end)) }
    }
    file.framePosition = 0
    return result
}

// MARK: - Streaming WAV header (unknown length -> 0xFFFFFFFF sizes)

func wavStreamHeader(sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
    var d = Data()
    func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let blockAlign = channels * bitsPerSample / 8
    str("RIFF"); le32(0xFFFF_FFFF); str("WAVE")
    str("fmt "); le32(16)
    le16(1) // PCM
    le16(UInt16(channels))
    le32(UInt32(sampleRate))
    le32(UInt32(sampleRate * blockAlign)) // byte rate
    le16(UInt16(blockAlign))
    le16(UInt16(bitsPerSample))
    str("data"); le32(0xFFFF_FFFF)
    return d
}

/// Raw bytes of an interleaved int16 buffer.
func interleavedInt16Data(_ buf: AVAudioPCMBuffer) -> Data {
    let bytesPerFrame = Int(buf.format.streamDescription.pointee.mBytesPerFrame)
    let count = Int(buf.frameLength) * bytesPerFrame
    guard count > 0, let p = buf.audioBufferList.pointee.mBuffers.mData else { return Data() }
    return Data(bytes: p, count: count)
}
