#!/usr/bin/env bash
# itests/program-imports-package-not-sdk.sh — an Aether program node sees what
# `ae build` would see for that project, not aeb's own SDK modules.
#
# aeb's lib/ holds the SDK modules a BUILD FILE imports (`import lua`, `import
# python`, `import ruby`, `import go`, ...). The Aether-guest-language package
# github.com/aether-lang-dev/aether-guest-languages exports bridge modules with
# the same names, which a PROGRAM imports. aeb put its own lib/ on the search
# path of every aether.program / aether.program_test compile (--lib <aeb>/lib,
# which is searched before an installed package), so `import lua` in a program
# found the SDK's builder module and the compile failed with
#   E0301 Undefined function 'lua.run'
# while plain `ae build` of the same source worked
# (hosted-language-headers/asks/aeb-lib-shadows-guest-language-bridges.md).
#
# The fixture, in a temp dir, with no network:
#
#   fakeguest/          a package: aether.toml says `modules = "lua"`, and
#                       lua/module.ae has run() and finalize() (no aeb builder
#                       of that name has them). It is wired in with [patch] the
#                       way `ae add` / --override would wire a real one.
#   app/.tests.ae       aether.program_test on app.ae, which does `import lua`
#                       and calls lua.run / lua.finalize
#   sdk/.tests.ae       a BUILD FILE that does `import lua` (aeb's SDK builder)
#                       and runs lua.test() with a step
#   needsdk/.tests.ae   a program whose source imports an aeb SDK module
#                       (agent, from <aeb>/lib) and says so with lib(...)
#   noopt/.tests.ae     the same program WITHOUT lib(...): it must be refused,
#                       because aeb's lib/ is no longer on a program's path
#   both/.tests.ae      app + sdk + needsdk in ONE aeb run, so the package's lua
#                       and the SDK's lua resolve correctly side by side
#
# Usage: AETHER=/path/to/ae ./itests/program-imports-package-not-sdk.sh
# Exit: 0 if every assertion passed; 1 otherwise. POSIX hosts only.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "  SKIP: Windows"; exit 0 ;; esac
AEB="${AEB:-$REPO_ROOT/aeb}"
AETHER="${AETHER:-ae}"
export AETHER
command -v "$AETHER" >/dev/null 2>&1 || { echo "error: '$AETHER' not found (set \$AETHER)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aeb_pkgshadow.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT INT TERM
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "[program-imports-package-not-sdk] ae $("$AETHER" --version 2>/dev/null | sed -n 1p)"

PROJ="$WORK/proj"
mkdir -p "$PROJ/app" "$PROJ/sdk" "$PROJ/needsdk" "$PROJ/noopt" "$WORK/fakeguest/lua"

# --- the package: a `lua` module with run() and finalize() ------------------
cat > "$WORK/fakeguest/aether.toml" <<'EOF'
[package]
name = "fakeguest"
modules = "lua"
EOF
cat > "$WORK/fakeguest/lua/module.ae" <<'EOF'
// A stand-in for aether-guest-languages' lua bridge: same module name, a
// run(code) and a finalize() that aeb's own lib/lua builder module does not have.
import std.string
exports(run, finalize)

run(code: string) {
    println("fakeguest lua.run: ${code}")
    return 0
}

finalize() {
    return 0
}
EOF

# --- the project -------------------------------------------------------------
cat > "$PROJ/aether.toml" <<'EOF'
[package]
name = "pkgshadow"

[dependencies]
"example.invalid/fakeguest" = "0.1.0"

[patch]
"example.invalid/fakeguest" = "../fakeguest"
EOF
( cd "$PROJ" && git init -q . )

cat > "$PROJ/app/app.ae" <<'EOF'
import lua

main() {
    rc = lua.run("print('hi')")
    lua.finalize()
    return rc
}
EOF
cat > "$PROJ/app/.tests.ae" <<'EOF'
import bldr
import aether
import aether(source, output)

aeb(cap) {
    bldr.build() {
        aether.program_test() {
            source("app.ae")
            output("app")
        }
    }
}
EOF

# a BUILD FILE importing aeb's SDK lua builder
cat > "$PROJ/sdk/.tests.ae" <<'EOF'
import bldr
import lua
import bldr(step)

aeb(cap) {
    bldr.build() {
        lua.test() {
            step("echo ran > sdk-lua-builder-ran.marker")
        }
    }
}
EOF

# a program importing an aeb SDK module (agent), explicit and not
cat > "$PROJ/needsdk/needsdk.ae" <<'EOF'
import agent(_secret_marker)

main() {
    println(_secret_marker())
    return 0
}
EOF
cp "$PROJ/needsdk/needsdk.ae" "$PROJ/noopt/noopt.ae"
cat > "$PROJ/needsdk/.tests.ae" <<EOF
import bldr
import aether
import aether(source, output, lib)

aeb(cap) {
    bldr.build() {
        aether.program_test() {
            source("needsdk.ae")
            output("needsdk")
            lib("$REPO_ROOT/lib")
        }
    }
}
EOF
cat > "$PROJ/noopt/.tests.ae" <<'EOF'
import bldr
import aether
import aether(source, output)

aeb(cap) {
    bldr.build() {
        aether.program_test() {
            source("noopt.ae")
            output("noopt")
        }
    }
}
EOF
cat > "$PROJ/.tests.ae" <<'EOF'
import bldr
import bldr(dep)

aeb(cap) {
    bldr.build() {
        dep("app/.tests.ae")
        dep("sdk/.tests.ae")
        dep("needsdk/.tests.ae")
    }
}
EOF

# plain `ae build` is the reference: what the project's own toolchain sees
echo
echo "0: the reference, plain ae build"
if ( cd "$PROJ/app" && "$AETHER" build app.ae -o "$WORK/ref" ) > "$WORK/ref.log" 2>&1 && "$WORK/ref" 2>&1 | grep -q "fakeguest lua.run"; then
    pass "ae build resolves 'import lua' to the package (fixture is sound)"
else
    fail "plain ae build of app.ae did not use the package's lua (the fixture is wrong, not aeb)"; sed 's/^/        /' "$WORK/ref.log" | tail -8
fi

run_aeb() {  # run_aeb LOGNAME TARGET
    ( cd "$PROJ" && env AETHER="$AETHER" AEB_CACHE_DIR="$WORK/cache" bash "$AEB" "$2" ) > "$WORK/$1.log" 2>&1
}

echo
echo "1: a program that imports a package's lua"
if run_aeb app app/.tests.ae && grep -q "1/1 PASS" "$WORK/app.log"; then
    pass "aether.program_test with 'import lua' builds and passes"
else
    fail "the program that imports the package's lua did not build or pass"; grep -E "E0[0-9]+|error|FAIL" "$WORK/app.log" | head -6 | sed 's/^/        /'
fi

echo
echo "2: a build file that imports aeb's SDK lua"
if run_aeb sdk sdk/.tests.ae && grep -q "1/1 PASS" "$WORK/sdk.log" && [ -f "$PROJ/sdk/sdk-lua-builder-ran.marker" ]; then
    pass "lua.test() from aeb's SDK ran"
else
    fail "the build file importing aeb's lua SDK did not run its step"; tail -8 "$WORK/sdk.log" | sed 's/^/        /'
fi

echo
echo "3: a program that imports an aeb SDK module must say so with lib()"
if run_aeb needsdk needsdk/.tests.ae && grep -q "1/1 PASS" "$WORK/needsdk.log"; then
    pass "with lib(<aeb>/lib) the program imports agent"
else
    fail "the program with lib() did not build"; grep -E "E0[0-9]+|error|FAIL" "$WORK/needsdk.log" | head -6 | sed 's/^/        /'
fi
if run_aeb noopt noopt/.tests.ae; then
    fail "the same program WITHOUT lib() built: aeb's lib/ is still on a program's search path"
else
    if grep -q "unresolved import 'agent'" "$WORK/noopt.log"; then
        pass "without lib() the program is refused for the missing module"
    else
        fail "without lib() it failed, but not for the module"; tail -6 "$WORK/noopt.log" | sed 's/^/        /'
    fi
fi

echo
echo "4: all together in one run"
rm -f "$PROJ/sdk/sdk-lua-builder-ran.marker"
if run_aeb both .tests.ae && [ -f "$PROJ/sdk/sdk-lua-builder-ran.marker" ] && [ "$(grep -c '1/1 PASS' "$WORK/both.log")" -ge 3 ]; then
    pass "the package's lua, the SDK's lua and an SDK-importing program resolve side by side"
else
    fail "the combined run failed"; tail -12 "$WORK/both.log" | sed 's/^/        /'
fi

echo
if [ "$FAILURES" -eq 0 ]; then echo "program-imports-package-not-sdk: all assertions passed"; exit 0; fi
echo "program-imports-package-not-sdk: $FAILURES assertion(s) failed"
exit 1
