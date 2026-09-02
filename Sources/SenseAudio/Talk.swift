import AVFoundation
import Foundation

// Ported from mactalk (Daily/20260826/mactalk) — same behavior, new home.

private func talkUsage() -> Never {
    errPrint("""
    usage: sense audio talk [options] "words go here"     (alias: sense audio say)
           echo "words" | sense audio talk [options]

    options:
      -v, --voice <name|identifier|lang>  voice (default: best premium voice for locale)
      -o, --output <file>                 write audio instead of playing
                                          (.wav .caf .aiff .m4a natively; .mp3 via lame/ffmpeg)
      -r, --rate <0.0-1.0>                speech rate (default \(AVSpeechUtteranceDefaultSpeechRate))
      -p, --pitch <0.5-2.0>               pitch multiplier (default 1.0)
      -f, --file <path>                   read text from a file (.md/.markdown implies -m)
      -m, --markdown                      treat input as Markdown: strip syntax, add pauses
          --ssml                          treat input as raw SSML (<speak>...</speak>);
                                          .ssml/.xml files imply this
          --dump-ssml                     print the generated SSML instead of speaking
      -l, --list-voices                   list installed voices (best quality first)

    Premium/Enhanced voices are downloaded in:
      System Settings > Accessibility > Spoken Content > System Voice > Manage Voices...
    """)
    exit(2)
}

private struct TalkOpts {
    var voice: String?
    var output: String?
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var pitch: Float = 1.0
    var listVoices = false
    var markdown = false
    var ssml = false
    var dumpSSML = false
    var file: String?
    var text: [String] = []
}

// MARK: - Voices

private func qualityRank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
    switch q {
    case .premium: return 3
    case .enhanced: return 2
    default: return 1
    }
}

private func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
    switch q {
    case .premium: return "premium"
    case .enhanced: return "enhanced"
    default: return "default"
    }
}

private func sortedVoices() -> [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices().sorted {
        let (qa, qb) = (qualityRank($0.quality), qualityRank($1.quality))
        if qa != qb { return qa > qb }
        if $0.language != $1.language { return $0.language < $1.language }
        return $0.name < $1.name
    }
}

private func listVoices() {
    for v in sortedVoices() {
        let personal = v.voiceTraits.contains(.isPersonalVoice) ? " personal" : ""
        print("\(v.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(v.language.padding(toLength: 7, withPad: " ", startingAt: 0)) \(qualityName(v.quality).padding(toLength: 9, withPad: " ", startingAt: 0))\(personal)  \(v.identifier)")
    }
}

private func pickVoice(_ spec: String?) -> AVSpeechSynthesisVoice {
    let voices = sortedVoices()
    guard let spec else {
        let preferred = [Locale.current.identifier.replacingOccurrences(of: "_", with: "-"), "en-US", "en"]
        for lang in preferred {
            let c = voices.filter { $0.language.lowercased().hasPrefix(lang.lowercased()) }
            guard let best = c.first else { continue }
            let top = c.filter { $0.quality == best.quality }
            return top.first(where: { $0.name == "Samantha" }) ?? best
        }
        guard let v = voices.first else { fail("no voices installed") }
        return v
    }
    let s = spec.lowercased()
    if let v = voices.first(where: { $0.identifier.lowercased() == s }) { return v }
    if let v = voices.first(where: { $0.name.lowercased() == s }) { return v }
    if let v = voices.first(where: { $0.name.lowercased().hasPrefix(s) }) { return v }
    if let v = voices.first(where: { $0.language.lowercased() == s }) { return v }
    if let v = voices.first(where: { $0.language.lowercased().hasPrefix(s) }) { return v }
    if let v = voices.first(where: { $0.identifier.lowercased().contains(s) }) { return v }
    fail("voice not found: \(spec) (try `sense audio talk -l`)")
}

// MARK: - Synthesis

private final class Done: NSObject, AVSpeechSynthesizerDelegate {
    var finished = false
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finished = true }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { finished = true }
}

