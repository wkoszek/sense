# sense — local perception CLI for macOS

`sense` is a command-line tool for vision and audio processing on macOS built using native Apple frameworks (Vision, CoreImage, ImageIO, AVFoundation, ScreenCaptureKit, PDFKit, CoreML, Speech, and CoreAudio).

Website: [sense.koszek.com](https://sense.koszek.com)

All processing is executed on-device. The only exceptions are optional network transcription (`sense audio transcribe --allow-network`) and MP3 encoding, which uses `lame` or `ffmpeg` if available on `PATH`.

## Installation

```sh
brew install wkoszek/tap/sense
```

That is the whole thing — it pulls a signed, notarized universal binary
(Apple silicon and Intel) from the [tap](https://github.com/wkoszek/homebrew-tap).
To upgrade later, `brew upgrade sense`.

Requires **macOS 15 (Sequoia) or newer**.

<details>
<summary>Why a prebuilt binary instead of building from source?</summary>

macOS ties camera, microphone and screen-recording permissions to an
executable's code signature. Released binaries are signed with a Developer ID,
so a grant you give once keeps working across upgrades. A locally compiled
binary is only ad-hoc signed and its identity changes on every build, which
means macOS would ask for those permissions again every time you update.

You can verify what you installed came from this project:

```sh
codesign -dv --verbose=2 "$(brew --prefix)/bin/sense" 2>&1 | grep TeamIdentifier
# TeamIdentifier=QQ5A9Q7C7Z
```

</details>

### Building from source

Requires Xcode 16+ (Swift 6 toolchain) in addition to macOS 15.

```sh
git clone https://github.com/wkoszek/sense.git && cd sense
make build    # release binary at .build/release/sense
make install  # install to /usr/local/bin/sense (PREFIX= to change)
make test     # vision and audio smoke suites
```

Note the permission caveat above: a source build re-prompts for camera, mic and
screen access after each rebuild.

`sense` merges the former `vision` and `audio` tools into a single binary. Commands and flags under `sense vision` and `sense audio` retain their original syntax.

## Quickstart

```sh
# OCR an image or PDF
sense vision ocr scan.pdf
sense vision ocr photo.jpg -o photo.pdf

# OCR current screen content
sense vision screenshot | sense vision ocr -

# Detect barcodes or QR codes
sense vision detect poster.jpg --what barcodes

# Redact faces in an image
sense vision filter photo.jpg out.jpg --redact faces --redact-blur

# Find near-duplicate images in a directory
sense vision dedupe ~/Pictures/Export

# Transcribe audio file on-device
sense audio transcribe interview.m4a
sense audio transcribe talk.m4a --srt > talk.srt

# Text-to-speech output or file generation
sense audio talk "The build finished successfully"
sense audio talk -o output.m4a "The build finished successfully"

# Get the premium voices — free, and a large quality jump
sense audio voices --install

# Pipeline OCR text directly to speech
sense vision ocr contract.pdf --md | sense audio talk -m
```

Additional workflow scripts are available in [`examples/`](examples/).

## Conventions

- `stdout` outputs data; `stderr` outputs status and diagnostic logs. Binary output to a TTY is refused.
- Output file format is inferred from the file extension (`-o out.jpg`, `-o out.m4a`).
- `--json` is supported across analysis commands.
- Exit codes: `0` success, `1` error, `2` invalid usage, `3` permission denied, `4` no results found.
- Vision commands accept PDF inputs (`--pages 1-3,7`, `--dpi 300`), output pixel geometry with a top-left origin, and support `--annotate out.png` for visual overlays.

## Commands

### `sense vision`

| Command | Description |
|---|---|
| `ocr` | Text recognition via Live Text (plain text, `--md`, `--json --words`, `--hocr`, `--tsv`, or `-o out.pdf` for searchable PDF) |
| `detect` | Feature detection (`--what faces,landmarks,bodies,pose,hands,animals,rects,barcodes,text,horizon,contours,saliency`) with optional `--crop` or `--annotate` |
| `classify` | Image classification using Apple taxonomy (`--labels`) or custom CoreML models (`--model`) |
| `scan` | Document scanning, page detection, perspective correction, enhancement, and optional PDF OCR text layer |
| `segment` | Subject cutout and segmentation (`--person`, `--mask`, `--instances`, `--bg`, `--blur-bg`) |
| `similar`, `embed`, `dedupe` | Perceptual similarity analysis and near-duplicate cleanup (`--delete-dupes`) |
| `capture` | Camera stills, timelapses (`--every`), or video recording (`-d`) |
| `screenshot` | Screen, window (`--window`), or region (`--region`) capture and recording |
| `info` | Image and video metadata dump (dimensions, color space, DPI, EXIF, GPS, depth map, codec/fps) |
| `convert`, `resize`, `crop`, `rotate` | Image manipulation (`crop --smart` via saliency, `rotate --auto` via horizon) |
| `filter` | Image filters (blur, sharpen, exposure, `--redact`, CoreImage filters via `--ci`) |
| `diff` | Image comparison (pixel change %, PSNR, perceptual distance, heatmap generation) |
| `align` | Image registration and translational alignment |
| `video` | Video processing (`frames`, `thumb`, `ocr`, `detect`, `scenes`, `contact`) |
| `aesthetics` | Aesthetic scoring and utility image detection |
| `doctor` | Diagnostic check for permissions, camera devices, and OCR languages (`--request` triggers permission prompts) |

#### Vision Examples

```sh
sense vision ocr scan.pdf --md > notes.md
sense vision ocr scan.pdf --json --words
sense vision detect group.jpg --what faces pose --annotate out.png --json
sense vision scan *.jpg -o doc.pdf --ocr
sense vision segment photo.jpg --person --blur-bg 25 -o portrait.png
sense vision crop photo.jpg thumb.jpg --smart 1:1
sense vision screenshot --window Safari -o screen.png
sense vision diff before.png after.png --threshold 0.01 -o diff.png
sense vision video ocr recording.mov --changes --srt > captions.srt
sense vision classify --model Model.mlpackage img.jpg
```

### `sense audio`

| Command | Description |
|---|---|
| `record` | Audio recording from microphone to WAV/M4A with VAD silence detection (`--vad`) or live metering |
| `transcribe` | On-device speech recognition via `SFSpeechRecognizer` (live mic or audio file, optional `--srt` output) |
| `talk`, `say` | Text-to-speech synthesis via `AVSpeechSynthesizer` (supports Markdown or SSML input; see `voices` to list or install voices) |
| `play` | Audio playback via `AVAudioPlayer` |
| `info` | Audio file metadata inspection and silence detection (`--silences`) |
| `convert` | Format conversion and resampling via `AVAudioConverter` |
| `trim` | Audio trimming and silence removal |
| `split` | Audio splitting on silence boundaries |
| `gain` | Gain adjustment and peak normalization (`--normalize`) |
| `voices` | List installed TTS voices by quality; `--install` opens the System Settings pane where premium voices are downloaded |
| `samples` | Synthesize one passage in several voices into a single self-contained HTML page with inline players — the fastest way to hear premium vs default |
| `devices` | List audio input/output devices and test microphone levels (`--test`) |

#### Audio Examples

```sh
sense audio record > out.wav
sense audio record -o note.m4a -d 10 --level
sense audio record -o note.wav --vad 2
sense audio transcribe
sense audio record -d 5 | sense audio transcribe -
sense audio talk -f notes.md -o notes.mp3
sense audio talk -f msg.ssml -o msg.m4a
sense audio play out.wav --rate 1.5
sense audio voices                            # installed voices, best first
sense audio voices --premium                  # just the good ones
sense audio voices --install                  # open Settings to download more
sense audio devices --test
sense audio info file.mp3 --silences
sense audio convert in.aiff out.m4a -r 44100 -b 160k
sense audio trim in.wav out.wav --silence
sense audio split talk.wav part_%02d.wav --on-silence
sense audio gain in.wav out.wav --normalize --db -3
```

## Notes & Limitations

### Permissions & Security
- Permissions for microphone, speech recognition, camera, and screen recording are managed under the bundle ID `com.koszek.sense`.
- `make build` signs the binary with Developer ID credentials so TCC permissions persist across builds.
- Run `sense vision doctor --request` to prompt for camera and screen recording permissions.

### Audio Processing
- Decodes formats supported by CoreAudio (WAV, AIFF, CAF, M4A, AAC, ALAC, FLAC, MP3).
- Encodes WAV, AIFF, CAF, M4A, AAC, and FLAC natively. MP3 encoding requires `lame` or `ffmpeg` on `PATH`.
- On-device speech recognition requires installed dictation language models (System Settings > Keyboard > Dictation). Pass `--allow-network` if on-device models are unavailable.
- Supported SSML tags: `<break>`, `<prosody>`, `<phoneme>`, and `<say-as>`. Tags `<p>`, `<s>`, and `<emphasis>` are rejected due to macOS framework crashes.
- **Premium voices are a free download and sound dramatically better** than the
  ones macOS ships with. `sense audio talk` picks the best installed voice
  automatically, so this is the single highest-impact thing to set up:

  ```sh
  sense audio voices --install     # opens Accessibility > Spoken Content
  ```

  From there: **System voice > (i) > Manage Voices**, then download any voice
  marked *Premium* or *Enhanced*. `sense audio voices --premium` shows what you
  already have; if a language has none, `voices` and `talk` say so.

### Vision Processing
- Feature-print distance values range from `0.0` (identical) to `~0.3` (near-duplicate) and `>1.0` (distinct).
- WebP decoding is supported, but WebP encoding is not supported by ImageIO on macOS 15 (use `cwebp`).
- `convert` re-encodes pixel data, which strips existing image metadata.
- Object classification with custom models requires a CoreML model package via `classify --model`.

## Specifications

- [`docs/vision_spec.md`](docs/vision_spec.md)
- [`docs/audio_spec.md`](docs/audio_spec.md)

## Author

`sense` is written and maintained by **Wojciech Adam Koszek**
([@wkoszek](https://github.com/wkoszek), [koszek.com](https://koszek.com)).

Issues and patches are welcome at
[github.com/wkoszek/sense](https://github.com/wkoszek/sense).

## Copyright & License

Copyright © 2026 Wojciech Adam Koszek.

Released under the **MIT License** — see [`LICENSE`](LICENSE) for the full
text. In short: do what you like with it, keep the copyright notice, and it
comes with no warranty.

### Third-party

- [swift-argument-parser](https://github.com/apple/swift-argument-parser)
  1.8.2 — Apache License 2.0, Copyright © Apple Inc. The only external
  dependency; everything else is Apple system frameworks.

Released binaries are signed with the Developer ID of Adam Koszek
(`QQ5A9Q7C7Z`) and notarized by Apple. A binary that does not report that team
identifier under `codesign -dv` did not come from this project.

