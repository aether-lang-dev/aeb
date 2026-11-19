#!/usr/bin/env bash
# itests/mvn-nodes-arbitration.sh — `aeb mvn add` writes a hashed node per
# Maven artifact, and a classpath that would hold one artifact at two
# versions stops until a dep_arbitration settles it.
#
# The fixture is a diamond in a Maven repository served on 127.0.0.1 (no
# Maven Central): app wants b and c; b's pom wants d:1.0, c's wants d:1.2,
# and d:1.2 alone wants e. Each d jar holds a real class whose version()
# says which jar it came from, so "which d is on the classpath" is answered
# by running the program, not by reading a file aeb wrote.
#
#   1. aeb mvn add writes five nodes, each with the jar's sha256, edges as
#      the poms declare them (both d versions), and reports the diamond.
#   2. The app does not build: the failure names the artifact, both
#      versions, who asked for each, and the line to write.
#   3. A dep_arbitration in the app settles it: the program runs with the
#      pick, and e (wanted only by the pick) is there.
#   4. Picking the other way: the program runs with 1.0, and e is gone.
#   5. An and_not list that does not name the version in contention does
#      not cover it.
#   6. A library node's arbitration is inherited by the app above it.
#   7. `aeb mvn add --pick` writes the default beside the artifact; it
#      settles the app with no line in the app; the app's own line wins
#      over it.
#   8. A node whose sha256 is not the jar's does not build.
#
# Usage:  ./mvn-nodes-arbitration.sh
# Exit:   0 all assertions pass, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "[mvn-nodes-arbitration]"

JAR="${AEB_RESOLVE_JAR:-$REPO_ROOT/tools/aeb-resolve.jar}"
[ -f "$JAR" ] || JAR="$HOME/.local/share/aeb/tools/aeb-resolve.jar"
if [ ! -f "$JAR" ]; then
    echo "  SKIP: no aeb-resolve.jar (build it: aeb tools/resolver/.dist.ae)"
    exit 0
fi
for tool in java javac jar python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "  SKIP: no $tool on PATH"
        exit 0
    fi
done
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t aeb_mvn_nodes)"
TMP="$(cd "$TMP" && pwd -P)"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# Everything aeb keeps outside the project goes under $TMP: the jar store
# (~/.cache/aeb/jars), the action cache, the resolver's downloads.
export HOME="$TMP/home" XDG_DATA_HOME="$TMP/home/xdg-data" XDG_CACHE_HOME="$TMP/home/xdg-cache"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"

