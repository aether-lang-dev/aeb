#!/usr/bin/env bash
# get.sh and tools/gh-release-fetch.sh survive GitHub's release-download
# endpoint failing: every https://github.com/<repo>/releases/download/... URL
# answered HTTP 504 for aether on 2026-11-09 while the REST API served the same
# assets. The mock (gh-mock.py) 504s the download URLs and serves the API;
# AE_GITHUB_WEB_BASE / AE_GITHUB_API_BASE point the scripts at it. Nothing
# touches the public internet.
#
#   1. the function in get.sh and in tools/gh-release-fetch.sh are the same text,
#   2. the helper fetches through the API, as octet-stream, unauthenticated by
#      default and with GITHUB_TOKEN / GH_TOKEN as a Bearer token when set
#      (never on the web URL), and checks the listed sha256 digest,
#   3. a bad digest, an unlisted asset and a dead API each fail, the last two
#      saying both ways were tried,
#   4. with wget only (no curl) the helper does the same, when wget exists,
#   5. get.sh installs a pinned ae and aeb (the checksum sidecar included)
#      while the download URLs 504, and the result runs.
#
# Usage: itests/gh-release-fallback.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 needed"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl needed"; exit 0; }
if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"; else SHA="shasum -a 256"; fi

WORK="$(mktemp -d)"
SRV=""
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; wait 2>/dev/null; rm -rf "${WORK:?}"; }
trap cleanup EXIT
FAILURES=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); [ -n "${2:-}" ] && [ -f "$2" ] && sed 's/^/        /' "$2"; }

# --- 1. the two copies match ---------------------------------------------------
blk() { sed -n '/^# >>> gh-release-download/,/^# <<< gh-release-download/p' "$1"; }
if [ -n "$(blk "$ROOT/get.sh")" ] && [ "$(blk "$ROOT/get.sh")" = "$(blk "$ROOT/tools/gh-release-fetch.sh")" ]; then
    pass "get.sh and tools/gh-release-fetch.sh carry the same function"
else
    fail "the gh-release-download block differs between get.sh and tools/gh-release-fetch.sh"
fi

case "$(uname -s)" in Linux) OS=linux ;; Darwin) OS=macos ;; FreeBSD) OS=freebsd ;; *) echo "SKIP: platform"; exit 0 ;; esac
case "$(uname -m)" in x86_64|amd64) ARCH=x86_64 ;; arm64|aarch64) ARCH=arm64 ;; *) echo "SKIP: arch"; exit 0 ;; esac

REL="$WORK/rel"; mkdir -p "$REL"
printf 'payload-%s\n' "$(date +%s)" > "$REL/blob.bin"
head -c 3000 /dev/urandom >> "$REL/blob.bin"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
BASE="http://127.0.0.1:$PORT"
start_mock() {
    [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; }
    : > "$REL/requests.log"
    python3 "$HERE/gh-mock.py" "$PORT" "$REL" "$1" >/dev/null 2>&1 &
    SRV=$!
    i=0; while [ "$i" -lt 50 ]; do curl -s -o /dev/null "$BASE/" 2>/dev/null && return 0; i=$((i+1)); sleep 0.1; done
    echo "SKIP: mock did not start"; exit 0
}
envx() { env -u GITHUB_TOKEN -u GH_TOKEN AE_GITHUB_WEB_BASE="$BASE" AE_GITHUB_API_BASE="$BASE" "$@"; }

# --- 2. the helper ----------------------------------------------------------------
start_mock ok
if envx sh "$ROOT/tools/gh-release-fetch.sh" o/r v1.0 blob.bin "$WORK/out1" 2>"$WORK/h1.err" \
   && cmp -s "$WORK/out1" "$REL/blob.bin"; then pass "helper: 504 on the download URL, bytes arrive through the API"
else fail "helper did not fetch through the API" "$WORK/h1.err"; fi
grep -q "releases/assets/1000 auth=- accept=application/octet-stream" "$REL/requests.log" \
    && pass "helper: asset requested as octet-stream, no Authorization by default" \
    || fail "helper: asset request not as expected" "$REL/requests.log"

start_mock ok
envx GITHUB_TOKEN=ghp_tok123 sh "$ROOT/tools/gh-release-fetch.sh" o/r v1.0 blob.bin "$WORK/out2" 2>/dev/null
grep -q "releases/assets/1000 auth=Bearer ghp_tok123" "$REL/requests.log" \
    && ! grep -q "releases/download/.*auth=Bearer" "$REL/requests.log" \
    && pass "helper: GITHUB_TOKEN sent as Bearer to the API only" || fail "helper: token handling" "$REL/requests.log"
start_mock ok
envx GH_TOKEN=ghp_gh456 sh "$ROOT/tools/gh-release-fetch.sh" o/r v1.0 blob.bin "$WORK/out2b" 2>/dev/null
grep -q "releases/assets/1000 auth=Bearer ghp_gh456" "$REL/requests.log" \
    && pass "helper: GH_TOKEN honoured too" || fail "helper: GH_TOKEN" "$REL/requests.log"

