#!/usr/bin/env bash
# itests/rust-cargo-config-path.sh — the .cargo/config.toml aeb writes for a rust
# module points at the workspace's local registry whatever depth the module is at.
#
# It hard-coded local-registry = '../../../libs/rust/registry', right only for a
# module whose target dir sits exactly three levels below the root. Fixture: a
# stub `cargo` on PATH (no Rust toolchain needed) and modules at depth 1 and 4;
# the real registry dir exists at <root>/libs/rust/registry. Assertion: resolving
# the written local-registry path against the dir that contains `.cargo`
# (cargo's rule) lands on that registry dir.
#
# Usage: AETHER=/path/to/ae ./itests/rust-cargo-config-path.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export AEB_CACHE_DIR="$WORK/cache"

mkdir -p "$WORK/bin" "$WORK/proj/libs/rust/registry"
(cd "$WORK/proj" && git init -q .)
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/cargo"; chmod +x "$WORK/bin/cargo"

for mod in one a/b/c/d; do
    echo "module at depth: $mod"
    mkdir -p "$WORK/proj/$mod"
    printf '[package]\nname = "m"\nversion = "0.1.0"\n' > "$WORK/proj/$mod/Cargo.toml"
    cat > "$WORK/proj/$mod/.build.ae" <<EOT
import bldr
import rust
main() {
    bldr.build() {
        rust.cargo_project_existing()
    }
}
EOT
    (cd "$WORK/proj" && PATH="$WORK/bin:$PATH" "$AEB" "$mod/.build.ae" >"$WORK/out.txt" 2>&1) \
        && pass "build passed" || { fail "build failed: $(tail -5 "$WORK/out.txt")"; continue; }
    cfg="$(find "$WORK/proj/target" -path "*$mod/.cargo/config.toml" | head -1)"
    if [ -z "$cfg" ]; then fail "no config.toml written under target/ for $mod"; continue; fi
    rel="$(sed -n "s/^local-registry = '\(.*\)'$/\1/p" "$cfg")"
    resolved="$(cd "$(dirname "$cfg")/.." && cd "$rel" 2>/dev/null && pwd -P)"
    if [ "$resolved" = "$WORK/proj/libs/rust/registry" ]; then
        pass "local-registry '$rel' resolves to the workspace registry"
    else
        fail "local-registry '$rel' resolves to '${resolved:-nowhere}', want $WORK/proj/libs/rust/registry"
    fi
done

if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILURES FAILURE(S)"; exit 1
