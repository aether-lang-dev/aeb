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

- A pom that asks for a range (`[1.0,2.0)`) is settled when the node is
  written: the highest published version in the range, said in the output.
  The node records the version, not the range. `[1.2]` is 1.2.
- `--bom` only gives a version to a version-less coordinate on the command
  line. It changes no node's edges: a node is one file shared by everything
  that depends on it, so it cannot carry one consumer's BOM.

A consumer depends on a node like any other:
`dep("third_party/java/org/hibernate/hibernate-core/5.4.32.Final/.jar.ae")`.

## dep("group:artifact:version") is the node, written on first use

Keeping artifacts this way is a team's choice, and like every other intent
it is declared in `.ae`:

```aether
maven_nodes("third_party/java")
```

The line goes in a build file, or in a `.bom.ae` it loads, which says it for
everything that loads that file. The directory is the team's to name;
nothing in aeb looks for `third_party`. Where the line is in reach, the
coordinate form is shorthand for the path:

```aether
dep("org.hibernate:hibernate-core:5.4.32.Final")
```

A build file with no such line in reach is untouched: its coordinates
resolve at build time as they always did (`lib/maven`), recorded nowhere.
Existing repositories do not change, parts of one repository can choose
differently, and another strategy (vendored jars, a different layout) would
be another declaration beside this one.

While the graph is being read, before anything builds (`tools/aebmvn`, the
same place a `git:` dep is fetched):

- **The node is there**: that is the edge. Nothing is resolved.
- **It is not**: first use. `aeb mvn add` writes it and its closure, the
  build carries on, and the new files are the diff to review and commit. The
  hash is whatever the repository served that day, as with any lock file.
- **Locked** (`--locked`, `AEB_LOCKED=1`, or `CI` set and `AEB_LOCKED` not
  `0`): a missing node is an error that gives the command. A dependency
  nobody reviewed does not get in by being built.

## A BOM is a list of picks

A version-less `dep("group:artifact")` takes its version from the BOMs the
build file loads (`load_bom_file` → `maven_bom("G:A:V")`). What a BOM
manages is read once and kept in the tree
(`third_party/java/<group dirs>/<artifact>/<version>/managed.bom.ae`, one
`managed("g:a", "v")` line each), so a build reads versions from a file.

In Maven a BOM also replaces the version of anything in the closure. Here
that is an arbitration like any other, and it is written down: where the
closure asks for a version other than the BOM's, aeb appends

```aether
dep_arbitration("org.junit.jupiter:junit-jupiter-api", "6.1.1", and_not("5.13.4"))
```

to the `.bom.ae` that names the BOM, writes the node for the BOM's version
if it is missing, and gives the build file an edge to it. Every node that
loads that `.bom.ae` has those lines as its own. A line already there for
the artifact is left alone, whoever wrote it: change the pick on the line to
decide differently. A locked build does not write the line; it fails and
shows it.

On spring-data-examples' `jpa/example` (Spring Boot's BOM, which manages
about 1,500 artifacts) that came to ten lines, all written by aeb and none by
hand, over 108 artifacts; its 45 tests pass as they do resolved the old way.

Hand-written arbitrations for a whole project go in the same file. On jooby
(7 BOMs, 99 artifacts for the core, guice, hikari, netty and kotlin modules)
that was one line from a BOM and five by hand, among them slf4j-api 2.0.18
over HikariCP's 2.0.17 and log4jdbc's 1.6.0, and byte-buddy 1.18.3 (assertj)
over 1.17.7 (mockito): choices Maven makes without saying.

## A diamond stops the build

A classpath that would hold one artifact at two versions is a diamond. Maven
settles it silently (nearest wins), Gradle silently (highest wins). aeb does
not settle it. A generated node settles nothing either: it is what a pom
says, and it hands its record up with both versions in it. The first node a
person wrote whose classpath holds both fails, and says:

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
- A node's own arbitration holds without a contest too: "3.4.1, and not
  3.3.2" moves a lone request for 3.3.2 to 3.4.1. (That is how a BOM's
  version replaces a pom's.) An inherited or default one speaks only when
  two versions meet.
- An arbitration written in a build file that names nothing its classpath
  asks for is reported as out of date.
- With the pick applied, what is on the classpath is recomputed from the
  roots: the pick's own dependencies come with it and the loser's go.

## Where it is written: per leaf, with a default

Correctness needs one version per classpath, not per repository, so the
arbitration is written wherever the decision belongs, and three places are
read, nearest first:

1. **The node being built.** Its own `dep_arbitration`, and those in the
   `.bom.ae` files it loads, are the last word.
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

- Where no `maven_nodes` line is in reach, `dep("group:artifact:version")`
  resolves at build time through `aeb-resolve.jar`, unhashed, with versions
  mediated by the resolver. That is deliberate: existing repositories keep
  working.
- `java.jar_registry` resolves that way everywhere.
- Only `jar` and `pom` typed dependencies.
- The walk that finds what a BOM manages differently does not apply pom
  exclusions, so it can write a pick for a version only reached through an
  excluded edge. The line is then unused, not wrong.
- Compile and runtime scope are one closure.
- A `.dist.ae` that shades reads its deps' classpath lists as they wrote
  them. That is right when it depends on the node that compiled (whose list
  is already settled), and unchecked when it depends directly on two nodes
  that disagree.

The rules are in `lib/mvngraph` (pure, `tests/test_mvngraph.ae`); the
reading and reporting in `lib/bldr`; the builders (`java.jar_maven`,
`java.pom_maven`, `java.jar_bundle`) in `lib/java`; the coordinate-to-node
pass in `tools/aebmvn`; the generator in `tools/resolver` (`--output nodes`,
`--output managed`). `itests/mvn-nodes-arbitration.sh` and
`itests/mvn-first-use.sh` run the whole of it against a diamond and a BOM.
