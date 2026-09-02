import AVFoundation
import CoreAudio
import Foundation

// MARK: - CoreAudio device enumeration

struct AudioDev {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputs: Int
    let outputs: Int
    let sampleRate: Double
    let isDefaultInput: Bool
    let isDefaultOutput: Bool
}

private func addr(_ selector: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func allDeviceIDs() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func deviceString(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = addr(selector)
    var cf: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let err = withUnsafeMutablePointer(to: &cf) { ptr in
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, ptr)
    }
    guard err == noErr, let s = cf else { return nil }
    return s as String
}

private func deviceChannels(_ id: AudioDeviceID, input: Bool) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration,
                 input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

private func deviceSampleRate(_ id: AudioDeviceID) -> Double {
    var a = addr(kAudioDevicePropertyNominalSampleRate)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &rate) == noErr else { return 0 }
    return rate
}

func defaultDeviceID(input: Bool) -> AudioDeviceID {
    var a = addr(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
    return id
}

func listAudioDevices() -> [AudioDev] {
    let defIn = defaultDeviceID(input: true)
    let defOut = defaultDeviceID(input: false)
    return allDeviceIDs().compactMap { id in
        guard let name = deviceString(id, kAudioObjectPropertyName) else { return nil }
        return AudioDev(
            id: id,
            name: name,
            uid: deviceString(id, kAudioDevicePropertyDeviceUID) ?? "",
            inputs: deviceChannels(id, input: true),
            outputs: deviceChannels(id, input: false),
            sampleRate: deviceSampleRate(id),
            isDefaultInput: id == defIn,
            isDefaultOutput: id == defOut
        )
    }
}

func findInputDevice(named spec: String) -> AudioDeviceID? {
    let s = spec.lowercased()
    let devs = listAudioDevices().filter { $0.inputs > 0 }
    return devs.first(where: { $0.name.lowercased() == s })?.id
        ?? devs.first(where: { $0.name.lowercased().hasPrefix(s) })?.id
        ?? devs.first(where: { $0.name.lowercased().contains(s) })?.id
        ?? devs.first(where: { $0.uid == spec })?.id
}

// MARK: - Command

private func devicesUsage() -> Never {
    errPrint("""
    usage: sense audio devices [--json] [--test]
      --json   machine-readable output
      --test   mic check: live input level meter (Ctrl-C to stop)
    """)
    exit(2)
}

func cmdDevices(_ args: [String]) {
    var json = false
    var test = false
    let p = ArgList(args)
    while let a = p.next() {
        switch a {
        case "--json": json = true
        case "--test": test = true
        case "-h", "--help": devicesUsage()
        default: fail("devices: unknown option \(a)", code: 2)
        }
    }

    if test { runMicTest(); return }

    let devs = listAudioDevices()
    if json {
        printJSON(devs.map { d -> [String: Any] in
            [
                "id": Int(d.id),
                "name": d.name,
                "uid": d.uid,
                "inputs": d.inputs,
                "outputs": d.outputs,
                "sample_rate": d.sampleRate,
                "default_input": d.isDefaultInput,
                "default_output": d.isDefaultOutput,
            ]
        })
        return
    }
    for d in devs {
        var flags: [String] = []
        if d.isDefaultInput { flags.append("default input") }
        if d.isDefaultOutput { flags.append("default output") }
        let name = d.name.count >= 32 ? d.name : d.name.padding(toLength: 32, withPad: " ", startingAt: 0)
        let flagStr = flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]"
        print("\(name)  in:\(d.inputs)  out:\(d.outputs)  \(Int(d.sampleRate)) Hz\(flagStr)")
    }
}

private func runMicTest() {
    ensureMicAccess()
    installSigint()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let fmt = input.inputFormat(forBus: 0)
    guard fmt.sampleRate > 0, fmt.channelCount > 0 else { fail("no input device available") }
    input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
        drawMeter(bufferDB(buf))
    }
    engine.prepare()
    do { try engine.start() } catch { fail("cannot start audio engine: \(error.localizedDescription)") }
    errPrint("mic test (\(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch) — Ctrl-C to stop")
    while gInterrupted == 0 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    input.removeTap(onBus: 0)
    engine.stop()
    errWrite("\n")
}
