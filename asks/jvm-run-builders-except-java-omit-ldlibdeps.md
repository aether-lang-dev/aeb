# `_collect_ldlibdeps` landed in `lib/java` only — kotlin/scala/groovy/clojure still need hand plumbing

**From:** html-sanitizer (2026-08-24). Small follow-on to the batch that
delivered `aether.shared_lib`, `java_main` and `min_jdk`/`skip_below_jdk` —
thank you, all three work and all three are adopted.

## What is now excellent

`core/.build.ae` is four lines:

```
aether.shared_lib(b) {
    source("embed.ae")
    extra_source("_embed_support.c")
    output("libhtmlsanitizer.so")
}
```

and `java/.tests.ae` finds the resulting `.so` with **no path plumbing at
all** — `java_main` calls `_collect_ldlibdeps` and emits
`-Djava.library.path`, so a bare `dep(b, "core/.build.ae")` is the whole
contract. That is exactly the "aeb does the linkage" story. Verified `1/1 PASS`.

## The gap

`_collect_ldlibdeps` is referenced 3× in `lib/java/module.ae` and **0×** in
`lib/kotlin`, `lib/scala`, `lib/groovy`, `lib/clojure`.

So `kotlin_test` / `scalac`+`munit` / `groovyc_test` / `clojure.run_main`
still cannot find a native lib their node deps, and the leaf must do it by
hand. Ours does:

```
lib = build.dep_artifact(b, "core/.build.ae", "shared_lib")
kotlin.kotlin_test(b, "...ConformanceTest") {
    jvm_args("-Dhtmlsanitizer.lib=${lib}")   // java/.tests.ae no longer needs this
}
```

That only works because our Java loader reads a `-D` property as a fallback.
A binding whose loader has no such hook would have nothing to reach for,
since `build.env()` does not reach SDK builders either (it stores under
`proc_env`, which only the project builders drain).

## The ask

Hoist `_collect_ldlibdeps` + the `-Djava.library.path` emission into the
shared JVM-run path so all five languages get it. They already share
`jvm_args` from `lib/java`, so there is precedent for the common surface
living there.

Related, and possibly the same fix: `kotlin_test`, `scalac_test` and
`groovyc_test` each reimplement the run classpath. `asks/java-run-main-builder.md`
suggested `kotlin_test` might simply become `java_main` + the stdlib jar; if
that consolidation happens, ldlibdeps comes along for free.

## Still outstanding from the earlier batch

`asks/sdk-builders-cannot-set-env-for-the-test-run.md` is unaffected by this
round — `env_var` is still absent from python, ruby, rust, dart, javascript,
php, lua, nim, zig, dotnet, elixir, gleam. That remains the blocker keeping 15
of our 21 bindings on hand-rolled `os.system`, and it is the one we would most
like next.
