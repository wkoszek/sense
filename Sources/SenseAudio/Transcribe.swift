import AVFoundation
import Foundation
import SenseCore
import Speech

private func transcribeUsage() -> Never {
    errPrint("""
    usage: sense audio transcribe [options]          # live from microphone (Ctrl-C to finish)
           sense audio transcribe <file> [options]   # any format CoreAudio reads (wav/m4a/mp3/...)
           sense audio transcribe - [options]        # audio piped on stdin (e.g. from `sense audio record`)

    options:
          --lang <bcp47>      language, e.g. en-US, pl-PL (default: system locale)
          --json              text + word segments with timestamps and confidence
          --srt / --vtt       subtitle output with timestamps
          --engine <name>     'apple' (default; on-device)
          --allow-network     permit Apple-server recognition if no on-device model
    """)
    exit(2)
}

private enum TransFormat { case text, json, srt, vtt }

private struct TransOpts {
    var input: String?
    var lang: String?
    var format = TransFormat.text
    var engine = "apple"
    var allowNetwork = false
}

func cmdTranscribe(_ args: [String]) {
    var o = TransOpts()
    let p = ArgList(args)
    while let a = p.next() {
        switch a {
        case "--lang": o.lang = p.value(a)
        case "--json": o.format = .json
        case "--srt": o.format = .srt
        case "--vtt": o.format = .vtt
        case "--engine": o.engine = p.value(a)
        case "--allow-network": o.allowNetwork = true
        case "-h", "--help": transcribeUsage()
        case "-": o.input = "-"
        default:
            if a.hasPrefix("-") { fail("transcribe: unknown option \(a)", code: 2) }
            if o.input != nil { fail("transcribe: only one input file", code: 2) }
            o.input = a
        }
    }
    guard o.engine == "apple" else { fail("engine '\(o.engine)' not implemented (only 'apple' for now)") }

    // Disclaiming makes this binary its own TCC subject, which is what lets an
    // unbundled CLI answer the Speech Recognition prompt. But TCC will not
    // store a *Microphone* grant for a bare path — every microphone and camera
    // entry in the database belongs to a real app bundle, and there is no
    // client_type=1 row for either service. So a disclaimed `sense` shows the
    // mic dialog, the user clicks Allow, nothing persists, and requestAccess
    // returns false forever.
    //
    // Live capture therefore stays attributed to the terminal, which is a
    // bundle and can hold a mic grant. Only the file and stdin paths — which
    // need Speech but never the microphone — disclaim.
    let usesMicrophone = o.input == nil
    if !usesMicrophone { reexecDisclaimedIfNeeded() }
    ensureSpeechAccess()
    let localeID = o.lang ?? Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    guard let rec = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
        fail("no speech recognizer for locale \(localeID)")
    }
    guard rec.isAvailable else { fail("speech recognizer for \(localeID) is not available") }
    if !rec.supportsOnDeviceRecognition && !o.allowNetwork {
        fail("""
        no on-device model for \(localeID); this tool is local-only by default.
        Pass --allow-network to let Apple's servers transcribe, or add the language in
        System Settings > Keyboard > Dictation to get the on-device model.
        """)
    }

    if let input = o.input {
        transcribeFile(rec, input: input, o)
    } else {
        transcribeMic(rec, o)
    }
}

private func ensureSpeechAccess() {
    var status = SFSpeechRecognizer.authorizationStatus()
    if status == .notDetermined {
        errPrint("\(programName): waiting for the Speech Recognition permission dialog (click Allow)…")
        let sema = DispatchSemaphore(value: 0)
        SFSpeechRecognizer.requestAuthorization { s in status = s; sema.signal() }
        sema.wait()
    }
    guard status == .authorized else {
        fail("speech recognition access denied (System Settings > Privacy & Security > Speech Recognition)", code: 3)
    }
}

private func configure(_ req: SFSpeechRecognitionRequest, _ rec: SFSpeechRecognizer, _ o: TransOpts) {
    if rec.supportsOnDeviceRecognition {
        req.requiresOnDeviceRecognition = true
    }
    req.taskHint = .dictation
    if #available(macOS 13.0, *) { req.addsPunctuation = true }
}

// MARK: - File / stdin

