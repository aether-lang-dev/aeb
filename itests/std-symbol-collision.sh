#!/usr/bin/env bash
# itests/std-symbol-collision.sh — don't define functions in std's C namespace.
#
# THE BUG THIS PREVENTS. tools/aeb-link.ae, tools/gen-orchestrator.ae and
# tools/encode-name.ae each defined a local helper called
# `string_replace_all`. Aether 0.465.0 added a C function with exactly that
# name to std.string's runtime, and two definitions of one symbol is a hard
# link error:
#
#   /usr/bin/ld: libaether.a(aether_string.o): in function `string_replace_all':
#   multiple definition of `string_replace_all';
#   aeb-link.c:(.text+0x2e70): first defined here
#
# `make` then failed outright on any aether >= 0.465 — not a warning, not a
# deprecation, a build that stops. Nothing caught it: the unit suite never
# builds those tools, and CI pinned an older Aether, so it only surfaced
# when someone happened to compile against a newer toolchain.
#
# WHY A NAME CHECK RATHER THAN "BUILD AGAINST LATEST". Building against the
# newest Aether would catch today's collision but needs a second toolchain
# in CI and only tells you about symbols that already exist. This is the
# cheap, offline half: an aeb source must not define a function in a
# namespace std owns, because std can add one at any release and the two
# only meet at link time. It costs milliseconds and needs no toolchain.
#
# HOW IT DECIDES. It reads the ACTUAL exported/extern symbol set out of the
# installed toolchain's std/*/module.ae (~1355 names) and looks for aeb
# sources defining any of them. An earlier draft matched by PREFIX instead
# (`string_`, `path_`, `file_`, `os_`, …) and produced three false
# positives — lib/rust's `path_dep`, aeblabel's `file_to_label`,
# aeb-agent's `os_getpid_safe` — none of which std defines. Guessing by
# namespace flags innocent code; comparing against the real list does not.
#
# A local helper that wants a name std has taken should use a leading
# underscore — `_replace_all` — which is also the convention for
# module-private functions.
#
# Needs an `ae` whose std/ tree it can read (AETHER, or `ae` on PATH). It
# checks against THAT toolchain, so running it under a newer Aether is what
# gives early warning about symbols std has just added.
#
# Usage:  ./std-symbol-collision.sh
# Exit:   0 clean, 1 if any source defines a symbol std also defines.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "[std-symbol-collision]"

# Locate std/ from whichever toolchain is in play.
AE_BIN="${AETHER:-ae}"
AE_PATH="$(command -v "$AE_BIN" 2>/dev/null)"
if [ -z "$AE_PATH" ]; then
    echo "  SKIP: no '$AE_BIN' on PATH — cannot read std's symbol set"
    echo "std-symbol-collision: SKIP"
    exit 0
fi
# Resolve symlinks first: some installs put a launcher at ~/.aether/bin/ae
# that points into a versioned dir, so `dirname $AE_PATH/..` on the LINK is
# the wrong tree. Then try the layouts seen in practice.
AE_REAL="$(readlink -f "$AE_PATH" 2>/dev/null || echo "$AE_PATH")"
STD_DIR=""
for base in "$(dirname "$AE_REAL")/.." "$(dirname "$AE_PATH")/.." "$HOME/.aether/current"; do
    cand="$base/share/aether/std"
    if [ -d "$cand" ]; then STD_DIR="$(cd "$cand" && pwd)"; break; fi
done
if [ -z "$STD_DIR" ]; then
    # In CI a silent skip is worse than a failure: the step would go green
    # having checked nothing. Locally (no toolchain) skipping is fine.
    if [ -n "${CI:-}" ]; then
        echo "  FAIL: cannot locate std/ for $AE_PATH — refusing to pass vacuously"
        echo "std-symbol-collision: FAIL"
        exit 1
    fi
    echo "  SKIP: cannot locate std/ beside $AE_PATH"
    echo "std-symbol-collision: SKIP"
    exit 0
fi
echo "  (std from $STD_DIR)"

