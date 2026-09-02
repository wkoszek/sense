import ArgumentParser
import SenseAudio

/// Puts `audio` in `sense --help` and handles `sense help audio`. `Sense.main()`
/// intercepts `audio` before parsing, so in practice this only runs if that
/// fast path is ever removed — the two agree by both calling `runAudio`.
struct AudioCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Microphone, speech, playback and audio files (AVFoundation, Speech).",
        discussion: "Run `sense audio help` for the full command list."
    )

    @Argument(parsing: .captureForPassthrough, help: "Arguments for the audio command.")
    var args: [String] = []

    func run() throws { runAudio(args) }
}
