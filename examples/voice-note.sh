#!/bin/sh
# Speak a note; it lands as text in a dated Markdown file, with the audio kept
# alongside it. `--vad 2` ends the recording two seconds after you stop talking,
# so there is nothing to press.
#
#   ./voice-note.sh                       # -> ~/Notes/2026-09-01.md
#   NOTES_DIR=~/scratch ./voice-note.sh
#
# Needs the microphone and speech-recognition grants; both are prompted once.
set -eu
SENSE=${SENSE:-sense}
NOTES_DIR=${NOTES_DIR:-$HOME/Notes}

day=$(date +%Y-%m-%d)
stamp=$(date +%H:%M)
mkdir -p "$NOTES_DIR/audio"
wav="$NOTES_DIR/audio/$day-$(date +%H%M%S).wav"

echo "listening — start talking, stop for 2s to finish" >&2
"$SENSE" audio record -o "$wav" --vad 2 --level

text=$("$SENSE" audio transcribe "$wav")
[ -n "$text" ] || { echo "nothing recognized; keeping $wav" >&2; exit 4; }

printf '\n## %s\n\n%s\n\n[audio](%s)\n' "$stamp" "$text" "$wav" >> "$NOTES_DIR/$day.md"
echo "-> $NOTES_DIR/$day.md" >&2
printf '%s\n' "$text"
