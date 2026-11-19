#!/usr/bin/env bash
# itests/resolver-failure-fails.sh — a Maven resolve that could not get
# everything it was asked for fails, and hands back nothing.
#
# aeb-resolve.jar used to report a coordinate it could not resolve, a jar it
# could not download or a BOM it could not read as a "warning:" and exit 0,
# printing whatever part of the classpath it did get. lib/maven took that for
# the answer: the node compiled against a short classpath and failed on a
# missing class with no mention of the coordinate, or passed and met the gap
# at run time. The part classpath was also written to the cache.
#
# Offline, like resolver-bom-ae.sh: a python3 http.server holds one artifact
# that exists nowhere else, so nothing here depends on Maven Central.
#
# Rounds 1 to 4 drive the jar; round 5 drives aeb, since the exit status has
# to reach the node (os.exec does not report one).
#
# Usage:  ./resolver-failure-fails.sh
# Exit:   0 all assertions pass, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "[resolver-failure-fails]"

JAR="${AEB_RESOLVE_JAR:-$REPO_ROOT/tools/aeb-resolve.jar}"
[ -f "$JAR" ] || JAR="$HOME/.local/share/aeb/tools/aeb-resolve.jar"
if [ ! -f "$JAR" ]; then
    echo "  SKIP: no aeb-resolve.jar (build it: aeb tools/resolver/.dist.ae)"
    exit 0
fi
for tool in java javac python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "  SKIP: no $tool on PATH"
        exit 0
    fi
done
echo "  jar: $JAR"

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t aeb_resolver_fail)"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# --- a fake Maven repository holding com.example:widget:1.0.0 only ----------
REPO="$TMP/repo"
mkdir -p "$REPO/com/example/widget/1.0.0"
cat > "$REPO/com/example/widget/1.0.0/widget-1.0.0.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>widget</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
</project>
POM
printf 'PK\005\006\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' \
    > "$REPO/com/example/widget/1.0.0/widget-1.0.0.jar"

( cd "$REPO" && exec python3 -u -m http.server 0 --bind 127.0.0.1 ) \
    > "$TMP/httpd.log" 2>&1 &
SERVER_PID=$!
PORT=""
for _ in $(seq 1 50); do
    PORT=$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$TMP/httpd.log" 2>/dev/null | head -1)
    [ -n "$PORT" ] && [ "$PORT" != "0" ] && break
    sleep 0.1
done
if [ -z "$PORT" ] || [ "$PORT" = "0" ]; then
    echo "  SKIP: could not start the local repo server"
    exit 0
fi
BASE="http://127.0.0.1:$PORT"

RC=0
run_resolver() {   # run_resolver <outfile> <args...>; sets RC
    local out="$1"; shift
    java -jar "$JAR" --cache "$TMP/cache-$RANDOM" "$@" > "$out" 2> "$out.err"
    RC=$?
}

# refused <round> <text the error must carry>
refused() {
    local out="$TMP/$1.out"
    if [ "$RC" -ne 0 ]; then pass "$1: exit status $RC"; else fail "$1: exited 0"; fi
    if [ ! -s "$out" ]; then
        pass "$1: nothing on stdout"
    else
        fail "$1: part of a result on stdout: $(head -c 200 "$out")"
    fi
    if grep -q "^error: .*$2" "$out.err"; then
        pass "$1: the error names $2"
    else
        fail "$1: no 'error:' line naming $2"
        sed 's/^/        /' "$out.err" | head -5
    fi
}

echo
echo "round 0: what does resolve still does"
run_resolver "$TMP/r0.out" --output classpath --repo "$BASE" com.example:widget:1.0.0
if [ "$RC" -eq 0 ] && grep -q "widget-1.0.0.jar" "$TMP/r0.out"; then
    pass "r0: a coordinate that exists resolves, exit 0"
else
    fail "r0: the good coordinate did not resolve (rc=$RC)"
    sed 's/^/        /' "$TMP/r0.out.err" | head -5
fi

echo
echo "round 1: one coordinate of two does not exist (classpath)"
run_resolver "$TMP/r1.out" --output classpath --repo "$BASE" \
    com.example:widget:1.0.0 com.example:nosuch:9.9.9
