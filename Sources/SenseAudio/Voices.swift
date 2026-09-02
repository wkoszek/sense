import AVFoundation
import Foundation

// Voice enumeration and quality, shared by `voices` and `talk`.
//
// Premium voices are the single biggest quality win available here and they are
// a free download, but macOS buries them four levels deep in System Settings and
// nothing tells you they exist. So `voices` says so, and `--install` opens the
// exact pane rather than making anyone follow a breadcrumb trail.

private func voicesUsage() -> Never {
    errPrint("""
    usage: sense audio voices [options]

    options:
          --lang <prefix>     only voices whose language matches, e.g. en, en-GB
          --premium           only premium and enhanced voices
          --json              machine-readable output
          --install           open System Settings where premium voices are downloaded
          --quiet             suppress the summary on stderr

    Premium voices (Ava, Zoe, Serena…) sound dramatically better than the
    default ones and cost nothing. `sense audio voices --install` opens the
    right pane; from there: System voice > (i) > Manage Voices.
    """)
    exit(2)
}

func qualityRank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
    switch q {
    case .premium: return 3
    case .enhanced: return 2
    default: return 1
    }
}

func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
    switch q {
    case .premium: return "premium"
    case .enhanced: return "enhanced"
    default: return "default"
    }
}

func sortedVoices() -> [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices().sorted {
        let (qa, qb) = (qualityRank($0.quality), qualityRank($1.quality))
        if qa != qb { return qa > qb }
        if $0.language != $1.language { return $0.language < $1.language }
        return $0.name < $1.name
    }
}

/// The language we would pick a voice for if the user did not say.
func currentLanguage() -> String {
    Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
}

/// Best quality available for a language prefix, or nil if it has no voices.
func bestQuality(forLanguage prefix: String) -> AVSpeechSynthesisVoiceQuality? {
    sortedVoices().first { $0.language.lowercased().hasPrefix(prefix.lowercased()) }?.quality
}

/// Opens System Settings > Accessibility > Spoken Content, where the voice
/// downloads live. The anchor is undocumented but stable on macOS 13–15; if it
/// ever stops resolving, Settings still opens and the printed path applies.
@discardableResult
func openVoiceSettings() -> Bool {
    let url = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [url]
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// One-line nudge printed when the language we would speak has no good voice.
/// Goes to stderr so it never pollutes piped output.
func premiumHintIfNeeded(language: String? = nil) {
    let lang = language ?? currentLanguage()
    guard let q = bestQuality(forLanguage: lang) ?? bestQuality(forLanguage: String(lang.prefix(2))) else { return }
    guard qualityRank(q) < 3 else { return }
    errPrint("""

    Only \(qualityName(q))-quality voices are installed for \(lang). Premium voices
    sound dramatically better and are a free download:
      sense audio voices --install
    """)
}

private struct VoiceOpts {
    var lang: String?
    var premiumOnly = false
    var json = false
    var install = false
    var quiet = false
}

func cmdVoices(_ argv: [String]) {
    var o = VoiceOpts()
    var i = 0
    while i < argv.count {
        switch argv[i] {
        case "--lang", "-L":
            i += 1
            guard i < argv.count else { fail("--lang needs a value", code: 2) }
            o.lang = argv[i]
        case "--premium": o.premiumOnly = true
        case "--json": o.json = true
        case "--install", "--manage": o.install = true
        case "--quiet", "-q": o.quiet = true
        case "-h", "--help": voicesUsage()
        default: fail("unknown option '\(argv[i])' (see `sense audio voices -h`)", code: 2)
        }
        i += 1
    }

    if o.install {
        errPrint("opening System Settings > Accessibility > Spoken Content…")
        errPrint("from there: System voice > (i) > Manage Voices, then pick any voice marked")
        errPrint("Premium or Enhanced and press the download arrow.")
        guard openVoiceSettings() else {
            fail("could not open System Settings; go to Accessibility > Spoken Content manually")
        }
        return
    }

    var voices = sortedVoices()
    if let lang = o.lang {
        voices = voices.filter { $0.language.lowercased().hasPrefix(lang.lowercased()) }
    }
    if o.premiumOnly {
        voices = voices.filter { qualityRank($0.quality) >= 2 }
    }

    if o.json {
        emitVoicesJSON(voices)
        return
    }

    for v in voices {
        let personal = v.voiceTraits.contains(.isPersonalVoice) ? " personal" : ""
        print("\(v.name.padding(toLength: 22, withPad: " ", startingAt: 0)) "
            + "\(v.language.padding(toLength: 7, withPad: " ", startingAt: 0)) "
            + "\(qualityName(v.quality).padding(toLength: 9, withPad: " ", startingAt: 0))\(personal)  "
            + "\(v.identifier)")
    }

    guard !o.quiet else { return }

    let all = sortedVoices()
    let premium = all.filter { $0.quality == .premium }.count
    let enhanced = all.filter { $0.quality == .enhanced }.count
    errPrint("\n\(voices.count) shown of \(all.count) installed — "
        + "\(premium) premium, \(enhanced) enhanced, \(all.count - premium - enhanced) default")
    premiumHintIfNeeded(language: o.lang)
}

private func emitVoicesJSON(_ voices: [AVSpeechSynthesisVoice]) {
    let arr: [[String: Any]] = voices.map { v in
        [
            "name": v.name,
            "language": v.language,
            "quality": qualityName(v.quality),
            "identifier": v.identifier,
            "personal": v.voiceTraits.contains(.isPersonalVoice),
        ]
    }
    guard let d = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys]) else {
        fail("could not serialize JSON")
    }
    FileHandle.standardOutput.write(d)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}
