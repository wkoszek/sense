# Changelog

Every release needs a section here **before** it is cut — `make release` reads
it as the GitHub release body and refuses to run without one.

## v3.0.0 — 2026-09-02

### Removed

- **`sense audio talk -l` / `--list-voices`.** Use `sense audio voices`, which
  does the same thing plus filtering, JSON, and `--install`. Passing the old
  flag now exits 2 with a message naming the replacement rather than dumping
  usage, so the break is self-explaining.

  A removed flag is a breaking change to the CLI surface, so this is a major
  version even though it is a small edit — the rule is worth more than the
  number.

## v2.1.0 — 2026-09-02

### Added

- **`sense audio voices`** — list installed text-to-speech voices, best quality
  first, with `--lang`, `--premium`, `--json` and `--quiet`.

- **`sense audio voices --install`** opens System Settings directly at
  Accessibility > Spoken Content, where premium voices are downloaded.

  Premium voices are free and sound dramatically better than the ones macOS
  ships with, but they are buried several levels into System Settings and
  nothing tells you they exist. Now `voices` prints what you have, and both
  `voices` and `talk` say so when the language you are speaking has only
  default-quality voices installed — the hint appears at the moment the audio
  actually sounds mediocre, and never when you named a voice yourself.

### Changed

- `sense audio talk -l` still works and now delegates to `voices`; voice
  enumeration and quality ranking moved to one place so the two agree.

## v2.0.0 — 2026-09-02

First release of `sense`, and a major version because it supersedes two 1.x-era
tools rather than starting from nothing: `vision` and `audio` are now one
binary, and their command surface moved. Anyone upgrading from those has a
breaking change to absorb, so the number says so.

`sense` covers both halves of local, on-device perception on macOS:

```sh
brew install wkoszek/tap/sense
```

### What it is

`sense vision …` does images, PDFs, video, the screen and the camera: OCR with
searchable-PDF, hOCR, TSV and Markdown output; face, body, hand, pose, barcode,
rectangle, horizon and saliency detection; classification against Apple's
taxonomy or your own CoreML model; document scanning with perspective
correction; subject segmentation; perceptual similarity and dedupe; camera and
screen capture; video frame ops; and CoreImage transforms and filters.

`sense audio …` does the microphone, speech and audio files: recording with
voice-activity cutoff, on-device speech-to-text with SRT/VTT/JSON output,
text-to-speech from plain text, Markdown or SSML, playback, metadata and
silence detection, and convert/trim/split/gain.

Everything runs on-device. The two exceptions are explicit: MP3 *encoding*
shells out to `lame`/`ffmpeg`, and `sense audio transcribe --allow-network` is
opt-in.

### Merged from `vision` and `audio`

This release consolidates two separate tools into one binary. Commands and
flags are unchanged — every old invocation works with `sense ` prefixed:

```sh
vision ocr scan.pdf     ->  sense vision ocr scan.pdf
audio transcribe a.m4a  ->  sense audio transcribe a.m4a
```

The two halves keep their own modules so their internal helpers stay
namespaced; `SenseCore` holds the little they genuinely share. Vision parses
with swift-argument-parser while audio hand-rolls its flags, so the root
command hands audio its raw argument tail rather than re-declaring a flag
surface just to pass it through.

Merging also made the cross-sense pipelines the point rather than an accident:

```sh
sense vision ocr contract.pdf --md | sense audio talk -m   # read a document aloud
sense vision screenshot | sense vision ocr -               # read the screen
```

### If you used `vision` or `audio` before

The bundle identifier is now `com.koszek.sense`, so macOS asks once more for
microphone, speech-recognition, camera and screen-recording access. Run
`sense vision doctor --request` to get the camera and screen prompts over with.

### Notes

- Requires macOS 15 (Sequoia) or newer. Universal binary — Apple silicon and
  Intel.
- Shipped signed with a Developer ID and notarized, so permission grants
  survive upgrades instead of re-prompting on every install.
- Known limits: WebP encoding is unavailable on macOS 15 (decoding works),
  `convert` drops metadata because it re-encodes from pixels, Continuity Camera
  is not enumerated, and there is no image captioning or open-vocabulary
  detection in Apple's frameworks — use `classify --model` with your own.
