# BUG: `python.pytest` reports `0/0 PASS` when the venv cannot be built or pytest is absent

**From:** html-sanitizer (2026-08-31). **Severity: silent-green.**

---

## RESOLVED — both defects fixed in `lib/python/module.ae`. Thanks for the precise report.

**Defect 1 (venv failure not propagated):** `_ensure_venv` discarded the
`python3 -m venv` rc and always returned the path. It now returns `(venv, ok)`
and verifies the venv python exists AND runs (`-c 'import sys'`); `ok==0` on any
failure. All six callers (`pytest`, `install`, `lint`, `typecheck`, `package`,
`package_existing`) check `ok` and fail closed with a clear diagnostic naming
`python3-venv`. Verified on a box WITHOUT python3-venv (this dev box has exactly
that state): `python.pytest` now prints the venv diagnostic and reports
`0/1 FAIL`, aeb exits 1 — where it used to report `0/0 PASS`.

**Defect 2 (`0/0` treated as success):** two independent fixes.
  1. The run was `cmd 2>&1 | tee log`, so `$?` was TEE's exit (~always 0) —
     pytest's exit 5 ("no tests collected") and any real failure were masked.
     Changed to `cmd > log 2>&1` (the same fix lib/dotnet already carries for
     its Bug 1). Verified at the shell: `| tee` → exit 0 (masked), `> log 2>&1`
     → exit 5 (propagates → FAIL).
  2. Belt-and-suspenders: even if a run lands at exit 0 with zero counts, the
     verdict now rejects `passed==0 && failed==0` as a failure ("pytest
     collected 0 tests") rather than a green pass.

Regression coverage: `tests/test_python_cmd.ae` gains `_parse_pytest_counts`
cases including the `0/0` "no tests ran" shape the verdict now rejects.

**Feature request NOT done (deferred):** `no_venv()` / `python_bin()` setters so
`python.pytest` can drive the system python offline (your hand-rolled path's
requirement). That's a real gap but a separate enhancement — file/keep a
follow-up ask if you want it prioritised. Your `os.system` path stays correct
in the meantime.

Original report follows.

---

## Thank you first

`bldr.env(K, V)` reaching the SDK verbs via `_env_export_prefix` — 23 libs
including python, ruby, rust, dart — is exactly what
`asks/sdk-builders-cannot-set-env-for-the-test-run.md` asked for. That ask is
satisfied. This report is a bug found *while adopting* it.

## Reproduce

On a box where `python3-venv` is not installed (Debian/Ubuntu splits it out of
the base python package — a very common state):

```aether
aeb(cap) {
    bldr.build() {
        dep("core/.build.ae")
        lib = dep_artifact("core/.build.ae", "shared_lib")
        env("HTMLSANITIZER_LIB", "${lib}")
        return python.pytest()
    }
}
```

```
$ aeb python/.tests.ae
  tests:   python    0.24s [n/a] 0/0 PASS
total: 5.79s wall
```

**PASS.** The log tells the real story:

```
    apt install python3.11-venv
Failing command: /home/paul/scm/html-sanitizer/.aeb/venv/bin/python3
/home/paul/scm/html-sanitizer/.aeb/venv/bin/python: No module named pytest
tests:python: running tests (pytest)
tests:python: tests PASSED
```

`_ensure_venv` failed, the venv python does not exist, pytest is not
installed, zero tests ran — and the verb reported PASSED.

## Two separate defects

1. **`_ensure_venv`'s failure is not propagated.** It printed the whole
   `apt install python3.11-venv` diagnostic and the builder carried on to
   invoke a python that isn't there.

2. **`0/0` is treated as success.** pytest exits **5** for "no tests
   collected", which is not 0 and should not be PASS. Even setting the venv
   aside, a suite that collected nothing is never a pass — it is the exact
   shape of a misconfigured path. The telemetry even prints `0/0`, so the
   count is known at the point the verdict is decided.

Defect 2 is the one worth fixing regardless of environment: `0/0 PASS` should
be an error (or at minimum a loud SKIP), the same way `lib/dotnet` reporting
`PASSED (0/0, exit 0)` when dotnet is absent was worth filing
(`asks/lib-dotnet-test-builder-reports-passed-when-dotnet-absent.md` — same
family of bug).

## What we do instead, for now

Our `python/.tests.ae` keeps its `os.system` invocation. It deliberately does
**not** use a venv: the suite must run offline against the system python with
no network install step, and `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1` keeps a
developer's site-packages plugins from failing the run before our first test.
`python.pytest` mandates the venv, so it is not adoptable for us even once the
verdict bug is fixed — a `no_venv()` / `python_bin()` setter would close that
gap.

Verified our hand-rolled path still runs the real suite: `PASS — 12-check
conformance + callback shapes`.
