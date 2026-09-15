# v0.311's `_dir_newest_mtime` helper fails E0200 (int narrowing) under the ae 0.675.0 it pins — blocks every node using those SDKs

> **Severity: blocker.** aeb v0.311 pins Aether 0.675.0, but its own SDK source
> does not type-check under 0.675.0's stricter narrowing rule. Any binding node
> that imports one of the affected SDKs (dart, python, gleam, moonbit, and the
> other `_dir_newest_mtime` copies) fails to link, so a whole presubmit dies.

## Symptom

On a fresh v0.311 install (tools built ae 0.675.0), building ANY node that
imports an affected SDK — e.g. `aeb python/.tests.ae` — fails at type-check:

```
error[E0200]: narrowing assignment to 'newest': its type was inferred as 32-bit
int from its initializer, but a 64-bit value is assigned here and would truncate.
Annotate the declaration to keep 64 bits (e.g. `long newest = ...` or
`uint64 newest = ...`), or write `int newest = ...` to make the narrowing explicit.
Type checking failed with 1 error(s)
aeb-link: FATAL — failed to link the fan-out orchestrator (…/target/_ae_build_all).
```

The fan-out then can't link, and every node reports Error 127.

## Cause

The `_dir_newest_mtime(dir_abs)` recursive-mtime helper — duplicated across
several SDK modules — does:

```
newest = 0                       // inferred 32-bit int from the 0 literal
...
if sub > newest { newest = sub } // sub / t are 64-bit mtimes (fs.mtime)
if t   > newest { newest = t }
```

Under ae 0.675.0's E0200, assigning the 64-bit mtime into the int-inferred
`newest` is now a hard error. v0.311 (which introduced/leans on this native-mtime
walk — commits e05b926 / 9faf844 "fs.copy_tree/remove_tree", the
version-sort/mtime sweep) shipped without annotating these.

Confirmed copies (grep `newest = 0` in lib/):
- `lib/gleam/module.ae:627`
- `lib/moonbit/module.ae:656`
- `lib/dart/module.ae:834`
- `lib/python/module.ae` (the `_dir_newest_mtime` at ~1115)
- likely the other SDKs listing `_dir_newest_mtime` (clojure/groovy import paths hit it too)

## Fix

Annotate the accumulator to 64-bit at every copy: `long newest = 0` (or
`uint64`), matching the mtime type. A shared `bldr._dir_newest_mtime` would also
collapse the duplication so this can't drift per-SDK again.

## Repro

libphonenumber-ae (branch reboot), which converted its binding `.tests.ae` to the
canonical SDK builders (python.pytest, dart.test, gleam.test, …):
```
AEB_REF=v0.311 sh install.sh        # tools built ae 0.675.0
aeb python/.tests.ae                # → E0200 on 'newest', link FATAL
```
Was green on v0.310 (ae 0.668.0); v0.311 is the regression. Rolling back to
v0.310 restores it.