refused r1 "com.example:nosuch:9.9.9"

echo
echo "round 2: the same, for an SBOM"
run_resolver "$TMP/r2.out" --output sbom --repo "$BASE" \
    com.example:widget:1.0.0 com.example:nosuch:9.9.9
refused r2 "com.example:nosuch:9.9.9"

echo
echo "round 3: a coordinate with no version and no BOM"
run_resolver "$TMP/r3.out" --output classpath --repo "$BASE" \
    com.example:widget:1.0.0 com.example:unversioned
refused r3 "com.example:unversioned"

echo
echo "round 4: a BOM that is not in any repository"
run_resolver "$TMP/r4.out" --output classpath --repo "$BASE" \
    --bom com.example:nobom:1.0.0 com.example:widget:1.0.0
refused r4 "com.example:nobom:1.0.0"

# --- round 5: the failure reaches the aeb node ------------------------------
echo
echo "round 5: aeb fails the node, and does not cache the part result"
PROJ="$TMP/proj"
mkdir -p "$PROJ/.aeb" "$PROJ/libs/widgets"
cat > "$PROJ/local.bom.ae" <<BOM
maven_repo("$BASE")
BOM
cat > "$PROJ/libs/widgets/.jar.ae" <<'NODE'
import bldr
import java
import java (jar_registry)
import maven (load_bom_file)
main() {
    bldr.build() {
        load_bom_file("../../local.bom.ae")
        jar_registry("com.example:widget:1.0.0")
        jar_registry("com.example:nosuch:9.9.9")
        java.jar_registry_finalize()
    }
}
NODE
export XDG_DATA_HOME="$TMP/xdg-data" XDG_CACHE_HOME="$TMP/xdg-cache"
mkdir -p "$XDG_DATA_HOME/aeb"
# The node resolves through AEB_HOME/tools/aeb-resolve.jar; point a private
# home at the jar under test without touching the checkout's tools/.
AEB_REAL_HOME="$(cd "$(dirname "$AEB")" && pwd)"
if [ "$JAR" != "$AEB_REAL_HOME/tools/aeb-resolve.jar" ]; then
    HOME_COPY="$TMP/aebhome"
    mkdir -p "$HOME_COPY"
    for e in "$AEB_REAL_HOME"/*; do
        [ "$(basename "$e")" = tools ] || ln -s "$e" "$HOME_COPY/$(basename "$e")"
    done
    mkdir -p "$HOME_COPY/tools"
    for e in "$AEB_REAL_HOME"/tools/*; do ln -s "$e" "$HOME_COPY/tools/$(basename "$e")"; done
    ln -sf "$JAR" "$HOME_COPY/tools/aeb-resolve.jar"
    AEB_RUN="$HOME_COPY/aeb"
    export AEB_HOME="$HOME_COPY"
else
    AEB_RUN="$AEB"
fi
( cd "$PROJ" && "$AEB_RUN" libs/widgets/.jar.ae ) > "$TMP/r5.log" 2>&1
rc5=$?
if [ "$rc5" -ne 0 ]; then
    pass "r5: aeb exits $rc5"
else
    fail "r5: aeb exited 0 with a coordinate unresolved"
    tail -15 "$TMP/r5.log" | sed 's/^/        /'
fi
if grep -q "com.example:nosuch:9.9.9" "$TMP/r5.log" && grep -q "FAILED" "$TMP/r5.log"; then
    pass "r5: the log names the coordinate and the node as failed"
else
    fail "r5: the log does not name the coordinate and a failed node"
    tail -15 "$TMP/r5.log" | sed 's/^/        /'
fi
if find "$PROJ/target" -name jvm_classpath_deps_including_transitive 2>/dev/null | grep -q .; then
    fail "r5: a classpath artifact was written from the part result"
else
    pass "r5: no classpath artifact from the part result"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "[resolver-failure-fails] OK"
    exit 0
fi
echo "[resolver-failure-fails] $FAILURES assertion(s) failed"
exit 1