private func makeUtterance(_ text: String, _ o: TalkOpts, _ voice: AVSpeechSynthesisVoice) -> AVSpeechUtterance {
    var u: AVSpeechUtterance
    if o.ssml {
        // Apple's SSML parser SIGSEGVs (macOS 15.7) on these tags; refuse up front.
        if let m = text.range(of: #"<(p|s|emphasis)(\s[^>]*)?/?>"#, options: .regularExpression) {
            fail("SSML tag \(text[m]) crashes Apple's synthesizer; use <break>/<prosody> instead (safe: break, prosody, phoneme, say-as)")
        }
        guard let parsed = AVSpeechUtterance(ssmlRepresentation: text) else {
            fail("SSML rejected by the synthesizer (check it is well-formed and wrapped in <speak>; avoid <p>/<s>)")
        }
        u = parsed
    } else if o.markdown, let ssml = AVSpeechUtterance(ssmlRepresentation: Markdown.toSSML(text)) {
        u = ssml
    } else {
        if o.markdown { errPrint("\(programName): SSML rejected, falling back to plain text") }
        u = AVSpeechUtterance(string: o.markdown ? Markdown.inline(text) : text)
    }
    u.voice = voice
    u.rate = o.rate
    u.pitchMultiplier = o.pitch
    return u
}

private func speak(_ u: AVSpeechUtterance) {
    let synth = AVSpeechSynthesizer()
    let d = Done()
    synth.delegate = d
    installSigint()
    synth.speak(u)
    while !d.finished && gInterrupted == 0 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    if !d.finished { synth.stopSpeaking(at: .immediate) }
}

private func render(_ u: AVSpeechUtterance, to path: String) {
    let out = OutputFile(path)
    let synth = AVSpeechSynthesizer()
    var file: AVAudioFile?
    var finished = false
    var writeErr: Error?

    synth.write(u) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 { finished = true; return }
        if file == nil {
            guard let settings = fileSettings(ext: out.writeExt, sampleRate: pcm.format.sampleRate,
                                              channels: pcm.format.channelCount) else {
                writeErr = NSError(domain: programName, code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "unsupported output extension .\(pathExt(path)) (use wav/caf/aiff/m4a/flac/mp3)",
                ])
                finished = true
                return
            }
            do {
                file = try AVAudioFile(forWriting: URL(fileURLWithPath: out.writePath), settings: settings,
                                       commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
            } catch { writeErr = error; finished = true; return }
        }
        do { try file?.write(from: pcm) } catch { writeErr = error; finished = true }
    }
    while !finished {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    file = nil // close
    if let writeErr { fail("writing \(path): \(writeErr.localizedDescription)") }
    out.finalize()
}

// MARK: - Command

func cmdTalk(_ args: [String]) {
    var o = TalkOpts()
    let p = ArgList(args)
    while let a = p.next() {
        switch a {
        case "-v", "--voice": o.voice = p.value(a)
        case "-o", "--output": o.output = p.value(a)
        case "-r", "--rate": o.rate = Float(p.doubleValue(a))
        case "-p", "--pitch": o.pitch = Float(p.doubleValue(a))
        case "-f", "--file": o.file = p.value(a)
        case "-m", "--markdown": o.markdown = true
        case "--ssml": o.ssml = true
        case "--dump-ssml": o.dumpSSML = true
        case "-l", "--list-voices": o.listVoices = true
        case "-h", "--help": talkUsage()
        case "--": while let rest = p.next() { o.text.append(rest) }
        default:
            if a.hasPrefix("-") && a.count > 1 { fail("talk: unknown option \(a)", code: 2) }
            o.text.append(a)
        }
    }

    if o.listVoices { listVoices(); return }

    var text = o.text.joined(separator: " ")
    if let f = o.file {
        guard let d = FileManager.default.contents(atPath: f), let s = String(data: d, encoding: .utf8) else {
            fail("cannot read \(f)")
        }
        text = s
        let ext = pathExt(f)
        if ext == "md" || ext == "markdown" { o.markdown = true }
        if ext == "ssml" || ext == "xml" { o.ssml = true }
    }
    if text.isEmpty, isatty(STDIN_FILENO) == 0 {
        text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { talkUsage() }
    if o.dumpSSML { print(o.ssml ? text : Markdown.toSSML(text)); return }

    let voice = pickVoice(o.voice)
    let u = makeUtterance(text, o, voice)
    if let out = o.output {
        render(u, to: out)
        errPrint("\(programName): wrote \(out) [\(voice.name), \(qualityName(voice.quality))]")
    } else {
        speak(u)
    }
}
