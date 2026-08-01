#!/usr/bin/env bash
# itests/toolchain-fetch.sh — the trampoline's private-Aether fetch.
#
# WHY THIS EXISTS. Nothing tested this path, and it silently drifted from
# its own documentation for months: the trampoline built Aether FROM
# SOURCE via upstream's get.sh (~69 s, needs a C compiler), while
# .github/workflows/release.yml fetched the PREBUILT tarball (<1 s) under
# a comment saying it did so "the same way a cold node would" — and
# docs/aeb-host-vm-or-container-setup.md asserted "Aether itself is a
# 2.8 MB binary tarball, not a source build". Three places, two
# behaviours, no test to notice. The fetch now prefers the prebuilt and
# falls back to source; this pins that so it cannot quietly invert again.
#
# HOW IT AVOIDS THE NETWORK. Downloading a real toolchain per assertion
# would make this slow and flaky, and the source fallback alone is ~70 s.
# So `curl` is stubbed on PATH and serves fixtures from a temp dir. That
# is not a cop-out: every property under test is about what the
# TRAMPOLINE does with what it receives — which URL it asks for, whether
# it probes before caching, what it does when the probe fails — and none
# of that needs GitHub. The one thing a stub cannot prove (that the URL
# actually resolves) is covered separately by the --live round below.
#
# Assertions:
#   1. ASSET URL      — asks for the release asset, not get.sh, and names
#                       it aether-<ver>-<os>-<arch>.<ext>
#   2. PROBE GATE     — a downloaded tree that cannot COMPILE is rejected
#                       and never cached, even though it unpacks fine and
#                       has an executable bin/ae
#   3. NO POISON      — after such a rejection the cache holds no usable
#                       toolchain (the `-x bin/ae` fast path on the next
#                       run must not adopt it)
#   4. SOURCE FALLBACK— when the prebuilt 404s, get.sh is fetched instead
#   5. OPT OUT        — AEB_FETCH_SOURCE=1 skips the prebuilt entirely
#   6. NO FETCH       — AEB_NO_FETCH=1 exits 2 and downloads nothing
#   7. LOG SURVIVES   — the log the failure message names actually EXISTS
#                       (it used to live inside the dir the success path
#                       rm -rf's, so it vanished exactly when needed)
#   8. CACHE REUSE    — a populated cache short-circuits with no download
#
# Assertion 2 is the load-bearing one. Upstream publishes no .sha256, so
# the compile probe is the ONLY integrity gate on the fast path — and the
# cache is consulted with a bare `-x .../bin/ae` on every later run, so a
# bad tree admitted once is reused forever.
#
# Usage:
#   cd itests && ./toolchain-fetch.sh          # stubbed, no network
#   ./toolchain-fetch.sh --live                # + one real download
#
# Exit code: 0 if every assertion passed; 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"

LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1

if [ ! -x "$AEB" ]; then
    echo "error: aeb not found/executable at '$AEB' (set \$AEB)" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "[toolchain-fetch]"

FETCH_VER="$(grep -v '^#' "$REPO_ROOT/AETHER_FETCH" 2>/dev/null | tr -d '[:space:]')"
[ -n "$FETCH_VER" ] || { echo "error: cannot read AETHER_FETCH" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Stub curl. Records every URL it is asked for (so assertions can inspect
# WHICH url, not just whether something was fetched), and serves whatever
# fixture $STUB_MODE selects.
#
# The real invocation is:  curl -fsSL -o <path> <url>
# so the stub parses -o and takes the last argument as the URL.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/stub"
cat > "$WORK/stub/curl" <<'STUB'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift; out="$1" ;;
        -*) : ;;
        *)  url="$1" ;;
    esac
    shift
