# `lib/java` has no "run this main class" builder, though kotlin and clojure do

**From:** html-sanitizer (2026-08-23). Small one, and low priority.

`lib/java`'s only run builders are `junit` and `junit5`. Both glob for
`*Test.class` / `*Tests.class` and drive the JUnit console launcher.

There is no way to say "run this main class on the test classpath", even
though the sibling JVM libs have exactly that:

- `lib/kotlin`: `builder kotlin_test(ctx: ptr, test_class: string)` (module.ae:561)
- `lib/clojure`: `builder run_main`

Our Java conformance suite is a plain `main` runner with **no JUnit
dependency** — deliberately, so the suite needs nothing but a JDK, runs
offline, and cannot fail on artifact resolution. (The checks are written so
wrapping them in `@Test` is mechanical; we just don't want to vendor junit +
hamcrest to run 21 assertions.)

So `java/.tests.ae` uses `java.javac_test(b)` for the compile and then hand-rolls
the run with `os.system`, which means reconstructing the test classpath —
duplicating knowledge of where `javac_test` writes (`target/tests/<mod>/test-classes`).
Getting that path wrong fails in a way that looks like a test failure, not a
build-config error.

## The ask

```
java.java_main(b, "org.htmlsanitizer.ConformanceTest") {
    jvm_args("--enable-native-access=ALL-UNNAMED")
}
```

i.e. `kotlin_test`'s shape, in `lib/java`. `kotlin_test` already does the
non-obvious parts worth reusing — putting the module's own prod classes on the
run classpath (`asks/jvm-run-builders-omit-own-prod-classes-from-run-classpath.md`),
and the `min_jdk` gate that SKIPs green rather than failing on an old JDK.

Plausibly `kotlin_test` should just move down to `lib/java` as `java_main`,
with `lib/kotlin` adding the stdlib jar on top — the two differ only in that
one line.
