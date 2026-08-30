# Toolchain selection + generated self-validating locks

Design spec. The feature request and trade-off discussion live in
[`asks/versioned-bom-and-self-validating-lock.md`](../asks/versioned-bom-and-self-validating-lock.md);
this doc is the committed design and the implementation map.

Two capabilities, one shared shape:

1. **Toolchain selection** — declare the needed runtime version
   (`jdk("21")`, `python("3.12")`) and aeb **selects among
   already-installed runtimes** (discover-select-or-fail). Never
   provisions. Closes the "uses whatever's on PATH" gap for the
   multi-SDK-installed case.
2. **Self-validating lock** — a generated `.ae` lock node that embeds the
   hash of the BOM it was generated from and **hard-fails on visit** if
   that BOM changed, so a consumer can depend on the lock alone.

## Toolchain selection — discover-select-or-fail

`<lang>.select_toolchain(version)`-shaped setter records a requirement on
the builder map. At build time the SDK:

1. **Discovers** installed runtimes by probing conventional roots
   (Java: `/usr/lib/jvm/*`, `$JAVA_HOME`, `/Library/Java/.../Home`;
   Python: `/usr/bin/pythonX.Y`, `$PYENV_ROOT/versions/*`, framework dirs).
2. **Selects** the one matching the requested version (exact, or `N+`
   floor) and runs the compiler/interpreter from *that* home — not PATH's.
3. **Fails loudly** if none matches, naming what *was* found:
   `need jdk 21; found: 17, 24 at /usr/lib/jvm` — actionable, vs today's
   silent PATH binding.

It does **not** download or install. Provisioning stays the user's / CI's
job (sdkman, apt, `actions/setup-java`).

### Shared core (lib/build)

The discovery + version-match + error logic is generic and lives once in
`lib/build` so SDKs can't drift (the `file_to_label` three-copy lesson):

- `_match_jvm_version(want, candidate_version)` — pure: does a discovered
  version satisfy the request (exact / `N+` floor)? Tested in `tests/`.
- `_select_toolchain_home(roots_listing, want, version_probe_cmd_template)`
  — pure given a directory listing + the requested version: pick the home,
  or "" if none. The I/O (listing dirs, probing `<home>/bin/javac
  -version`) is a thin wrapper in the SDK.

### Fidelity asymmetry (do not erase)

Identical grammar across SDKs; per-SDK semantics for whether the runtime
version is a *resolution input*:

| | Python / Ruby | Java |
|---|---|---|
| Version in dep identity | yes (`cp312` wheel / native-ext ABI) | no (`junit:5.10` one jar across JDKs) |
| Runtime ↔ resolution | entangled (version is a resolver input) | orthogonal |
| `locked_for(tag)` | load-bearing gate | informational |

Java's `select_toolchain` changes *which javac runs*; the resolved
classpath is JDK-independent. Python's `python(...)` changes which
interpreter builds the venv AND which wheels resolve — so it must feed the
wheel-resolution cache key. A future session must not "symmetrize" Java
into per-JDK locking.

## Self-validating lock — generated, hash-stamped, dep-alone

Three node types:

1. **Versions BOM** (hand-authored) — runtime + dep version pins. Per
   language `pip_versions.ae` / `gem_versions.ae`; Java reuses the existing
   `.bom.ae` (`maven.load_bom_file`). Scope = file location + who deps it.
2. **Lock generator** (hand-authored target) — `aeb .<lang>_make_lockfile.ae`,
   deps the BOM, resolves the closure for the BOM's runtime, emits node 3.
3. **Generated lock** (machine-authored, committed, greppable, never
   hand-edited):

   ```
   // GENERATED — do not hand-edit
   generated_from("pip_versions.ae", "sha256:…")
   locked_for("cp312")
   locked("numpy==2.1.0", "sha256:…")
   ```

   **On visit** the lock node self-validates (one impl in lib/build,
   `_validate_generated_lock`): re-hash the named source, hard-fail on
   mismatch / missing-source / runtime≠`locked_for`. Because the link to
   the BOM is an *embedded content hash, not a `dep()` edge*, a consumer
   deps the lock alone and still gets unconditional validation:

   ```
   python.test(b) { dep("./pip_lockfile.ae")  pip("pytest~8.2") }
   ```

Edge order is irrelevant (`build.dep()` is a runtime no-op; topo-sort
obliterates source-line order). The guarantee rides the embedded hash.

### Shared core (lib/build) — pure, fully testable

- `lock_validate(generated_from_path, embedded_hash, current_runtime_tag,
  locked_for_tag) -> string` — returns "" if consistent, else the
  hard-fail message. Pure (caller supplies the freshly-computed hash);
  tested exhaustively in `tests/` with no toolchains.
