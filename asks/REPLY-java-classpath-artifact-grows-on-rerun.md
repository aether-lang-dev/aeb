# Reply: a java.javac node's classpath artifact grew on every re-run

Answers `asks/aeb-java-classpath-artifact-grows-on-rerun.md` in the
html-sanitizer repo (found verifying html-sanitizer on aeb v0.348).
**Status: RESOLVED (2026-11-20, in aeb main, for the next release).**

## Cause

`java.javac` (`lib/java/module.ae`) built its compile classpath from, among
other things, the node's OWN `jvm_classpath_deps_including_transitive` file in
`target/`: it read it back so as to keep the jars the node's own
`jar_pinned`/`jar_vendored` calls had written there earlier in the block.
Then it wrote the same artifact: classes dir, dep classpath, maven classpath,
file classpath, and that own part. After run 1 the file held `classes`; run 2
read it, appended it, and wrote `classes` twice; run 3 three times; and so on.
The artifact was a function of the node's inputs AND of its own previous
output, which a re-run in one `target/` is exactly where the second one
shows. The sibling's guess (the `own_cp` block) was right.

## Fix

The node's own jars are already in memory: `jar_vendored` and `jar_pinned`
append every jar to the per-build `_vendored_jars` list of the node's context
(`_accumulate_classpath_jar`), and `java.shade` already reads that list rather
than the file. `javac` now does too (`_own_jars_colon`). Nothing that a node
writes is read back by the node on a later run.

## The other JVM builders

Checked `lib/java`, `lib/kotlin`, `lib/scala`, `lib/groovy`, `lib/clojure` and
every other reader of a file in the node's own `target_dir`:

- kotlin, groovy, clojure and scala's compile step build the artifact from
  their dependencies and their own output dir only; none reads its own artifact.
- `scala.assembly` reads the artifact `scala.scalac` wrote in the same run
  (scalac rewrites it from scratch on every run, so it does not accumulate).
  That is a later step of the same run reading an earlier step's output, not a
  node reading its previous run.
- The other `target_dir` reads (`_read_cache_outcome`, `_read_test_result`,
  `_read_test_report_flag`, `_read_test_failures`) are the orchestrator reading
  what a node's run left for the report, never a node's input.

## Test

`itests/java-classpath-artifact-stable.sh`: four runs of a javac node in one
`target/` leave one line, byte-identical; the same with a `jar_vendored` jar in
the block (the case the file read was for: the jar once, every time); and,
where `kotlinc` exists, a Kotlin node consuming the re-run javac node compiles.
It failed on the previous `lib/java` and passes now (cachyos, JDK 25). Skipped
where there is no JDK.

html-sanitizer's tolerance of a multi-line artifact can come out once it is on
an aeb with this fix.
