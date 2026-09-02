import AVFoundation
import Foundation

private func playUsage() -> Never {
    errPrint("""
    usage: sense audio play <file> [options]
           sense audio play - [options]          # audio piped on stdin

    options:
          --rate <0.5-2.0>    playback speed (default 1.0)
          --volume <0.0-1.0>  playback volume (default 1.0)
          --seek <time>       start position (seconds or mm:ss)
    """)
    exit(2)
}

private final class PlayDelegate: NSObject, AVAudioPlayerDelegate {
    var done = false
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { done = true }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        errPrint("\(programName): decode error: \(error?.localizedDescription ?? "unknown")")
        done = true
    }
}

func cmdPlay(_ args: [String]) {
    var file: String?
    var rate: Double?
    var volume: Double?
    var seek: Double?
    let p = ArgList(args)
    while let a = p.next() {
        switch a {
        case "--rate": rate = p.doubleValue(a)
        case "--volume": volume = p.doubleValue(a)
        case "--seek": seek = p.timeValue(a)
        case "-h", "--help": playUsage()
        case "-": file = "-"
        default:
            if a.hasPrefix("-") { fail("play: unknown option \(a)", code: 2) }
            if file != nil { fail("play: only one file", code: 2) }
            file = a
        }
    }
    guard let file else { playUsage() }

    let player: AVAudioPlayer
    do {
        if file == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty else { fail("no data on stdin") }
            player = try AVAudioPlayer(data: data)
        } else {
            player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: file))
        }
    } catch {
        fail("cannot play \(file): \(error.localizedDescription)")
    }

    if let r = rate {
        guard (0.5...2.0).contains(r) else { fail("--rate must be 0.5-2.0", code: 2) }
        player.enableRate = true
        player.rate = Float(r)
    }
    if let v = volume {
        guard (0.0...1.0).contains(v) else { fail("--volume must be 0.0-1.0", code: 2) }
        player.volume = Float(v)
    }
    let d = PlayDelegate()
    player.delegate = d
    player.prepareToPlay()
    if let s = seek {
        guard s < player.duration else { fail("--seek \(prettyTime(s)) is past the end (\(prettyTime(player.duration)))", code: 2) }
        player.currentTime = s
    }

    installSigint()
    guard player.play() else { fail("playback failed to start") }
    while !d.done && gInterrupted == 0 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    player.stop()
}
