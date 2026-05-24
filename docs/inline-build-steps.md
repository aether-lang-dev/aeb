# Inline build steps — dropping into raw Aether

A `.build.ae` is not a config file; it's an **Aether program** with a
`main()`. The idiomatic SDK builders (`java.javac(b)`,
`rust.cargo_project(b)`, `pnpm.run(b, "lint")`, …) are just function
calls. Between them — or instead of them — you can write *any* Aether:
shell out, parse stdout, transform strings, do arithmetic, and write
artifacts.

That inline code calls functions like any normal Aether program:

- functions defined **in the same `.build.ae` file** (an adjacent
  helper), or
- functions pulled in with **`import`** (the stdlib — `std.os`,
  `std.io`, `std.string`, `std.path` — or your own module).

For a multi-step worked example of this — bringing a container up,
poking an endpoint inside it, then tearing it down as three dep-ordered
inline steps — see [container-lifecycle.md](container-lifecycle.md).

This is the escape hatch that means you never hit a wall: if no SDK
builder does what you need, the full language is right there. (When a
pattern recurs across projects, promote it to a real SDK setter or
builder — see [the load-bearing principle](#when-to-promote-to-an-sdk).)

## What a build step has access to

After `b = build.start()`, these public accessors give inline code the
paths it usually needs:

| Accessor | Returns |
|----------|---------|
| `build.target_dir(b)` | `target/<module>/` — where build outputs and artifacts belong; a later `.dist.ae` / archive step pulls from here |
| `build.source_dir(b)` | the module's source directory (where the `.build.ae` lives) |
| `build.root(b)` | the repo root aeb was invoked from |
| `build.mkdirs(path)` | create a directory (and parents) before writing into it |

Everything else is the Aether stdlib: `os.exec(cmd)` (run a command,
capture stdout + an error string), `os.system(cmd)` (run for its exit
code), `io.write_file` / `io.read_file`, the `std.string` family, etc.

## Worked example: a git-history artifact

This step captures the last 10 commits, reformats them into a numbered
list with a header, and writes the result into the target dir for a
later archive step to bundle. The full runnable example lives at
[`docs/examples/inline-git-changelog/.build.ae`](examples/inline-git-changelog/.build.ae).

```aether
import build
import std.os
import std.io
import std.string
import std.path

main() {
    b = build.start()

    // --- Idiomatic SDK builders would go here, e.g. ---
    //   java.javac(b) { release("21") }
    // Between them, this is plain inline Aether:

    // 1. Shell out to git, capture stdout.
    log_raw, err = os.exec("git log --oneline -10")
    if string.length(err) > 0 {
        println("inline-changelog: git failed: ${err}")
        return 1
    }

    // 2. Reformat via an adjacent function (called like any Aether fn).
    formatted = format_recent(string.trim(log_raw))

    // 3. Write into the target dir for a later archive step to pull in.
    tdir = build.target_dir(b)
    build.mkdirs(tdir)
    outfile = path.join(tdir, "RECENT_CHANGES.txt")
    werr = io.write_file(outfile, formatted)
    if string.length(werr) > 0 {
        println("inline-changelog: write failed: ${werr}")
        return 1
    }
    println("inline-changelog: wrote ${outfile}")
    return 0
}

// Adjacent helper — a normal Aether function, invoked from main()
// above. Numbers each commit line and prepends a header.
format_recent(raw: string) {
    title = "Recent changes (last 10 commits)\n"
    rule  = "================================\n\n"
    out = string.concat(title, rule)

    n = 0
    rest = raw
    line = ""
    while string.length(rest) > 0 {
        nl = string.index_of(rest, "\n")
        if nl < 0 {
            line = rest
            rest = ""
        } else {
            line = string.substring(rest, 0, nl)
            rest = string.substring(rest, nl + 1, string.length(rest))
        }
        trimmed = string.trim(line)
        if string.length(trimmed) > 0 {
            n = n + 1
            num = string.from_int(n)
            entry = string.concat("  ", num)
            entry = string.concat(entry, ". ")
            entry = string.concat(entry, trimmed)
            entry = string.concat(entry, "\n")
            out = string.concat(out, entry)
        }
    }
    return out
}
```

Running it:

```
$ aeb docs/examples/inline-git-changelog/.build.ae
inline-changelog: wrote /…/target/docs/examples/inline-git-changelog/RECENT_CHANGES.txt
aeb: 1 compile + 0 dist + 0 test
```

The artifact:

```
$ cat target/docs/examples/inline-git-changelog/RECENT_CHANGES.txt
Recent changes (last 10 commits)
================================

  1. 86726f8 aeb: fast-fail on dangling .aeb/lib; auto-link Aether FFI; fix shade fat-jars
  2. 4c068af Fix aeb breakages surfaced by the google-monorepo-sim showcase
  3. dba28b0 TODO: record four itest-driven gaps with expected grammar
  …
  10. 3964537 TODO: platform-branching ergonomics section
```

## Pulling the artifact into a later step

The file lives under `target/<module>/`, the same place every SDK
builder writes its outputs. A `.dist.ae` in the same directory shares
that `target/<module>/` dir, so it reads the artifact straight from
`build.target_dir(b)` — no fragile relative paths — and a
`dep(b, ".build.ae")` edge guarantees the producer ran first
([full example](examples/inline-git-changelog/.dist.ae)):

```aether
// docs/examples/inline-git-changelog/.dist.ae
import build
import build (dep)
import std.io
import std.string
import std.path

main() {
    b = build.start()
    dep(b, ".build.ae")          // ensure the inline producer ran first

    tdir = build.target_dir(b)
    body, rerr = io.read_file(path.join(tdir, "RECENT_CHANGES.txt"))
    if string.length(rerr) > 0 { return 1 }

    dist_dir = path.join(tdir, "dist")
    build.mkdirs(dist_dir)
    _w = io.write_file(path.join(dist_dir, "RECENT_CHANGES.txt"), body)
    return 0
}
```

The `dep(b, ".build.ae")` edge guarantees topological ordering: the
inline step that *produces* `RECENT_CHANGES.txt` runs before any step
that *consumes* it. The DAG doesn't care that the producer was inline
Aether rather than an SDK builder — an artifact in `target/<module>/`
is an artifact, however it got there. (A real archive would tar the
`dist/` tree or hand it to `container.image`; the read-and-restage
here is just the smallest thing that shows the hand-off.)

## When to promote to an SDK

Inline Aether is the right tool for one-off, project-specific steps.
But aeb's [load-bearing principle](../LLM.md) is that the
dot-prefixed `.ae` file should stay declarative and greppable. So:

- **One-off, this-project-only** (a bespoke changelog format, a
  repo-specific codegen wrapper) → inline Aether is fine and idiomatic.
- **Recurs across modules in one repo** → factor it into a helper
  module the repo's `.build.ae` files `import` (the consumer-local SDK
  pattern: `.aeb/lib/<name>/module.ae`, tracked in that repo).
- **Recurs across repos / is genuinely generic** → it belongs in a
  core `lib/<name>` SDK as a builder + setters, with the exec strings
  behind pure `*_cmd` helpers that `tests/test_*_cmd.ae` cover.

The progression mirrors how `lib/copy`, `lib/fetch`, and the language
SDKs all started life: a recurring inline shape, lifted into a builder
once the third caller showed up.
