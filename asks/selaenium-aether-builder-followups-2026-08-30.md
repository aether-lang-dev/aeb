# Handoff from selaenium — two more aether-SDK fixes on top of f7ecaa7

Thanks for landing `f7ecaa7` (closure-regen `--lib` dirs + `_union_caps` cap
flooring) — that unblocked the selaenium native-Aether client. Driving it further
(WebDriver-BiDi productionization) surfaced two more `lib/aether/module.ae` gaps.
Both are sitting UNCOMMITTED in the aeb working tree right now, intermingled with
your in-progress docs reorg (`docs/ → docs/{comparisons,design,guides,plans}/`) —
I did NOT touch your reorg; these are just the `lib/aether/module.ae` +
`tests/test_aether_cmd.ae` hunks. Pull them into a commit (or tell me to) at your
convenience.

## 1. Transitive-DISCOVERY cap floor — f7ecaa7 floored the wrong spot for auto-discovered siblings

`f7ecaa7`'s `_union_caps` floor lives in `_run_regen_pass`, guarded by
`if string.length(caps) == 0` (the "no explicit caps" branch). But
`_expand_transitive_regens` appends every auto-discovered sibling to the regen
list with `regen_caps = _detect_caps(f2)` — a NON-empty value — so in
`_run_regen_pass` those entries take the `explicit_caps` branch and the floor is
**skipped**. Net: a transitively-discovered module still regens with only its OWN
`import std.X` caps.

**Symptom (real):** selaenium's `aether/webdriver.ae` imports `driver`, which
imports `std.os`/`std.net`; webdriver.ae itself imports only `std.file` (→ `fs`).
The discovered `driver.ae`/`drivermgr/*.ae` regened with `fs`-only, and aetherc's
`--emit=lib` gate (which follows the whole closure) rejected it:
`--emit=lib rejects 'import std.os' without --with=os`.

**Fix:** floor at the DISCOVERY site too — in `_expand_transitive_regens`, read
the node's `csrc_caps` and `caps = _union_caps(_detect_caps(f2), node_caps)`
before appending. (The `_run_regen_pass` floor from f7ecaa7 is now
belt-and-suspenders; harmless to keep.) The hunk is in the working tree.

## 2. `program_test` output collision — >1 per node silently drops all but the last

`program_test`'s `bin_path`/`c_path` were hardcoded to `test_program` /
`test_program.c`. Two+ `aether.program_test()` builders in one `bldr.build()`
therefore wrote to the SAME binary — only the last survived, and the node still
reported a green `1/1 PASS` while silently never running the others. No error,
no breadcrumb: pure false-green.

**Symptom (real):** selaenium's `selenium_core/tests/.tests.ae` has three
program_tests (engine probe, BiDi demux unit test, BiDi live slice). Only one
binary existed under `target/tests/bin/`; the node reported 1/1 and finished in
~1.5s (too fast to have run all three).

**Fix:** new pure helper `_test_bin_stem(src_name)` — basename, drop trailing
`.ae`, prefix `test_` (`probe.ae` → `test_probe`, `../bidi_slice.ae` →
`test_bidi_slice`, `test/live_test.ae` → `test_live_test`). `program_test` names
its binary + `.c` from it, so N program_tests coexist. Single-test nodes still get
a stable unique name (behaviour-compatible: the name just changes from
`test_program` to `test_<stem>`; nothing external pins the old name — verified
`grep -rn test_program lib/ tools/` finds no consumer). Covered by 4 new
`std.spec` assertions in `tests/test_aether_cmd.ae` (`_test_bin_stem` describe
block). The hunks are in the working tree.

Verified after both fixes: selaenium's `selenium_core/tests/.tests.ae` builds
THREE distinct binaries (`test_probe`, `test_bidi_demux_probe`, `test_bidi_slice`)
and the BiDi live slice, run directly, drives real Chrome green through the demux
including the async event round-trip. `test_aether_cmd.ae`: 24 passing (20 + 4).

## Note on the aeb suite's own build

`aeb tests/test_aether_cmd.ae` shows `24 passing` but the *node* reports FAILED —
that's the fan-out orchestrator failing to LINK (`aeb-link: FATAL — failed to
link the fan-out orchestrator`), which reproduces on a CLEAN tree with my changes
stashed. So it's pre-existing in the current WIP tree (looks tied to the parked
`tools/resolver/.dist.ae` java-DSL rewrite at 97b3855), not from these hunks. The
assertions themselves are green.
