#!/usr/bin/env bash
# itests/java-classpath-artifact-stable.sh — a java.javac node's classpath
# artifact is a function of the node's inputs, not of its own previous output.
#
# The bug (found by html-sanitizer on aeb v0.348): javac read the node's own
# jvm_classpath_deps_including_transitive file back in (to pick up the jars its
# own jar_pinned/jar_vendored calls had written) and appended it to the
# artifact it was about to write. That file holds the classes dir javac itself
# puts first, so every re-run in the same target/ added one more copy of it:
# `classes`, then `classes\nclasses`, ... A consumer taking the artifact as one
# classpath got a newline in it (kotlinc: "unresolved reference" for every
# Java class).
#
#   1. Four runs of a javac node in one target/: the artifact is one line,
#      and byte-identical, every time.
#   2. A node with a jar_vendored jar and a javac in the same block: the jar is
#      in the artifact once, every time (the case the file read was for).
#   3. (needs kotlinc) A Kotlin node that depends on the javac node compiles
#      and runs after the javac node has been re-run.
#
# Needs a JDK (javac); skipped, exit 0, where there is none.
# Usage: AETHER=/path/to/ae ./itests/java-classpath-artifact-stable.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AETHER="${AETHER:-ae}"; export AETHER
command -v "$AETHER" >/dev/null 2>&1 || { echo "error: '$AETHER' not found" >&2; exit 1; }
if ! command -v javac >/dev/null 2>&1 || ! javac -version >/dev/null 2>&1; then
    echo "  SKIP: no JDK (javac) on this host"; exit 0
fi
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t aeb_javacp)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# a copy of aeb, so the checkout's helpers are not touched
H="$TMP/aeb"; mkdir -p "$H/tools"
cp "$REPO_ROOT/aeb" "$H/aeb"; cp -R "$REPO_ROOT/lib" "$H/lib"
( cd "$REPO_ROOT/tools" && for e in *; do
    if [ -d "$e" ]; then cp -R "$e" "$H/tools/$e"
    else case "$e" in *.ae|*.sh|*.py) cp "$e" "$H/tools/$e" ;; esac; fi
  done )
for f in AETHER_PIN AETHER_FETCH VERSION; do [ -f "$REPO_ROOT/$f" ] && cp "$REPO_ROOT/$f" "$H/$f"; done
unset AEB_HOME
P="$TMP/proj"; mkdir -p "$P/lib/src/main/java/demo" "$P/app/src/main/kotlin" "$P/jarnode/src/main/java/jn" "$P/vend"
( cd "$P" && git init -q . 2>/dev/null )
cat > "$P/lib/src/main/java/demo/Hello.java" <<'JAVA'
package demo;
public class Hello { public static String hi() { return "hello from java"; } }
JAVA
cat > "$P/lib/.build.ae" <<'AE'
import bldr
import java
import java (source_layout)
aeb(cap) {
    bldr.build() { java.javac() { source_layout("maven idiomatic") } }
}
AE
run() { ( cd "$P" && bash "$H/aeb" "$@" ) > "$TMP/run.log" 2>&1; }
art() { cat "$P/target/build/$1/jvm_classpath_deps_including_transitive" 2>/dev/null; }

echo "[java-classpath-artifact-stable]"
echo
echo "1: four runs of one javac node"
run lib/.build.ae || { echo "  the first build failed:"; tail -8 "$TMP/run.log" | sed 's/^/    /'; exit 1; }
first="$(art lib)"
ok=1
for i in 2 3 4; do
    run lib/.build.ae
    now="$(art lib)"
    [ "$now" = "$first" ] || { ok=0; fail "run $i: the artifact changed: $(printf '%s' "$now" | tr '\n' '|')"; }
done
lines=$(printf '%s\n' "$first" | grep -c .)
[ "$lines" = 1 ] || { ok=0; fail "the artifact has $lines lines, not 1"; }
[ "$ok" = 1 ] && pass "one line, byte-identical over four runs"

echo
echo "2: a vendored jar beside the javac, same node"
# a real jar to vendor
mkdir -p "$TMP/vj/v" && printf 'package v; public class V {}\n' > "$TMP/vj/v/V.java"
( cd "$TMP/vj" && javac -d out v/V.java && jar cf "$P/vend/v.jar" -C out . ) >/dev/null 2>&1
cat > "$P/jarnode/src/main/java/jn/J.java" <<'JAVA'
package jn;
public class J { public static v.V make() { return new v.V(); } }
JAVA
cat > "$P/jarnode/.build.ae" <<'AE'
import bldr
import java
import java (source_layout, jar_vendored)
aeb(cap) {
    bldr.build() {
        jar_vendored("vend/v.jar")
        java.javac() { source_layout("maven idiomatic") }
    }
}
AE
run jarnode/.build.ae || { fail "the vendored-jar build failed"; tail -8 "$TMP/run.log" | sed 's/^/    /'; }
first="$(art jarnode)"
for i in 2 3 4; do run jarnode/.build.ae; [ "$(art jarnode)" = "$first" ] || fail "run $i: the artifact changed: $(art jarnode | tr '\n' '|')"; done
n=$(printf '%s\n' "$first" | grep -c 'v.jar')
if [ "$n" = 1 ] && [ "$(printf '%s\n' "$first" | grep -c .)" = 2 ]; then pass "classes dir and the jar, once each, over four runs"; else fail "unexpected artifact: $(printf '%s' "$first" | tr '\n' '|')"; fi

echo
echo "3: a Kotlin node consuming the javac node"
if command -v kotlinc >/dev/null 2>&1; then
    cat > "$P/app/src/main/kotlin/Main.kt" <<'KT'
fun main() { println(demo.Hello.hi()) }
KT
    cat > "$P/app/.build.ae" <<'AE'
import bldr
import bldr (dep)
import kotlin
import kotlin (source_layout)
aeb(cap) {
    bldr.build() {
        dep("lib/.build.ae")
        kotlin.kotlinc() { source_layout("maven idiomatic") }
    }
}
AE
    run lib/.build.ae; run lib/.build.ae
    if run app/.build.ae; then pass "kotlinc compiled against the re-run javac node"; else fail "the Kotlin node failed"; tail -8 "$TMP/run.log" | sed 's/^/    /'; fi
else
    echo "  SKIP: no kotlinc on this host"
fi

echo
if [ "$FAILURES" -eq 0 ]; then echo "java-classpath-artifact-stable: all assertions passed"; exit 0; fi
echo "java-classpath-artifact-stable: $FAILURES assertion(s) failed"; exit 1
