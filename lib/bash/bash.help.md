# bash SDK — authoring notes

Surfaced by `ae help <script>.tests.ae --lib .aeb/lib` when a name
below appears. See docs/cic-help.md for the mechanism.

## Bare setters need the second import line

The setters inside a `bash.test() { ... }` / `bash.run() { ... }`
block (`script`, `jobs`, `pre_command`, `post_command`, `fixture_seed`,
`fixture_server`) resolve as plain top-level calls — NOT against the
`bash` namespace. A block that uses them needs BOTH `import bash` (for
the builder verb) AND a selective `import bash (script)` (for the bare
setter names). A missing second import surfaces as
`undefined function 'script'`.

Pattern: literal-name `script`

## `test` counts pass/fail; `script` just runs

`bash.test()` is the test runner — per-test PASS/FAIL accounting,
`jobs(N)` parallelism, `fixture_seed` / `fixture_server` lifecycle, and
`pre_command` / `post_command` hooks. `bash.run()` only runs each
declared script once and fails the build on the first non-zero exit. A
`.tests.ae` target almost always wants `bash.test`.

Pattern: literal-name `test`

## `jobs(0)` is auto, and hooks/fixtures force sequential

`jobs(0)` means auto (`nproc`/2, min 1), not "unbounded". Declaring any
`pre_command` / `post_command` hook OR any `fixture_seed` /
`fixture_server` forces sequential execution regardless of `jobs(N)` —
parallel mode and ordered hooks/fixtures are mutually exclusive.

Pattern: literal-name `jobs`
