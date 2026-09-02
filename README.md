# sense — local perception CLI for macOS

One binary, two senses:

```
sense vision …    images, PDFs, video, screen and camera
sense audio …     microphone, speech, playback and audio files
```

Swift + Apple frameworks only (Vision, CoreImage, ImageIO, AVFoundation,
ScreenCaptureKit, PDFKit, CoreML, Speech, CoreAudio) plus
`swift-argument-parser`. Everything runs on-device; nothing leaves the machine.
The two exceptions are explicit: MP3 *encoding* shells out to `lame`/`ffmpeg`,
and `sense audio transcribe --allow-network` is opt-in.

```sh
make build            # → .build/release/sense (signed so TCC grants stick)
make install          # → /usr/local/bin/sense
make test             # both smoke suites, no hardware needed
```

Requires macOS 15+ (Xcode 16+ / Swift 6 toolchain to build).

`sense` merges the former `vision` and `audio` tools. The commands and flags
under each are unchanged — old invocations work with `sense ` prefixed.

## Quickstart

The ten things it is most worth having installed for:

1. **Read the text off an image or PDF**
   ```sh
   sense vision ocr scan.pdf
   ```
2. **Turn a photo of a document into a searchable PDF** — same pixels, plus an
   invisible text layer Preview and Spotlight can find
   ```sh
   sense vision ocr photo.jpg -o photo.pdf
   ```
3. **Read what's on your screen** — for the dialog you can't select text from
   ```sh
   sense vision screenshot | sense vision ocr -
   ```
4. **Decode a QR code or barcode** in a photo or screenshot
   ```sh
   sense vision detect poster.jpg --what barcodes
   ```
5. **Blur the faces before sharing a photo**
   ```sh
   sense vision filter shot.jpg out.jpg --redact faces --redact-blur
   ```
6. **Find the near-duplicate photos** in a folder before you back it up
   ```sh
   sense vision dedupe ~/Pictures/Export
   ```
7. **Transcribe a recording**, on-device
   ```sh
   sense audio transcribe interview.m4a
   ```
8. **Turn that recording into subtitles**
   ```sh
   sense audio transcribe talk.m4a --srt > talk.srt
   ```
9. **Say something out loud, or save it as audio**
   ```sh
   sense audio talk "the build is done"
   sense audio talk -o reminder.m4a "the build is done"
   ```
10. **Read a document aloud** — both senses in one pipe
    ```sh
    sense vision ocr contract.pdf --md | sense audio talk -m
    ```

Longer recipes live in [`examples/`](examples/) as scripts you can run:
`read-aloud.sh`, `receipts.sh`, `screen-to-speech.sh`, `voice-note.sh`.

## Conventions

Both halves follow the same Unix rules:

- stdout is data, stderr is status. `-` reads stdin; binary output to a TTY is refused.
- Output format comes from the extension (`-o out.jpg`, `out.m4a`).
- `--json` on every analysis command.
- Exit codes: `0` ok · `1` error · `2` usage · `3` permission denied · `4` nothing found.

Vision-specific: PDFs are first-class inputs everywhere (`--pages 1-3,7`,
`--dpi 300`), geometry in JSON is **pixels, top-left origin**, and detection
commands take `--annotate out.png` to draw results over the input.

## `sense vision`

| command | what |
|---|---|
| `ocr` | text recognition (Live Text engine): plain / `--md` / `--json --words` / `--hocr` / `--tsv`; `-o out.pdf` writes a **searchable PDF** |
| `detect` | `--what faces landmarks bodies pose hands animals rects barcodes text horizon contours saliency`; `--crop` writes per-hit crops (rects are perspective-corrected) |
| `classify` | Apple's ~1300-label taxonomy (`--labels`), or any CoreML classifier via `--model` |
| `scan` | document scanner: find page → perspective-correct → enhance / `--bw`; `--ocr` adds a text layer to PDF output |
| `segment` | subject cut-out / `--person` / `--mask` / `--instances` / `--at x,y`; `--bg #fff`, `--blur-bg 20` |
| `similar` `embed` `dedupe` | perceptual feature-print distance; near-duplicate grouping (`--delete-dupes` moves to Trash) |
| `capture` | camera still / `--every N` timelapse / `-d SECS` video; `--devices` |
| `screenshot` | display / `--window Safari` / `--region x,y,w,h`; `-d SECS` records; `--windows` |
| `info` | dimensions, color, DPI, EXIF/GPS, `--exif` full dump, `--depth out.png`; video codec/fps |
| `convert` `resize` `crop` `rotate` | ImageIO/CoreImage; `crop --smart 16:9` (saliency), `rotate --auto` (horizon) |
| `filter` | grayscale/blur/sharpen/exposure/`--enhance`, `--redact faces text barcodes`, any `--ci CIFilterName --param k=v`; `--list` |
| `diff` | changed-pixel %, PSNR, perceptual distance, heatmap; `--threshold` for CI |
| `align` | translational registration of one image onto another |
| `video frames\|thumb\|ocr\|detect\|scenes\|contact` | frame sampling, timestamped OCR (`--srt`), per-frame detections (NDJSON), scene cuts, contact sheet |
| `aesthetics` | aesthetic score + utility-image flag |
| `doctor` | permission state, cameras, OCR languages; `--request` triggers prompts |

