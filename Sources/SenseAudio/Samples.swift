import AVFoundation
import Foundation

// `sense audio samples` — synthesize the same passage in several voices and
// write one self-contained HTML page with the audio inlined as base64 data
// URIs, so it can be opened straight from disk with no server and no sidecar
// files.
//
// This exists because the premium-vs-default difference has to be *heard*. A
// page you generate locally does that; hosting the clips would not be allowed
// (macOS SLA §F permits System Voice output for personal, non-commercial use
// only, and explicitly excludes publishing or public sharing). Hence the note
// stamped into every generated page.
//
// Budget: ~12s of speech at 48 kbps AAC is ~70 KB, ~95 KB once base64'd, so a
// two-voice comparison lands around 200 KB. Base64 costs 4 bytes per 3.

private let defaultPassage = """
The quarterly figures came in at four point two million, up eleven percent. \
Should we tell the board today, or wait until Thursday? Honestly — I'd wait. \
The numbers are good, but the story isn't finished yet.
"""

private func samplesUsage() -> Never {
    errPrint("""
    usage: sense audio samples [options]

    Synthesizes the same passage in several voices and writes a self-contained
    HTML page with inline players — the fastest way to hear what premium voices
    actually sound like next to the default ones.

    options:
      -o, --output <file>   output path (default: samples-<rand>.html)
          --text <words>    passage to speak (default: a prosody-heavy sample)
      -f, --file <path>     read the passage from a file
          --voices <list>   comma-separated voice names (default: best premium
                            and best default for your locale)
          --lang <prefix>   pick the default pair for this language, e.g. en-GB
          --bitrate <bps>   AAC bitrate for the embedded audio (default 48000,
                            16000-64000; the synthesizer is mono 22.05 kHz)
          --open            open the page when it is written

    The page is for your own listening. Apple licenses the system voices for
    personal, non-commercial use — do not publish the audio it contains.
    """)
    exit(2)
}

private struct SampleOpts {
    var output: String?
    var text: String?
    var file: String?
    var voices: [String] = []
    var lang: String?
    var bitrate = 48000
    var open = false
}

/// Best premium/enhanced voice and best default voice for a language, so the
/// page is an A/B rather than a list. Either may be missing.
private func comparisonVoices(lang: String) -> [AVSpeechSynthesisVoice] {
    let inLang = sortedVoices().filter { $0.language.lowercased().hasPrefix(lang.lowercased()) }
    let good = inLang.first { qualityRank($0.quality) >= 2 }
    let plain = inLang.first { qualityRank($0.quality) == 1 }
    return [good, plain].compactMap { $0 }
}