# Top-level function definitions look like `name(args) {` at column 0.
# Externs are declarations, not definitions, and are fine — they are how
# you *use* a std symbol.
# lib/veto_trace_os/std/ is EXCLUDED deliberately: it is a drop-in shadow of
# std.os for veto tracing, so defining std's names is its entire purpose and
# it is never linked alongside the real std.os. Flagging it would be a
# permanent false positive that trains people to ignore this check.
SOURCES="$(find tools lib tests -name '*.ae' -type f 2>/dev/null \
    | grep -v '^lib/veto_trace_os/std/' | sort)"
test -n "$SOURCES" || { echo "  no .ae sources found"; exit 1; }

HITS="$(python3 - "$STD_DIR" $SOURCES <<'PY'
import re, sys, glob, os
std_dir, srcs = sys.argv[1], sys.argv[2:]
syms = set()
for f in glob.glob(os.path.join(std_dir, '*', 'module.ae')):
    s = open(f, encoding='utf-8', errors='replace').read()
    m = re.search(r'exports\((.*?)\)', s, re.S)
    if m:
        syms |= set(re.findall(r'\b([a-z][a-z0-9_]*)\b', m.group(1)))
    syms |= set(re.findall(r'^extern\s+([a-z][a-z0-9_]*)\s*\(', s, re.M))
for src in srcs:
    for i, line in enumerate(open(src, encoding='utf-8', errors='replace'), 1):
        m = re.match(r'([a-z][a-z0-9_]*)\s*\(', line)
        if not m:
            continue
        name = m.group(1)
        # ONLY the fully-qualified <module>_<fn> form can collide. A short
        # unqualified name (`get`, `run`, `path`, `new`) is an SDK setter
        # inside a module and compiles to <module>_<name>, so it never
        # competes with std's bare C symbol — flagging those buried the
        # real hit under ~50 false positives.
        if '_' not in name:
            continue
        # A name is only a hazard if std exports it as a BARE C symbol.
        # Module-scoped functions (cache.get_string -> cache_get_string,
        # aeb-main's run_capture -> a tool-local symbol) share a spelling
        # with a std *wrapper* but not with its emitted symbol; verified by
        # building aeb-main under 0.465.0, which links clean. So require
        # the name to look like std's <module>_<fn> C convention.
        if name in syms and re.match(r'(string|list|map|path|dir|file|fs|io|os|net|json|time|math|strbuilder)_', name):
            print(f"{src}:{i}: {name}")
PY
)"

if [ -z "$(printf '%s' "$HITS" | tr -d '[:space:]')" ]; then
    pass "no aeb source defines a symbol std also defines"
else
    fail "aeb sources define symbols std also defines (link-collision risk)"
    printf '%s\n' "$HITS" | sed 's/^/        /'
    echo "        -> rename with a leading underscore, e.g. _replace_all"
fi

# Regression pin: the three files that carried the original collision must
# not reintroduce it. Named explicitly so the failure says WHICH history is
# repeating, not just "a rule was broken".
for f in tools/aeb-link.ae tools/gen-orchestrator.ae tools/encode-name.ae; do
    if grep -q "^string_replace_all(" "$f" 2>/dev/null; then
        fail "$f defines string_replace_all again (collides with std.string >= 0.465.0)"
    fi
done
if [ "$FAILURES" -eq 0 ]; then
    pass "the three historically-affected tools are still clean"
fi

# And the shared implementation must still exist — the point was to have
# ONE copy, not zero. A deletion would make the checks above pass vacuously.
if grep -q "^encode_name(" tools/aeblabel/module.ae 2>/dev/null \
   && grep -q "^_replace_all(" tools/aeblabel/module.ae 2>/dev/null; then
    pass "aeblabel still holds the single shared encode_name/_replace_all"
else
    fail "aeblabel is missing encode_name/_replace_all (the canonical copy)"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "std-symbol-collision: PASS"
    exit 0
fi
echo "std-symbol-collision: FAIL ($FAILURES assertion(s))"
exit 1
