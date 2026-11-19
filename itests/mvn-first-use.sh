#!/usr/bin/env bash
# itests/mvn-first-use.sh — where a team declares maven_nodes("<dir>"),
# dep("group:artifact:version") is the artifact's node there, written on first
# use; a locked build refuses to write; a BOM's managed versions are written
# down as arbitrations.
#
# Same fixture as mvn-nodes-arbitration.sh (a diamond on d, served on
# 127.0.0.1), plus a BOM, x:platform:1, that manages c at 1 and d at 1.2.
#
#   1. First build of an app that says dep("x:b:1") and dep("x:c") with the
#      BOM loaded: the nodes and the BOM's record are written, the BOM's
#      d:1.2 over b's d:1.0 is written into the .bom.ae as a dep_arbitration,
#      and the program runs with d 1.2.
#   2. A second build writes nothing.
#   3. The BOM's version replaces a lone request: an app with only b (whose
#      pom asks d:1.0) runs with d 1.2.
#   4. Locked (--locked, and CI set): a coordinate with no node is an error
#      naming it and the command; nothing is written.
#   5. A person changes the pick on the line: the build follows it.
#   6. A build file with no maven_nodes line in reach is as before (a
#      third_party/java directory existing declares nothing): the coordinate
#      resolves at build time and nothing is written into the tree.
#   9. The line can be in the build file itself, and the directory is the
#      team's to name.
#
# Usage:  ./mvn-first-use.sh
# Exit:   0 all assertions pass, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "[mvn-first-use]"

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

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t aeb_mvn_first)"
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
# f asks for e at exactly 1, written as a range; g asks for d in [1.0,1.5).
artifact f 1   "" 'x:e:[1]'
artifact g 1   "" 'x:d:[1.0,1.5)'
cat > "$REPO/x/d/maven-metadata.xml" <<'META'
<metadata><groupId>x</groupId><artifactId>d</artifactId><versioning><versions>
<version>1.0</version><version>1.2</version><version>2.0-beta</version>
</versions></versioning></metadata>
META
# h's pom begins with a UTF-8 byte-order mark, as some on Maven Central do.
artifact h 1   "" x:e:1
printf '\357\273\277' > "$REPO/x/h/1/h-1.pom.new"
cat "$REPO/x/h/1/h-1.pom" >> "$REPO/x/h/1/h-1.pom.new"
mv "$REPO/x/h/1/h-1.pom.new" "$REPO/x/h/1/h-1.pom"
# i's dependency on d has no <version>; i's own dependencyManagement gives it.
artifact i 1   ""
cat > "$REPO/x/i/1/i-1.pom" <<'POM'
<project><modelVersion>4.0.0</modelVersion>
<groupId>x</groupId><artifactId>i</artifactId><version>1</version>
<dependencyManagement><dependencies>
<dependency><groupId>x</groupId><artifactId>d</artifactId><version>1.2</version></dependency>
</dependencies></dependencyManagement>
<dependencies><dependency><groupId>x</groupId><artifactId>d</artifactId></dependency></dependencies>
</project>
POM
mkdir -p "$REPO/x/platform/1"
cat > "$REPO/x/platform/1/platform-1.pom" <<'POM'
<project><modelVersion>4.0.0</modelVersion>
<groupId>x</groupId><artifactId>platform</artifactId><version>1</version><packaging>pom</packaging>
<dependencyManagement><dependencies>
<dependency><groupId>x</groupId><artifactId>c</artifactId><version>1</version></dependency>
<dependency><groupId>x</groupId><artifactId>d</artifactId><version>1.2</version></dependency>
</dependencies></dependencyManagement></project>
POM

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
# new_project [keeps]: with "keeps", the .bom.ae declares maven_nodes(...).
new_project() {
    rm -rf "$PROJ"
    mkdir -p "$PROJ/.aeb" "$PROJ/app"
    cat > "$PROJ/local.bom.ae" <<BOM
maven_repo("$BASE")
maven_bom("x:platform:1")
BOM
    if [ "${1:-}" = keeps ]; then echo 'maven_nodes("third_party/java")' >> "$PROJ/local.bom.ae"; fi
    cat > "$PROJ/app/Main.java" <<'JAVA'
public class Main {
    public static void main(String[] a) {
        String e = "absent";
        try { Class.forName("x.E"); e = "present"; } catch (ClassNotFoundException x) { }
        System.out.println("D=" + x.D.version() + " E=" + e);
    }
}
JAVA
}
# app_node <dep lines>
app_node() {
    {
        echo 'import bldr'
        echo 'import bldr (dep, maven_nodes)'
        echo 'import maven (load_bom_file)'
        echo 'import java'
        echo 'main() {'
        echo '    bldr.build() {'
        echo '        load_bom_file("../local.bom.ae")'
        printf '%s\n' "$1"
        echo '        java.javac()'
        echo '        java.java_main("Main")'
        echo '    }'
        echo '}'
    } > "$PROJ/app/.build.ae"
}
RC=0
build_app() {   # build_app <log> [aeb flags]; sets RC
    local log="$1"; shift
    rm -rf "$PROJ/target"
    ( cd "$PROJ" && "$AEB_RUN" "$@" app/.build.ae ) > "$log" 2>&1
    RC=$?
}
ran_with() {    # ran_with <log> <expected output line> <what>
    if [ "$RC" -eq 0 ] && grep -rqx "$2" "$1" "$PROJ/target/.aeb/logs" 2>/dev/null; then
        pass "$3"
    else
        fail "$3 (rc=$RC, wanted the program to print '$2')"
        grep -rh "D=\|FAILED\|more than one\|aeb: " "$1" "$PROJ/target/.aeb/logs" 2>/dev/null | sort -u | head -8 | sed 's/^/        /'
    fi
}
tree_sum() { ( cd "$PROJ" && find third_party local.bom.ae -type f 2>/dev/null | LC_ALL=C sort | xargs cat | cksum ); }
unset CI AEB_LOCKED

