# BUG: a kotlin `.tests.ae` node serves `[hit] 1/1 PASS` after a test-source edit that must fail

**From:** html-sanitizer (2026-08-23). **Severity: correctness.** This reports
a **green test run for code that does not compile to what was asserted**, which
is the one failure mode a build system must never have.

## Reproduce

`kotlin/.tests.ae` is `kotlin.kotlinc` + `kotlinc_test` + `kotlin_test(b, "…ConformanceTest")`.
With a warm cache, edit any assertion in `src/test/kotlin/**` so it MUST fail:

```
-    assertEquals("<html><head></head><body><div>doc</div></body></html>", s.sanitizeDocument(…))
+    assertEquals("DELIBERATELY-WRONG", s.sanitizeDocument(…))
```

then re-run:

```
$ aeb kotlin/.tests.ae
  tests:   kotlin    8.56s [hit] 1/1 PASS
```

**PASS.** Not only is the assertion not re-checked — the node never recompiles.
No `compiling test code` line is printed, and the stale class is still on disk:

```
$ strings target/tests/kotlin/test-classes/…/ConformanceTest.class | grep -c WRONG2
0
```

`rm -rf target/.aeb target/tests/kotlin` does **not** help; only
`rm -rf ~/.cache/aeb` does. So this is the node-level cache, above
`kotlinc_test`'s own action cache.

## Not a general aeb bug — java is correct

The same experiment against `java/.tests.ae` (`java.javac_test` + a hand-rolled
run) behaves properly:

```
  tests:   java      1.03s [miss] FAILED
```

`[miss]`, and it fails. So `_cache_key_for_javac` picks up the edit and
whatever gates the kotlin node does not.

## Where it is probably NOT

`_cache_key_for_kotlinc` (lib/kotlin/module.ae:181) looks right — it hashes
each source's path + content from the argfile, plus kotlinc version, stdlib jar
content, and the command string. Its doc comment is careful and the reasoning
is sound.

The problem appears to be a level up: the node short-circuits before that key
is ever computed (hence no `compiling test code` output at all). Something in
the `.tests.ae` node's own up-to-date check is not treating
`src/test/kotlin/**` as an input — plausibly because `source_layout("maven
idiomatic")` moves the test sources somewhere the node-level input scan does
not look, while `kotlinc_test` itself resolves them correctly at
module.ae:461.

That last sentence is a hypothesis; the reproduce above is not.

## Why we care disproportionately

We are migrating 21 language bindings to idiomatic SDK builders precisely so
aeb owns build+link+test across all of them. A silent stale PASS defeats the
purpose of running the suite at all — worse than a hand-rolled `os.system`,
which at least always runs. We hit this while fixing a genuinely wrong
assertion: the fix appeared not to work, then appeared to work, depending only
on cache state.

Two real bugs were hiding behind it in our repo (a stale `sanitize_document`
assertion, and a Kotlin 1.3 toolchain), and the cache made both harder to see.
