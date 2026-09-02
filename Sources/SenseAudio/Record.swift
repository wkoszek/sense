import AudioToolbox
import AVFoundation
import Foundation

private func recordUsage() -> Never {
    errPrint("""
    usage: sense audio record [options]              # WAV stream to stdout until Ctrl-C
           sense audio record -o out.wav [options]   # write file (wav/aiff/caf/m4a/flac/mp3)

    options:
      -o, --output <file>       write to file instead of stdout
      -d, --duration <time>     stop after this long (seconds or mm:ss)
          --device <name>       input device (see `sense audio devices`)
      -r, --rate <hz>           sample rate (default: device native)
      -c, --channels <n>        channel count (default: device native)
          --level               live level meter on stderr while recording
          --vad <seconds>       stop after this many seconds of silence
          --vad-threshold <db>  silence threshold for --vad (default -40)
    """)
    exit(2)
}

private struct RecordOpts {
    var output: String?
    var device: String?
    var duration: Double?
    var rate: Double?
    var channels: AVAudioChannelCount?
    var level = false
    var vad: Double?
    var vadThreshold = -40.0
}

func cmdRecord(_ args: [String]) {
    var o = RecordOpts()
    let p = ArgList(args)
    while let a = p.next() {
        switch a {
        case "-o", "--output": o.output = p.value(a)
        case "--device": o.device = p.value(a)
        case "-d", "--duration": o.duration = p.timeValue(a)
        case "-r", "--rate": o.rate = p.doubleValue(a)
        case "-c", "--channels": o.channels = AVAudioChannelCount(p.intValue(a))
        case "--level": o.level = true
        case "--vad": o.vad = p.doubleValue(a)
        case "--vad-threshold": o.vadThreshold = p.doubleValue(a)
        case "-h", "--help": recordUsage()
        default: fail("record: unknown option \(a)", code: 2)
        }
    }

    let toStdout = o.output == nil
    if toStdout && isatty(STDOUT_FILENO) != 0 {
        fail("refusing to write raw audio to a terminal; redirect (sense audio record > out.wav), pipe, or use -o", code: 2)
    }

    ensureMicAccess()
    installSigint()

    let engine = AVAudioEngine()
    let input = engine.inputNode
    if let spec = o.device {
        guard let devID = findInputDevice(named: spec) else {
            fail("input device not found: \(spec) (see `sense audio devices`)")
        }
        var id = devID
        guard let au = input.audioUnit,
              AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        else { fail("cannot select input device: \(spec)") }
    }

    let native = input.inputFormat(forBus: 0)
    guard native.sampleRate > 0, native.channelCount > 0 else { fail("no input device available") }
    let outRate = o.rate ?? native.sampleRate
    let outCh = o.channels ?? native.channelCount

    // Target format + sink.
    var converter: AVAudioConverter?
    var target = native
    var outFile: AVAudioFile?
    var outSpec: OutputFile?

    if toStdout {
        guard let t = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outRate,
                                    channels: outCh, interleaved: true) else { fail("bad target format") }
        target = t
        converter = AVAudioConverter(from: native, to: t)
        guard converter != nil else { fail("cannot convert \(Int(native.sampleRate)) Hz/\(native.channelCount)ch -> \(Int(outRate)) Hz/\(outCh)ch") }
        FileHandle.standardOutput.write(wavStreamHeader(sampleRate: Int(outRate), channels: Int(outCh), bitsPerSample: 16))
    } else {
        if outRate != native.sampleRate || outCh != native.channelCount {
            guard let t = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate,
                                        channels: outCh, interleaved: false) else { fail("bad target format") }
            target = t
            converter = AVAudioConverter(from: native, to: t)
            guard converter != nil else { fail("cannot convert \(Int(native.sampleRate)) Hz/\(native.channelCount)ch -> \(Int(outRate)) Hz/\(outCh)ch") }
        }
        let spec = OutputFile(o.output!)
        outSpec = spec
        outFile = makeWriter(spec, format: target)
    }

    var framesOut: Int64 = 0
    var lastLoudFrame: Int64 = 0
    var stopRequested = false

    input.installTap(onBus: 0, bufferSize: 4096, format: native) { buf, _ in
        if stopRequested { return }
        var out = buf
        if let conv = converter {
            guard let c = convertPCM(conv, buf, to: target) else { return }
            out = c
        }
        if toStdout {
            FileHandle.standardOutput.write(interleavedInt16Data(out))
        } else if let f = outFile {
            do { try f.write(from: out) } catch { errPrint("\(programName): write failed: \(error.localizedDescription)"); stopRequested = true; return }
        }
        framesOut += Int64(out.frameLength)
        let db = bufferDB(buf)
        if o.level { drawMeter(db) }
        if db >= o.vadThreshold { lastLoudFrame = framesOut }
        if let vad = o.vad, Double(framesOut - lastLoudFrame) / outRate >= vad { stopRequested = true }
        if let d = o.duration, Double(framesOut) / outRate >= d { stopRequested = true }
    }

    engine.prepare()
    do { try engine.start() } catch { fail("cannot start audio engine: \(error.localizedDescription)") }
    if !toStdout {
        errPrint("recording (\(Int(outRate)) Hz, \(outCh) ch) — Ctrl-C to stop")
    }

    while gInterrupted == 0 && !stopRequested {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    stopRequested = true
    input.removeTap(onBus: 0)
    engine.stop()
    if o.level { errWrite("\n") }

    outFile = nil // close the file
    outSpec?.finalize()

    let secs = Double(framesOut) / outRate
    if let path = o.output {
        errPrint("\(programName): wrote \(path) (\(String(format: "%.1f", secs))s, \(Int(outRate)) Hz, \(outCh) ch)")
    }
}
