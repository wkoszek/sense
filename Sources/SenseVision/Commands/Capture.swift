import ArgumentParser
import AVFoundation
import Foundation

final class PhotoSink: NSObject, AVCapturePhotoCaptureDelegate {
    private var cont: CheckedContinuation<Data, Error>?
    func capture(_ output: AVCapturePhotoOutput, settings: AVCapturePhotoSettings) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            cont = c
            output.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { cont?.resume(throwing: error) }
        else if let d = photo.fileDataRepresentation() { cont?.resume(returning: d) }
        else { cont?.resume(throwing: VisionError("no photo data")) }
        cont = nil
    }
}

final class MovieSink: NSObject, AVCaptureFileOutputRecordingDelegate {
    var done: CheckedContinuation<Void, Error>?
    var duration: Double = 0
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        // start the clock only once frames are actually being written
        DispatchQueue.global().asyncAfter(deadline: .now() + duration) { output.stopRecording() }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error, (error as NSError).code != AVError.Code.maximumDurationReached.rawValue { done?.resume(throwing: error) } else { done?.resume() }
        done = nil
    }
}

func cameraDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .deskViewCamera],
                                     mediaType: .video, position: .unspecified).devices
}

func ensureCameraAccess() async {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return
    case .notDetermined:
        if await AVCaptureDevice.requestAccess(for: .video) { return }
        fail("camera access denied", code: Exit.permission)
    default:
        fail("camera access denied (System Settings > Privacy & Security > Camera)", code: Exit.permission)
    }
}

struct Capture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Grab a still, a timelapse, or a video clip from a camera.")

    @Option(name: .shortAndLong, help: "Output file (jpg/png/heic; mov/mp4 with -d). Default: JPEG to stdout.") var output: String?
    @Option(name: .long, help: "Camera name substring (see --devices).") var device: String?
    @Flag(help: "List cameras and exit.") var devices = false
    @Option(name: .long, help: "Seconds to let exposure settle before the shot.") var warmup: Double = 0.7
    @Option(name: .long, help: "Timelapse: shoot every N seconds until Ctrl-C (-o needs %d).") var every: Double?
    @Option(name: .long, help: "Max number of timelapse shots.") var count: Int?
    @Option(name: .shortAndLong, help: "Record video for this many seconds instead of a still.") var duration: Double?
    @Option(name: .shortAndLong) var quality: Int?

    func run() async throws {
        if devices {
            for d in cameraDevices() { print("\(d.localizedName)\t\(d.deviceType.rawValue)\t\(d.uniqueID)") }
            return
        }
        await ensureCameraAccess()
        let all = cameraDevices()
        let cam: AVCaptureDevice
        if let device {
            guard let d = all.first(where: { $0.localizedName.localizedCaseInsensitiveContains(device) }) else {
                fail("no camera matching '\(device)'; have: \(all.map(\.localizedName).joined(separator: ", "))")
            }
            cam = d
        } else {
            guard let d = AVCaptureDevice.default(for: .video) ?? all.first else { fail("no camera found") }
            cam = d
        }
        status("using \(cam.localizedName)")

        let session = AVCaptureSession()
        session.sessionPreset = .photo
        let input = try AVCaptureDeviceInput(device: cam)
        guard session.canAddInput(input) else { fail("cannot use \(cam.localizedName)") }
        session.addInput(input)

        if let duration {
            session.sessionPreset = .high
            let movie = AVCaptureMovieFileOutput()
            guard session.canAddOutput(movie) else { fail("cannot record video") }
            session.addOutput(movie)
            session.startRunning()
            defer { session.stopRunning() }
            try await Task.sleep(nanoseconds: UInt64(warmup * 1e9))
            let out = output ?? "capture.mov"
            let url = URL(fileURLWithPath: out)
            try? FileManager.default.removeItem(at: url)
            let sink = MovieSink()
            sink.duration = duration
            status("recording \(duration)s to \(out)")
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                sink.done = c
                movie.startRecording(to: url, recordingDelegate: sink)
            }
            return
        }

        let photo = AVCapturePhotoOutput()
        guard session.canAddOutput(photo) else { fail("cannot add photo output") }
        session.addOutput(photo)
        session.startRunning()
        defer { session.stopRunning() }
        try await Task.sleep(nanoseconds: UInt64(warmup * 1e9))
        let sink = PhotoSink()

        var shot = 0
        let ext = output.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? "jpg"
        repeat {
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            let data = try await sink.capture(photo, settings: settings)
            shot += 1
            if (ext == "jpg" || ext == "jpeg") && quality == nil {
                if let output { try data.write(to: URL(fileURLWithPath: outputPath(output, index: shot))) }
                else {
                    if isatty(1) != 0 { fail("refusing to write JPEG to a terminal; use -o", code: Exit.usage) }
                    FileHandle.standardOutput.write(data)
                }
            } else {
                guard let src = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("bad frame") }
                try writeImage(cg, to: output.map { outputPath($0, index: shot) }, quality: quality.map { Double($0) / 100 })
            }
            if let output { status("wrote \(outputPath(output, index: shot))") }
            if let every {
                if let count, shot >= count { break }
                try await Task.sleep(nanoseconds: UInt64(every * 1e9))
            }
        } while every != nil
    }
}
