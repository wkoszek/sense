# `vision` — holistic local image/vision CLI (spec)

> Design spec for the `vision` half. Written before the merge into `sense`;
> every `vision <cmd>` below is now invoked as `sense vision <cmd>`.

> Status (2026-08-27): implemented in this directory (`make build`). Everything
> below is in place except: `capture --preview/--size/--motion`, `scan --camera`,
> `stitch`, `video track/flow`, `run` (generic CoreML — `classify --model`
> covers classifiers), and the "Nice-to-have / later" list. See README.md.

One binary, macOS-native (Swift + Vision/VisionKit/ImageIO/CoreImage/
AVFoundation), fully local — no cloud calls ever. Exposes the on-device
vision stack Apple ships but never gave a CLI for: OCR, detection,
segmentation, capture, and a uniform UX over info/convert/resize.

Sibling of `audio` (`Daily/20260827/audio_spec.md`); same conventions.

## Design principles

- **Unix-friendly.** stdout is for data, stderr for status. Every command
  works in a pipe: `vision capture | vision ocr -` should work. Binary
  image data on stdout only when stdout is not a TTY (else refuse, exit 2).
- **Format from extension.** `-o out.png`, `vision convert in.heic out.jpg`
  — codec inferred from `EXT`; override with `--format`. Supported via
  ImageIO: png jpg heic webp tiff gif bmp pdf (read: everything
  `CGImageSource` knows, incl. RAW/DNG via `CIRAWFilter`).
- **PDF and multi-page are first-class.** Any command taking an image
  takes a PDF; `--page N` / `--pages 1-3,7` / default all pages.
- **Sane defaults.** OCR: `.accurate`, language correction on, auto
  language detect. Capture: default camera, one frame, JPEG.
- **`--json` everywhere** for scripting; human-readable otherwise. All
  geometry in JSON is pixel coordinates, origin top-left (Vision's
  normalized bottom-left boxes are converted — nobody wants those).
- **`--annotate out.png`** on every detection command: draws the result
  boxes/masks/points over the input. Fastest way to eyeball a result.
- **Exit codes:** 0 ok, 1 error, 2 usage, 3 permission denied
  (camera/screen recording), 4 nothing found (opt-in via `--strict`).

## Core commands

### `vision ocr`
On-device text recognition (`VNRecognizeTextRequest` /
`RecognizeTextRequest` on macOS 15+). Same engine as Live Text.
```
vision ocr img.png                # plain text, reading order, one line per line
vision ocr -                      # from stdin (pipe from capture/screenshot)
vision ocr scan.pdf               # all pages; page breaks as form-feed
vision ocr img.png --json         # lines: text, bbox, confidence, candidates
vision ocr img.png --words        # word-level boxes in json
vision ocr img.png --lang pl-PL,en-US
vision ocr img.png --fast         # .fast level (no ML, ~10x quicker)
vision ocr img.png --roi 0,0,800,200   # only this rect (x,y,w,h px)
vision ocr img.png --custom-words words.txt   # vocabulary boost
vision ocr img.png --hocr | --tsv | --md      # hOCR/tesseract-style TSV/markdown
vision ocr in.pdf -o out.pdf      # searchable PDF: invisible text layer over scan
vision ocr img.png --annotate boxes.png
vision ocr --langs                # list supported recognition languages
```
`--md` uses line geometry to reconstruct paragraphs, headings (by height),
and simple tables (column alignment) — best-effort.

### `vision detect`
One command for all "find things" requests; `--what` selects the
detector(s). Output: list of objects with bbox/points/confidence.
```
vision detect img.png                       # faces + rects + text regions + barcodes
vision detect img.png --what faces          # VNDetectFaceRectanglesRequest
vision detect img.png --what landmarks      # 76-point face landmarks (eyes, nose, mouth…)
vision detect img.png --what bodies         # VNDetectHumanRectanglesRequest
vision detect img.png --what pose           # 19-joint body pose (VNDetectHumanBodyPoseRequest)
vision detect img.png --what hands          # 21-joint hand pose, handedness
vision detect img.png --what animals        # cat/dog (VNRecognizeAnimalsRequest)
vision detect img.png --what rects          # VNDetectRectanglesRequest (documents, screens)
vision detect img.png --what barcodes       # QR, Aztec, EAN, Code128, DataMatrix, …
vision detect img.png --what text           # text regions only, no recognition
vision detect img.png --what horizon        # horizon angle (VNDetectHorizonRequest)
vision detect img.png --what contours       # VNDetectContoursRequest → paths
vision detect img.png --what saliency       # attention/objectness heatmap + salient boxes
vision detect img.png --what faces,barcodes --annotate out.png
vision detect img.png --what faces --min-conf 0.8
vision detect img.png --what faces --crop faces_%02d.png   # write one crop per hit
```
`--what barcodes` prints decoded payload; `--what rects --crop` gives
perspective-corrected output (see `vision scan`).

