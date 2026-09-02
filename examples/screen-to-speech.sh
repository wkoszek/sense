#!/bin/sh
# Read the screen out loud. Useful for a dialog you can't be bothered to read,
# or an error message in a window you can't select text from.
#
#   ./screen-to-speech.sh                 # whole main display
#   ./screen-to-speech.sh Safari          # just Safari's window
#
# Needs the screen-recording grant: `sense vision doctor --request` once.
set -eu
SENSE=${SENSE:-sense}

if [ $# -ge 1 ]; then
  set -- --window "$1"
fi

"$SENSE" vision screenshot "$@" | "$SENSE" vision ocr - --strict | "$SENSE" audio talk
