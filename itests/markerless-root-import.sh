#!/usr/bin/env bash
# itests/markerless-root-import.sh — a project-root-relative `import core.util`
# resolves in a tree with NO .git and NO .aeb (a `git archive` / GitHub tarball
# extract), and also under a `.git` FILE (git worktree / submodule).
#
# Bug guarded (2026-11-07, libphonenumber-ae feat/aether-port): aeb found the
# project root by walking up for .aeb or a VCS marker and, with none, added no
# root to the compiler's --lib, so root-relative imports from another dir failed
# in an archive extract (workaround was `git init`). Now the root falls back to
# the invocation dir.
#
# Usage: AEB_BIN=/path/to/aeb ./itests/markerless-root-import.sh
set -euo pipefail
AEB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AEB_BIN="${AEB_BIN:-$AEB_ROOT/aeb}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aeb-markerless.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Precondition: nothing above WORK may be a marker, or the test proves nothing.
d="$WORK"
while [ "$d" != "/" ]; do
    for m in .git .aeb .hg .svn .avn .bzr; do
        [ ! -e "$d/$m" ] || { echo "SKIP: $d/$m above temp dir; set TMPDIR elsewhere"; exit 0; }
    done
    d="$(dirname "$d")"
done

mk() { # $1 = tree dir
    mkdir -p "$1/core" "$1/app"
    printf 'export answer() { return 42 }\n' > "$1/core/util.ae"
    cat > "$1/app/.build.ae" <<'AE'
import bldr
import aether

aeb(cap) {
    bldr.build() {
        aether.program() {
            source("main.ae")
            output("rootimp")
        }
        return 0
    }
}
AE
    cat > "$1/app/main.ae" <<'AE'
import core.util
main() { println("answer=${util.answer()}") }
AE
}
run_case() { # $1 = tree, $2 = label
    ( cd "$1" && "$AEB_BIN" app/.build.ae > build.log 2>&1 ) || { cat "$1/build.log"; echo "FAIL ($2): build failed"; exit 1; }
    out="$(find "$1/target" -type f -name rootimp -perm -u+x | head -1)"
    [ -n "$out" ] || { echo "FAIL ($2): no binary"; exit 1; }
    [ "$("$out")" = "answer=42" ] || { echo "FAIL ($2): wrong output"; exit 1; }
    echo "PASS: $2"
}

mk "$WORK/archive"
run_case "$WORK/archive" "no .git/.aeb: root-relative import resolves"

mk "$WORK/wt"
printf 'gitdir: /nonexistent/worktrees/wt\n' > "$WORK/wt/.git"
run_case "$WORK/wt" ".git FILE (worktree/submodule) is a root marker"