echo
echo "1: first use"
new_project keeps
app_node '        dep("x:b:1")
        dep("x:c")'
build_app "$TMP/b1.log"
ran_with "$TMP/b1.log" "D=1.2 E=present" "the app builds and runs with the BOM's d, 1.2"
n=$(find "$PROJ/third_party/java" -name .jar.ae 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" = 5 ]; then pass "five nodes were written"; else fail "expected five nodes, found $n"; fi
if grep -q 'managed("x:d", "1.2")' "$PROJ/third_party/java/x/platform/1/managed.bom.ae" 2>/dev/null; then
    pass "what the BOM manages is recorded in the tree"
else
    fail "no record of what x:platform:1 manages"
fi
if grep -q 'dep_arbitration("x:d", "1.2", and_not("1.0"))' "$PROJ/local.bom.ae"; then
    pass "the BOM's 1.2 over the pom's 1.0 is written into the .bom.ae"
else
    fail "local.bom.ae has no dep_arbitration for x:d"; sed 's/^/        /' "$PROJ/local.bom.ae"
fi

echo
echo "2: a second build writes nothing"
before="$(tree_sum)"
build_app "$TMP/b2.log"
if [ "$RC" -eq 0 ] && [ "$(tree_sum)" = "$before" ] && ! grep -q "first use" "$TMP/b2.log"; then
    pass "same tree, nothing generated"
else
    fail "the second build generated or rewrote something (rc=$RC)"
fi
build_app "$TMP/b2l.log" --locked
ran_with "$TMP/b2l.log" "D=1.2 E=present" "and it builds locked"

echo
echo "3: the BOM's version replaces a lone request"
new_project keeps
app_node '        dep("x:b:1")'
build_app "$TMP/b3.log"
ran_with "$TMP/b3.log" "D=1.2 E=present" "b alone asks d:1.0; with the BOM loaded it runs with 1.2"

echo
echo "4: locked"
new_project keeps
app_node '        dep("x:b:1")
        dep("x:c")'
build_app "$TMP/b4.log" --locked
if [ "$RC" -ne 0 ] && grep -q "this build is locked" "$TMP/b4.log" && grep -q "aeb mvn add" "$TMP/b4.log"; then
    pass "--locked: a coordinate with no node is an error that gives the command"
else
    fail "--locked did not refuse (rc=$RC)"; grep "aeb: " "$TMP/b4.log" | head -4 | sed 's/^/        /'
fi
if [ ! -e "$PROJ/third_party" ] && ! grep -q dep_arbitration "$PROJ/local.bom.ae"; then
    pass "--locked: nothing was written"
else
    fail "--locked wrote into the tree"
fi
rm -rf "$PROJ/target"
( cd "$PROJ" && CI=true "$AEB_RUN" app/.build.ae ) > "$TMP/b4c.log" 2>&1
if [ $? -ne 0 ] && grep -q "this build is locked" "$TMP/b4c.log"; then
    pass "CI set: locked without the flag"
else
    fail "a build with CI set generated nodes"
fi
rm -rf "$PROJ/target"
( cd "$PROJ" && CI=true AEB_LOCKED=0 "$AEB_RUN" app/.build.ae ) > "$TMP/b4d.log" 2>&1
RC=$?
ran_with "$TMP/b4d.log" "D=1.2 E=present" "CI set and AEB_LOCKED=0: first use is allowed"

echo
echo "5: a person changes the pick"
sed 's/dep_arbitration("x:d", "1.2", and_not("1.0"))/dep_arbitration("x:d", "1.0", and_not("1.2"))/' "$PROJ/local.bom.ae" > "$PROJ/local.bom.ae.new"
mv "$PROJ/local.bom.ae.new" "$PROJ/local.bom.ae"
build_app "$TMP/b5.log"
ran_with "$TMP/b5.log" "D=1.0 E=absent" "the build follows the line as edited, and adds none of its own"
if [ "$(grep -c 'dep_arbitration("x:d"' "$PROJ/local.bom.ae")" = 1 ]; then
    pass "the edited line is the only one for x:d"
else
    fail "aeb wrote a second line for x:d beside the edited one"; sed 's/^/        /' "$PROJ/local.bom.ae"
fi

echo
echo "6: a build file with no maven_nodes line in reach"
new_project
mkdir -p "$PROJ/third_party/java"   # the directory alone declares nothing
app_node '        dep("x:b:1")
        dep("x:c")'
build_app "$TMP/b6.log"
if [ "$RC" -eq 0 ] && [ -z "$(find "$PROJ/third_party" -type f)" ] && ! grep -q dep_arbitration "$PROJ/local.bom.ae"; then
    pass "resolves at build time as before; nothing written into the tree"
else
    fail "a build file that declares nothing changed behaviour (rc=$RC)"
    grep -rh "FAILED\|aeb: \|error" "$TMP/b6.log" | head -5 | sed 's/^/        /'
fi

echo
echo "7: a pom that asks for a range"
new_project
( cd "$PROJ" && "$AEB_RUN" mvn add --repo "$BASE" x:f:1 x:g:1 ) > "$TMP/range.log" 2> "$TMP/range.err"
if grep -q 'dep("third_party/java/x/e/1/.jar.ae")' "$PROJ/third_party/java/x/f/1/.jar.ae" 2>/dev/null; then
    pass "[1] is version 1"
else
    fail "x:f's node has no edge to x:e:1"; tail -3 "$TMP/range.err" | sed 's/^/        /'
fi
if grep -q 'dep("third_party/java/x/d/1.2/.jar.ae")' "$PROJ/third_party/java/x/g/1/.jar.ae" 2>/dev/null \
   && grep -q "^range: x:g:1 asks for x:d at \[1.0,1.5): taken as 1.2" "$TMP/range.log"; then
    pass "[1.0,1.5) is the highest published in it, 1.2, and the output says so"
else
    fail "the range was not settled to 1.2 and reported"; cat "$TMP/range.log" | sed 's/^/        /' | head -5
fi

echo
echo "8: poms as they are published"
new_project
( cd "$PROJ" && "$AEB_RUN" mvn add --repo "$BASE" x:h:1 x:i:1 ) > "$TMP/odd.log" 2> "$TMP/odd.err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'dep("third_party/java/x/e/1/.jar.ae")' "$PROJ/third_party/java/x/h/1/.jar.ae" 2>/dev/null; then
    pass "a pom that begins with a byte-order mark is read"
else
    fail "x:h, whose pom has a byte-order mark, did not resolve (rc=$rc)"; grep "^error" "$TMP/odd.err" | head -3 | sed 's/^/        /'
fi
if grep -q 'dep("third_party/java/x/d/1.2/.jar.ae")' "$PROJ/third_party/java/x/i/1/.jar.ae" 2>/dev/null; then
    pass "a dependency with no version takes it from its own pom's dependencyManagement"
else
    fail "x:i's node has no edge to x:d:1.2"; grep "^error" "$TMP/odd.err" | head -3 | sed 's/^/        /'
fi

echo
echo "9: declared in the build file, in a directory of the team's naming"
new_project
app_node '        maven_nodes("deps/maven")
        dep("x:b:1")
        dep("x:c")'
build_app "$TMP/b9.log"
ran_with "$TMP/b9.log" "D=1.2 E=present" "the app builds from nodes under deps/maven"
if [ -f "$PROJ/deps/maven/x/b/1/.jar.ae" ] && [ ! -e "$PROJ/third_party" ]; then
    pass "the nodes are where the line says, and nowhere else"
else
    fail "nodes were not written under deps/maven"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "[mvn-first-use] OK"
    exit 0
fi
echo "[mvn-first-use] $FAILURES assertion(s) failed"
exit 1
