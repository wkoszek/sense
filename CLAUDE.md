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

## Releasing — always bump the version

`sense` is distributed as a **notarized universal binary** through the Homebrew
tap `wkoszek/homebrew-tap`. Users get it with:

```sh
brew install wkoszek/tap/sense
```

**Rule: every release gets a new version number. Never re-cut an existing one.**
A published tarball's sha256 is baked into the formula; re-releasing the same
version silently breaks `brew install` for anyone who already has it cached, and
Homebrew will not re-download a version it thinks it has. `make release`
enforces this — it refuses to build a version that is already tagged locally or
on the remote — but the rule applies to anything done by hand too.

The version lives in exactly one place: `senseVersion` in
`Sources/SenseCore/Version.swift`. `sense --version`, `sense vision --version`
and `sense audio version` all read it. Do not hard-code a version anywhere else.

Every release also needs a `## vX.Y.Z` section in `CHANGELOG.md` **written
before** the release runs — `make release` reads that section as the GitHub
release body and aborts if it is missing. Notes are part of the release, not an
afterthought.

```sh
make release BUMP=patch     # 0.1.0 -> 0.1.1  (fixes only)
make release BUMP=minor     # 0.1.0 -> 0.2.0  (new commands or flags)
make release BUMP=major     # 0.1.0 -> 1.0.0  (breaking CLI changes)
make release VERSION=0.4.0  # explicit
make release                # asks which
DRY_RUN=1 make release BUMP=patch   # build+sign+notarize, publish nothing
```

Semver against the **CLI surface**, not the internals: a renamed flag or a
changed exit code is breaking; a new subcommand is minor; anything users cannot
observe is a patch.

After a release, bump the formula in the tap (`make formula` prints it with the
new url and sha256 filled in).

### Signing and notarization

Two separate things, and only one of them is about Gatekeeper:

- **Developer ID signing is load-bearing.** TCC keys camera/mic/screen grants to
  the code signature. An ad-hoc signature changes its cdhash on every build, so
  an ad-hoc release would re-prompt users for permissions after every upgrade.
  This is why we ship a prebuilt binary rather than letting Homebrew compile it.
- **Notarization is hygiene.** Homebrew does not quarantine what it downloads,
  so a brew install works either way — but anyone who downloads the tarball from
  the GitHub release page in a browser *does* get it quarantined, and without
  notarization Gatekeeper blocks it.

Release signing uses `--options runtime --timestamp` (a real secure timestamp).
Do **not** copy `make build`'s `--timestamp=none` into the release path;
notarization rejects it. A standalone Mach-O cannot be stapled — only bundles,
dmgs and pkgs can — so the notarization ticket is checked online. That is
expected, not a bug.

## Build / test

```sh
make build         # release + codesign (stable identity so TCC grants stick)
make test          # both smoke suites
make test-vision   # scripts/smoke-vision.sh: synthetic images, every command
make test-audio    # scripts/smoke-audio.sh: talk -> file ops -> transcribe
```

Smoke tests never touch the camera, screen or microphone unless `SMOKE_HW=1`.