private func transcribeFile(_ rec: SFSpeechRecognizer, input: String, _ o: TransOpts) {
    var path = input
    var cleanup: String?
    if input == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { fail("no data on stdin") }
        path = tempFilePath(ext: "wav")
        FileManager.default.createFile(atPath: path, contents: data)
        cleanup = path
    }
    defer { if let c = cleanup { try? FileManager.default.removeItem(atPath: c) } }
    guard FileManager.default.fileExists(atPath: path) else { fail("no such file: \(path)") }

    let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
    req.shouldReportPartialResults = false
    configure(req, rec, o)

    var final: SFSpeechRecognitionResult?
    var taskErr: Error?
    var done = false
    let task = rec.recognitionTask(with: req) { result, error in
        if let r = result, r.isFinal { final = r; done = true }
        if let e = error { taskErr = e; done = true }
    }
    installSigint()
    while !done && gInterrupted == 0 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    if gInterrupted != 0 && !done { task.cancel(); exit(130) }
    if final == nil, let e = taskErr {
        fail("recognition failed: \((e as NSError).localizedDescription)")
    }
    guard let final else { fail("no transcription produced") }
    emit(final.bestTranscription, o)
}

// MARK: - Microphone

private func transcribeMic(_ rec: SFSpeechRecognizer, _ o: TransOpts) {
    ensureMicAccess()
    installSigint()

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let native = input.inputFormat(forBus: 0)
    guard native.sampleRate > 0, native.channelCount > 0 else { fail("no input device available") }

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    configure(req, rec, o)

    var final: SFSpeechRecognitionResult?
    var taskErr: Error?
    var done = false
    _ = rec.recognitionTask(with: req) { result, error in
        if let r = result {
            if r.isFinal {
                final = r
                done = true
            } else {
                let t = r.bestTranscription.formattedString
                let shown = t.count > 76 ? "…" + t.suffix(75) : t
                errWrite("\r\u{1B}[K" + shown)
            }
        }
        if let e = error { taskErr = e; done = true }
    }

    input.installTap(onBus: 0, bufferSize: 4096, format: native) { buf, _ in
        req.append(buf)
    }
    engine.prepare()
    do { try engine.start() } catch { fail("cannot start audio engine: \(error.localizedDescription)") }
    errPrint("listening (\(rec.locale.identifier)) — Ctrl-C to finish")

    while !done && gInterrupted == 0 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    input.removeTap(onBus: 0)
    engine.stop()
    if !done {
        req.endAudio()
        let deadline = Date().addingTimeInterval(10)
        while !done && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
    errWrite("\r\u{1B}[K")
    if let final {
        emit(final.bestTranscription, o)
    } else if let e = taskErr {
        let ns = e as NSError
        // "No speech detected" and cancellation are normal ends for a live session.
        if ns.code == 1110 || ns.code == 216 || ns.code == 301 { errPrint("\(programName): no speech detected") ; exit(1) }
        fail("recognition failed: \(ns.localizedDescription)")
    } else {
        fail("no transcription produced")
    }
}

// MARK: - Output

private func emit(_ t: SFTranscription, _ o: TransOpts) {
    switch o.format {
    case .text:
        print(t.formattedString)
    case .json:
        printJSON([
            "text": t.formattedString,
            "segments": t.segments.map { s -> [String: Any] in
                [
                    "start": s.timestamp,
                    "duration": s.duration,
                    "text": s.substring,
                    "confidence": s.confidence,
                ]
            },
        ])
    case .srt, .vtt:
        let cues = makeCues(t)
        if cues.isEmpty || cues.allSatisfy({ $0.end == 0 }) {
            errPrint("\(programName): warning: recognizer returned no usable timestamps; falling back to plain text")
            print(t.formattedString)
            return
        }
        let sep = o.format == .srt ? "," : "."
        if o.format == .vtt { print("WEBVTT\n") }
        for (i, c) in cues.enumerated() {
            if o.format == .srt { print(i + 1) }
            print("\(hms(c.start, sep: sep)) --> \(hms(c.end, sep: sep))")
            print(c.words.joined(separator: " "))
            print("")
        }
    }
}

private struct Cue {
    var start: Double
    var end: Double
    var words: [String]
}

private func makeCues(_ t: SFTranscription) -> [Cue] {
    var cues: [Cue] = []
    var cur: Cue?
    for s in t.segments {
        let end = s.timestamp + s.duration
        if var c = cur {
            let tooLong = end - c.start > 4.5 || c.words.count >= 10
            if tooLong {
                cues.append(c)
                cur = Cue(start: s.timestamp, end: end, words: [s.substring])
            } else {
                c.end = max(c.end, end)
                c.words.append(s.substring)
                cur = c
            }
        } else {
            cur = Cue(start: s.timestamp, end: end, words: [s.substring])
        }
    }
    if let c = cur { cues.append(c) }
    return cues
}
