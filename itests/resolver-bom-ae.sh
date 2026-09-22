#!/usr/bin/env bash
# itests/resolver-bom-ae.sh — `--bom-file` must accept an aeb `.bom.ae`.
#
# THE BUG THIS PREVENTS. `aeb-resolve.jar` takes `--bom-file <path>`, and a
# path handed to it is one of TWO things:
#
#   1. an aeb `.bom.ae` — the aeb DSL, scanned as text for maven_bom(),
#      maven_repo() and dep() lines. This is the documented contract; every
#      `*.bom.ae` under itests/ says so in its own header comment, and
#      lib/maven's load_bom_file() feeds these files and nothing else.
#   2. a literal Maven BOM POM (XML), whose <dependencyManagement> supplies
#      versions for version-less coordinates.
#
# The Eclipse-Aether resolver handled both (MavenResolver.parseBomAeFile).
# The Aug-2026 rewrite onto bld (commit c32a5be) said it "reproduces
# aeb-resolve's exact CLI" and kept only branch 2, so every `.bom.ae` in the
# tree hit an XML parser:
#
#   [Fatal Error] :1:1: Content is not allowed in prolog.
#   warning: could not load BOM file .../clojars.bom.ae — Content is not
#            allowed in prolog.
#
# A WARNING, and exit 0. So the resolver "succeeded" having silently dropped
# every repository and coordinate the BOM declared, and the damage surfaced
# one step removed from its cause — as Clojars-hosted artifacts reported
# missing from Maven Central:
#
#   warning: cannot resolve integrant:integrant:0.13.0 — Couldn't find
#            artifact ... at https://repo1.maven.org/maven2/...
#
# Nothing caught it. tests/run.sh is Aether-only and cannot exercise a Java
# jar; tests/test_maven_cmd.ae asserts the command STRING aeb builds, which
# was right the whole time. The one thing that would have noticed — running
# the Clojure itest — was not run between the rewrite and this script.
#
# WHY IT IS OFFLINE. The assertions are about whether the resolver READ the
# file, not about Maven Central. A python3 `http.server` serves a two-file
# fake repository on 127.0.0.1 holding one artifact that exists nowhere
# else, so "did maven_repo() register" and "did dep() register" are both
# answered by whether that coordinate comes back — no network, no flakes,
# and a positive result that cannot come from a cached Central artifact.
#
# ASSERT ON OUTPUT, NOT ON $?. The broken resolver exited 0 while resolving
# nothing, which is precisely why this went unnoticed; a test that checked
# only the exit code would have passed against the bug.
#
# Mutation-checked: against the pre-fix jar, 3 assertions fail across rounds
# 1 and 2, while round 3 — the XML branch — still passes. That split is the
# point: the two --bom-file meanings are independent and both need pinning.
#
# Usage:  ./resolver-bom-ae.sh
# Exit:   0 all assertions pass, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "[resolver-bom-ae]"

# --- locate the resolver jar ------------------------------------------------
# Prefer the dev tree's, fall back to an installed one. Build it if neither
# exists: `aeb tools/resolver/.dist.ae` is the documented way and needs a JDK.
JAR="${AEB_RESOLVE_JAR:-$REPO_ROOT/tools/aeb-resolve.jar}"
if [ ! -f "$JAR" ]; then
    JAR="$HOME/.local/share/aeb/tools/aeb-resolve.jar"
fi
if [ ! -f "$JAR" ]; then
    echo "  SKIP: no aeb-resolve.jar (build it: aeb tools/resolver/.dist.ae)"
    exit 0
fi
if ! command -v java >/dev/null 2>&1; then
    echo "  SKIP: no java on PATH"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: no python3 on PATH (needed for the local repo server)"
    exit 0
fi
echo "  jar: $JAR"

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t aeb_resolver_bom)"
PORT=0
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# --- a fake Maven repository, served over HTTP ------------------------------
# One artifact, com.example:widget:1.0.0, which exists in NO public
# repository. Anything that resolves it did so through our maven_repo() URL.
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
# An empty-but-valid zip: enough to be a jar if anything reaches for one.
printf 'PK\005\006\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' \
    > "$REPO/com/example/widget/1.0.0/widget-1.0.0.jar"

