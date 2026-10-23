#!/usr/bin/env bash
# itests/node-helper-rename-scope.sh — the node-local helper rename (static
# linkage, 55f80a6) touches CODE only.
#
# transform-ae appends `_` to every top-level helper a node defines, so the same
# helper name in two nodes cannot collide at the whole-tree link. It used to do
# that with a word-boundary sed over the whole file, which also rewrote the name
# inside string literals and comments, and turned another module's member into
# a call that doesn't exist. Seen in the selenium port: a node with a `pin(i)`
# helper printed "expected 2 version pin_(s), found …".
#
# Assertions:
#   1. STRING LITERAL — "… pin(s) …" prints unchanged.
#   2. INTERPOLATION  — "${pin(1)}" still calls the (renamed) helper.
#   3. NESTED STRING  — a string inside ${…}, opened by \", is left alone.
#   4. MEMBER ACCESS  — a node-local `trim` does not turn `string.trim(` into
#                       `string.trim_(` (which would not compile).
#   5. COMMENTS       — // and /* */ mentions of the helper are left alone.
#   6. NO COLLISION   — two nodes defining the same helper still link together.
#
# Usage: AEB=/path/to/aeb ./itests/node-helper-rename-scope.sh
# Exit: 0 if all pass; 1 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
if [ ! -x "$AEB" ]; then echo "error: aeb not found at '$AEB' (set \$AEB)" >&2; exit 1; fi

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/.pins.ae" <<'EOF'
import bldr
import std.string

// pin(i) is a node-local helper; this comment mentions pin(x) too.
pin(i: int) -> string {
    return "p${i}"
}

trim(s: string) -> string {
    return string.trim(s)
}

aeb(cap) {
    println("expected 2 version pin(s), found ${pin(1)}")
    println("nested ${string.length(\"pin(z)\")}")
    println("[${trim("  t  ")}]")
    /* block comment: pin(b) */
    return 0
}
EOF

cat > "$WORK/.other.ae" <<'EOF'
import bldr

pin(i: int) -> string {
    return "o${i}"
}

aeb(cap) {
    println("other ${pin(2)}")
    return 0
}
EOF

echo "node-helper-rename-scope:"
BUILD="$(cd "$WORK" && AEB_JOBS=1 "$AEB" .pins.ae .other.ae 2>&1)"
RC=$?
# A node's own stdout goes to its per-node log, not the build's output.
OUT="$(cat "$WORK"/target/.aeb/logs/*.log 2>/dev/null)"
GEN="$(cat "$WORK"/target/_aeb/*pins*.ae 2>/dev/null)"

if [ "$RC" -eq 0 ]; then pass "both nodes build and link together (rc 0)"
else fail "build failed (rc $RC)"; echo "$BUILD" | tail -20; fi

if echo "$OUT" | grep -qF "expected 2 version pin(s), found p1"; then pass "string literal unchanged; interpolated call renamed and runs"
else fail "string literal or interpolated call wrong"; echo "$OUT" | grep -i 'version pin' ; fi

if echo "$OUT" | grep -qF "nested 6"; then pass "nested \\\" string inside \${…} left alone"
else fail "nested string inside \${…} was rewritten"; fi

if echo "$OUT" | grep -qF "[t]"; then pass "string.trim( is not renamed by a node-local trim"
else fail "member call string.trim( was renamed"; fi

if echo "$OUT" | grep -qF "other o2"; then pass "second node's same-named helper resolves to its own"
else fail "second node's helper wrong"; fi

if [ -n "$GEN" ]; then
    if echo "$GEN" | grep -qF "mentions pin(x) too" && echo "$GEN" | grep -qF "block comment: pin(b)"; then
        pass "comments left alone"
    else fail "a comment was rewritten"; fi
    if echo "$GEN" | grep -qE '^pin_\(i: int\)' && echo "$GEN" | grep -qE '^trim_\(s: string\)'; then
        pass "helper defs renamed (static linkage kept)"
    else fail "helper defs not renamed"; fi
else
    fail "generated node source not found under target/_aeb/"
fi

if [ "$FAILURES" -eq 0 ]; then echo "node-helper-rename-scope: all passed"; exit 0; fi
echo "node-helper-rename-scope: $FAILURES failure(s)"; exit 1