# --- the repository --------------------------------------------------------
REPO="$TMP/repo"
# artifact <a> <v> <java source or ""> <dep g:a:v>...
artifact() {
    local a="$1" v="$2" src="$3"; shift 3
    local d="$REPO/x/$a/$v"
    mkdir -p "$d" "$TMP/src/$a-$v/x" "$TMP/cls/$a-$v"
    if [ -n "$src" ]; then
        printf '%s\n' "$src" > "$TMP/src/$a-$v/x/$(echo "$src" | sed -n 's/.*class \([A-Z][A-Za-z]*\).*/\1/p' | head -1).java"
        javac -d "$TMP/cls/$a-$v" "$TMP/src/$a-$v"/x/*.java || exit 1
    else
        echo "$a $v" > "$TMP/cls/$a-$v/marker-$a.txt"
    fi
    ( cd "$TMP/cls/$a-$v" && jar cf "$d/$a-$v.jar" . ) || exit 1
    {
        echo "<project><modelVersion>4.0.0</modelVersion>"
        echo "<groupId>x</groupId><artifactId>$a</artifactId><version>$v</version><dependencies>"
        for dep in "$@"; do
            IFS=: read -r dg da dv <<<"$dep"
            echo "<dependency><groupId>$dg</groupId><artifactId>$da</artifactId><version>$dv</version></dependency>"
        done
        echo "</dependencies></project>"
    } > "$d/$a-$v.pom"
}
artifact b 1   "" x:d:1.0
artifact c 1   "" x:d:1.2
artifact d 1.0 'package x; public class D { public static String version() { return "1.0"; } }'
artifact d 1.2 'package x; public class D { public static String version() { return "1.2"; } }' x:e:1
artifact e 1   'package x; public class E { }'

( cd "$REPO" && exec python3 -u -m http.server 0 --bind 127.0.0.1 ) > "$TMP/httpd.log" 2>&1 &
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

# --- an aeb home that resolves with the jar under test ----------------------
AEB_REAL_HOME="$(cd "$(dirname "$AEB")" && pwd)"
HOME_COPY="$TMP/aebhome"
mkdir -p "$HOME_COPY/tools"
for e in "$AEB_REAL_HOME"/*; do
    [ "$(basename "$e")" = tools ] || ln -s "$e" "$HOME_COPY/$(basename "$e")"
done
for e in "$AEB_REAL_HOME"/tools/*; do ln -s "$e" "$HOME_COPY/tools/$(basename "$e")"; done
ln -sf "$JAR" "$HOME_COPY/tools/aeb-resolve.jar"
export AEB_HOME="$HOME_COPY"
AEB_RUN="$HOME_COPY/aeb"

# --- the project ------------------------------------------------------------
PROJ="$TMP/proj"
mkdir -p "$PROJ/.aeb" "$PROJ/app" "$PROJ/lib"
cat > "$PROJ/app/Main.java" <<'JAVA'
public class Main {
    public static void main(String[] a) {
        String e = "absent";
        try { Class.forName("x.E"); e = "present"; } catch (ClassNotFoundException x) { }
        System.out.println("D=" + x.D.version() + " E=" + e);
    }
}
JAVA
# app_node <extra import names> <lines before the builders>
app_node() {
    {
        echo 'import bldr'
        echo "import bldr (dep$1)"
        echo 'import java'
        echo 'main() {'
        echo '    bldr.build() {'
        printf '%s\n' "$2"
        echo '        java.javac()'
        echo '        java.java_main("Main")'
        echo '    }'
        echo '}'
    } > "$PROJ/app/.build.ae"
}
B='        dep("third_party/java/x/b/1/.jar.ae")'
C='        dep("third_party/java/x/c/1/.jar.ae")'
build_app() {   # build_app <log>; sets RC
    rm -rf "$PROJ/target"
    ( cd "$PROJ" && "$AEB_RUN" app/.build.ae ) > "$1" 2>&1
    RC=$?
}
ran_with() {    # ran_with <log> <expected output line> <what>
    if [ "$RC" -eq 0 ] && grep -rqx "$2" "$1" "$PROJ/target/.aeb/logs" 2>/dev/null; then
        pass "$3"
    else
        fail "$3 (rc=$RC, wanted the program to print '$2')"
        grep -rh "D=\|FAILED\|more than one" "$1" "$PROJ/target/.aeb/logs" 2>/dev/null | sort -u | head -6 | sed 's/^/        /'
    fi
}

echo
echo "1: aeb mvn add"
( cd "$PROJ" && "$AEB_RUN" mvn add --repo "$BASE" x:b:1 x:c:1 ) > "$TMP/add.log" 2> "$TMP/add.err"
rc=$?
n=$(find "$PROJ/third_party/java" -name .jar.ae 2>/dev/null | wc -l | tr -d ' ')
if [ "$rc" -eq 0 ] && [ "$n" = 5 ]; then pass "five nodes written"; else
    fail "expected five nodes, exit 0 (rc=$rc, nodes=$n)"; tail -5 "$TMP/add.err" | sed 's/^/        /'; fi
want_sha="$(sha256_of "$REPO/x/d/1.2/d-1.2.jar")"
if grep -q "java.jar_maven(\"x:d:1.2\", \"$want_sha\")" "$PROJ/third_party/java/x/d/1.2/.jar.ae" 2>/dev/null; then
    pass "a node carries its jar's sha256"
else
    fail "x:d:1.2's node does not carry sha256 $want_sha"
fi
if grep -q 'dep("third_party/java/x/d/1.0/.jar.ae")' "$PROJ/third_party/java/x/b/1/.jar.ae" 2>/dev/null \
   && grep -q 'dep("third_party/java/x/d/1.2/.jar.ae")' "$PROJ/third_party/java/x/c/1/.jar.ae" 2>/dev/null; then
    pass "edges are as each pom declares: b to d:1.0, c to d:1.2"
else
    fail "an edge was changed from what the pom declares"
fi
if grep -q "^diamond: x:d" "$TMP/add.log" && grep -q "1.0  asked for by x:b:1" "$TMP/add.log" \
   && grep -q "1.2  asked for by x:c:1" "$TMP/add.log"; then
    pass "the diamond is reported, with who asked for each version"
else
    fail "the diamond was not reported"; sed 's/^/        /' "$TMP/add.log" | head -8
fi
( cd "$PROJ" && "$AEB_RUN" mvn add --repo "$BASE" x:b:1 x:c:1 ) > "$TMP/add2.log" 2>/dev/null
if grep -q "0 nodes written, 5 unchanged" "$TMP/add2.log"; then
    pass "a second run changes nothing"
else
    fail "a second run rewrote nodes"; tail -1 "$TMP/add2.log" | sed 's/^/        /'
fi

echo
echo "2: the diamond stops the build"
app_node "" "$B
$C"
build_app "$TMP/b2.log"
if [ "$RC" -ne 0 ]; then pass "aeb exits $RC"; else fail "the app built with x:d at two versions"; fi
if grep -q "x:d is on this classpath at more than one version" "$TMP/b2.log" \
   && grep -q "1.0  asked for by x:b:1" "$TMP/b2.log" && grep -q "1.2  asked for by x:c:1" "$TMP/b2.log"; then
    pass "the failure names the artifact, the versions and who asked"
else
    fail "the failure does not say what is in contention"; grep -v "^warning\|^ *[0-9|]" "$TMP/b2.log" | tail -8 | sed 's/^/        /'
fi
if grep -q 'dep_arbitration("x:d", "1.2", and_not("1.0"))' "$TMP/b2.log"; then
    pass "the failure gives the line to write"
else
    fail "no dep_arbitration line offered"
fi

echo
echo "3: an arbitration in the app"
app_node ", dep_arbitration, and_not" "$B
$C
        dep_arbitration(\"x:d\", \"1.2\", and_not(\"1.0\"))"
build_app "$TMP/b3.log"
ran_with "$TMP/b3.log" "D=1.2 E=present" "runs with the pick, 1.2, and with e, which only 1.2 wants"

echo
echo "4: picking the other way"
app_node ", dep_arbitration, and_not" "$B
$C
        dep_arbitration(\"x:d\", \"1.0\", and_not(\"1.2\"))"
build_app "$TMP/b4.log"
ran_with "$TMP/b4.log" "D=1.0 E=absent" "runs with 1.0, and e is not on the classpath"

echo
echo "5: an and_not list that does not name the version"
app_node ", dep_arbitration, and_not" "$B
$C
        dep_arbitration(\"x:d\", \"1.2\", and_not(\"0.9\"))"
build_app "$TMP/b5.log"
if [ "$RC" -ne 0 ] && grep -q "does not name 1.0" "$TMP/b5.log"; then
    pass "1.0 was never named, so it is not covered"
else
    fail "an arbitration covered a version it does not name (rc=$RC)"
fi

echo
echo "6: a library's arbitration is inherited"
cat > "$PROJ/lib/.jar.ae" <<'NODE'
import bldr
import bldr (dep, dep_arbitration, and_not)
import java
main() {
    bldr.build() {
        dep("third_party/java/x/b/1/.jar.ae")
        dep("third_party/java/x/c/1/.jar.ae")
        dep_arbitration("x:d", "1.2", and_not("1.0"))
        java.jar_bundle()
    }
}
NODE
app_node "" '        dep("lib/.jar.ae")'
build_app "$TMP/b6.log"
ran_with "$TMP/b6.log" "D=1.2 E=present" "the app above it writes nothing and runs with the library's pick"

echo
echo "7: the default beside the artifact"
( cd "$PROJ" && "$AEB_RUN" mvn add --repo "$BASE" --pick x:d=1.0 x:b:1 x:c:1 ) > "$TMP/pick.log" 2>/dev/null
if grep -q 'dep_arbitration("x:d", "1.0", and_not("1.2"))' "$PROJ/third_party/java/x/d/.jar.ae" 2>/dev/null; then
    pass "--pick writes third_party/java/x/d/.jar.ae"
else
    fail "--pick did not write the default"; tail -3 "$TMP/pick.log" | sed 's/^/        /'
fi
app_node "" "$B
$C"
build_app "$TMP/b7.log"
ran_with "$TMP/b7.log" "D=1.0 E=absent" "an app with no line of its own gets the default"
app_node ", dep_arbitration, and_not" "$B
$C
        dep_arbitration(\"x:d\", \"1.2\", and_not(\"1.0\"))"
build_app "$TMP/b7b.log"
ran_with "$TMP/b7b.log" "D=1.2 E=present" "the app's own line wins over the default"

echo
echo "8: a hash that is not the jar's"
node="$PROJ/third_party/java/x/e/1/.jar.ae"
good="$(sha256_of "$REPO/x/e/1/e-1.jar")"
bad="0000000000000000000000000000000000000000000000000000000000000000"
sed "s/$good/$bad/" "$node" > "$node.new" && mv "$node.new" "$node"
rm -rf "$HOME/.cache/aeb/jars"
build_app "$TMP/b8.log"
if [ "$RC" -ne 0 ] && grep -rq "jar_maven: x:e:1 unresolved" "$TMP/b8.log" "$PROJ/target/.aeb/logs" 2>/dev/null; then
    pass "the node does not build"
else
    fail "a jar whose hash is not the node's was accepted (rc=$RC)"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "[mvn-nodes-arbitration] OK"
    exit 0
fi
echo "[mvn-nodes-arbitration] $FAILURES assertion(s) failed"
exit 1