# --- 3. failures ----------------------------------------------------------------------
start_mock baddigest
if envx sh "$ROOT/tools/gh-release-fetch.sh" o/r v1.0 blob.bin "$WORK/out3" 2>"$WORK/h3.err"; then fail "a wrong digest was accepted"
elif grep -q "digest" "$WORK/h3.err" && [ ! -e "$WORK/out3" ]; then pass "helper: wrong digest refused, file removed"
else fail "wrong digest handling" "$WORK/h3.err"; fi
start_mock noasset
if envx sh "$ROOT/tools/gh-release-fetch.sh" o/r v1.0 blob.bin "$WORK/out4" 2>"$WORK/h4.err"; then fail "unlisted asset accepted"
elif grep -q "both the release URL and the GitHub API failed" "$WORK/h4.err" && grep -q "no asset" "$WORK/h4.err"; then pass "helper: unlisted asset says both ways failed"
else fail "unlisted asset message" "$WORK/h4.err"; fi
start_mock apidown
if envx sh "$ROOT/tools/gh-release-fetch.sh" o/r v1.0 blob.bin "$WORK/out5" 2>"$WORK/h5.err"; then fail "dead API accepted"
elif grep -q "both the release URL and the GitHub API failed" "$WORK/h5.err"; then pass "helper: dead API says both ways failed"
else fail "dead API message" "$WORK/h5.err"; fi

# --- 4. wget only ---------------------------------------------------------------------------
if command -v wget >/dev/null 2>&1; then
    NOCURL="$WORK/nocurl"; mkdir -p "$NOCURL"
    for t in sh awk tr sed cat rm mktemp printf cp head sha256sum shasum wget uname env dirname cmp; do
        p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && [ -x "$p" ] && ln -sf "$p" "$NOCURL/$t"
    done
    start_mock ok
    if envx PATH="$NOCURL" "$NOCURL/sh" "$ROOT/tools/gh-release-fetch.sh" o/r v1.0 blob.bin "$WORK/out6" 2>"$WORK/h6.err" \
       && cmp -s "$WORK/out6" "$REL/blob.bin"; then pass "helper: works with wget and no curl"
    else fail "helper with wget only" "$WORK/h6.err"; fi
else
    echo "  SKIP: no wget on this host"
fi

# --- 5. get.sh, end to end -----------------------------------------------------------------------
rm -f "${REL:?}/blob.bin" "${REL:?}/requests.log"
mkdir -p "$WORK/ae/bin" "$WORK/aebpkg/aeb-$OS-$ARCH"
printf '#!/bin/sh\necho "ae 9.9.9 (fake)"\n' > "$WORK/ae/bin/ae"; chmod 755 "$WORK/ae/bin/ae"; cp "$WORK/ae/bin/ae" "$WORK/ae/bin/aetherc"
( cd "$WORK/ae" && COPYFILE_DISABLE=1 tar -czf "$REL/aether-9.9.9-$OS-$ARCH.tar.gz" bin )
cat > "$WORK/aebpkg/aeb-$OS-$ARCH/install.sh" <<'INST'
#!/bin/sh
mkdir -p "$1/bin"
printf '#!/bin/sh\necho "aeb v0.999"\n' > "$1/bin/aeb"
chmod 755 "$1/bin/aeb"
INST
( cd "$WORK/aebpkg" && COPYFILE_DISABLE=1 tar -czf "$REL/aeb-$OS-$ARCH.tar.gz" "aeb-$OS-$ARCH" )
( cd "$REL" && $SHA "aeb-$OS-$ARCH.tar.gz" | awk '{print $1"  aeb-'"$OS-$ARCH"'.tar.gz"}' > "aeb-$OS-$ARCH.tar.gz.sha256" )

start_mock ok
PFX="$WORK/prefix"
# A PATH with no ae or aeb of its own, so the pins are what is being satisfied.
envx PATH="/usr/bin:/bin" PREFIX="$PFX" AE_PIN=9.9.9 AEB_REF=v0.999 sh "$ROOT/get.sh" >"$WORK/get.out" 2>&1
rc=$?
if [ "$rc" = 0 ] && [ "$("$PFX/bin/ae" --version)" = "ae 9.9.9 (fake)" ] && [ "$("$PFX/bin/aeb" --version)" = "aeb v0.999" ]; then
    pass "get.sh: ae 9.9.9 and aeb v0.999 installed while every download URL 504s"
else
    fail "get.sh did not install both tools through the API (rc=$rc)" "$WORK/get.out"
fi
grep -q "sha256 OK" "$WORK/get.out" && pass "get.sh: aeb .sha256 sidecar fetched through the API and verified" \
    || fail "get.sh: aeb checksum not verified" "$WORK/get.out"

echo
if [ "$FAILURES" -eq 0 ]; then echo "gh-release-fallback: PASS"; exit 0; fi
echo "gh-release-fallback: FAIL ($FAILURES)"; exit 1
