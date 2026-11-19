#!/usr/bin/env python3
"""Keep docs/sdk-ladder.md honest.

The ladder says, per SDK, which build stages aeb does itself and which it
hands to a native build tool. A table like that rots silently: an SDK gets
added, renamed or rewritten and nobody touches the doc. This check fails when

  1. a directory under lib/ has no row in the table and is not listed in the
     "Not languages" line;
  2. a row (or a "Not languages" name) names a lib/ directory that is gone;
  3. a table cell claims a grade other than none / n/a / module-only / no
     (so: aeb, lockfile, delegated, yes) for a rung with no evidence row in
     the appendix;
  4. an appendix row cites a file:line that does not exist, or whose line
     does not contain the quoted tool string, or names an unknown SDK.

--fix moves an appendix row's line number when the quoted tool string is
still in the file but on another line (code added above it): it takes the
nearest line that contains the string, rewrites the row, and then checks as
usual. It changes line numbers only; a string that is gone is still a problem
for a person.

Usage: python3 tools/check-sdk-ladder.py [--fix] [repo-root]
Exit 0 = consistent, 1 = problems (listed), 2 = doc unparsable.
"""
import os
import re
import sys

args = [a for a in sys.argv[1:] if a != "--fix"]
FIX = "--fix" in sys.argv[1:]
root = args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
root = os.path.abspath(root)
doc_path = os.path.join(root, "docs", "sdk-ladder.md")
RUNGS = ["compile", "test", "resolve", "package", "publish", "incremental", "cache", "coverage"]
CLAIMS = {"aeb", "lockfile", "delegated", "yes"}

problems = []
try:
    lines = open(doc_path, encoding="utf-8").read().splitlines()
except OSError as e:
    print(f"error: cannot read {doc_path}: {e}")
    sys.exit(2)

rows = {}        # sdk -> {rung: cell text}
not_lang = set()
evidence = []    # (lineno, sdk, rung, grade, loc, tool)
in_appendix = False
for n, line in enumerate(lines, 1):
    if line.startswith("## Appendix"):
        in_appendix = True
    cells = [c.strip() for c in line.strip().strip("|").split("|")] if line.startswith("|") else None
    if line.startswith("Not languages"):
        # names may wrap onto following lines until a blank line
        text = line
        k = n
        while k < len(lines) and lines[k].strip():
            text += " " + lines[k]
            k += 1
        not_lang = set(re.findall(r"`([^`]+)`", text.split("(no row)")[-1]))
        continue
    if cells is None:
        continue
    if not in_appendix:
        m = re.fullmatch(r"`([^`]+)`", cells[0])
        if m and len(cells) >= 9:
            rows[m.group(1)] = dict(zip(RUNGS, cells[1:9]))
    else:
        if len(cells) == 6 and re.match(r"lib/.+:\d+$", cells[3]):
            evidence.append((n, cells[0], cells[1], cells[2], cells[3], cells[4].strip("`")))

if not rows:
    print("error: no table rows parsed from docs/sdk-ladder.md")
    sys.exit(2)

libdirs = sorted(d for d in os.listdir(os.path.join(root, "lib"))
                 if os.path.isdir(os.path.join(root, "lib", d)))
for d in libdirs:
    if d not in rows and d not in not_lang:
        problems.append(f"lib/{d} has no row in docs/sdk-ladder.md (add a row, or list it under 'Not languages')")
for name in sorted(set(rows) | not_lang):
    if name not in libdirs:
        problems.append(f"docs/sdk-ladder.md names '{name}' but lib/{name} does not exist")
for name in rows:
    if name in not_lang:
        problems.append(f"'{name}' is both a row and listed under 'Not languages'")

have = {(sdk, rung) for _, sdk, rung, _, _, _ in evidence}
for sdk, cellmap in rows.items():
    for rung, text in cellmap.items():
        words = {w.strip() for w in re.split(r"[/,]", text)}
        if words & CLAIMS and (sdk, rung) not in have:
            problems.append(f"{sdk}/{rung} is '{text}' but the appendix has no evidence row for it")

if FIX:
    moved = 0
    for n, sdk, rung, grade, loc, tool in evidence:
        path, _, ln = loc.rpartition(":")
        try:
            src = open(os.path.join(root, path), encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        ln = int(ln)
        if 1 <= ln <= len(src) and tool in src[ln - 1]:
            continue
        hits = [i + 1 for i, text in enumerate(src) if tool in text]
        if not hits:
            continue
        new = min(hits, key=lambda h: abs(h - ln))
        lines[n - 1] = lines[n - 1].replace(f"{path}:{ln} |", f"{path}:{new} |", 1)
        moved += 1
    if moved:
        with open(doc_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        print(f"sdk-ladder: moved {moved} line number(s)")
        sys.stdout.flush()
        os.execv(sys.executable, [sys.executable, os.path.abspath(__file__)] + args)

for n, sdk, rung, grade, loc, tool in evidence:
    where = f"docs/sdk-ladder.md:{n}"
    if sdk not in rows:
        problems.append(f"{where}: evidence for unknown SDK '{sdk}'")
    if rung not in RUNGS:
        problems.append(f"{where}: unknown rung '{rung}'")
    path, _, ln = loc.rpartition(":")
    full = os.path.join(root, path)
    try:
        src = open(full, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        problems.append(f"{where}: {path} does not exist")
        continue
    ln = int(ln)
    if ln < 1 or ln > len(src):
        problems.append(f"{where}: {loc} is past the end of the file ({len(src)} lines)")
    elif tool not in src[ln - 1]:
        problems.append(f"{where}: {loc} does not contain `{tool}` (line reads: {src[ln-1].strip()[:80]})")

if problems:
    print("docs/sdk-ladder.md is out of step with lib/:")
    for p in problems:
        print("  - " + p)
    sys.exit(1)
print(f"sdk-ladder ok: {len(rows)} SDK rows, {len(evidence)} evidence rows, {len(not_lang)} non-language libs")
