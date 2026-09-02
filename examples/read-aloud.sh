#!/bin/sh
# Turn a scanned page, photo or PDF into an audiobook — both senses, one pipe.
#
#   ./read-aloud.sh contract.pdf            -> contract.m4a
#   ./read-aloud.sh scan.jpg narration.m4a
#
# `ocr --md` reconstructs headings and paragraphs, which `talk -m` then reads
# with real pauses instead of speaking the punctuation. Nothing leaves the box.
set -eu
SENSE=${SENSE:-sense}

[ $# -ge 1 ] || { echo "usage: $0 <image-or-pdf> [out.m4a]" >&2; exit 2; }
in=$1
out=${2:-$(basename "${in%.*}").m4a}

"$SENSE" vision ocr "$in" --md --strict | "$SENSE" audio talk -m -o "$out"
