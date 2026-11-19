#!/usr/bin/env bash
# itests/go-build-no-mod-mutation.sh — go.go_build must not rewrite go.mod.
#
# go_build ran `go mod tidy` before every cache-miss build. That reaches the
# network and rewrites go.mod/go.sum, so a build mutated the source tree and
# could succeed on a module whose go.mod was wrong. A build now runs
# `go build` (read-only module mode) and fails with a pointer to `go mod tidy`
# when go.mod is out of date; tidying is the user's act.
#
# Fixture (no network: the dependency is a local `replace`):
#   A. go.mod carries an unused require. tidy would delete it.
#      -> build succeeds, go.mod byte-identical afterwards.
#   B. main.go imports a package go.mod does not require (replace present).
#      tidy would add the require.
#      -> build FAILS, go.mod byte-identical, output tells the user to run `go mod tidy`.
#
# Needs `go` on PATH; prints SKIP and exits 0 when absent.
# Usage: AETHER=/path/to/ae ./itests/go-build-no-mod-mutation.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
if ! command -v go >/dev/null 2>&1; then echo "SKIP: go not installed"; exit 0; fi
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export AEB_CACHE_DIR="$WORK/cache"   # a cache hit would skip go build and hide the result

mk() { # dir require-line(optional) import-line
    d="$WORK/$1"
    mkdir -p "$d/app/dep" "$d/app/target-src"
    cat > "$d/app/dep/go.mod" <<EOT
module example.com/dep
go 1.21
EOT
    cat > "$d/app/dep/dep.go" <<EOT
package dep
func Hello() string { return "hi" }
EOT
    {
        echo "module example.com/app"
        echo "go 1.21"
        [ -n "$2" ] && echo "require example.com/dep v0.0.0"
        echo "replace example.com/dep => ./dep"
    } > "$d/app/go.mod"
    if [ -n "$3" ]; then
        printf 'package main\nimport "example.com/dep"\nfunc main() { println(dep.Hello()) }\n' > "$d/app/main.go"
    else
        printf 'package main\nfunc main() { println("hi") }\n' > "$d/app/main.go"
    fi
    cat > "$d/app/.build.ae" <<EOT
import bldr
import go
main() {
    bldr.build() {
        go.go_build() { output_file("app") }
    }
}
EOT
    (cd "$d" && git init -q .)
}
run() { (cd "$WORK/$1" && "$AEB" app/.build.ae >"$WORK/$1.out" 2>&1); }

echo "A. unused require: build ok, go.mod untouched"
mk A yes ""
cp "$WORK/A/app/go.mod" "$WORK/A.mod.orig"
if run A; then pass "build succeeded"; else fail "build failed: $(tail -5 "$WORK/A.out")"; fi
if cmp -s "$WORK/A/app/go.mod" "$WORK/A.mod.orig"; then pass "go.mod unchanged"; else fail "go.mod was rewritten"; fi

echo "B. missing require: build fails, go.mod untouched, hint printed"
mk B "" yes
cp "$WORK/B/app/go.mod" "$WORK/B.mod.orig"
if run B; then fail "build passed with a go.mod that lacks a required module"; else pass "build failed"; fi
if cmp -s "$WORK/B/app/go.mod" "$WORK/B.mod.orig"; then pass "go.mod unchanged"; else fail "go.mod was rewritten"; fi
if grep -q "go mod tidy" "$WORK/B.out"; then pass "output tells the user to run go mod tidy"; else fail "no go mod tidy hint"; fi

if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILURES FAILURE(S)"; exit 1
