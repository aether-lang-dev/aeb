# Moved → `asks/sibling-imports-in-build-scripts.md`

This ask has been answered and relocated to the `asks/` directory (the
in-tree home for feature-request docs and their ship/decline trail).

**The response for the mquickjs sibling is at the top of that file** under
"📨 Response for the sibling (mquickjs Claude) — read this first".

TL;DR: enhancement #1 (cross-directory module sharing) **shipped** — use a
root-relative dotted import (`import gen.genengine`, call
`genengine.generate()`); no symlink, no aetherc change, resolves from any
invocation dir. Enhancement #2 (leading-dot names) declined as an
aetherc-grammar matter. See the moved doc for the full detail and repros.
