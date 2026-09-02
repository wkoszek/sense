#!/bin/sh
# Photos of receipts in, one searchable PDF and a JSON index out.
#
#   ./receipts.sh ~/Desktop/receipts        # -> receipts.pdf + receipts.json
#
# `scan` finds the page in each photo, corrects the perspective and cleans it
# up; `--ocr` adds the invisible text layer that makes the PDF searchable in
# Preview and Spotlight.
set -eu
SENSE=${SENSE:-sense}

[ $# -ge 1 ] || { echo "usage: $0 <dir-of-photos> [name]" >&2; exit 2; }
dir=$1
name=${2:-receipts}

# $dir and $name are saved, so reuse the positional params as the file list.
# An unmatched glob stays literal in sh, so keep only the ones that exist.
set --
for pat in "$dir"/*.jpg "$dir"/*.jpeg "$dir"/*.png "$dir"/*.heic; do
  [ -e "$pat" ] && set -- "$@" "$pat"
done
[ $# -gt 0 ] || { echo "no images in $dir" >&2; exit 4; }

"$SENSE" vision scan "$@" -o "$name.pdf" --ocr
"$SENSE" vision ocr "$name.pdf" --json > "$name.json"
"$SENSE" vision detect "$@" --what barcodes --json > "$name-barcodes.json"

echo "-> $name.pdf, $name.json, $name-barcodes.json" >&2
