# sense

One local, on-device perception CLI for macOS: `sense vision …` for pixels,
`sense audio …` for sound. Swift + Apple frameworks only (Vision, CoreImage,
ImageIO, AVFoundation, ScreenCaptureKit, PDFKit, CoreML, Speech, CoreAudio)
plus `swift-argument-parser`. No network, no cloud, ever.

Merged from the former `../vision` and `../audio` projects. Specs are in
`docs/vision_spec.md` and `docs/audio_spec.md`.

## Layout

Four modules, one executable:

- `Sources/SenseCLI/` — `@main struct Sense`, the root command. `Sense.swift`
  dispatches `audio` before ArgumentParser parses anything;
  `AudioPassthrough.swift` exists so `audio` shows up in `sense --help`.
- `Sources/SenseCore/` — the two things both sides need: `senseVersion` and
  `reexecDisclaimedIfNeeded()` (TCC responsibility disclaim).
- `Sources/SenseVision/` — `VisionCommand.swift` (subcommand list),
  `Common/Common.swift` (image loading from files/stdin/PDF with EXIF
  orientation normalized, `writeImage`/`writeBatch`/`writePDF`, geometry, JSON,
  shared `InputOptions`/`OutputOptions`), `Common/Annotator.swift` (boxes/paths
  /labels in pixel top-left coordinates), `Commands/*.swift` one file per
  command family. `Detect.swift` holds `runDetectors`/`annotate`, reused by
  `filter --redact` and `video detect`; `OCR.swift` holds `recognizeText` + the
  PDF text layer, reused by `scan --ocr` and `video ocr`.
- `Sources/SenseAudio/` — `AudioCommand.swift` (`runAudio` verb switch), one
  file per subcommand, shared helpers in `Util.swift` / `AudioFileOps.swift` /
  `Devices.swift`.

## Rules

- The two sense modules stay separate. They each define `fail`, an `Info`
  command and their own conventions; merging them into one target would force a
  rename spree for no gain. Anything genuinely shared goes in `SenseCore` and
  must be `public`.
- The vision module cannot be named `Vision` — it clashes with the framework on
  a case-insensitive filesystem. `SenseVision` is the name; `VisionCommand` is
  also the namespace for `hocrText`/`tsvText`/`annotateImage` extensions.
- Vision parses with ArgumentParser; audio hand-rolls its flags. Do not convert
  audio to ArgumentParser piecemeal — `SenseCLI` hands it the raw argument tail
  precisely so its parsing stays self-contained.
- All vision JSON geometry is pixels, top-left origin. Convert Vision's
  normalized bottom-left coords only via `CGRect.pixels(w,h)` /
  `CGPoint.pixels(w,h)`.
- stdout = data, stderr = status; refuse binary on a TTY.
- New vision output commands take `OutputOptions` and call
  `writeBatch(_, output: options.spec, ...)`. Never construct `OutputOptions()`
  by hand (ArgumentParser leaves wrappers uninitialized); build an `OutSpec`.
- Exit codes across both: 0 ok, 1 error, 2 usage, 3 permission, 4 nothing found.
- Everything on-device; network is opt-in only (`sense audio transcribe
  --allow-network`).
- Don't break the TCC setup: `Resources/Info.plist` is embedded into
  `__TEXT,__info_plist` via the `SenseCLI` target's `unsafeFlags`, and
  `transcribe` re-execs disclaimed (`SenseCore/Disclaim.swift`). Both are
  required or Speech kills the process. `make build` signs with a stable
  Developer ID so grants survive rebuilds.
- Keep macOS 15 as the floor; guard newer APIs with `@available`.

## Build / test

```sh
make build         # release + codesign (stable identity so TCC grants stick)
make test          # both smoke suites
make test-vision   # scripts/smoke-vision.sh: synthetic images, every command
make test-audio    # scripts/smoke-audio.sh: talk -> file ops -> transcribe
```

Smoke tests never touch the camera, screen or microphone unless `SMOKE_HW=1`.