# Bind an ephemeral port and read back which one we got, so concurrent runs
# (and a developer with something already on a fixed port) don't collide.
( cd "$REPO" && exec python3 -u -m http.server 0 --bind 127.0.0.1 ) \
    > "$TMP/httpd.log" 2>&1 &
SERVER_PID=$!
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
echo "  local repo: $BASE"

run_resolver() {   # run_resolver <outfile> <args...>
    local out="$1"; shift
    # A per-round cache dir: a warm ~/.local/share/aeb/repo could otherwise
    # satisfy a coordinate the resolver never actually looked up.
    java -jar "$JAR" --cache "$TMP/cache-$RANDOM" "$@" > "$out" 2> "$out.err"
}

# --- round 1: a .bom.ae's maven_repo() + dep() are honoured -----------------
echo
echo "round 1: .bom.ae maven_repo() + dep()"
cat > "$TMP/local.bom.ae" <<BOM
// A comment line naming a coordinate that must NOT register:
// dep("com.example:decoy:9.9.9")
maven_repo("$BASE")
dep("com.example:widget:1.0.0")
BOM

run_resolver "$TMP/r1.out" --output sbom --bom-file "$TMP/local.bom.ae"

if grep -q "Content is not allowed in prolog" "$TMP/r1.out.err"; then
    fail "a .bom.ae was fed to the XML parser (the original bug)"
else
    pass "a .bom.ae is not fed to the XML parser"
fi

if grep -qx "com.example:widget:1.0.0" "$TMP/r1.out"; then
    pass "maven_repo() + dep() from the .bom.ae reached the resolution"
else
    fail "com.example:widget:1.0.0 absent — .bom.ae lines were dropped"
    sed 's/^/        /' "$TMP/r1.out.err" | head -5
fi

if grep -q "com.example:decoy" "$TMP/r1.out"; then
    fail "a coordinate inside a // comment registered"
else
    pass "a coordinate inside a // comment is ignored"
fi

# --- round 2: maven_bom() supplies a version for a version-less coord -------
# The third .bom.ae verb. A version-less positional coordinate resolves only
# if some BOM provided its version; otherwise the resolver says so by name.
echo
echo "round 2: .bom.ae maven_bom() supplies a managed version"
mkdir -p "$REPO/com/example/platform/2.0.0"
cat > "$REPO/com/example/platform/2.0.0/platform-2.0.0.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>platform</artifactId>
  <version>2.0.0</version>
  <packaging>pom</packaging>
  <dependencyManagement>
    <dependencies>
      <dependency>
        <groupId>com.example</groupId>
        <artifactId>widget</artifactId>
        <version>1.0.0</version>
      </dependency>
    </dependencies>
  </dependencyManagement>
</project>
POM
cat > "$TMP/platform.bom.ae" <<BOM
maven_repo("$BASE")
maven_bom("com.example:platform:2.0.0")
BOM

run_resolver "$TMP/r2.out" --output sbom --bom-file "$TMP/platform.bom.ae" \
    com.example:widget

if grep -q "no version and no BOM provides one" "$TMP/r2.out.err"; then
    fail "maven_bom() did not register — version-less coord had no version"
else
    pass "maven_bom() from the .bom.ae supplied the managed version"
fi

# --- round 3: the XML branch still works ------------------------------------
# --bom-file's other meaning. Discriminating on content rather than on the
# filename means this branch must keep working for a file named anything.
echo
echo "round 3: --bom-file still accepts a literal BOM POM"
cp "$REPO/com/example/platform/2.0.0/platform-2.0.0.pom" "$TMP/platform-bom.xml"

run_resolver "$TMP/r3.out" --output sbom --repo "$BASE" \
    --bom-file "$TMP/platform-bom.xml" com.example:widget

if grep -qx "com.example:widget:1.0.0" "$TMP/r3.out"; then
    pass "an XML BOM POM still supplies managed versions"
else
    fail "XML BOM POM branch regressed"
    sed 's/^/        /' "$TMP/r3.out.err" | head -5
fi

# --- result -----------------------------------------------------------------
echo
if [ "$FAILURES" -eq 0 ]; then
    echo "[resolver-bom-ae] OK"
    exit 0
fi
echo "[resolver-bom-ae] $FAILURES assertion(s) failed"
exit 1