- `lock_render(...)` / setter grammar (`generated_from`, `locked_for`,
  `locked`) — the lock node's own surface.

## Implementation status on this checkout

This Chromebook has **side-by-side JVMs** (`/usr/lib/jvm`: 17, 21, 24) but
a **single Python (3.11)** and **single Ruby (3.1)**. So:

- **Generic core** (lib/build): pure version-match + lock-validate +
  toolchain-home-select helpers + their `tests/` — implementable and
  fully verifiable offline. **DONE / IN PROGRESS.**
- **Java toolchain selection**: real multi-JVM box → discover-select-or-fail
  is implementable AND end-to-end verifiable here. **TARGET.**
- **Python/Ruby selection**: implementable; only the single-version + the
  "fail when asked for a missing version" paths are verifiable here (no
  second interpreter to select between). Resolution-input wiring +
  version-tagged venv: implementable, verifiable for "uses 3.11", not for
  "picks 3.12 over 3.11".
- **Lock generator + resolution-input cache key**: pure parts done +
  tested; live resolution wiring is per-SDK follow-up.

### Implemented in this pass

- `lib/build`: the generic pure core — `_digits_prefix`,
  `_version_is_floor`, `_match_major_version`, `_jvm_dir_major`,
  `_select_jvm_home`, `_toolchain_not_found_msg`, `lock_validate`. Tested
  in `tests/test_toolchain_select.ae` (35 assertions, offline).
- `lib/java`: `select_jdk(version)` setter + discover-select-or-fail
  (`_discover_jvm_root` → `_select_jvm_home` → `<home>/bin/javac`),
  cache-key folds the selected JDK home + its probed version, `javac_cmd`
  honors the resolved binary via the `_javac_bin` opts key. Verified
  end-to-end on this box's side-by-side JDKs: `select_jdk("21")` with
  PATH=24 produced bytecode **major version 65 (JDK 21)**;
  `select_jdk("99")` printed the actionable not-found message naming
  installed 17/21/24 and skipped the compile.

### Node-failure propagation — now wired (was a repo-wide silent-green bug)

Earlier, a builder's failure did NOT redden the build: `gen-orchestrator`
discarded the node function's return, always exited 0, so a failed
`javac`/`gcc`/test still produced a green build (a dependent test target
ran against no classes and reported `0/0 PASS`, top-level exit 0). The
root cause was twofold and it affected EVERY SDK, not just `select_jdk`:

1. **The orchestrator never inspected node outcome.** Fixed: it now
   captures `_rc = <node>(s)`, calls `build.record_status`, and
   `exit(1)`s when `build.any_failed(s)` — OUTSIDE the per-node `_sel`
   guard, so it fires in both per-node (the subprocess exits non-zero →
   its rc mark is non-zero → `aeb-driver` aggregates and `exit(1)`s) and
   in-process modes. (The old "typed void, deferred" note at
   `gen-orchestrator.ae` was stale: `transform-ae` already injects the
   `if b == 0 { return 0 }` begin-guard, which makes every builder fn
   int-typed — verified.)

2. **Builders swallowed their own rc.** A user's `.build.ae` `main()`
   calls `java.javac(b)` WITHOUT `return`, so the builder's non-zero
   return falls off the end as 0 — the orchestrator's `record_status`
   never saw it. Fixed by the sweep: every `os.system`-failure (and
   missing-required-setter guard) inside a `builder` body across all
   SDKs now calls `build.fail(ctx, "<reason>")`, which records into the
   shared session that `any_failed` reads. ~69 sites across 16 SDKs.

Verified end-to-end: a test target whose compile dep fails now exits
non-zero in BOTH per-node and in-process modes, the driver prints
`FAILED (see <log>)` and cats the log, the failed compile's rc mark is
1, `make -k` skips the dependent (no rc mark → flagged failed), and a
clean build still exits 0. `select_jdk("99")`'s not-found is now a true
hard-fail (`build.fail` + non-zero exit), not a soft skip. Design record
for the propagation fix: this section + `asks/node-failure-propagation.md`.

### Not implemented here (follow-up)

- Python/Ruby `select`/`python(...)` setters + version-tagged venv +
  interpreter-in-resolution-cache-key (single-version box limits
  verification; the generic core they'd call is done).
- The lock *generator* target (`.<lang>_make_lockfile.ae`) and the
  generated lock node's setter grammar (`generated_from`/`locked_for`/
  `locked`). `lock_validate` (the consume-side check) is done + tested;
  the produce-side is the next slice.