### `vision classify`
```
vision classify img.png               # VNClassifyImageRequest: ~1300 labels, confidences
vision classify img.png --top 5
vision classify img.png --min-conf 0.3
vision classify --labels              # dump the taxonomy
vision classify img.png --model my.mlmodelc   # any CoreML classifier
```

### `vision capture`
Grab frames from a camera (AVFoundation) — the `audio record` twin.
```
vision capture                        # one JPEG to stdout (must be non-TTY)
vision capture -o shot.png            # one frame, format by ext
vision capture -o shot.heic --warmup 1.0   # let auto-exposure settle (default 0.5s)
vision capture --device "FaceTime HD Camera"
vision capture --devices              # list cameras (incl. iPhone Continuity Camera)
vision capture --every 5 -o frame_%04d.jpg   # timelapse until Ctrl-C
vision capture -d 10 -o clip.mov      # record video for 10s (h264/hevc by ext)
vision capture --preview              # tiny live preview window while capturing
vision capture --size 1280x720
```

### `vision screenshot`
ScreenCaptureKit; needs Screen Recording permission.
```
vision screenshot                     # full main display → PNG stdout
vision screenshot -o s.png --display 2
vision screenshot --window "Safari"   # by app or title substring
vision screenshot --region 0,0,800,600
vision screenshot --windows           # list capturable windows (id, app, title)
vision screenshot -o s.mov -d 10      # screen recording
vision screenshot | vision ocr -      # the killer pipe
```

## Additional commands (proposed)

### `vision scan` — document scanner
Rect detection → perspective correction → clean-up. The Notes/Files
scanner, headless.
```
vision scan photo.jpg -o page.png          # deskew + crop to largest quad
vision scan photo.jpg -o page.pdf --ocr    # searchable PDF in one shot
vision scan photo.jpg --bw                 # adaptive threshold, "photocopy" look
vision scan *.jpg -o doc.pdf               # multi-page PDF
vision scan --camera -o page.pdf           # live: auto-shoot when stable quad found
```

### `vision segment` — masks and cutouts
```
vision segment img.png -o cut.png                  # VNGenerateForegroundInstanceMaskRequest (macOS 14+), transparent bg
vision segment img.png --person -o cut.png         # VNGeneratePersonSegmentationRequest
vision segment img.png --mask -o mask.png          # write mask only (8-bit)
vision segment img.png --instances -o obj_%02d.png # one file per foreground instance
vision segment img.png --at 120,340 -o cut.png     # instance under a point (Live Text "lift subject")
vision segment img.png --bg "#ffffff" -o out.png   # replace background
vision segment img.png --blur-bg 20 -o out.png     # portrait mode
```

### `vision similar` / `vision dedupe`
Feature-print embeddings (`VNGenerateImageFeaturePrintRequest`).
```
vision similar a.png b.png                 # distance (0 = identical)
vision similar query.png dir/*.jpg --top 10
vision embed img.png --json                # raw float vector
vision dedupe ~/Pictures --threshold 0.3   # near-duplicate groups
vision dedupe ~/Pictures --delete-dupes --keep largest   # asks unless --yes
```

### `vision info`
```
vision info img.heic              # dims, colorspace, depth, DPI, orientation, ICC, file size
vision info img.jpg --exif        # full EXIF/IPTC/XMP/GPS via ImageIO
vision info img.jpg --json
vision info photo.heic --depth -o depth.png   # extract depth/portrait matte if present
vision info clip.mov              # codec, fps, frames, duration
```

### `vision convert` / `vision resize` / `vision crop`
```
vision convert in.heic out.jpg -q 85
vision convert in.png out.webp
vision convert in.dng out.jpg --raw-exposure 0.5    # CIRAWFilter
vision convert in.pdf out_%03d.png --dpi 300
vision convert *.jpg out.pdf                        # images → PDF
vision convert in.jpg out.jpg --strip               # drop all metadata
vision resize in.jpg out.jpg --width 800            # keep aspect; --height / --fit WxH / --scale 0.5
vision resize in.jpg out.jpg --max 2048             # longest edge
vision crop in.jpg out.jpg 10,20,300,200
vision crop in.jpg out.jpg --smart 1:1              # saliency-based crop to aspect (VNGenerateAttentionBasedSaliencyImageRequest)
vision rotate in.jpg out.jpg --auto                 # apply EXIF orientation / horizon
vision rotate in.jpg out.jpg 90
```

### `vision filter` — CoreImage one-liners
```
vision filter in.jpg out.jpg --grayscale
vision filter in.jpg out.jpg --blur 10 --sharpen 0.5 --exposure 0.3
vision filter in.jpg out.jpg --ci CIPhotoEffectNoir   # any CIFilter by name
vision filter in.jpg out.jpg --enhance              # auto-enhance (CIImage.autoAdjustmentFilters)
vision filter in.jpg out.jpg --redact faces         # blur/blackout detected faces (also: text, barcodes, --roi)
vision filter --list                                # all CIFilters + params
```

