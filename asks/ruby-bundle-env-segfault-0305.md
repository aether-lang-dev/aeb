# aeb v0.305: `env()` in a ruby builder segfaults — ROOT-CAUSED + FIXED

**Status: FIXED in `lib/ruby/module.ae` (rename); an underlying compiler gap
remains (separate ask below).**

## Symptom
`ruby.mri(){ test_file("x.rb") env("K","v") }` (or the same `env()` inside
`ruby.bundle()`) SEGFAULTs the node in ~0.02s — `SIGSEGV in map_put_raw`,
called from the generated node fn. Removing the `env()` line → no crash.

## Root cause (bisected + isolated)
Introduced by commit `4c1d960` (the rbenv grammar), which added a module
function **`ruby_env(_ctx, manager)`**. Inside a `ruby.<verb>() { … }` block the
compiler mangles the bare `env` setter to `<module>_<name>` = **`ruby_env`** —
which now collides with the literal `ruby_env` function. They have DIFFERENT
arities (`env`: `(_ctx,k,v)` = 3 args; `ruby_env`: `(_ctx,manager)` = 2), so the
mis-dispatched `env("K","V")` calls the 2-arg `ruby_env` with 3 args → arg/stack
corruption → SIGSEGV in the `map.put`.

Proof chain (all on ae 0.666 / aeb 0.305):
- v0.303 ruby module (before `ruby_env` existed): `env()` node → PASS.
- + only `ruby_env`/`ruby_version` setters → CRASH; + two UNIQUELY-named
  setters instead → PASS; + `my_env`/`xrbenv` → PASS. So it is the *name*
  `ruby_env` specifically, not symbol count or the `_env` suffix.
- Renaming the setter `ruby_env` → `ruby_manager` in the module → `env()` PASS.

This is exactly the class LLM.md:370 documents ("a builder must not share a name
with a function in its module — both mangle to `<module>_<name>` and collide"),
except here it's a **block SETTER's mangled form** (`env` → `ruby_env`) clashing
with a real function name — which the ae 0.178 duplicate-definition guard does
NOT catch, and instead of erroring it silently mis-dispatches and segfaults.

## The fix (applied)
Renamed the setter `ruby_env` → **`ruby_manager`** (+ `ruby_version` doc/prose)
in `lib/ruby/module.ae` and its `tests/test_ruby_cmd.ae` uses. The internal map
key (`ruby_env_manager`) and helpers (`_ruby_env_manager`) are unchanged.
`ruby_manager` does not mangle-collide (no `manager` setter exists). Verified:
`test_ruby_cmd.ae` 32 passing; the `env()` node no longer crashes (rc 0).

Public-API note: any node using `ruby_env("rbenv")` must switch to
`ruby_manager("rbenv")`. (selaenium's ruby/.tests.ae + .package.ae updated.)

## Follow-up compiler ask (separate)
See `asks/setter-mangle-collides-with-function-name.md`: the ae compiler should
treat "a block setter's mangled `<module>_<name>` equals a real function name in
the module" as a compile error (like the 0.178 builder-vs-function guard), not a
silent mis-dispatch + segfault.

Found + fixed 2026-09-11.
