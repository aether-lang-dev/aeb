# Maven-Resolver compile stubs (headers, not implementation)

These are **empty-body Java stubs** — the equivalent of C header files — for
the `org.eclipse.aether.*` (Maven Resolver, née Eclipse Aether) and
`org.apache.maven.*` (Maven model) API surface that
`src/main/java/aeb/maven/MavenResolver.java` references.

## Why they exist

`aeb-resolve.jar` (aeb's Maven coordinate resolver) is a thin driver over the
Maven Resolver library. Building it used to require `mvn dependency:build-
classpath` to put that library on javac's classpath — so building the tool that
resolves Maven deps needed Maven itself (chicken-and-egg), which coupled a fresh
aeb build to a Maven install.

**Compile only needs the symbols, not the behavior.** javac type-checks against
signatures; it never runs a method. So these stubs — every class/interface/
enum/exception `MavenResolver.java` names, with `return null;`/`{}` bodies —
satisfy the compiler completely, with **no mvn and no downloaded jars**:

```
cd tools/resolver
find stubs -name '*.java' > /tmp/stublist
javac -d <out> @/tmp/stublist src/main/java/aeb/maven/MavenResolver.java   # exit 0
```

## What they are NOT

They carry **no behavior**. They are compile scaffolding — never shipped, never
loaded. At RUNTIME the real Maven Resolver impl jars provide the actual classes
(the resolver is shaded / classpathed against the real library). A shaded jar
built from these stubs alone would `NoClassDefFoundError` the moment it tried to
resolve anything — which is correct: headers describe, the library does.

This is the C model: check in the headers (small, textual, source); obtain the
`.so`/impl separately, never in git. The 3.7 MB `aeb-resolve.jar` is
(rightly) gitignored; these ~38 stub files are the source that lets the tool
*compile* without it.

## Maintenance

If `MavenResolver.java` starts using a new API member, javac will say exactly
what's missing ("cannot find symbol"); add the minimal stub for it. Keep them
minimal — only members actually referenced. The Maven Resolver API is stable, so
this rarely changes.
