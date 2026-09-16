#!/usr/bin/env bash
# itests/sdk-cold-compile-smoke.sh — prove every SDK module TYPE-CHECKS AND LINKS
# from a COLD checkout under the pinned Aether.
#
# WHY THIS EXISTS (the gap that shipped v0.311):
#   The unit suite (tests/run.sh) compiles aeb's OWN test_*.ae and its tools —
#   a WARM build of aeb itself. It never instantiates an SDK module the way a
#   CONSUMER node does: `aeb python/.tests.ae` compiles lib/python INTO the
#   fan-out orchestrator, which is where SDK-only helpers (the _dir_newest_mtime
#   staleness walk, _nl_to_colon's seq_filter, …) actually get code-generated.
#   Two v0.311 bugs lived exactly there and were invisible warm:
#     - _nl_to_colon passed a BARE fn to string.seq_filter -> SIGSEGV at run
#       (Error 139, empty log) whenever the classpath was built.
#     - the mtime accumulators inferred 32-bit from `0` then took a 64-bit
#       file.mtime -> E0200 narrowing error, so python/dart/gleam/moonbit nodes
#       could not COLD-build under ae 0.675 (a warm tree hid it — the node
#       objects were already cached).
#   Both type-check/link failures. This gate builds a consumer node per SDK from
#   a FRESH temp dir (no cached target/) so the orchestrator is regenerated and
#   linked from scratch, and asserts it reached a working binary.
#
# WHAT IT ASSERTS (deliberately narrow): the SDK COMPILES AND LINKS. Not that
# its tests pass — a missing language toolchain (no pytest, no dart) fails at
# RUN, AFTER the compile+link that is the actual regression surface. So a
# "linked, then the tool was absent" outcome PASSES this gate; only an E0200 /
# a link FATAL / an orchestrator that never linked FAILS it.
#
# No language toolchain required. Fixtures are synthesised in a temp dir;
# nothing is committed and no upstream fetch happens.
#
# Usage:
#   AEB=/path/to/aeb AETHER=/path/to/ae ./itests/sdk-cold-compile-smoke.sh
# Exit code: 0 if every SDK compiled+linked cold; 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AEB="${AEB:-$REPO_ROOT/aeb}"
AETHER="${AETHER:-ae}"
export AETHER

if [ ! -x "$AEB" ]; then
    echo "error: aeb not found/executable at '$AEB' (set \$AEB)" >&2
    exit 1
fi
if ! command -v "$AETHER" >/dev/null 2>&1; then
    echo "error: '$AETHER' not found (set \$AETHER=/path/to/ae)" >&2
    exit 1
fi

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# The SDKs whose modules carry cold-only-instantiated helpers (staleness mtime
# walks, classpath seq_filter, version-sort finders). A representative builder
# per SDK; the point is that lib/<sdk> compiles into the orchestrator, so any
# builder that pulls the module in works.
#   sdk : builder-call
SDK_BUILDERS="
python:python.pytest()
dart:dart.test()
gleam:gleam.test()
moonbit:moonbit.test()
groovy:groovy.groovyc_test()
clojure:clojure.test()
gleam-manifest:gleam.generate_manifest()
erlang-manifest:erlang.generate_manifest()
elixir-manifest:elixir.generate_manifest()
lfe-manifest:lfe.generate_manifest()
javascript-manifest:javascript.generate_manifest()
ts-manifest:ts.generate_manifest()
dart-manifest:dart.generate_manifest()
crystal-manifest:crystal.generate_manifest()
go-manifest:go.generate_manifest()
ruby-manifest:ruby.generate_manifest()
nim-manifest:nim.generate_manifest()
haskell-manifest:haskell.generate_manifest()
swift-manifest:swift.generate_manifest()
julia-manifest:julia.generate_manifest()
"

echo "SDK cold-compile smoke (type-check + link each SDK from a fresh tree)"

for entry in $SDK_BUILDERS; do
    sdk="${entry%%:*}"            # label (may be "<sdk>-manifest")
    call="${entry#*:}"           # e.g. "gleam.generate_manifest()"
    mod="${call%%.*}"            # import module = the part before the first '.'

    # Fresh temp dir per SDK => guaranteed COLD (no cached target/ node objects).
    WORK="$(mktemp -d)"
    cat > "$WORK/.build.ae" <<EOF
import bldr
import ${mod}
main() {
    bldr.build() {
        ${call}
    }
}
EOF

    log="$WORK/out.log"
    ( cd "$WORK" && "$AEB" .build.ae ) >"$log" 2>&1
    rc=$?

    # The regression surface: a compile/link failure. E0200 (narrowing), an
    # orchestrator link FATAL, or a codegen error mean the SDK did not compile.
    if grep -qE "error\[E[0-9]|aeb-link: FATAL|undefined reference|Type checking failed" "$log"; then
        fail "${sdk}: SDK failed to type-check/link cold"
        echo "        --- first error lines ---"
        grep -E "error\[E[0-9]|aeb-link: FATAL|undefined reference|Type checking failed" "$log" | head -3 | sed 's/^/        /'
    elif [ $rc -eq 0 ]; then
        pass "${sdk}: compiled, linked, and the node ran green"
    else
        # Non-zero exit with NO compile/link error = the SDK compiled+linked and
        # the failure is downstream (a missing toolchain, an empty fixture with
        # no tests, Error 139 would show as a crash — check for that too).
        if grep -qE "Error 139|signal 11|SIGSEGV|core dumped" "$log"; then
            fail "${sdk}: linked but CRASHED at run (SIGSEGV — the seq_filter-class bug)"
            grep -E "Error 139|signal 11|SIGSEGV" "$log" | head -2 | sed 's/^/        /'
        else
            pass "${sdk}: compiled + linked cold (node failed downstream, e.g. no toolchain — not a compile regression)"
        fi
    fi

    rm -rf "$WORK"
done

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "sdk-cold-compile-smoke: all SDKs compiled + linked cold"
    exit 0
fi
echo "sdk-cold-compile-smoke: $FAILURES SDK(s) failed to compile/link cold"
exit 1
