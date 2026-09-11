# A setter called as a top-level builder (e.g. `ruby.rspec()`) silently no-ops — make it a hard error

**Status:** PARTIALLY RESOLVED in aeb (2026-09-11); the general check remains a
LANGUAGE ask for the Aether sibling. Found migrating servirtium-vcr to the
v0.303 tool-named ruby grammar.

## Resolution (aeb side — the ruby footgun)

`lib/ruby/module.ae`: the four demoted setters (`install`/`rspec`/`minitest`/
`rubocop`) now call a `_reject_node_call(_ctx, verb)` guard first. It
discriminates on the ctx it was handed: a setter called correctly (inside
`ruby.bundle() { … }`) receives a fresh block map `map_new()` that carries no
graph-ctx keys; a setter called as a NODE receives the graph build ctx, which
carries `"target_dir"` (and `"_session"`). When `target_dir` is present the guard
prints the migration hint and `os.exit(1)`s — a hard, loud failure instead of the
silent no-op / segfault. Verified on ae 0.665.0 / aeb HEAD:

```
ruby.rspec()  (top-level node)  -> "ruby.rspec() is a block setter, not a builder.
                                    ... ruby.bundle() { rspec() } ..." then exit 1
ruby.bundle() { rspec() }       -> unaffected: announce + install + rspec run
```

Unit-tested (the inert block-map / null paths) + itest (the abort path). Full
suite 135/135. This closes the ruby footgun the v0.303 change opened.

## Still open — the GENERAL check (Aether language)

The guard above is ruby-specific and pattern-matches a bldr convention
(`target_dir` on the graph ctx). The clean, universal fix — "a name declared as
a plain setter, invoked in builder position, is a compile error" — needs the
`builder` keyword information the Aether compiler has and aeb's SDK does not.
`transform-ae` is a mechanical sed rewrite with no semantic model of which module
functions are `builder`s, so aeb cannot enforce this generically. A language-level
diagnostic ("`<mod>.<name>()` is a setter, not a node builder") would catch this
class across every SDK (python/rust/scala/… all have block setters), not just
ruby's four verbs. Filing that half against Aether.

## The trap

The v0.303 ruby rework moved `rspec` / `install` / `minitest` / `rubocop` from
top-level builders to **block setters** — they're meaningful only *inside* a
`ruby.bundle() { … }`. The builders that remain are `bundle` / `mri` / `rake` /
`gem` / `consumer_example`.

But the OLD form still **compiles clean and runs NOTHING**:

```aether
ruby.rspec() { env("X", lib) }        // pre-v0.303 form — no error, no test
```

`rspec` is now `rspec(_ctx: ptr) { map.put(_ctx, "ruby_do_rspec", "1") }`
(lib/ruby/module.ae:102). Called as a node builder it resolves (the name exists),
gets the build DAG's `_ctx` auto-injected, flips `ruby_do_rspec` on *that* context
— which no ruby *builder* ever reads, because no `builder bundle/mri/…` runs. Net
result: type-checks, produces a **0-byte test log**, reports a bare fail with no
output. Verified on aeb v0.303/v0.304:

```
old ruby.rspec() form  -> target/.aeb/logs/tests_ruby.log is 0 bytes (nothing ran)
new ruby.bundle(){rspec()} -> log shows "tests:ruby: running tests (rspec)"
```

## Why this is worse than a clean break

A removed builder that ERRORS ("no builder `rspec`") is a 10-second fix for the
consumer. One that **silently executes zero work** is a false signal: a repo that
didn't migrate gets a Ruby "test" node that tests nothing, and — depending on how
the fail is surfaced — can read as green (it certainly produces no failing
assertions, because it runs no assertions). That's exactly the "dishonest green"
class aeb is careful about elsewhere (cf. the dotnet-silent-green and
python-pytest-reports-passed asks).

## Ask

When a **setter** name is invoked in **builder position** (a top-level `mod.x()`
node with `_ctx` auto-injected, where `x` is a setter, not a `builder`), fail
LOUD at build time — e.g. `ruby.rspec() is a block setter, not a builder; use
ruby.bundle() { rspec() }`. A generic form ("`<mod>.<name>()` is a setter, not a
node builder") would catch this class across every SDK, not just ruby's four
verbs. If a general check is hard, a targeted guard in the ruby builders (a
top-level `rspec`/`install`/`minitest`/`rubocop` errors with the migration hint)
would still close the ruby footgun the v0.303 breaking change opened.

Not blocking servirtium — its ruby/.tests.ae is migrated (commit dbc5d02). Filing
because the silent-no-op is the kind of thing that bites the next consumer of a
breaking SDK change without them noticing.
