# `audio` — holistic local audio CLI (spec)

> Design spec for the `audio` half. Written before the merge into `sense`;
> every `audio <cmd>` below is now invoked as `sense audio <cmd>`.

One binary, macOS-native (Swift + AVFoundation/Speech), fully local — no
cloud calls ever. Fills the gaps Apple left: recording, STT, and a uniform
UX over play/convert/info.

## Design principles

- **Unix-friendly.** stdout is for data, stderr for status. Every command
  works in a pipe: `audio record | audio transcribe -` should work.
- **Format from extension.** `> file.wav`, `-o file.mp3`, `audio convert in.aiff out.aac`
  — container/codec inferred from `EXT`; override with `--format`.
- **Sane defaults.** Default record: 48kHz stereo WAV from default input.
  Default transcribe: system locale, on-device model.
- **`--json` everywhere** for scripting; human-readable otherwise.
- **Exit codes:** 0 ok, 1 error, 2 usage, 3 permission denied (mic/speech).

## Core commands (as requested)

### `audio record`
Record from default system input (mic).
```
audio record                      # raw WAV stream to stdout until Ctrl-C
audio record > out.wav            # stdout redirect; WAV (stdout is always wav)
audio record -o out.mp3           # encode by extension: wav | aac | mp3 | flac | alac
audio record -d 10                # stop after 10s
audio record --device "MacBook Pro Microphone"
audio record -r 16000 -c 1       # sample rate / channels (16k mono = STT-ready)
audio record --level              # print live VU meter to stderr while recording
```
Note: capturing *system output* (loopback) requires a virtual device
(ScreenCaptureKit audio tap on macOS 13+ — `--system` flag uses it; needs
Screen Recording permission).

### `audio transcribe`
On-device STT via Speech framework (`SFSpeechRecognizer` / `SpeechAnalyzer`).
```
audio transcribe                  # live from mic, prints partials, final on exit
audio transcribe file.wav         # any format AVAudioFile reads; else pipe ffmpeg
audio transcribe -                # from stdin (pipe from record)
audio transcribe --lang pl-PL
audio transcribe --srt|--vtt|--json    # timestamps; json = words + confidences
audio transcribe --engine apple|whisper   # optional whisper.cpp backend later
```

### `audio play`
```
audio play file.wav               # afplay equivalent
audio play -                      # play from stdin
audio play --rate 1.5 --volume 0.5
audio play --seek 1:23 file.mp3
```

## Additional commands (proposed)

### `audio talk` — TTS (the missing symmetric half)
`audio say` is accepted as an alias. Unlike Apple's `say`, can emit mp3.
Absorbs the existing **mactalk** tool (`Daily/20260826/mactalk`) wholesale:
AVSpeechSynthesizer, auto-picks best installed voice (Premium > Enhanced >
default), Markdown-aware reading via SSML.
```
audio talk "hello"                # speak via default output device
echo "hello" | audio talk         # from stdin
audio talk -v Ava -o out.m4a "hello"   # wav/caf/aiff/m4a native; mp3 via lame/ffmpeg
audio talk -f notes.md            # Markdown read naturally (syntax stripped, pauses)
audio talk -f doc.md --dump-ssml  # inspect generated SSML
audio talk -r 0.45 -p 1.1 "slower and higher"   # rate 0..1, pitch 0.5..2
audio talk -l                     # list voices, best quality first
```

### `audio devices`
```
audio devices                     # list input/output devices, mark defaults
audio devices --json
audio devices --test              # mic check: live input level meter (Ctrl-C to stop)
```

### `audio info`
```
audio info file.mp3               # duration, codec, rate, channels, bitrate, tags
audio info file.wav --silences    # print detected silence ranges
```

### `audio convert`
```
audio convert in.aiff out.mp3     # by extension; -r/-c/-b (bitrate) overrides
```

### `audio trim`
```
audio trim in.wav out.wav --from 0:10 --to 1:30
audio trim in.wav out.wav --silence     # strip leading/trailing silence
```

### `audio split`
```
audio split in.wav out_%03d.wav --on-silence      # split at silences
audio split in.wav out_%03d.wav --every 10:00     # fixed-length chunks
```
(Silence *detection* — printing the ranges — lives in `audio info --silences`.)

### `audio gain`
```
audio gain in.wav out.wav --normalize       # peak-normalize
audio gain in.wav out.wav --db -3
```

## Nice-to-have / later

- `audio wait --above -30dB` — block until sound detected (scripting trigger)
- `audio transcribe --diarize` — speaker labels (whisper backend)
- `audio record --vad` — auto-stop on N seconds of silence
- `audio notes` — record → transcribe → timestamped markdown, one shot
- shell completions (`audio completions zsh`)

## Implementation notes

- Swift Package, single `audio` binary; `swift-argument-parser` for CLI.
- Recording: `AVAudioEngine` tap → `AVAudioFile`/`ExtAudioFile` writer.
  MP3 encode: Apple has no MP3 encoder — bundle LAME or shell out; or make
  mp3 the one case that requires ffmpeg on PATH (documented).
- STT: `SFSpeechRecognizer(requiresOnDeviceRecognition: true)`; macOS 26+
  can use `SpeechAnalyzer`/`SpeechTranscriber` for better long-form.
- Permissions: mic (TCC) + speech recognition prompts on first use; `audio
  doctor` subcommand to diagnose permission state.
- Prior art in this repo:
  - `Daily/20260826/mactalk` — complete TTS CLI (main.swift + Markdown.swift);
    becomes the `talk` subcommand nearly verbatim. Known bug it works around:
    Apple's SSML parser segfaults on `<p>`/`<s>` (macOS 15.7) — only `<break>`.
  - `Daily/20250825/{speech_analyzer,record_audio,test_speech}.swift`
    — reuse the ffmpeg-pipe fallback from `speech_analyzer.swift`.
