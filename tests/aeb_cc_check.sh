#!/bin/sh
# Exercises tools/aeb-cc.sh against a throwaway cache. Prints "OK" on success,
# a diagnostic otherwise. Run from the repo root by test_aeb_cc.ae.
set -u
T=$(mktemp -d 2>/dev/null || mktemp -d -t aebcc)
trap 'rm -rf "$T"' EXIT
export AEB_CACHE_DIR="$T/cache"
unset AEB_NO_CACHE
CC=${CC:-cc}
export AEB_CC="$CC"
S=tools/aeb-cc.sh
mkdir -p "$T/inc"
printf 'int hdr(void) { return 1; }\n' > "$T/inc/h.h"
printf '#include "h.h"\nint a(void) { return hdr() + 1; }\n' > "$T/a.c"
printf 'int b(void) { return 2; }\n' > "$T/b.c"
export AEB_CC_INC="-I$T/inc"
printf '0 %s/a.c\n1 %s/b.c\n' "$T" "$T" > "$T/list"

fail() { echo "FAIL: $1"; exit 1; }
run() { AEB_CC_JOBS=2 sh "$S" "$T/obj" "$T/list" 2>&1; }

o=$(run) || fail "cold run: $o"
[ "$(echo "$o" | grep -c 'aeb-cc: miss')" = 2 ] || fail "cold run should miss twice: $o"
[ -s "$T/obj/0.o" ] && [ -s "$T/obj/1.o" ] || fail "objects not written"

rm -f "$T/obj/0.o" "$T/obj/1.o"
o=$(run) || fail "warm run: $o"
[ "$(echo "$o" | grep -c 'aeb-cc: hit')" = 2 ] || fail "warm run should hit twice: $o"
[ -s "$T/obj/0.o" ] && [ -s "$T/obj/1.o" ] || fail "objects not restored"

# A changed HEADER must move a.c's key (the preprocessed text changed), not b.c's.
printf 'int hdr(void) { return 5; }\n' > "$T/inc/h.h"
o=$(run) || fail "header-change run: $o"
echo "$o" | grep "miss" | grep -q "a.c" || fail "header change did not rebuild a.c: $o"
echo "$o" | grep "hit" | grep -q "b.c" || fail "header change rebuilt b.c: $o"

# A changed source rebuilds.
printf 'int b(void) { return 3; }\n' > "$T/b.c"
o=$(run) || fail "source-change run: $o"
echo "$o" | grep "miss" | grep -q "b.c" || fail "source change did not rebuild b.c: $o"

# AEB_NO_CACHE skips the read.
o=$(AEB_NO_CACHE=1 run) || fail "no-cache run: $o"
[ "$(echo "$o" | grep -c 'aeb-cc: miss')" = 2 ] || fail "AEB_NO_CACHE should miss: $o"

# A TU that does not compile fails the run.
printf 'int c(void) { return ; ;;; syntax error\n' > "$T/c.c"
printf '0 %s/c.c\n' "$T" > "$T/list"
if run >/dev/null; then fail "a broken TU must fail"; fi
echo OK