### `vision diff`
```
vision diff a.png b.png                   # % pixels changed, PSNR/SSIM, feature-print distance
vision diff a.png b.png -o diff.png       # visual diff (heatmap)
vision diff a.png b.png --threshold 0.01  # exit 1 if over → CI screenshot tests
```

### `vision align` / `vision stitch`
```
vision align ref.png moving.png -o aligned.png   # VNTranslationalImageRegistrationRequest / homographic
vision stitch a.jpg b.jpg c.jpg -o pano.jpg      # feature-based (best effort)
```

### `vision video` — frame-level ops on movies
```
vision video frames clip.mov -o f_%05d.jpg --fps 1
vision video ocr clip.mov                  # timestamped text (screen recordings!) --srt
vision video detect clip.mov --what faces  # per-frame json stream
vision video track clip.mov --what faces --annotate out.mov   # VNTrackObjectRequest
vision video flow clip.mov                 # optical flow (VNGenerateOpticalFlowRequest)
vision video scenes clip.mov               # scene-cut timestamps (feature-print jumps)
vision video thumb clip.mov -o t.jpg --at 1:23
vision video contact clip.mov -o sheet.jpg --cols 6
```

### `vision aesthetics`
```
vision aesthetics img.jpg                  # CalculateImageAestheticsScoresRequest (macOS 15+): score, isUtility
vision aesthetics *.jpg --sort             # rank a folder
```

### `vision compare` — 3rd-party/CoreML escape hatch
```
vision run model.mlpackage img.jpg --json  # any CoreML vision model; auto-handle input size/output kinds
vision run --compile model.mlpackage       # → .mlmodelc
```

## Nice-to-have / later

- `vision watch DIR --ocr` — OCR new files as they land (screenshots folder → text)
- `vision capture --motion` — start on motion, stop after N s of stillness
- `vision ocr --translate pl` — Translation framework (macOS 15+, on-device packs)
- `vision describe img.jpg` — image captioning via a bundled small VLM (e.g. FastVLM / MLX) — the one thing Vision.framework can't do
- `vision qr "text" -o qr.png` — generate codes (CIQRCodeGenerator/CIAztec…)
- `vision text-in-image --search "invoice" ~/Screenshots` — grep across images (cached OCR index in sqlite)
- Continuity Camera via `vision capture --device iphone`
- shell completions (`vision completions zsh`)

## Implementation notes

- Swift Package, single `vision` binary; `swift-argument-parser`. Subcommands
  as separate files; one `ImageInput` type that loads path/stdin/PDF page/
  camera frame to `CGImage` + orientation + DPI so every command is agnostic.
- Prefer the modern Swift-only Vision API (`RecognizeTextRequest`,
  `DetectFaceRectanglesRequest`, …, macOS 15+) with `async/await`; keep
  `VN*` legacy fallbacks only if we need macOS 13/14. Target macOS 15
  minimum unless there's a reason not to.
- Coordinate conversion: Vision → pixel via
  `VNImageRectForNormalizedRect` then flip y; do it in exactly one helper.
- Annotate: draw with CoreGraphics into a `CGContext` over the source;
  colour per detector class; labels in SF Mono.
- Searchable PDF: PDFKit page + `CGPDFContext`; draw original image, then
  text in render mode 3 (invisible) positioned per OCR line with font size
  scaled to bbox height.
- Camera: `AVCaptureSession` + `AVCapturePhotoOutput` (stills) /
  `AVCaptureMovieFileOutput` (video). Screen: `SCStream` /
  `SCScreenshotManager` (macOS 14+).
- Video: `AVAssetReader` → `CMSampleBuffer` → `VNImageRequestHandler(cmSampleBuffer:)`;
  `VNSequenceRequestHandler` for tracking/flow.
- Segmentation output: `CVPixelBuffer` mask → `CIImage` → `CIBlendWithMask`.
- Batch: every command accepts multiple inputs and `-o` with `%d`/`%03d`
  or a directory; parallel via `TaskGroup`, `-j N`.
- Performance: reuse one `VNImageRequestHandler` per image when multiple
  requests are asked (`--what a,b,c` → single `perform([...])`).
- Permissions: camera + screen recording (TCC). `vision doctor` reports
  state and how to fix; exit 3 on denial. Binary must be signed (ad-hoc is
  fine) for TCC prompts to attribute correctly.
- Not available in Apple frameworks, be honest in `--help`: image
  captioning, arbitrary object detection (COCO-style) — hence `vision run`
  for user-supplied CoreML models and the later VLM idea.
- Prior art: none in this repo yet. Related: `Daily/20260826/mactalk`
  shows the arg-parser/stdin/`-o` conventions we mirror; `audio_spec.md`
  is the sibling to keep flag names consistent with (`-o`, `-d`, `--device`,
  `--json`, `--srt`, `-`).