done
echo "$url" >> "$STUB_URLS"
case "$STUB_MODE" in
    asset-ok)
        # A well-formed archive whose bin/ae CANNOT compile. Unpacks
        # cleanly, is executable, passes any --version-style check that
        # only looks at exit status — and fails the compile probe.
        case "$url" in
            *releases/download/*) cp "$STUB_FIXTURE" "$out"; exit 0 ;;
            *) exit 22 ;;
        esac ;;
    asset-good)
        # An archive whose bin/ae DOES satisfy the compile probe, so the
        # SUCCESS path runs — the one that rm -rf's $_aeb_priv.
        case "$url" in
            *releases/download/*) cp "$STUB_GOOD" "$out"; exit 0 ;;
            *) exit 22 ;;
        esac ;;
    asset-404)
        # Prebuilt missing; get.sh must then be requested.
        case "$url" in
            *releases/download/*) exit 22 ;;
            *get.sh) printf '#!/bin/sh\nexit 7\n' > "$out"; exit 0 ;;
            *) exit 22 ;;
        esac ;;
    all-404) exit 22 ;;
esac
exit 22
STUB
chmod +x "$WORK/stub/curl"

# Fixture 1 — bin/ae exists and is executable, but is not a compiler.
mkdir -p "$WORK/fixture/bin"
printf '#!/bin/sh\necho "ae 99.0.0 (fake)"\nexit 0\n' > "$WORK/fixture/bin/ae"
chmod +x "$WORK/fixture/bin/ae"
( cd "$WORK/fixture" && tar czf "$WORK/fake-toolchain.tgz" bin )

# Fixture 2 — bin/ae that satisfies the compile probe by echoing what the
# probe greps for. Enough to exercise the ACCEPT path (stage -> probe ->
# rm -rf $_aeb_priv -> mv into place) without a 2 MB real toolchain.
mkdir -p "$WORK/good/bin"
printf '#!/bin/sh\n[ "$1" = "run" ] && echo aeb_probe_ok\nexit 0\n' > "$WORK/good/bin/ae"
chmod +x "$WORK/good/bin/ae"
( cd "$WORK/good" && tar czf "$WORK/good-toolchain.tgz" bin )

# run_aeb <mode> <cache> [extra env assignments...] — invoke aeb with the
# stub on PATH and a scratch cache. `ae` is deliberately absent from PATH
# so the pin check always decides to fetch.
run_aeb() {
    _mode="$1"; _cache="$2"; shift 2
    rm -rf "$_cache"
    : > "$WORK/urls.txt"
    env -u AETHER \
        PATH="$WORK/stub:/usr/bin:/bin" \
        AEB_CACHE_DIR="$_cache" \
        STUB_MODE="$_mode" \
        STUB_URLS="$WORK/urls.txt" \
        STUB_FIXTURE="$WORK/fake-toolchain.tgz" \
        STUB_GOOD="$WORK/good-toolchain.tgz" \
        "$@" \
        "$AEB" --version >"$WORK/out.txt" 2>&1
    echo $? > "$WORK/rc.txt"
}

# --- 1 + 2 + 3 + 7: prebuilt requested, probe rejects it, nothing cached ---
run_aeb asset-ok "$WORK/c1"

if grep -q "releases/download/v$FETCH_VER/aether-$FETCH_VER-" "$WORK/urls.txt"; then
    pass "asks for the prebuilt release asset (not get.sh) first"
else
    fail "did not request the prebuilt release asset"
    sed 's/^/        /' "$WORK/urls.txt"
fi

# The asset name must carry a platform, matching upstream's scheme. Not
# pinned to THIS runner's platform — the point is the shape.
if grep -qE "aether-$FETCH_VER-(linux|macos|windows|freebsd)-(x86_64|arm64)\.(tar\.gz|zip)" "$WORK/urls.txt"; then
    pass "asset name follows aether-<ver>-<os>-<arch>.<ext>"
else
    fail "asset name does not match upstream's naming scheme"
    sed 's/^/        /' "$WORK/urls.txt"
fi

# The fixture unpacks fine and bin/ae runs — only COMPILING fails. If the
# trampoline ever regresses to a --version check, this flips.
if grep -q "no usable prebuilt" "$WORK/out.txt"; then
    pass "compile probe rejects a toolchain that unpacks but cannot build"
else
    fail "a non-compiling toolchain was accepted (probe regressed to --version?)"
    grep '^aeb:' "$WORK/out.txt" | sed 's/^/        /'
fi

if [ ! -x "$WORK/c1/toolchain/aether-$FETCH_VER/bin/ae" ]; then
    pass "rejected toolchain is NOT left in the cache"
else
    fail "cache poisoned — a later run would reuse the bad tree forever"
fi

# The failure message names a log; that log has to exist. It used to be
# written inside the dir the success path rm -rf's.
LOGLINE="$(grep -o '(see [^)]*)' "$WORK/out.txt" | head -1 | sed -e 's/^(see //' -e 's/)$//')"
if [ -n "$LOGLINE" ] && [ -f "$LOGLINE" ]; then
    pass "the log named in the failure message exists"
else
    fail "failure message points at a nonexistent log: '${LOGLINE:-<none>}'"
fi

# --- ACCEPT PATH: probe passes -> tree is cached, log still exists ---------
# Exercises the branch the rejection cases never reach: rm -rf "$_aeb_priv"
# followed by mv of the staged tree. The log must survive THAT, which is
# why it lives outside $_aeb_priv — a log written inside the dir being
# deleted would vanish exactly when a failed `mv` needed reporting.
run_aeb asset-good "$WORK/c6"

if [ -x "$WORK/c6/toolchain/aether-$FETCH_VER/bin/ae" ]; then
    pass "accept path: probe-passing toolchain lands in the cache"
else
    fail "accept path: probe-passing toolchain was not cached"
    grep '^aeb:' "$WORK/out.txt" | sed 's/^/        /'
fi

if grep -q 'ready (prebuilt' "$WORK/out.txt"; then
    pass "accept path: reports which path it took"
else
    fail "accept path: no 'ready (prebuilt ...)' line"
fi

# The staged temp dir must not be left behind.
if ! ls -d "$WORK/c6/toolchain/".dl-* >/dev/null 2>&1; then
    pass "accept path: staging dir cleaned up"
else
    fail "accept path: left a .dl-* staging dir behind"
fi

# THE POINT OF THIS BLOCK: the log survives the success path's rm -rf.
if [ -f "$WORK/c6/toolchain/fetch-$FETCH_VER.log" ]; then
    pass "accept path: fetch log survives (lives outside the wiped dir)"
else
    fail "accept path: fetch log destroyed by the cache swap"
fi

# --- 4: prebuilt 404 -> source fallback ------------------------------------
run_aeb asset-404 "$WORK/c2"
if grep -q 'get\.sh' "$WORK/urls.txt"; then
    pass "falls back to get.sh when the prebuilt is unavailable"
else
    fail "no source fallback attempted after a 404"
    sed 's/^/        /' "$WORK/urls.txt"
fi

# --- 5: AEB_FETCH_SOURCE=1 skips the prebuilt entirely ---------------------
run_aeb asset-ok "$WORK/c3" AEB_FETCH_SOURCE=1
if grep -q 'releases/download' "$WORK/urls.txt"; then
    fail "AEB_FETCH_SOURCE=1 still requested the prebuilt"
else
    pass "AEB_FETCH_SOURCE=1 skips the prebuilt"
fi
if grep -q 'AEB_FETCH_SOURCE=1' "$WORK/out.txt"; then
    pass "AEB_FETCH_SOURCE=1 says so, rather than silently changing path"
else
    fail "AEB_FETCH_SOURCE=1 gave no indication it took effect"
fi

# --- 6: AEB_NO_FETCH=1 downloads nothing and exits 2 -----------------------
run_aeb asset-ok "$WORK/c4" AEB_NO_FETCH=1
if [ "$(cat "$WORK/rc.txt")" = "2" ]; then
    pass "AEB_NO_FETCH=1 exits 2"
else
    fail "AEB_NO_FETCH=1 exited $(cat "$WORK/rc.txt"), expected 2"
fi
if [ ! -s "$WORK/urls.txt" ]; then
    pass "AEB_NO_FETCH=1 downloads nothing at all"
else
    fail "AEB_NO_FETCH=1 still hit the network"
    sed 's/^/        /' "$WORK/urls.txt"
fi

# --- 8: a populated cache short-circuits with no download ------------------
# Hand-build a cache entry with a bin/ae that DOES satisfy the fast path
# (`-x`), and assert no curl happens. This is the steady state — every run
# after the first — so a regression here would mean re-downloading forever.
mkdir -p "$WORK/c5/toolchain/aether-$FETCH_VER/bin"
printf '#!/bin/sh\necho "ae %s (cached)"\nexit 0\n' "$FETCH_VER" \
    > "$WORK/c5/toolchain/aether-$FETCH_VER/bin/ae"
chmod +x "$WORK/c5/toolchain/aether-$FETCH_VER/bin/ae"
: > "$WORK/urls.txt"
env -u AETHER PATH="$WORK/stub:/usr/bin:/bin" AEB_CACHE_DIR="$WORK/c5" \
    STUB_MODE=all-404 STUB_URLS="$WORK/urls.txt" STUB_FIXTURE="$WORK/fake-toolchain.tgz" \
    "$AEB" --version >"$WORK/out5.txt" 2>&1
if [ ! -s "$WORK/urls.txt" ]; then
    pass "a populated cache short-circuits with no download"
else
    fail "re-downloaded despite a cached toolchain"
fi

# --- LIVE: the URL the stub only pretended to serve actually resolves -------
# The one property a stub cannot establish. Kept opt-in so the default run
# stays offline and fast, but without it a typo in the URL template would
# sail through every assertion above.
if [ "$LIVE" = "1" ]; then
    OS=""; EXT="tar.gz"
    case "$(uname -s)" in
        Linux) OS=linux ;; Darwin) OS=macos ;; FreeBSD) OS=freebsd ;;
        MINGW*|MSYS*|CYGWIN*) OS=windows; EXT=zip ;;
    esac
    ARCH=""
    case "$(uname -m)" in x86_64|amd64) ARCH=x86_64 ;; arm64|aarch64) ARCH=arm64 ;; esac
    ASSET="aether-$FETCH_VER-$OS-$ARCH.$EXT"
    URL="https://github.com/aether-lang-dev/aether/releases/download/v$FETCH_VER/$ASSET"
    case "$OS-$ARCH" in
        linux-x86_64|macos-arm64|macos-x86_64|windows-x86_64|freebsd-x86_64)
            if curl -fsSL -o /dev/null "$URL" 2>/dev/null; then
                pass "live: $ASSET resolves"
            else
                fail "live: $URL does not resolve"
            fi ;;
        *)
            # Not a failure: this is the case the source fallback exists for.
            echo "  SKIP: live — no asset published for $OS-$ARCH (source path covers it)" ;;
    esac
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "toolchain-fetch: PASS"
    exit 0
fi
echo "toolchain-fetch: FAIL ($FAILURES assertion(s))"
exit 1
