#!/bin/sh
# Smoke test for `sense vision`: generate synthetic images, run every command,
# fail on any error. Camera/screen commands only run with SMOKE_HW=1.
set -eu
V=${1:-.build/release/sense}
T=$(mktemp -d "${TMPDIR:-/tmp}/sense-vision-smoke.XXXXXX")
trap 'rm -rf "$T"' EXIT
A=$T/assets; O=$T/out; mkdir -p "$A" "$O"
swift "$(dirname "$0")/gen-assets.swift" "$A" >/dev/null

ok() { printf '  ok  %s\n' "$*"; }
run() { "$V" vision "$@" >"$T/last.out" 2>"$T/last.err" || { echo "FAIL: sense vision $*"; cat "$T/last.err"; exit 1; }; ok "$*"; }
expect() { want=$1; shift; set +e; "$V" vision "$@" >/dev/null 2>&1; got=$?; set -e; [ "$got" = "$want" ] || { echo "FAIL: sense vision $* exit $got, want $want"; exit 1; }; ok "$* (exit $want)"; }

run ocr "$A/page.png"
grep -q "Quarterly Report 2026" "$T/last.out"
run ocr "$A/page.png" --md
run ocr "$A/page.png" --json --words
run ocr "$A/page.png" --hocr
run ocr "$A/page.png" --tsv
run ocr "$A/page.png" -o "$O/page.pdf" --annotate "$O/page-ocr.png"
run ocr "$O/page.pdf" --pages 1
run detect "$A/page.png" --what barcodes rects text --json
grep -q "koszek.com" "$T/last.out"
run detect "$A/photo.png" --what rects --annotate "$O/rects.png" --crop "$O/crop-%d.png"
run detect "$A/scene.png" --what horizon saliency contours --annotate "$O/scene.png"
run scan "$A/photo.png" -o "$O/scan.pdf" --ocr
run ocr "$O/scan.pdf"
grep -q "Quarterly" "$T/last.out"
run segment "$A/scene.png" -o "$O/cut.png"
run segment "$A/scene.png" --mask -o "$O/mask.png"
run classify "$A/scene.png" --top 3
run aesthetics "$A/scene.png" "$A/page.png"
run crop "$A/scene.png" "$O/sq.png" --smart 1:1
run resize "$A/page.png" "$O/small.jpg" --width 400
run rotate "$A/scene.png" "$O/level.png" --auto
run convert "$A/page.png" "$A/scene.png" "$O/both.pdf"
run convert "$A/page.png" "$O/page.heic"
run info "$O/page.heic" "$O/both.pdf" --json
run filter "$A/scene.png" "$O/f.png" --grayscale --blur 3 --ci CIVignette --param intensity=1
run filter "$A/page.png" "$O/redact.png" --redact barcodes text
run diff "$A/scene.png" "$O/f.png" -o "$O/diff.png"
expect 1 diff "$A/scene.png" "$O/f.png" --threshold 0.01
run similar "$A/page.png" "$A/photo.png" "$A/scene.png" "$O/small.jpg"
run embed "$A/scene.png"
run dedupe "$A" "$O"
run align "$A/scene.png" "$O/level.png" -o "$O/aligned.png"
run doctor --json
expect 4 detect "$A/scene.png" --what faces --strict
expect 4 ocr "$A/scene.png" --strict
expect 1 ocr /nonexistent/file.png
expect 2 ocr "$A/page.png" --bogus-flag

if [ "${SMOKE_HW:-0}" = 1 ]; then
  run screenshot -o "$O/screen.png"
  run screenshot --windows
  run capture -o "$O/cam.jpg" --warmup 1
  run capture -d 2 -o "$O/cam.mov"
  run info "$O/cam.mov"
  run video thumb "$O/cam.mov" -o "$O/thumb.jpg" --at 1
  run video contact "$O/cam.mov" -o "$O/contact.jpg" --cols 3 --rows 2
  run video scenes "$O/cam.mov" --fps 4
  run video detect "$O/cam.mov" --fps 2 --what faces
  run video ocr "$O/cam.mov" --fps 1
fi
echo "smoke: sense vision all passed"
