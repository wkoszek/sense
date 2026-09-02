import ArgumentParser
import CoreGraphics
import Foundation
import ScreenCaptureKit

final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { warn("recording failed: \(error.localizedDescription)") }
}

func ensureScreenAccess() {
    if CGPreflightScreenCaptureAccess() { return }
    if CGRequestScreenCaptureAccess() { return }
    fail("screen recording access denied (System Settings > Privacy & Security > Screen Recording)", code: Exit.permission)
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a display, window or region (ScreenCaptureKit); record with -d.",
        discussion: "sense vision screenshot | sense vision ocr -")

    @Option(name: .shortAndLong, help: "Output file (png/jpg…; mov with -d). Default: PNG to stdout.") var output: String?
    @Option(name: .long, help: "Display number (1 = main).") var display: Int = 1
    @Option(name: .long, help: "Window by app name or title substring.") var window: String?
    @Option(name: .long, help: "Region x,y,w,h in points on the display.") var region: String?
    @Flag(help: "List capturable windows and exit.") var windows = false
    @Flag(help: "List displays and exit.") var displays = false
    @Flag(help: "Exclude the cursor.") var noCursor = false
    @Option(name: .shortAndLong, help: "Record video for this many seconds.") var duration: Double?
    @Option(name: .long, help: "Recording frame rate.") var fps: Int = 30
    @Option(name: .shortAndLong) var quality: Int?

    func run() async throws {
        ensureScreenAccess()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if displays {
            for (i, d) in content.displays.enumerated() { print("\(i + 1)\t\(d.width)x\(d.height)\tid=\(d.displayID)") }
            return
        }
        if windows {
            for w in content.windows where w.windowLayer == 0 && (w.frame.width > 50) {
                print("\(w.windowID)\t\(w.owningApplication?.applicationName ?? "?")\t\(w.title ?? "")\t\(Int(w.frame.width))x\(Int(w.frame.height))")
            }
            return
        }
        guard display >= 1, display <= content.displays.count else { fail("display \(display) not found (have \(content.displays.count))") }
        let disp = content.displays[display - 1]
        let scale = CGFloat(CGDisplayPixelsWide(disp.displayID)) / CGFloat(disp.width)

        let filter: SCContentFilter
        var size = CGSize(width: CGFloat(disp.width) * scale, height: CGFloat(disp.height) * scale)
        var sourceRect: CGRect?
        if let window {
            let ws = content.windows.filter { w in
                w.windowLayer == 0 && (
                    (w.owningApplication?.applicationName.localizedCaseInsensitiveContains(window) ?? false) ||
                    (w.title?.localizedCaseInsensitiveContains(window) ?? false) ||
                    String(w.windowID) == window)
            }
            guard let w = ws.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                fail("no window matching '\(window)' (see --windows)")
            }
            status("window: \(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "")")
            filter = SCContentFilter(desktopIndependentWindow: w)
            size = CGSize(width: w.frame.width * scale, height: w.frame.height * scale)
        } else {
            filter = SCContentFilter(display: disp, excludingWindows: [])
            if let region {
                let r = try parseRect(region)
                sourceRect = r
                size = CGSize(width: r.width * scale, height: r.height * scale)
            }
        }

        let cfg = SCStreamConfiguration()
        cfg.width = Int(size.width)
        cfg.height = Int(size.height)
        cfg.showsCursor = !noCursor
        cfg.captureResolution = .best
        if let sourceRect { cfg.sourceRect = sourceRect }

        if let duration {
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            cfg.capturesAudio = false
            let out = output ?? "screen.mov"
            let url = URL(fileURLWithPath: out)
            try? FileManager.default.removeItem(at: url)
            let rc = SCRecordingOutputConfiguration()
            rc.outputURL = url
            rc.outputFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
            let recDelegate = RecordingDelegate()
            let recording = SCRecordingOutput(configuration: rc, delegate: recDelegate)
            let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try stream.addRecordingOutput(recording)
            try await stream.startCapture()
            status("recording \(duration)s to \(out)")
            try await Task.sleep(nanoseconds: UInt64(duration * 1e9))
            try await stream.stopCapture()
            return
        }

        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        try writeImage(img, to: output, quality: quality.map { Double($0) / 100 })
        if let output { status("wrote \(output) (\(img.width)x\(img.height))") }
    }
}
