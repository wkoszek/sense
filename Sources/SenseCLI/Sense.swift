import ArgumentParser
import Foundation
import SenseAudio
import SenseCore
import SenseVision

@main
struct Sense: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sense",
        abstract: "Local, on-device perception toolbox for macOS: images and sound.",
        discussion: """
            sense vision …   images, PDFs, video, screen and camera
            sense audio …    microphone, speech, playback and audio files

            Nothing leaves the machine. stdout is for data, stderr for status; '-' \
            means stdin. Run `sense vision --help` or `sense audio help` for the \
            commands under each.

            Exit codes: 0 ok, 1 error, 2 usage, 3 permission denied, 4 nothing found.
            """,
        version: senseVersion,
        subcommands: [VisionCommand.self, AudioCommand.self]
    )

    static func main() async {
        // `audio` is dispatched before ArgumentParser sees the arguments: those
        // commands parse their own flags (`-o`, `--db`, `--from`…) and would
        // otherwise have to be re-declared here just to be passed through.
        let argv = CommandLine.arguments.dropFirst()
        if argv.first == "audio" {
            runAudio(Array(argv.dropFirst()))
        }

        do {
            var command = try parseAsRoot()
            if var async = command as? AsyncParsableCommand {
                try await async.run()
            } else {
                try command.run()
            }
        } catch {
            // ArgumentParser exits 64 (EX_USAGE) on bad arguments; we promise 2.
            if exitCode(for: error) == .validationFailure {
                FileHandle.standardError.write((fullMessage(for: error) + "\n").data(using: .utf8)!)
                Foundation.exit(VisionExit.usage)
            }
            exit(withError: error)
        }
    }
}
