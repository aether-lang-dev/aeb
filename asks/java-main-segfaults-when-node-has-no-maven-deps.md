# BUG: JVM builders SEGFAULT on a node that declares no maven deps (`java_main`, `kotlinc`, `kotlinc_test`)

**From:** html-sanitizer (2026-08-27). **Severity: crash.** Exit 139, no
diagnostic — the node dies before printing anything.

## Reproduce

A `.tests.ae` that uses `java_main` and declares **no** `maven_dep()` /
`load_bom_file()`:

```aether
import bldr
import java
import java (source_layout, jvm_args, skip_below_jdk)

aeb(cap) {
    bldr.build() {
        dep("core/.build.ae")
        dep("java/.build.ae")
        java.javac_test() { source_layout("maven idiomatic") }
        java.java_main("org.htmlsanitizer.ConformanceTest") {
            skip_below_jdk(22)
            jvm_args("--enable-native-access=ALL-UNNAMED")
        }
    }
}
```

```
$ aeb java/.tests.ae
make: *** [target/.aeb/bldr.mk:4: java_.tests.ae] Error 139
Segmentation fault (core dumped)
```

The log file contains exactly one line: `Segmentation fault (core dumped)`.

**`javac_test` alone is fine** — deleting just the `java_main` block makes the
node exit 0.

**`lib/kotlin` has the same bug**, at two sites: `maven.classpath(ctx)` at
module.ae:300 (`kotlinc`) and :443 (`kotlinc_test`). Our kotlin leaf segfaults
identically. So this is not a `java_main` quirk — it is every JVM builder that
reaches maven, on any node that declares no maven deps.

## Backtrace

```
Program received signal SIGSEGV, Segmentation fault.
0x00005555555812a4 in string_trim ()
#0  0x00005555555812a4 in string_trim ()
#1  0x000055555557d0f0 in java__D_tests_D_ae ()
#2  0x0000555555557c7b in main ()
```

## Cause

`builder java_main` calls `maven.classpath(ctx)` unconditionally:

```aether
maven_cp = maven.classpath(ctx)      // lib/java/module.ae, java_main
```

which calls `resolve(ctx)`, which does:

```aether
maven_deps, _ = map.get(ctx, "maven_deps")
dep_count = list.size(maven_deps)          // <-- maven_deps is NULL here
if dep_count == 0 { … }
```

On a node with no maven deps the `maven_deps` key was never created, so
`map.get` yields null and `list.size(null)` walks a null pointer. The
guard that would return early (`dep_count == 0`) is *after* the deref, so it
never runs.

(The frame says `string_trim` rather than `list_size` — likely inlining, or the
crash lands at `lib/maven/module.ae:232`'s `string.trim(result_raw)` on a null
`_sh_capture` result along the same unguarded path. Either way the trigger is
"no maven deps declared", and the fix is the same shape: guard for the absent
key before use.)

## Suggested fix

Null-guard the key read, in `resolve` and anywhere else reading a
possibly-absent list/map key:

```aether
if map.has(ctx, "maven_deps") == 0 {
    _e1 = map.put(ctx, "_maven_resolved", "")
    return ""
}
```

Worth a sweep: `map.get(ctx, "<key>")` followed by `list.size(...)` with no
`map.has` guard is the general shape, and a node not using a given feature is
the common case, not the exotic one.

## Note on discovery

This was masked for us by a separate bug — see
`asks/extract-deps-still-matches-the-pre-shape-a-dep-syntax.md`. With the dep
graph silently empty, `.presubmit.ae` ran one node and reported success, so
neither this crash nor several real test failures surfaced. Fixing the scanner
turned up all of them at once.

---

## RESOLVED (2026-08-30, aeb-side)

Fixed in `lib/maven/module.ae`: `resolve()` and `_cache_key_for_resolve()`
now `if map.has(ctx, "maven_deps") == 0 { return "" }` BEFORE reading the
key, so `list.size(null)` is never reached. One guard covers java_main,
kotlinc, and kotlinc_test (all route through `resolve()` via
`maven.classpath()`). Regression test added to `tests/test_maven_cmd.ae`
(`resolve()` on a no-maven-deps map returns `""`). The commit's box has a
benign `list.size(null)` (returns 0) so the crash didn't reproduce locally,
but the guard removes the null deref regardless.
