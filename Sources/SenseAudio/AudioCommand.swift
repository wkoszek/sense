import Foundation
import SenseCore

func printUsage() {
    errPrint("""
    sense audio \(senseVersion) - local audio toolbox for macOS (fully on-device)

    usage: sense audio <command> [options]     (each command supports -h)

    capture & speech:
      record       record from the microphone (stdout WAV stream or -o file)
      transcribe   speech-to-text: live mic, file, or stdin  [Speech.framework]
      talk, say    text-to-speech, best installed voice      [AVSpeechSynthesizer]
      voices       list voices; --install gets the premium ones (free, much better)

    playback & inspection:
      play         play a file or stdin
      devices      list audio devices (--test = mic level check)
      info         duration/codec/bitrate/tags (--silences to detect silence)

    processing:
      convert      convert between wav/aiff/caf/m4a/aac/flac/mp3
      trim         cut by time range, or strip edge silence (--silence)
      split        split at silences (--on-silence) or fixed chunks (--every)
      gain         normalize (--normalize) or adjust level (--db)

    Everything runs locally. MP3 encoding shells out to `lame` or `ffmpeg`.
    """)
}

/// Dispatch `sense audio <verb> …`. The audio side hand-rolls its argument
/// parsing (no ArgumentParser), so `SenseCLI` hands it the raw tail verbatim
/// rather than re-parsing flags that only these commands understand.
public func runAudio(_ argv: [String]) -> Never {
    guard let verb = argv.first else {
        printUsage()
        exit(2)
    }
    let rest = Array(argv.dropFirst())

    switch verb {
    case "record": cmdRecord(rest)
    case "transcribe", "stt": cmdTranscribe(rest)
    case "play": cmdPlay(rest)
    case "talk", "say", "tts": cmdTalk(rest)
    case "voices": cmdVoices(rest)
    case "devices": cmdDevices(rest)
    case "info": cmdInfo(rest)
    case "convert": cmdConvert(rest)
    case "trim": cmdTrim(rest)
    case "split": cmdSplit(rest)
    case "gain": cmdGain(rest)
    case "help", "-h", "--help": printUsage(); exit(0)
    case "version", "--version": print("sense audio \(senseVersion)"); exit(0)
    default: fail("unknown command '\(verb)' (see `sense audio help`)", code: 2)
    }
    exit(0)
}
