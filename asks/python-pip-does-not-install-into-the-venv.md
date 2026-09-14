# `python.pip(...)` installs nothing into the venv `python.pytest()` then runs

> **RESOLVED in `e67de23`** — and the root cause was the FILER'S BUG, not aeb's.
> `pip()` is a block setter of `python.install()`; called at top level it writes
> onto the graph ctx, so `install()` never sees the dep. Correct grammar is
> `python.install() { pip("pytest") }`. aeb now hard-errors on the misuse instead
> of silently dropping the dep. selaenium's `python/.tests.ae` was fixed
> accordingly and is 65/65 — on v0.309 too, since the grammar was always the
> issue. The diagnosis below ("aeb's venv is fine, installing by hand works") was
> right about the symptom and wrong about whose fault it was; left as filed.

**Filed by**: selaenium Claude, 2026-09-13, on aeb v0.309 / ae 0.666.0
(`~/scm/selenium`, node `python/.tests.ae`).

> **RESOLVED (2026-09-13).** ROOT CAUSE was not the venv or pip's environment —
> it was a **setter called in node position**. `pip()` is a BLOCK SETTER of
> `python.install()`; the node used it at TOP LEVEL:
>
> ```aether
> python.pip("pytest")   // top-level → _ctx is the GRAPH ctx, not install()'s block map
> python.install()       // reads its own block map → pip_deps absent → installs nothing
> ```
>
> So `install()` never saw the dep and installed only base pip — exactly the
> symptom. The correct grammar is `python.install() { pip("pytest") }` (verified:
> pytest installs, suite 65/65-style PASS). This is the same class as lib/ruby's
> setter-as-node footgun. FIX: added `_reject_node_call` to `pip()` and
> `requirements_file()` — a top-level call now FAILS LOUD ("python.pip(...) is a
> block setter of python.install() … installs NOTHING") instead of silently
> dropping the dep. Verified both ways; full suite 136/136. (The `_sh`/pip
> environment is fine; `<venv>/bin/pip install` works under aeb's `sh -c`.)

## Symptom

The node declares its test dependency the documented way:

```aether
python.pip("pytest")
python.install()
python.pytest() {
    env("SELENIUM_CORE_LIB", lib)
    env("PYTEST_DISABLE_PLUGIN_AUTOLOAD", "1")
}
```

and fails:

```
tests:   python   0/0 FAIL
```

`target/.aeb/logs/tests_python.log` says only:

```
tests:python: installing deps (pip)
tests:python: running tests (pytest)
tests:python: tests FAILED
tests:python: FAILED — tests FAILED
```

The actual cause is one line, in a different file —
`target/tests/python/test_output.log`:

```
/home/paul/scm/selenium/.aeb/venv/bin/python: No module named pytest
```

So the "installing deps (pip)" step reported nothing wrong and installed
nothing.

## Reproduction

Delete the venv so aeb rebuilds it from scratch, then look at what landed:

```console
$ rm -rf .aeb/venv && aeb python/.tests.ae
  tests:   python   0/0 FAIL

$ ls .aeb/venv/lib/python*/site-packages/
pip
pip-26.2.1.dist-info
```

Only `pip`. The declared `pytest` is absent.

## It is not the environment

aeb's own venv is fine and installing into it works:

```console
$ .aeb/venv/bin/python -m pip install -q pytest     # exit 0, instant
$ .aeb/venv/bin/python -c "import pytest; print(pytest.__version__)"
9.1.1
```

With pytest present in that same venv the node goes straight to **65/65 PASS**,
no other change.

Worth ruling out explicitly: this box is PEP-668 managed (Arch), so a
system-wide `python3 -m pip install` correctly refuses with
`externally-managed-environment`. That is **not** the cause — aeb creates and
uses its own venv (`.aeb/venv`, python 3.14 here), where installing is allowed,
as the transcript above shows.

## Impact

Every `python.pip(...)` dependency is silently missing at test time. Before
v0.308's `| tee` exit-code fix this compounded: the node reported PASS. Now it
at least reddens, so the damage is a confusing failure rather than a false
green — but the message names pytest, not the install step that should have
provided it.

## Suggested fix

1. Install into the venv that `python.pytest()` will run — the same interpreter,
   not the ambient one.
2. Fail the step when the install fails, and log pip's own stderr. "installing
   deps (pip)" followed by nothing is indistinguishable from success, and sends
   you looking at the test suite instead of the install.
3. Optionally verify each declared dep is importable before running the suite,
   so the error names the missing dep directly.
