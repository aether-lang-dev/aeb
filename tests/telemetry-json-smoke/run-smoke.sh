#!/usr/bin/env bash
# telemetry-json end-to-end smoke — the acceptance harness for
# asks/for_ci_use.md (`--telemetry-json <path>`).
#
# Builds a fixture with the three target shapes the ask's acceptance
# criteria name, in ONE aeb invocation:
#
#   cachelib/.build.ae   — cache-hit target (aether.program, manual
#                          aetherc+gcc path → content-address cached).
#   failtest/.tests.ae   — failing aeocha driver_test → 2/3 FAIL with a
#                          genuine per-it report (tests object present).
#   exitcode/.tests.ae   — hand-rolled exit-code-only program_test →
#                          PASS, tests: null (rc only, no per-it report).
#
# Then asserts, per the acceptance criteria:
#   1. The JSON is written (atomically) and is well-formed.
#   2. Per-target rows agree with the run: cache-hit / 2-of-3-fail /
#      exit-code-null-tests, with rc in agreement with status.
#   3. The parallel (make -jN) and sequential (AEB_JOBS=1) driver paths
#      produce the SAME document (modulo duration_ms).
#
# Not part of tests/run.sh (that suite is pure string-builder units, no
# toolchain build). This is the integration counterpart — run it
# directly:  tests/telemetry-json-smoke/run-smoke.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
AEB="$(cd "$HERE/../.." && pwd)/aeb"
TARGETS=(cachelib/.build.ae failtest/.tests.ae exitcode/.tests.ae)

PY="$(command -v python3 || command -v python)"
if [[ -z "$PY" ]]; then
    echo "SKIP: python not found (needed to parse/compare JSON)"
    exit 0
fi

fail=0
say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }

cd "$HERE" || exit 2
rm -rf target ./*/target

# Pre-warm the content-addressed cache so cachelib is a deterministic
# cache-hit on BOTH measured runs below (first build populates it).
AEB_JOBS=1 "$AEB" "${TARGETS[@]}" >/dev/null 2>&1

# JSON output lands OUTSIDE target/ — the build owns target/ and we
# rm it between the two driver runs, which would take the JSON with it.
OUT="$HERE/smoke-out"
rm -rf "$OUT"; mkdir -p "$OUT"
SEQ="$OUT/telemetry-seq.json"
PAR="$OUT/telemetry-par.json"

# --- Sequential driver path (marker reconstruction) ---
rm -rf target
AEB_JOBS=1 AEB_TELEMETRY_JSON="$SEQ" "$AEB" "${TARGETS[@]}" >/dev/null 2>&1

# --- Parallel driver path (make -jN) ---
rm -rf target
AEB_TELEMETRY_JSON="$PAR" "$AEB" "${TARGETS[@]}" >/dev/null 2>&1

say "[telemetry-json smoke]"

[[ -f "$SEQ" ]] && ok "sequential run wrote telemetry JSON" \
                || bad "sequential run left no telemetry JSON"
[[ -f "$PAR" ]] && ok "parallel run wrote telemetry JSON" \
                || bad "parallel run left no telemetry JSON"

# Per-target assertions + cross-path parity, all in one python pass.
"$PY" - "$SEQ" "$PAR" <<'PY'
import json, sys

seq_path, par_path = sys.argv[1], sys.argv[2]
rc = 0
def ok(m):  print(f"  ok   {m}")
def bad(m):
    global rc; rc = 1; print(f"  FAIL {m}")

def load(p):
    try:
        with open(p) as f: return json.load(f)
    except Exception as e:
        bad(f"{p}: not well-formed JSON ({e})"); return None

seq = load(seq_path); par = load(par_path)
if seq is None or par is None: sys.exit(1)

# Schema envelope
for name, d in (("seq", seq), ("par", par)):
    if d.get("version") == 1: ok(f"{name}: version == 1")
    else: bad(f"{name}: version != 1 ({d.get('version')!r})")
    for k in ("aeb_version", "since_ref", "targets", "summary"):
        if k in d: ok(f"{name}: has {k}")
        else: bad(f"{name}: missing {k}")

def by_label(d): return {t["label"]: t for t in d.get("targets", [])}
S = by_label(seq)

# cachelib — cache-hit build, rc 0, tests null
c = S.get("cachelib", {})
if c.get("status") == "cache-hit" and c.get("cache") == "hit":
    ok("cachelib: status cache-hit, cache hit")
else:
    bad(f"cachelib: expected cache-hit/hit, got {c.get('status')!r}/{c.get('cache')!r}")
if c.get("rc") == 0 and c.get("tests") is None:
    ok("cachelib: rc 0, tests null")
else:
    bad(f"cachelib: expected rc 0 + tests null, got rc={c.get('rc')!r} tests={c.get('tests')!r}")

# failtest — failing aeocha, 2/3, status fail, rc agrees (1), tests object present
f = S.get("failtest", {})
if f.get("status") == "fail" and f.get("rc") == 1:
    ok("failtest: status fail, rc 1 (rc agrees with status)")
else:
    bad(f"failtest: expected fail/rc1, got {f.get('status')!r}/rc={f.get('rc')!r}")
t = f.get("tests")
if t == {"total": 3, "passed": 2, "failed": 1, "skipped": 0, "errored": 0}:
    ok("failtest: tests {total:3, passed:2, failed:1, skipped:0} (per-it granularity preserved)")
else:
    bad(f"failtest: expected 2/3 granularity, got {t!r}")

# exitcode — hand-rolled exit-code-only, PASS, tests null (rc only)
e = S.get("exitcode", {})
if e.get("status") == "pass" and e.get("rc") == 0:
    ok("exitcode: status pass, rc 0")
else:
    bad(f"exitcode: expected pass/rc0, got {e.get('status')!r}/rc={e.get('rc')!r}")
if e.get("tests") is None:
    ok("exitcode: tests null (exit-code target reports rc only)")
else:
    bad(f"exitcode: expected tests null, got {e.get('tests')!r}")

# summary — 3 built, 1 failed
sm = seq.get("summary", {})
if sm.get("built") == 3 and sm.get("failed") == 1 and sm.get("skipped") == 0:
    ok("summary: built 3, failed 1, skipped 0")
else:
    bad(f"summary: expected 3/1/0, got {sm.get('built')}/{sm.get('failed')}/{sm.get('skipped')}")

# Cross-path parity: identical documents modulo the volatile duration_ms.
def strip_time(d):
    d = json.loads(json.dumps(d))
    for tg in d["targets"]: tg["duration_ms"] = 0
    d["summary"]["duration_ms"] = 0
    return d
if strip_time(seq) == strip_time(par):
    ok("parallel and sequential paths produce the same document")
else:
    bad("parallel and sequential documents differ (beyond duration_ms)")

sys.exit(rc)
PY
[[ $? -eq 0 ]] || fail=1

if [[ $fail -eq 0 ]]; then
    say "telemetry-json smoke: PASS"
    exit 0
fi
say "telemetry-json smoke: FAIL"
exit 1
