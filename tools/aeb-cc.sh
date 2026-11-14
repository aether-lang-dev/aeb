#!/bin/sh
# aeb-cc.sh — compile aeb-link's translation units to objects in parallel,
# each one cached by content.
#
#   aeb-cc.sh <obj-dir> <tu-list>
#
# <tu-list> has one "<index> <path-to-.c>" per line; <obj-dir>/<index>.o is
# written for each. Environment (set by aeb-link): AEB_CC (compiler command),
# AEB_CC_INC (the -I flags), AEB_CC_JOBS (parallel width). AEB_NO_CACHE=1
# skips cache READS (the result is still written); the cache is the same
# directory the node cache uses (cache.dir(): $AEB_CACHE_DIR, $XDG_CACHE_HOME/aeb,
# ~/.cache/aeb), under obj/.
#
# WHY: aeb-link used to compile the orchestrator and every node's entry file
# in ONE `gcc a.c b.c ... -o out`: serial, on one core, and redone in full on
# every run because the orchestrator is rebuilt from those files each time.
# aether-ui's 171 nodes cost ~7.5 minutes that way whether every node was a
# cache hit or not, which is most of what a warm CI run spent.
#
# THE KEY is sha256 over: the compiler's identity (--version and -dumpmachine),
# the code-generation flags, and the PREPROCESSED translation unit (cc -E -P).
# That is the whole input of the compile: every header that mattered (toolchain
# or project) is already inlined in it, so a changed header, a changed
# toolchain, or a changed source all move the key, and nothing outside the
# text can. -P drops the line markers, so the key does not depend on where the
# checkout lives. A TU that is not plain C (.m, .mm, .cpp) is compiled
# directly, uncached. On a compile failure the TU is recompiled from the real
# file so the diagnostics name real lines.
set -u

if [ "${1:-}" = "--one" ]; then
    # worker: aeb-cc.sh --one <obj-dir> <index> <src>
    objdir=$2 idx=$3 src=$4
    obj="$objdir/$idx.o"
    OPTS="-O2 -pipe -w -pthread"
    case "$src" in
        *.c) ;;
        *) exec $AEB_CC $OPTS $AEB_CC_INC -c "$src" -o "$obj" ;;
    esac
    pre="$objdir/$idx.i"
    if ! $AEB_CC $OPTS $AEB_CC_INC -E -P "$src" -o "$pre" 2>/dev/null; then
        exec $AEB_CC $OPTS $AEB_CC_INC -c "$src" -o "$obj"
    fi
    key=$( { printf '%s\n%s\n' "$AEB_CC_ID" "$OPTS"; cat "$pre"; } | $AEB_SHA | cut -d' ' -f1 )
    store="$AEB_CC_STORE/${key%"${key#??}"}"
    entry="$store/$key.o.gz"
    if [ -z "${AEB_NO_CACHE:-}" ] && [ -f "$entry" ] && gzip -dc "$entry" > "$obj.tmp" 2>/dev/null; then
        mv "$obj.tmp" "$obj"
        rm -f "$pre"
        echo "aeb-cc: hit  $src"
        exit 0
    fi
    rm -f "$obj.tmp"
    if ! $AEB_CC $OPTS -x cpp-output -c "$pre" -o "$obj" 2>/dev/null; then
        rm -f "$pre"
        exec $AEB_CC $OPTS $AEB_CC_INC -c "$src" -o "$obj"
    fi
    rm -f "$pre"
    mkdir -p "$store" && gzip -1c "$obj" > "$entry.$$" && mv "$entry.$$" "$entry" || rm -f "$entry.$$"
    echo "aeb-cc: miss $src"
    exit 0
fi

objdir=$1 list=$2
: "${AEB_CC:=gcc}"
: "${AEB_CC_INC:=}"
jobs=${AEB_CC_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

if command -v sha256sum >/dev/null 2>&1; then AEB_SHA=sha256sum
elif command -v shasum >/dev/null 2>&1; then AEB_SHA="shasum -a 256"
else echo "aeb-cc: no sha256 tool" >&2; exit 1; fi

if [ -n "${AEB_CACHE_DIR:-}" ]; then base=$AEB_CACHE_DIR
elif [ -n "${XDG_CACHE_HOME:-}" ]; then base=$XDG_CACHE_HOME/aeb
elif [ -n "${HOME:-}" ]; then base=$HOME/.cache/aeb
else base=.aeb/cache; fi

AEB_CC_STORE="$base/obj"
AEB_CC_ID=$( { $AEB_CC --version 2>&1 | head -3; $AEB_CC -dumpmachine 2>&1; } )
export AEB_CC AEB_CC_INC AEB_CC_ID AEB_CC_STORE AEB_SHA

mkdir -p "$objdir" "$AEB_CC_STORE"
self=$0
# One worker per line; xargs stops launching after a failure and exits 123.
tr '\n' '\0' < "$list" | xargs -0 -n 1 -P "$jobs" sh -c '
    line=$1
    idx=${line%% *}
    src=${line#* }
    exec sh "'"$self"'" --one "'"$objdir"'" "$idx" "$src"
' _