func cmdSamples(_ argv: [String]) {
    var o = SampleOpts()
    let p = ArgList(argv)
    while let a = p.next() {
        switch a {
        case "-o", "--output": o.output = p.value(a)
        case "--text": o.text = p.value(a)
        case "-f", "--file": o.file = p.value(a)
        case "--voices": o.voices = p.value(a).split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        case "--lang": o.lang = p.value(a)
        case "--bitrate": o.bitrate = Int(p.doubleValue(a))
        case "--open": o.open = true
        case "-h", "--help": samplesUsage()
        default: fail("samples: unknown option \(a)", code: 2)
        }
    }

    var passage = o.text ?? defaultPassage
    if let f = o.file {
        guard let d = FileManager.default.contents(atPath: f), let s = String(data: d, encoding: .utf8) else {
            fail("cannot read \(f)")
        }
        passage = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !passage.isEmpty else { fail("nothing to speak", code: 2) }

    // The synthesizer emits mono at 22.05 kHz, and AAC only accepts roughly
    // 16k-64k for that format — outside it the encoder fails with a bare
    // CoreAudio error code rather than anything actionable. Measured on macOS
    // 15: 12000 and 72000 both fail, 16000 and 64000 both work.
    let maxBitrate = 64000, minBitrate = 16000
    if o.bitrate > maxBitrate {
        errPrint("\(programName): \(o.bitrate) bps exceeds what AAC accepts for mono 22.05 kHz; using \(maxBitrate)")
        o.bitrate = maxBitrate
    } else if o.bitrate < minBitrate {
        errPrint("\(programName): \(o.bitrate) bps is below the AAC floor for mono 22.05 kHz; using \(minBitrate)")
        o.bitrate = minBitrate
    }

    let lang = o.lang ?? currentLanguage()
    var voices: [AVSpeechSynthesisVoice]
    if o.voices.isEmpty {
        voices = comparisonVoices(lang: lang)
        if voices.isEmpty { voices = comparisonVoices(lang: String(lang.prefix(2))) }
        guard !voices.isEmpty else { fail("no voices installed for \(lang)") }
    } else {
        voices = o.voices.map { name in
            guard let v = sortedVoices().first(where: { $0.name.lowercased() == name.lowercased() })
                ?? sortedVoices().first(where: { $0.name.lowercased().hasPrefix(name.lowercased()) })
            else { fail("voice not found: \(name) (try `sense audio voices`)") }
            return v
        }
    }

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("sense-samples-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    var blocks: [String] = []
    for v in voices {
        errPrint("synthesizing \(v.name) [\(qualityName(v.quality))]…")
        let path = tmp.appendingPathComponent("\(v.identifier).m4a").path
        var t = TalkOpts()
        t.voice = v.name
        render(makeUtterance(passage, t, v), to: path, bitrate: o.bitrate)
        guard let data = FileManager.default.contents(atPath: path) else {
            fail("could not read synthesized audio for \(v.name)")
        }
        blocks.append(playerHTML(voice: v, base64: data.base64EncodedString(), bytes: data.count))
    }

    let out = o.output ?? "samples-\(String(UUID().uuidString.prefix(6)).lowercased()).html"
    let html = pageHTML(passage: passage, blocks: blocks)
    do {
        try html.write(toFile: out, atomically: true, encoding: .utf8)
    } catch {
        fail("writing \(out): \(error.localizedDescription)")
    }

    let kb = (html.utf8.count + 512) / 1024
    errPrint("wrote \(out) (\(kb) KB, \(voices.count) voice\(voices.count == 1 ? "" : "s"), self-contained)")
    if qualityRank(voices.first?.quality ?? .default) < 2 {
        premiumHintIfNeeded(language: lang)
    }
    if o.open {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [out]
        try? p.run()
        p.waitUntilExit()
    }
}

private func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func playerHTML(voice: AVSpeechSynthesisVoice, base64: String, bytes: Int) -> String {
    let q = qualityName(voice.quality)
    return """
        <div class="v">
          <div class="h"><b>\(esc(voice.name))</b><span class="q \(q)">\(q)</span>
            <span class="m">\(esc(voice.language)) · \((bytes + 512) / 1024) KB</span></div>
          <audio controls preload="metadata" src="data:audio/mp4;base64,\(base64)"></audio>
        </div>
    """
}

private func pageHTML(passage: String, blocks: [String]) -> String {
    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>sense — voice samples</title>
    <style>
      :root { color-scheme: light dark }
      body { font: 15px/1.6 -apple-system, system-ui, sans-serif; max-width: 40rem;
             margin: 3rem auto; padding: 0 1.25rem }
      h1 { font-size: 1.3rem; margin: 0 0 .25rem }
      .sub { color: #888; margin: 0 0 2rem }
      blockquote { margin: 0 0 2rem; padding: .75rem 1rem; border-left: 3px solid #8884;
                   background: #8881; border-radius: 0 4px 4px 0 }
      .v { margin: 0 0 1.5rem }
      .h { display: flex; align-items: baseline; gap: .5rem; margin-bottom: .4rem }
      .q { font-size: 11px; text-transform: uppercase; letter-spacing: .04em;
           padding: 1px 6px; border-radius: 3px; background: #8883 }
      .q.premium { background: #2e7d32; color: #fff }
      .q.enhanced { background: #1565c0; color: #fff }
      .m { color: #888; font-size: 12px; margin-left: auto }
      audio { width: 100% }
      footer { margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #8883;
               color: #888; font-size: 12.5px }
      code { font-family: ui-monospace, Menlo, monospace; font-size: 12.5px }
    </style></head><body>
    <h1>Voice samples</h1>
    <p class="sub">Same passage, different voices. Listen for the question at the end of
    the second sentence and the pause after &ldquo;Honestly&rdquo; — that is where premium
    voices pull away.</p>
    <blockquote>\(esc(passage))</blockquote>
    \(blocks.joined(separator: "\n"))
    <footer>
      Generated by <code>sense audio samples</code> — everything above was synthesized
      on this machine and is embedded in this file, which needs no network to play.
      Get more voices with <code>sense audio voices --install</code>.
      <br><br>
      Apple licenses the macOS system voices for personal, non-commercial use.
      Keep this page to yourself: do not publish or redistribute the audio in it.
    </footer>
    </body></html>
    """
}
