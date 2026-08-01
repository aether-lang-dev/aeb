#!/usr/bin/env python3
"""Assert every $VAR a workflow step expands is actually provided to it.

WHY THIS EXISTS. release.yml's steps run under `set -euo pipefail`. Under
`set -u`, referencing one unset variable aborts the step IMMEDIATELY —
before any command in it runs. In the Publish step that means `gh` is
never invoked, so the job fails with no `gh` output at all, which reads
like an auth or API problem rather than a typo.

That is not hypothetical: v0.281 tagged but never published because the
release notes grew seven inventory variables (SIZE, N_TOOLS, N_SDK,
N_EXE, UNPACKED, PIN, FETCHVER) that were computed in the stage step but
never wired into the Publish step's `env:`. The tag exists, the payload
verified green, and no release came out.

A workflow can only be tested by running it, and running it means cutting
a release — so a static check is the only thing that can catch this
before a tag is burned.

WHAT COUNTS AS "PROVIDED": the step's own `env:` block, names assigned
locally in the script (`FOO=...`), `for FOO in ...` loop variables, and
the runner-provided names GitHub always sets.

WHAT IS DELIBERATELY IGNORED:
  * `\\$VAR` — escaped, so it is literal text inside a heredoc. The release
    notes are full of these on purpose: they are shell snippets for the
    reader to run, not values to interpolate at publish time.
  * full-line `#` comments — prose that is never expanded. Without this
    the real hits drown in false positives (release.yml's comments discuss
    `$PREFIX/bin/aeb` at length).

Lowercase names are skipped: this targets the SCREAMING_CASE convention
these workflows use for step-to-step values, and matching every `$x`
would flag ordinary loop scratch.

Usage:  python3 tools/check-workflow-env.py [workflow.yml ...]
Exit:   0 clean, 1 if any step references something it will not have.
"""
import re
import sys

try:
    import yaml
except ImportError:
    print("check-workflow-env: PyYAML not installed; skipping", file=sys.stderr)
    sys.exit(0)

# Names the runner always sets. Not exhaustive — extend when a workflow
# legitimately uses another one.
RUNNER_PROVIDED = {
    "GITHUB_REPOSITORY", "GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY", "GITHUB_ENV",
    "GITHUB_PATH", "GITHUB_WORKSPACE", "GITHUB_SHA", "GITHUB_REF", "GITHUB_TOKEN",
    "GITHUB_ACTOR", "GITHUB_RUN_ID", "GITHUB_EVENT_NAME", "GITHUB_SERVER_URL",
    "RUNNER_OS", "RUNNER_TEMP", "RUNNER_ARCH", "RUNNER_TOOL_CACHE",
    "HOME", "PATH", "PWD", "SHELL", "USER", "CI",
}

VAR_REF = re.compile(r"(?<!\\)\$\{?([A-Z_][A-Z0-9_]*)\}?")
ASSIGN = re.compile(r"^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=", re.M)
FORVAR = re.compile(r"\bfor\s+([A-Z_][A-Z0-9_]*)\s+in\b")


def check(path):
    with open(path) as fh:
        doc = yaml.safe_load(fh)
    problems = 0
    for job_name, job in (doc.get("jobs") or {}).items():
        job_env = set(job.get("env") or {})
        for step in job.get("steps") or []:
            run = step.get("run")
            if not run:
                continue
            provided = set(step.get("env") or {}) | job_env | RUNNER_PROVIDED
            provided |= set(ASSIGN.findall(run))
            provided |= set(FORVAR.findall(run))
            # Comments are prose; they are never expanded.
            body = "\n".join(
                l for l in run.split("\n") if not l.lstrip().startswith("#")
            )
            missing = sorted({m.group(1) for m in VAR_REF.finditer(body)} - provided)
            if missing:
                problems += 1
                label = step.get("name") or "<unnamed step>"
                print(f"{path}: {job_name} / {label}")
                print(f"    unset under `set -u`: {', '.join(missing)}")
    return problems


def main(argv):
    paths = argv[1:] or [".github/workflows/release.yml"]
    total = sum(check(p) for p in paths)
    if total:
        print(f"\ncheck-workflow-env: {total} step(s) reference variables "
              f"they will not have at runtime")
        return 1
    print(f"check-workflow-env: OK ({len(paths)} workflow(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
