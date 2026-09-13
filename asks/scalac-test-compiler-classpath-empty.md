# `scala.scalac_test` compiles with an EMPTY compiler classpath (and an `env()` lands in that slot)

**Filed by**: selaenium Claude, 2026-09-13, on aeb v0.309 / ae 0.666.0
(`~/scm/selenium`, node `scala/.tests.ae`).

## Symptom

```console
$ aeb scala/.tests.ae
Error: Could not find or load main class dotty.tools.dotc.Main
Caused by: java.lang.ClassNotFoundException: dotty.tools.dotc.Main
tests:scala: compiling test code (scalac)
tests:scala: scalac (test) failed
```

Easy to misread as a broken Scala install. It is not: `scalac 3.8.4` on PATH
works, the resolved `scala3-compiler_3-3.8.2.jar` is present (23 MB) and does
contain `dotty/tools/dotc/Main.class`, and running the resolver's classpath by
hand compiles fine:

```console
$ CP=$(java -jar $AEB_HOME/tools/aeb-resolve.jar --output classpath \
        org.scala-lang:scala3-compiler_3:3.8.2 2>/dev/null)
$ java -cp "$CP" dotty.tools.dotc.Main -version
Scala compiler version 3.8.2 -- Copyright 2002-2026, LAMP/EPFL
```

## Cause

`AEB_SH_TRACE=1` shows the two compile invocations. The **main** `scala.scalac()`
gets a correct compiler classpath:

```
[aeb-sh trace] java -cp '/…/scala3-compiler_3-3.8.2.jar:/…/scala3-interfaces-3.8.2.jar:
                         /…/tasty-core_3-3.8.2.jar:/…/scala3-library_3-3.8.2.jar:…'
                    dotty.tools.dotc.Main …
```

The **test** `scala.scalac_test()` gets an empty one:

```
[aeb-sh trace] java -cp '' dotty.tools.dotc.Main …
```

Hence the missing main class — the classpath has no jars in it at all.

## The `env()` variant, which is what we actually hit

With an `env(K, V)` declared on `scalac_test`, `_env_export_prefix`'s output
lands in that same empty slot, so the classpath becomes the export assignment:

```
[aeb-sh trace] '/usr/lib/jvm/java-26-openjdk/bin/java' \
    -cp 'SELENIUM_CORE_LIB='/home/paul/scm/selenium/target/build/selenium_core/lib/libselenium_core.so'' \
    dotty.tools.dotc.Main …
```

`lib/scala/module.ae:546` applies `_env_export_prefix` to the **run** command,
which is right; the compile side should not see it at all, and would not if the
compiler classpath were populated.

Reproduced both ways in `selaenium`: remove the `env(...)` line and the `-cp` is
empty; put it back and the `-cp` is the env assignment. Either way
`scalac_test` never receives the classpath `scalac` resolves correctly a moment
earlier.

## Node that triggers it

```aether
scala.scalac() {
}
scala.scalac_test() {
    env("SELENIUM_CORE_LIB", lib)          // JVM-family binding needs the .so at run time
    main_class("org.openqa.selenium.scala.FfiTest")
    skip_below_jdk("22")
    jvm_flag("--enable-native-access=ALL-UNNAMED")
}
```

## Suggested fix

Have `scalac_test` resolve the compiler classpath the same way `scalac` does
(`_compiler_classpath(ctx)` — it is already memoised on the ctx, so the second
call is free), and keep `_env_export_prefix` to the run command only. Worth a
guard too: an empty compiler classpath should fail with "could not resolve the
Scala compiler classpath" rather than being handed to `java -cp ''`, where it
surfaces as a missing main class and sends you looking at the wrong thing.

## Note

Removing the `env()` is not a workaround for us — a JVM-family binding needs
`SELENIUM_CORE_LIB` set to find the engine `.so` at run time, so the node is
correct as written.
