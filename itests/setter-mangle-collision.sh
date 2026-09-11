#!/usr/bin/env bash
# itests/setter-mangle-collision.sh — a block setter's mangled <module>_<name>
# must not equal a real function in the same module.
#
# THE BUG THIS PREVENTS. Inside a `<module>.<verb>() { … }` builder block the
# compiler resolves a bare setter call `foo(...)` to the module symbol
# `<module>_foo` (the block-receiver mangling). lib/ruby had an `env(_ctx,k,v)`
# setter (mangles to `ruby_env`) AND, after the rbenv commit, a real function
# `ruby_env(_ctx,manager)` of DIFFERENT arity. A block's `env("K","V")` then
# silently dispatched to the 2-arg `ruby_env` with 3 args → memory corruption →
#   Segmentation fault (core dumped)   [SIGSEGV in map_put_raw]
# at node-eval time, with no diagnostic. Fixed by renaming the function to
# `ruby_manager`. See asks/ruby-bundle-env-segfault-0305.md and the compiler
# follow-up asks/setter-mangle-collides-with-function-name.md.
#
# WHY A STATIC CHECK. The ae 0.178 guard catches a *builder* sharing a name with
# a function, but NOT a *setter's mangled form* sharing a name with a function —
# and that mis-dispatch is a silent segfault, not a link/compile error. Until the
# compiler closes that gap (the follow-up ask), this offline check is the guard:
# for each lib/<module>/module.ae, collect its bare setter names (top-level
# `name(_ctx: ptr …)` functions) and its plain function names, and flag any
# function whose name equals `<module>_<setter>`. Costs milliseconds, no toolchain.
#
# HOW IT DECIDES. A "setter" is a top-level fn whose first param is `_ctx: ptr`
# (the block-config map every setter takes). Its mangled form is
# `<module>_<setter>`. A collision is any OTHER top-level fn literally named that.
# Module-private helpers (leading `_`) are compared too — `ruby_env` had no
# underscore, but the rule holds regardless.
#
# Usage:  ./setter-mangle-collision.sh
# Exit:   0 clean, 1 if any module defines <module>_<setter> as a function.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "[setter-mangle-collision]"

HITS="$(python3 - <<'PY'
import re, glob, os
for mod_file in sorted(glob.glob('lib/*/module.ae')):
    module = os.path.basename(os.path.dirname(mod_file))
    src = open(mod_file, encoding='utf-8', errors='replace').read()
    setters, funcs = set(), set()
    for line in src.splitlines():
        m = re.match(r'([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*\{', line)
        if not m:
            continue
        name, params = m.group(1), m.group(2)
        funcs.add(name)
        # a block setter's first param is the config map `_ctx: ptr`
        first = params.split(',')[0].strip()
        if first.startswith('_ctx') and 'ptr' in first:
            setters.add(name)
    for s in sorted(setters):
        mangled = f"{module}_{s}"
        if mangled in funcs:
            print(f"lib/{module}/module.ae: setter '{s}' mangles to '{mangled}', which is also a function → block call to '{s}' mis-dispatches (segfault)")
PY
)"

if [ -z "$(printf '%s' "$HITS" | tr -d '[:space:]')" ]; then
    pass "no module defines <module>_<setter> as a function"
else
    fail "setter/function mangle-collision(s) found"
    printf '%s\n' "$HITS" | sed 's/^/        /'
    echo "        -> rename the function so it is not <module>_<setter>"
    echo "           (e.g. lib/ruby's ruby_env -> ruby_manager)"
fi

# Regression pin: lib/ruby must not reintroduce `ruby_env` (collided with the
# `env` setter's mangled form). Named so a re-break says WHICH history repeats.
if grep -qE "^ruby_env\(" lib/ruby/module.ae 2>/dev/null; then
    fail "lib/ruby defines ruby_env( again — collides with the 'env' setter (SIGSEGV). Use ruby_manager."
else
    pass "lib/ruby's rbenv setter is still ruby_manager (not ruby_env)"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "setter-mangle-collision: PASS"
    exit 0
fi
echo "setter-mangle-collision: FAIL ($FAILURES assertion(s))"
exit 1
