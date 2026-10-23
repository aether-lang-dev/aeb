# REPLY: aeb drops `-lnghttp2` from aether.program_test's manual link

Answering `asks/aeb-program-test-link-drops-nghttp2-on-macos.md` (from
selaenium). **RESOLVED in aeb 61461324bf8f2f437434e24332df806d8ae8109a.**

## Cause (confirmed)

As the ask says: `bldr._link_token_is_toolchain_managed` drops `-lnghttp2`
from a module's `// aether-link:` header because `_resolve_sysdeps()`
(`lib/aether/module.ae`) is meant to supply it, and `_resolve_sysdeps()` asked
pkg-config for `zlib`, `openssl` and `libpcre2-8` only. Nothing added it back.
Reproduced with the released pair (aether 0.841.0, aeb v0.335) on macOS arm64:
selaenium's `aeb aether/.tests.ae` failed at the link on the 18
`_nghttp2_*` references from `aether_h2.o`.

## Fix

`_resolve_sysdeps()` now takes the set from `ae cflags --libs`, the
probe-derived list aether itself links with (and which `tools/aeb-link.ae`'s
orchestrator link already used), keeping every `-l<lib>` and `-L<dir>`: the
keg-only Homebrew `-L` for nghttp2, openssl and pcre2 comes with it. A hand
kept list is what lagged. The filter is a pure function,
`_published_libs_filter`. For an `ae` too old to have `cflags --libs`, the
pkg-config fallback is unchanged except that it now includes `libnghttp2` (a
missing `.pc` contributes nothing, so a toolchain built without nghttp2 is
unaffected). `_link_token_is_toolchain_managed` is left as it was: the
header's `-lnghttp2` is still dropped as a duplicate, now because sysdeps
really does carry it.

## Tests

- `tests/test_aether_sysdeps.ae` (new): the filter keeps `-lnghttp2` and its
  keg `-L` and drops `-laether`, `-pthread`, `-lm`, `-lpthread`, `-I` and
  other flags; and `_resolve_sysdeps()` against a stub `$AETHER` that prints a
  `cflags --libs` line returns it with `-lnghttp2` in it.
- `tests/run.sh` passes with the aether 0.841.0 toolchain.
- End to end: with this aeb (`/Users/paul/scm/aeb/aeb`) and ae 0.841.0,
  selaenium's `aeb aether/.tests.ae` links and passes (`tests: aether  1/1 PASS`)
  on macOS arm64, where the released aeb v0.335 fails.
