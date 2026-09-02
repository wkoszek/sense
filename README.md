# sense — local perception CLI for macOS

`sense` is a command-line tool for vision and audio processing on macOS built using native Apple frameworks (Vision, CoreImage, ImageIO, AVFoundation, ScreenCaptureKit, PDFKit, CoreML, Speech, and CoreAudio).

All processing is executed on-device. The only exceptions are optional network transcription (`sense audio transcribe --allow-network`) and MP3 encoding, which uses `lame` or `ffmpeg` if available on `PATH`.

## Requirements & Building

Requires macOS 15+ and Xcode 16+ (Swift 6 toolchain).

```sh
make build    # Build release binary (.build/release/sense) signed with Developer ID
make install  # Install binary to /usr/local/bin/sense
make test     # Run vision and audio smoke tests
```

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
| `talk`, `say` | Text-to-speech synthesis via `AVSpeechSynthesizer` (supports Markdown or SSML input) |
| `play` | Audio playback via `AVAudioPlayer` |
| `info` | Audio file metadata inspection and silence detection (`--silences`) |
| `convert` | Format conversion and resampling via `AVAudioConverter` |
| `trim` | Audio trimming and silence removal |
| `split` | Audio splitting on silence boundaries |
| `gain` | Gain adjustment and peak normalization (`--normalize`) |
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
- Premium TTS voices can be managed in System Settings > Accessibility > Spoken Content > Manage Voices.

### Vision Processing
- Feature-print distance values range from `0.0` (identical) to `~0.3` (near-duplicate) and `>1.0` (distinct).
- WebP decoding is supported, but WebP encoding is not supported by ImageIO on macOS 15 (use `cwebp`).
- `convert` re-encodes pixel data, which strips existing image metadata.
- Object classification with custom models requires a CoreML model package via `classify --model`.

## Specifications

- [`docs/vision_spec.md`](docs/vision_spec.md)
- [`docs/audio_spec.md`](docs/audio_spec.md)