Beyond the quickstart:

```sh
sense vision ocr scan.pdf --md > notes.md          # headings and paragraphs
sense vision ocr scan.pdf --json --words           # every word, with boxes
sense vision detect group.jpg --what faces pose --annotate out.png --json
sense vision scan *.jpg -o doc.pdf --ocr           # photos -> flat, clean PDF
sense vision segment me.jpg --person --blur-bg 25 -o portrait.png
sense vision crop wide.jpg thumb.jpg --smart 1:1   # keeps the subject
sense vision screenshot --window Safari -o s.png
sense vision diff before.png after.png --threshold 0.01 -o diff.png
sense vision video ocr recording.mov --changes --srt > captions.srt
sense vision classify --model MyModel.mlpackage img.jpg
```

## `sense audio`

| command | Apple framework |
|---|---|
| `record`, `devices` | AVAudioEngine + CoreAudio |
| `transcribe` | Speech (`SFSpeechRecognizer`, on-device by default) |
| `talk` / `say` | AVSpeechSynthesizer |
| `play` | AVAudioPlayer |
| `info` | AudioToolbox (`AudioFileGetProperty`) |
| `convert` `trim` `split` `gain` | AVAudioFile + AVAudioConverter |

Beyond the quickstart:

```sh
sense audio record > out.wav                  # mic to stdout (WAV) until Ctrl-C
sense audio record -o out.m4a -d 10 --level   # 10s to file with live meter
sense audio record -o note.wav --vad 2        # auto-stop after 2s of silence
sense audio transcribe                        # live mic -> text
sense audio record -d 5 | sense audio transcribe -
sense audio talk -f notes.md -o notes.mp3     # Markdown read naturally
sense audio talk -f msg.ssml -o msg.m4a       # raw SSML; see examples/
sense audio talk -f notes.md --dump-ssml      # debug the pauses, don't speak
sense audio play out.wav --rate 1.5
sense audio devices --test                    # mic level check
sense audio info file.mp3 --silences
sense audio convert in.aiff out.m4a -r 44100 -b 160k
sense audio trim in.wav out.wav --silence     # strip leading/trailing silence
sense audio split talk.wav part_%02d.wav --on-silence
sense audio gain in.wav out.wav --normalize --db -3
```

## Notes / limits

**Permissions.** Microphone, speech-recognition, camera and screen-recording
prompts appear once, attributed to "sense". `make build` signs with your
Developer ID so the grant survives rebuilds (ad-hoc signatures change per build
and re-prompt); the first sign asks for keychain access. The binary embeds its
Info.plist usage descriptions in `__TEXT,__info_plist` and re-execs itself with
TCC responsibility disclaimed for `transcribe` — without this, unbundled CLIs
are SIGABRT-killed by TCC. Run `sense vision doctor --request` once for the
camera and screen grants.

Migrating from the old `vision`/`audio` binaries: the bundle identifier changed
to `com.koszek.sense`, so macOS asks for these permissions once more.

**Audio formats.** Reads anything CoreAudio decodes
(wav/aiff/caf/m4a/aac/alac/flac/mp3); writes wav/aiff/caf/m4a/aac/flac
natively. MP3 *encoding* needs `lame` or `ffmpeg` on PATH (Apple ships no MP3
encoder).

**Transcribe languages.** On-device models come from System Settings > Keyboard
> Dictation. With no model the tool refuses (local-only) unless you pass
`--allow-network`.

**SSML.** Safe tags are `<break>`, `<prosody>`, `<phoneme>`, `<say-as>`. Apple's
parser segfaults on `<p>`, `<s>` and `<emphasis>` (macOS 15.7); `talk --ssml`
refuses those up front.

**Premium TTS voices** (Ava, Zoe, …) are downloaded in System Settings >
Accessibility > Spoken Content > Manage Voices; `talk` auto-picks the best.

**Vision limits.** Feature-print distance runs roughly 0 (identical) … 0.3
(near-duplicate) … >1 (different). WebP *decoding* works but *encoding* is not
supported by ImageIO on macOS 15 (use `cwebp`). `convert` re-encodes from
pixels, so metadata is dropped (this doubles as `--strip`). Continuity Camera is
not enumerated. Image captioning and open-vocabulary object detection are not in
Apple's frameworks; use `classify --model` with your own CoreML model.

Specs: `docs/vision_spec.md`, `docs/audio_spec.md`.
