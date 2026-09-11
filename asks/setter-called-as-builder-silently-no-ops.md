# A setter called as a top-level builder (e.g. `ruby.rspec()`) silently no-ops — make it a hard error

**Status:** OPEN (2026-09-11). Found migrating servirtium-vcr to the v0.303
tool-named ruby grammar.

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
