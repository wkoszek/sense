# Standup notes

Yesterday I finished the merge of the two CLIs. There is one binary now.

## Today

- Fix the flaky test in the capture path
- Review the migration doc
- Ship the `0.1.0` tag

## Blocked on

Nothing, though the **signing identity** question is still open — we sign with
a Developer ID so the permission grants survive a rebuild, and that means
anyone building from source without one gets a fresh prompt each time.

Skip this bit when reading aloud:

```sh
make build && make test
```

Back to prose. The point of this file is to show what `-m` does: headings
become pauses, list items get a beat between them, and the fenced code block is
dropped rather than spelled out character by character.
