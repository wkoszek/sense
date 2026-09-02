# examples

Small, real scripts — mostly things that need *both* senses, which is the
reason the two tools were merged in the first place.

Each one takes `SENSE=/path/to/sense` if the binary isn't on your PATH:

```sh
SENSE=../.build/release/sense ./read-aloud.sh contract.pdf
```

| script | what it does | needs |
|---|---|---|
| `read-aloud.sh` | image or PDF → OCR as Markdown → spoken `.m4a` audiobook | — |
| `receipts.sh` | a folder of photos → one searchable PDF + JSON text and barcode index | — |
| `screen-to-speech.sh` | screenshot → OCR → read out loud | screen recording |
| `voice-note.sh` | talk until you stop → transcript appended to a dated Markdown note | mic, speech |

`read-aloud.sh` and `receipts.sh` run on any machine. The other two need a
permission grant; `sense vision doctor --request` prompts for the screen and
camera ones, and the microphone/speech prompts appear the first time
`voice-note.sh` runs.

## Sample inputs

- `viola.ssml` — raw SSML with `<break>`, `<prosody>` and `<phoneme>`:

  ```sh
  sense audio talk -f viola.ssml -o viola.m4a
  ```

  Apple's parser segfaults on `<p>`, `<s>` and `<emphasis>` (macOS 15.7), so
  `talk --ssml` refuses those up front. `--dump-ssml` prints what `talk` would
  have spoken without speaking it, which is the fastest way to debug pauses.

- `notes.md` — ordinary Markdown, to show what `-m` does: headings become
  pauses, list items get a beat between them, and fenced code is announced and
  skipped instead of spelled out.

  ```sh
  sense audio talk -f notes.md -o notes.m4a   # .md implies -m
  sense audio talk -f notes.md --dump-ssml    # see the pauses it inserts
  ```
