import ArgumentParser
import Foundation
import SenseCore

/// `sense vision …` — everything that reads pixels.
public struct VisionCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "vision",
        abstract: "Images, video, screen and camera (Apple Vision, CoreImage, AVFoundation).",
        discussion: """
            stdout is for data, stderr for status. Every command accepts '-' for stdin and \
            PDF inputs (--pages/--dpi). Detection commands support --json and --annotate.

            Exit codes: 0 ok, 1 error, 2 usage, 3 permission denied, 4 nothing found (--strict).
            """,
        version: senseVersion,
        subcommands: [
            OCR.self, Detect.self, Classify.self, Capture.self, Screenshot.self,
            Scan.self, Segment.self, Similar.self, Embed.self, Dedupe.self,
            Info.self, Convert.self, Resize.self, Crop.self, Rotate.self,
            Filter.self, Diff.self, Align.self, Video.self, Aesthetics.self,
            Doctor.self,
        ]
    )

    public init() {}
}

/// Exit codes, re-exported so `SenseCLI` can map ArgumentParser's EX_USAGE (64)
/// onto the code this project promises (2) without duplicating the table.
public enum VisionExit {
    public static let usage = Exit.usage
}
