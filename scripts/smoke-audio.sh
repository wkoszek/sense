#!/bin/sh
# Smoke test for `sense audio`: synthesize a clip with `talk`, then push it
# through every file-based command. Microphone commands (record, live
# transcribe, devices --test) only run with SMOKE_HW=1.
set -eu
V=${1:-.build/release/sense}
T=$(mktemp -d "${TMPDIR:-/tmp}/sense-audio-smoke.XXXXXX")
trap 'rm -rf "$T"' EXIT

ok() { printf '  ok  %s\n' "$*"; }
run() { "$V" audio "$@" >"$T/last.out" 2>"$T/last.err" || { echo "FAIL: sense audio $*"; cat "$T/last.err"; exit 1; }; ok "$*"; }
expect() { want=$1; shift; set +e; "$V" audio "$@" >/dev/null 2>&1; got=$?; set -e; [ "$got" = "$want" ] || { echo "FAIL: sense audio $* exit $got, want $want"; exit 1; }; ok "$* (exit $want)"; }

run version
run devices
expect 2 talk -l          # removed in v3.0.0, must fail with a pointer
run voices
run voices --premium
run voices --lang en --json
run voices --quiet
expect 2 voices --bogus
run talk -o "$T/clip.wav" "the quick brown fox jumps over the lazy dog"
run info "$T/clip.wav"
run info "$T/clip.wav" --json
run info "$T/clip.wav" --silences
run convert "$T/clip.wav" "$T/clip.m4a"
run convert "$T/clip.wav" "$T/clip.caf" -r 22050 -c 1
run info "$T/clip.m4a"
run gain "$T/clip.wav" "$T/norm.wav" --normalize
run gain "$T/clip.wav" "$T/quiet.wav" --db -6
run trim "$T/clip.wav" "$T/cut.wav" --from 0 --to 1
run trim "$T/clip.wav" "$T/tight.wav" --silence
run split "$T/clip.wav" "$T/part_%03d.wav" --every 1
run transcribe "$T/clip.wav"
grep -qi "fox" "$T/last.out" || { echo "FAIL: transcribe did not recognize the test phrase"; cat "$T/last.out"; exit 1; }

expect 2 bogus-command
expect 1 info /nonexistent/file.wav

if [ "${SMOKE_HW:-0}" = 1 ]; then
  run devices --test
  run record -d 2 -o "$T/mic.wav"
  run info "$T/mic.wav"
  run play "$T/clip.wav"
fi
echo "smoke: sense audio all passed"
