#!/usr/bin/env bash
# itests/janet-sdk.sh — the Janet SDK (lib/janet) end to end on a tiny project.
#
# Fixture (synthesised in a temp dir, no network: the dependency is a local git
# repo reached over file://):
#   dep/        jpm project `mydep` exporting (hello)
#   app/        jpm project depending on dep; test/pass.janet imports mydep,
#               test/fail.janet asserts false
#
# Asserts:
#   1. janet.deps    installs the dependency into the PROJECT-LOCAL tree.
#   2. janet.test    green: a passing script that imports the dep through
#                    JANET_PATH=<tree>/lib (and sees env(K,V)) exits 0.
#   3. janet.test    red: a failing script turns the build red (non-zero).
#   4. janet.test    with no script runs `jpm test` (test/*.janet) green.
#   5. janet.install of the project, and of a git URL, lands in its own tree.
#   6. janet.package copies a bundle() file in and publishes package_dir.
#   7. missing toolchain is a clear error, not a green skip (janet_bin to a
#      nonexistent binary).
#
# Skips (exit 0, loudly) when janet or jpm is not installed.
# Usage: AEB=/path/to/aeb ./itests/janet-sdk.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
if [ ! -x "$AEB" ]; then echo "error: aeb not found at '$AEB' (set \$AEB)" >&2; exit 1; fi
if ! command -v janet >/dev/null 2>&1 || { ! command -v jpm >/dev/null 2>&1 && ! command -v janet-pm >/dev/null 2>&1; }; then
    echo "janet-sdk: SKIPPED (janet and jpm/janet-pm not on PATH)"; exit 0
fi

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/dep" "$WORK/app/test" "$WORK/app2/test"
cat > "$WORK/dep/project.janet" <<'JEOF'
(declare-project :name "mydep" :description "dep")
(declare-source :source ["mydep.janet"])
JEOF
echo '(defn hello [] "hi from dep")' > "$WORK/dep/mydep.janet"
( cd "$WORK/dep" && git init -q . && git add . \
  && git -c user.email=t@t -c user.name=t commit -qm init ) || { echo "git failed"; exit 1; }

for d in app app2; do
    cat > "$WORK/$d/project.janet" <<JEOF
(declare-project :name "$d" :description "$d" :dependencies ["file://$WORK/dep"])
(declare-source :source ["$d.janet"])
JEOF
    echo '(defn answer [] 42)' > "$WORK/$d/$d.janet"
done
cat > "$WORK/app/test/pass.janet" <<'JEOF'
(import mydep)
(assert (= (mydep/hello) "hi from dep") "dep visible via JANET_PATH")
(assert (= (os/getenv "JANET_SDK_FLAG") "on") "env() reaches the script")
JEOF
echo '(assert false "deliberate failure")' > "$WORK/app/test/fail.janet"
# app2's test/ holds only a passing script, for the script-less `jpm test` path.
echo '(import mydep) (assert (= (mydep/hello) "hi from dep"))' > "$WORK/app2/test/pass.janet"
echo blob > "$WORK/blob.txt"

# mknode <dir> <name> <body>: write <dir>/.<name>.ae wrapping <body> in bldr.build
mknode() {
    cat > "$WORK/$1/.$2.ae" <<AEOF
import bldr
import janet
import janet (script, tree, bundle, install_from, janet_bin)
aeb(cap) {
    bldr.build() {
$3
    }
}
AEOF
}
runnode() { ( cd "$WORK" && "$AEB" "$1/.$2.ae" ) >"$WORK/$2.log" 2>&1; }

mknode app deps "        janet.deps() { tree(\"$WORK/tree\") }"
mknode app ok "        dep(\"app/.deps.ae\")
        janet.test() {
            tree(\"$WORK/tree\")
            env(\"JANET_SDK_FLAG\", \"on\")
            script(\"test/pass.janet\")
        }"
mknode app bad "        dep(\"app/.deps.ae\")
        janet.test() {
            tree(\"$WORK/tree\")
            script(\"test/fail.janet\")
        }"
mknode app2 pm "        dep(\"app/.deps.ae\")
        janet.test() { tree(\"$WORK/tree\") }"
mknode app inst "        janet.install() { tree(\"$WORK/tree2\") }"
mknode app instgit "        janet.install() {
            tree(\"$WORK/tree3\")
            install_from(\"file://$WORK/dep\")
        }"
mknode app pkg "        janet.package() { bundle(\"$WORK/blob.txt\", \"native/blob.txt\") }"
mknode app nojanet "        janet.test() {
            janet_bin(\"/nonexistent/janet\")
            script(\"test/pass.janet\")
        }"

echo "janet-sdk: deps"
if runnode app deps && [ -f "$WORK/tree/lib/mydep.janet" ]; then pass "jpm deps installed mydep into the local tree"
else fail "deps"; cat "$WORK/deps.log"; fi

echo "janet-sdk: test (green)"
if runnode app ok; then pass "passing script, dep via JANET_PATH, env() honoured"
else fail "green test went red"; cat "$WORK/ok.log"; fi

echo "janet-sdk: test (red)"
if runnode app bad; then fail "failing script left the build green"; else pass "failing script turns the build red"; fi

echo "janet-sdk: test via jpm test"
if runnode app2 pm; then pass "script-less test runs jpm test"
else fail "jpm test path"; cat "$WORK/pm.log"; fi

echo "janet-sdk: install"
if runnode app inst && [ -f "$WORK/tree2/lib/app.janet" ]; then pass "jpm install of the project into its own tree"
else fail "install"; cat "$WORK/inst.log"; fi
if runnode app instgit && [ -f "$WORK/tree3/lib/mydep.janet" ]; then pass "jpm install of a git URL"
else fail "install git"; cat "$WORK/instgit.log"; fi

echo "janet-sdk: package"
if runnode app pkg && [ -f "$WORK/app/native/blob.txt" ]; then pass "bundle() staged, package built"
else fail "package"; cat "$WORK/pkg.log"; fi

echo "janet-sdk: missing toolchain"
if runnode app nojanet; then fail "missing janet left the build green"
elif grep -rq "janet not found" "$WORK/nojanet.log" "$WORK"/target/.aeb/logs 2>/dev/null; then pass "missing janet is a clear error"
else fail "missing janet failed without a clear message"; cat "$WORK/nojanet.log"; fi

if [ "$FAILURES" -eq 0 ]; then echo "janet-sdk: all passed"; exit 0; fi
echo "janet-sdk: $FAILURES failure(s)"; exit 1
