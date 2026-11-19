#!/usr/bin/env bash
# itests/step-with-dsl-conflict.sh — step("...") next to an SDK setter is refused,
# not silently resolved by dropping the setter.
#
# haskell.build/test, elixir.test, erlang.eunit (and php.test, javascript.test)
# take a generic path when the block declares step(...): it runs only those
# steps. A setter declared in the same block (link_dir/target, deps_get_first,
# escript/run_main, ...) was dropped without a message, so the build ran
# something other than what the file said. Fixture: stub cabal / mix / rebar3 /
# escript / erl on PATH logging their argv (no toolchains needed), a real aeb run.
#
# For each SDK:
#   conflict  step() + setter -> node FAILS, message names the setter, NO tool runs
#   step only                 -> the step runs, exit 0
#   setter only               -> the SDK's own command runs, exit 0
#
# Usage: AETHER=/path/to/ae ./itests/step-with-dsl-conflict.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export AEB_CACHE_DIR="$WORK/cache"

mkdir -p "$WORK/bin" "$WORK/proj/app"
(cd "$WORK/proj" && git init -q .)
touch "$WORK/proj/app/t.escript"
for t in cabal mix rebar3 escript erl echo-step; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$t" "$WORK" > "$WORK/bin/$t"
    chmod +x "$WORK/bin/$t"
done

run() { # sdk builder block
    rm -rf "$WORK/proj/target"; : > "$WORK/calls.log"
    cat > "$WORK/proj/app/.tests.ae" <<EOT
import bldr
import $1
main() {
    bldr.build() {
        $1.$2() { $3 }
    }
}
EOT
    (cd "$WORK/proj" && PATH="$WORK/bin:$PATH" "$AEB" app/.tests.ae >"$WORK/out.txt" 2>&1)
}
check() { # label sdk builder setter-name tool "step-block" "setter-block"
    label="$1"; sdk="$2"; b="$3"; setter="$4"; tool="$5"; stepb="$6"; setb="$7"
    echo "$label"
    if run "$sdk" "$b" "$stepb $setb"; then fail "step + $setter passed (setter silently dropped)"; else pass "step + $setter refused"; fi
    grep -q "$setter" "$WORK/out.txt" && pass "message names $setter" || fail "message does not name $setter: $(tail -3 "$WORK/out.txt")"
    [ -s "$WORK/calls.log" ] && fail "a tool ran despite the conflict: $(cat "$WORK/calls.log")" || pass "no tool ran"
    run "$sdk" "$b" "$stepb" && grep -q "echo-step" "$WORK/calls.log" && pass "step alone runs the step" || fail "step alone failed: $(tail -3 "$WORK/out.txt")"
    run "$sdk" "$b" "$setb" && grep -q "^$tool" "$WORK/calls.log" && pass "setter alone runs $tool" || fail "setter alone failed or did not run $tool: $(tail -3 "$WORK/out.txt"; cat "$WORK/calls.log")"
}

check "haskell.build: link_dir" haskell build link_dir cabal 'step("echo-step")' 'link_dir("/x")'
check "haskell.test: target"    haskell test  target   cabal 'step("echo-step")' 'target("test:live")'
check "elixir.test: deps_get_first" elixir test deps_get_first mix 'step("echo-step")' 'deps_get_first("1")'
check "erlang.eunit: escript"   erlang eunit  escript  escript 'step("echo-step")' 'escript("t.escript")'

if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILURES FAILURE(S)"; exit 1
