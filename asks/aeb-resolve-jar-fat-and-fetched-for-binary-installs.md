# aeb-resolve.jar: make it a single FAT jar, publish it as a release asset, and fetch it for binary installs

**Status:** OPEN (2026-09-13). Design agreed; two foundation fixes landed; the
packaging step is blocked on a pre-existing orchestrator limitation (below).

## The problem this closes

A **binary install** of aeb (via `get.sh` / a release tarball) has **no
`aeb-resolve.jar`**, and nothing acquires it:

- `release.yml` deliberately `rm -f`s `tools/aeb-resolve.jar` + `tools/resolver/`
  from the payload (it was ~3.6 MB on an otherwise ~440 KB payload).
- The jar is `.gitignore`d and built out-of-band by `aeb tools/resolver/.dist.ae`
  — absent from the dev tree too.
- release.yml's comment claims "A Java node fetches the jar separately," but
  **no such fetch code exists** anywhere (checked lib/maven, lib/scala, get.sh,
  the `aeb` trampoline). The three call sites — `lib/maven:~323`,
  `lib/scala:~138/159`, `tools/aeb-sbom:~58` — build `$AEB_HOME/tools/aeb-resolve.jar`
  and `java -jar` it with **no `file.exists` guard**.

So on a binary install, the first Maven/Scala/SBOM node fails with `Unable to
access jarfile .../aeb-resolve.jar` (+ for Scala, `Could not find or load main
class dotty.tools.dotc.Main`). Source installs (`make install`) are fine since
938faa9's jar-stash; binary installs are not.

## Agreed design (Paul, 2026-09-13)

1. **Fat jar, non-shaded.** `aeb-resolve.jar` folds bld's classes IN (no package
   relocation — the jar is only ever `java -jar`'d by aeb's own lib/maven +
   aeb-sbom, never mixed onto an end-user classpath, so `rife.*` can't collide).
   This makes **bld:2.3.0 a BUILD-TIME-ONLY input** — fetched once to compile
   against, folded in, never shipped or needed at runtime. (Today's `thin_jar`
   names bld in the manifest Class-Path and co-locates `bld-<v>.jar` as a runtime
   sibling — two files that must travel together.)
2. **Built + published as a gh-release asset at release time** (out of the base
   tarball, so non-JVM installs stay lean). +1 asset (+ its `.sha256`).
3. **Fetched by binary installs**, into `$AEB_HOME/tools/aeb-resolve.jar` (where
   the call sites already look). NOT build-on-first-use.
4. **get.sh pre-fetch:** if `java` is on PATH at install time, `get.sh` fetches
   the jar into `$AEB_HOME/tools` opportunistically (best-effort — a failure must
   NOT fail the aeb install) — so a `curl…|sh`-built container has the resolver
   baked in before the network goes away. Trigger on `java` present (only fetch,
   not compile). Absent java ⇒ skip silently.
5. **Layering:** get.sh pre-fetch (opportunistic) → first-use lazy fetch (keyed to
   the installed aeb tag via AEB_STAMP `version`, sha256-verified) → loud
   `file.exists` guard at the 3 call sites (print the tag + the manual
   `aeb tools/resolver/.dist.ae` fallback, never the raw JVM error).

## Foundation already landed (this session, in lib/java/module.ae)

Both are correct, orthogonal, and 136/136 green — keep regardless of the rest:

- **javac no longer clobbers jar_pinned's classpath.** `javac` published
  `jvm_classpath_deps_including_transitive` = classes + dep + maven + file cp, but
  DROPPED `own_cp` (the node's own jar_pinned/jar_vendored jars) — so any node that
  does `jar_pinned` + `javac` and is dep'd downstream lost the pinned jar. Now
  `own_cp` is appended. (Latent bug independent of this ask.)
- **package_jar from_classes EXPLODES a .jar entry** (`unzip -qq -o`) instead of
  copying it beside (which nested a jar-in-a-jar — never loadable). A dir entry
  still copies its tree; a non-jar file (a .so/resource) still copies beside. This
  is the non-shaded fat-jar behaviour; no existing caller passed a jar, so zero
  risk. (Matches lib/clojure uberjar + lib/java shade, which both `unzip`.)

## The blocker (needs the orchestrator/SDK owner)

Restructuring `tools/resolver/` into `.build.ae` (jar_pinned + javac) + `.dist.ae`
(`dep(".build.ae")` + `package_jar from_classes(dep_artifact(".build.ae",
"jvm_classpath_deps_including_transitive"))`) — the scala.assembly/clojure.uberjar
shape — hits a **pre-existing dep-rebuild limitation**:

> `tools/resolver/.build.ae` compiles cleanly when built STANDALONE (`aeb
> tools/resolver/.build.ae` → exit 0, BldResolve.class present, artifact lists
> classes + bld jar). But when built as a `dep()` of `.dist.ae`, the
> dep-triggered rebuild of `.build.ae` fails: `error: package
> rife.bld.dependencies does not exist` — javac runs WITHOUT bld on the compile
> classpath. Confirmed pre-existing: reverting the javac change above does NOT
> fix it; the split alone (java SDK untouched) fails identically.

So the dep-triggered build path doesn't thread a same-node `jar_pinned`'s
classpath into that node's `javac` the way a standalone build does. Until that's
understood/fixed, the fat-jar split can't be the packaging route.

`java.shade` was the other candidate (it explodes dep jars) but its dep-edge read
of `jvm_classpath_deps_including_transitive` came back **empty** when invoked as a
`.dist.ae` node (the staging shell is correct — verified by running it by hand —
but shade received no paths). shade has **zero test coverage** and is a legacy
Shape-A setter; likely the same dep-context issue.

## Suggested path

1. Fix the dep-rebuild classpath threading (the blocker) — or confirm the intended
   single-node fat-jar recipe if the split is not the way.
2. With that unblocked, `tools/resolver/.dist.ae` → a fat `package_jar from_classes`
   (the explode support is already in place). Verify: `unzip -l aeb-resolve.jar`
   shows `rife/bld/dependencies/*` + `aeb/maven/BldResolve` and a Main-Class
   manifest; `java -jar aeb-resolve.jar --output classpath <coord>` resolves with
   NO sibling bld jar present. (NB package_jar does not set Main-Class today — it
   `jar --create`s with no `--main-class`; add that, or reuse a main_class setter.)
3. release.yml: stop stripping the resolver source; build the fat jar in a
   JDK-bearing step; publish `aeb-resolve.jar` + `.sha256` as release assets.
4. get.sh: java-present opportunistic pre-fetch into `$AEB_HOME/tools` (best-effort).
5. A first-use lazy fetch + `file.exists` guards at the 3 call sites (tag-keyed,
   sha256-verified, loud on failure).

## Verified by hand (proof the fat jar is correct once packaged)

Running shade's staging shell manually over the `.build.ae` artifact
(`{classes dir, bld jar}`) produced a correct tree: 156 `rife/bld` classes +
`BldResolve.class` + module-info — a valid non-shaded fat jar. The design works;
only the aeb-side packaging wiring is blocked.
