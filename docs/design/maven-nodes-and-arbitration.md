# Maven artifacts as nodes, and who picks a version

Decided 2026-11-19 (Paul). What aeb concedes to Maven Central is two things:
an artifact arrives as a published jar, not built from source, and what it
depends on is whatever its pom says. Everything else stays aeb's: the graph,
the hashes, and above all the choice of version where two poms disagree.

## One artifact, one node, one hash

`aeb mvn add <group:artifact:version>...` reads the poms once and writes a
build file per artifact of the closure:

```
third_party/java/<group dirs>/<artifact>/<version>/.jar.ae
```

```aether
// org.hibernate.common:hibernate-commons-annotations:5.1.2.Final, as its pom declares it.
// Written by `aeb mvn add`; run that again rather than edit this.
import bldr
import bldr (dep)
import java
main() {
    bldr.build() {
        dep("third_party/java/org/jboss/logging/jboss-logging/3.3.2.Final/.jar.ae")
        java.jar_maven("org.hibernate.common:hibernate-commons-annotations:5.1.2.Final", "<sha256>")
    }
}
```

- The hash lives with the artifact, once, not on every `dep()` that reaches
  it. The transitive jars have a line to carry theirs because each is a node.
- The closure is ordinary graph edges. A build reads these files and
  resolves nothing; a jar whose sha256 is not the node's is not used.
- Each edge is **as the pom declares it**. Nothing is mediated when the
  nodes are written. If B's pom wants `D:1.0` and C's wants `D:1.2`, both
  version directories exist and the graph says so.
- A pom's `<exclusions>` on a dependency are written on that edge
  (`excluding("<the dependency>", "<what is left out>")`) and hold for
  everything reached through it, as in Maven.
- `--into <dir>` writes somewhere other than `third_party/java`; `--repo`
  and `--bom` are as for any resolve. `--into` is the only place the
  directory is named: nothing in aeb looks for `third_party`.

A consumer depends on a node like any other:
`dep("third_party/java/org/hibernate/hibernate-core/5.4.32.Final/.jar.ae")`.

## A diamond stops the build

A classpath that would hold one artifact at two versions is a diamond. Maven
settles it silently (nearest wins), Gradle silently (highest wins). aeb does
not settle it. The node whose classpath first holds both fails, and says:

```
app: org.jboss.logging:jboss-logging is on this classpath at more than one version:
app:   3.4.1.Final  asked for by org.hibernate:hibernate-core:5.4.32.Final
app:   3.3.2.Final  asked for by org.hibernate.common:hibernate-commons-annotations:5.1.2.Final
app: pick one, here or in a build file beside the artifact's version directories:
app:   dep_arbitration("org.jboss.logging:jboss-logging", "3.4.1.Final", and_not("3.3.2.Final"))
```

That example is real: Hibernate 5.4.32's own closure has it.

## dep_arbitration: the pick, and what it is not

```aether
dep_arbitration("org.jboss.logging:jboss-logging", "3.4.1.Final", and_not("3.3.2.Final"))
```

The `and_not` list is the point. A plain pin says "3.4.1 wins over
anything"; this says "3.4.1 wins over 3.3.2".

- It covers exactly the versions it names. When a later bump makes something
  ask for 3.5.0, that version is neither the pick nor in the list, and the
  build stops for a person to look again.
- A pick with no list is refused.
- An arbitration that settles nothing (the classpath asks for one version)
  is reported as out of date.
- With the pick applied, what is on the classpath is recomputed from the
  roots: the pick's own dependencies come with it and the loser's go.

## Where it is written: per leaf, with a default

Correctness needs one version per classpath, not per repository, so the
arbitration is written wherever the decision belongs, and three places are
read, nearest first:

1. **The node being built.** Its own `dep_arbitration` is the last word.
2. **The nodes it depends on.** An arbitration is inherited by whatever
   depends on the node that wrote it, so it is not repeated up the graph.
   Two nodes below that pick differently are a disagreement only this node
   can settle, by writing its own.
3. **The default**, in a build file beside the artifact's version
   directories (`third_party/java/<group dirs>/<artifact>/.jar.ae`).
   `aeb mvn add --pick <g:a>=<version>` writes it. A repository that wants
   one version of everything uses only these.

When a pick differs from what a node below was built or published against,
aeb says so (`note: lib has x:d 1.0 on its own classpath; here it runs with
1.2`). It does not rebuild that node against the pick.

## What is not done

- `dep("group:artifact:version")` still resolves at build time through
  `aeb-resolve.jar`, unhashed, with versions mediated by the resolver. The
  two ways do not see each other: a classpath fed by both is not checked
  across them.
- Only `jar` and `pom` typed dependencies; version ranges are not handled.
- A `.dist.ae` that shades reads its deps' classpath lists as they wrote
  them. That is right when it depends on the node that compiled (whose list
  is already settled), and unchecked when it depends directly on two nodes
  that disagree.

The rules are in `lib/mvngraph` (pure, `tests/test_mvngraph.ae`); the
reading and reporting in `lib/bldr`; the builders (`java.jar_maven`,
`java.pom_maven`, `java.jar_bundle`) in `lib/java`; the generator in
`tools/resolver` (`--output nodes`). `itests/mvn-nodes-arbitration.sh` runs
the whole of it against a diamond.
