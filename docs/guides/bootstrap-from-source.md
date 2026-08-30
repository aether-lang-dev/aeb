# Bootstrapping aeb from source

For **consumers** who want to install aeb and use it to build a repo —
whether you're tracking `HEAD`, pinning aeb in CI, or onboarding a
machine. This is **not** the contributor flow: you do **not** need to run
aeb's test suite (`./tests/run.sh`) or the `itests/` to *use* aeb.

aeb is written in Aether, so it has one hard prerequisite: the **Aether
toolchain** (`ae`). aeb's own `tools/*.ae` are compiled with `ae build`.

---

## TL;DR

```sh
# One-liner: install the latest tag to ~/.local (no sudo).
curl -sSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/install.sh | sh

# Pin an exact version (reproducible — recommended for CI):
curl -sSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/install.sh \
  | AEB_REF=v0.001 sh

# Or from a clone:
git clone https://github.com/aether-lang-dev/aeb.git
cd aeb && make install            # PREFIX defaults to ~/.local
```

Then ensure `~/.local/bin` is on your `PATH` and run `aeb` from any repo
that has `.build.ae` / `.tests.ae` / `.dist.ae` files (`aeb --init`
scaffolds a starter).

---

## Prerequisites

| Need | For |
|---|---|
| **Aether toolchain** (`ae` / `aetherc`) | building aeb's tools — the one hard dep. See [aether's bootstrap-from-source](https://github.com/aether-lang-dev/aether/blob/main/docs/guides/bootstrap-from-source.md). |
| **bash** (3.2+) | the `aeb` trampoline (POSIX-level; macOS bash 3.2 works) |
| **GNU make** | two distinct roles: the install is make-based, **and** the node driver uses it at *build* time to schedule nodes in parallel. Without it every build still works, just serially (see below). |
| **C compiler** (`gcc`/`clang`) | aeb shells out to it for C / Aether-program / generated-header targets |
| **curl, tar** | only for the `install.sh` one-liner |
| **git** | optional — sharpens `aeb --version` (a tag-derived stamp); a non-git tree falls back to a content hash |

Per-language tools (javac, cargo, dotnet, node/pnpm, scala, …) are only
needed by the *targets* that use those SDKs — they're runtime deps of a
build, not of aeb itself.

### `make` is a build-time dependency too, not just an install one

Worth calling out because the table above under-sold it for a long time.
`tools/aeb-driver` schedules the DAG's nodes by, **by default**, writing
`target/.aeb/build.mk` and running `make -jN`, so independent nodes build
as parallel subprocesses. It probes with `command -v make` first:

- **`make` present, `AEB_JOBS != 1`** → Makefile emitted, `make -jN`
  schedules the nodes.
- **`make` absent, or `AEB_JOBS=1`** → no Makefile is written at all; the
  driver runs an in-process sequential loop over the same per-node
  binary.

So `make` is **not required to build** — it is required to build
*concurrently*. A machine without it produces identical artifacts, more
slowly, with no warning and no error. That is deliberate ("the default
path never hard-breaks"), but it means a missing `make` shows up as
"aeb feels slow", not as a diagnostic.

**On Windows this has a sharper edge.** The emitted recipes are POSIX
shell (`2>&1`, `$$?`, `$$((_e-_s))`, `date +%s%3N`, `case`/`esac`), which
`cmd.exe` cannot run. They work only because the driver's probe and run
both go through aeb's POSIX-shell chokepoint, which routes shell-outs via
**MSYS/MinGW `sh`**. Consequences:

- the `make` on `PATH` must be the **MSYS/MinGW GNU make**. An `nmake`
  would not understand these recipes — though it would also fail the
  `command -v make`-under-`sh` probe, so the effect is a silent fall back
  to serial, not a crash;
- a native-Windows setup with no MSYS `make` is a **supported serial
  configuration**, not a broken one;
- this reasoning is read off the chokepoint, not off a Windows run —
  whether the multi-node *parallel* path has ever been exercised on
  Windows is not recorded. Treat it as unverified.

Full write-up: [`windows-cross-platform-notes.md`](windows-cross-platform-notes.md) § 4.

---

## The two install paths

### A. `install.sh` (fetch a pinned tarball)

```sh
curl -sSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/install.sh | sh
```

Knobs (env vars):

| Var | Default | Meaning |
|---|---|---|
| `AEB_REF` | latest `v0.NNN` tag (else `main`) | tag / branch / commit SHA to install |
| `PREFIX` | `$HOME/.local` | install prefix (no sudo) |
| `AETHER` | `ae` | the Aether toolchain to build with |

The script resolves the ref, downloads
`github.com/aether-lang-dev/aeb/archive/<ref>.tar.gz` (GitHub generates a
source tarball for every tag/branch/commit — no release upload needed),
and runs `make install`. It runs **no tests**.

### B. From a clone

```sh
git clone https://github.com/aether-lang-dev/aeb.git
cd aeb
make install                        # to ~/.local
make install PREFIX=/usr/local      # system-wide (needs write perms)
AETHER=/opt/ae/bin/ae make install  # explicit toolchain
```

`make install` force-rebuilds every `tools/*.ae` against the current
toolchain (so a stale prebuilt binary can't ship), then lays down:

```
$(PREFIX)/bin/aeb                 # wrapper that pins AEB_HOME
$(PREFIX)/share/aeb/aeb           # the trampoline
$(PREFIX)/share/aeb/lib           # the SDK modules (java, rust, c, …)
$(PREFIX)/share/aeb/tools         # the compiled tool binaries
$(PREFIX)/share/aeb/AEB_STAMP     # src hash + tag + install time
```

`make check-install` tells you whether an installed tree is current with
a dev checkout.

### C. Straight from a checkout (no install)

You can also just run `./aeb` from a clone — the trampoline lazy-builds
its tools into `tools/` on first use. Handy when hacking on aeb itself;
for a stable, PATH-resolved aeb on a machine, prefer `make install`.

---

## Pinning aeb in a using-repo (reproducible CI)

aeb auto-tags every push to `main` as `v0.001`, `v0.002`, … (see
[CONTRIBUTING.md](../CONTRIBUTING.md)). These are **pinnable markers, not
sem-ver promises** — a higher number just means "later." Pin one so your
build doesn't drift:

```sh
# In CI, before running the build:
curl -sSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/install.sh \
  | AEB_REF=v0.042 PREFIX="$PWD/.aeb-toolchain" sh
export PATH="$PWD/.aeb-toolchain/bin:$PATH"
aeb --since "$GITHUB_BASE_REF" --scan '.tests.ae'
```

Prefer a tag (`v0.042`) over a commit SHA — both are reproducible, but
the tag is human-ordered and tells you *when*. Set `aeb --timeout <secs>`
so a hung build fails fast (124) rather than wedging the runner.

---

## Tracking HEAD over time

```sh
# install.sh:
curl -sSL .../install.sh | AEB_REF=main sh

# clone:
git pull && make install     # install force-rebuilds the tools; no separate clean needed
```

`aeb --version` reports the installed source hash + tag + the toolchain
it was built with — so a stale or mismatched install self-identifies.

---

## For LLMs / automation

Deterministic, non-interactive. Assumes a POSIX shell, a C toolchain,
GNU make, and an installed `ae` on PATH.

```sh
# Install a pinned aeb to a writable prefix (no sudo).
curl -sSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/install.sh \
  | AEB_REF=v0.001 PREFIX="$PWD/.aeb" sh

# Verify (success signals to assert on):
"$PWD/.aeb/bin/aeb" --version            # prints "aeb 0.0.0-dev+<hash> …"
```

Rules of thumb:

- **`ae` must be installed first** — aeb is Aether source. If `install.sh`
  errors with "Aether toolchain not found," install aether (its own
  `docs/guides/bootstrap-from-source.md`) or pass `AETHER=/path/to/ae`.
- **Do not run aeb's tests to *use* it.** `./tests/run.sh` and `itests/`
  validate aeb itself; building + installing touches no test code.
- **Pin `AEB_REF`** for reproducibility; unpinned installs track `main`.
- **Use `PREFIX=…`** to avoid sudo; put `$PREFIX/bin` on `PATH` (or invoke
  `aeb` by absolute path).
- **Idempotent.** Re-running `install.sh` / `make install` is safe.

---

## See also

- [CONTRIBUTING.md](../CONTRIBUTING.md) — the contributor flow, the
  `v0.NNN` auto-tag policy, who pushes.
- [README.md](../README.md) — what aeb is, the CLI flags
  (`--since`, `--scan`, `--shard`, `--timeout`, …).
- aether's
  [bootstrap-from-source](https://github.com/aether-lang-dev/aether/blob/main/docs/guides/bootstrap-from-source.md)
  — install the prerequisite toolchain.
