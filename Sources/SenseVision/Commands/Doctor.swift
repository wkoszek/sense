import ArgumentParser
import AVFoundation
import CoreGraphics
import Foundation
import Vision

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report permission state and available hardware/models; --request triggers the prompts.")

    @Flag(help: "Trigger the camera / screen-recording permission prompts.") var request = false
    @Flag var json = false

    func run() async throws {
        var cam = AVCaptureDevice.authorizationStatus(for: .video)
        if request && cam == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            cam = AVCaptureDevice.authorizationStatus(for: .video)
        }
        var screen = CGPreflightScreenCaptureAccess()
        if request && !screen { screen = CGRequestScreenCaptureAccess() }
        let camName: String
        switch cam {
        case .authorized: camName = "authorized"
        case .denied: camName = "denied"
        case .restricted: camName = "restricted"
        default: camName = "not determined (run: sense vision doctor --request)"
        }
        let cameras = cameraDevices().map(\.localizedName)
        let langs = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        let ver = ProcessInfo.processInfo.operatingSystemVersionString
        if json {
            emitJSON(["macOS": ver, "camera": camName, "screenRecording": screen, "cameras": cameras, "ocrLanguages": langs])
        } else {
            print("macOS:            \(ver)")
            print("camera:           \(camName)")
            print("screen recording: \(screen ? "authorized" : "denied / not determined (run: sense vision doctor --request)")")
            print("cameras:          \(cameras.isEmpty ? "none" : cameras.joined(separator: ", "))")
            print("ocr languages:    \(langs.count) (\(langs.prefix(8).joined(separator: " "))…)")
            print("binary:           \(CommandLine.arguments[0])")
            if !Bundle.main.bundlePath.hasSuffix(".app") {
                print("note: TCC prompts attribute to the terminal app; the binary should be ad-hoc signed (make build does this).")
            }
        }
    }
}
