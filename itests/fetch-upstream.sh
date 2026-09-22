#!/usr/bin/env bash
#
# Fetch upstream sources needed by the integration tests.
# Run once from the itests/ directory before running aeb.
#
set -euo pipefail
cd "$(dirname "$0")"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Repo root, for restoring aeb-tracked files an rsync overwrote (see below).
ROOT=$(cd .. && pwd)

fetch_repo() {
    local repo_url="$1"
    local dest="$2"
    local pin="${3:-}"   # optional: commit SHA or tag to pin to

    echo "Fetching $repo_url ..."
    if [[ -n "$pin" ]]; then
        git clone "$repo_url" "$TMPDIR/clone"
        git -C "$TMPDIR/clone" checkout "$pin"
        echo "  pinned to $pin"
    else
        git clone --depth 1 "$repo_url" "$TMPDIR/clone"
    fi
    # Copy everything except .git into the destination
    rsync -a --exclude='.git' "$TMPDIR/clone/" "$dest/"
    rm -rf "$TMPDIR/clone"

    # Put back anything aeb tracks that upstream also ships at the same path.
    # rsync overwrites by path and knows nothing about which files are ours:
    # flutter-melos-monorepo's pubspec_overrides.yaml are aeb OVERLAYS (they
    # replace `melos bootstrap`, and carry an intl pin Flutter 3.3.x needs),
    # and every fetch silently reverted them to upstream's melos-generated
    # version. The itest then failed for a reason nothing in the tree
    # explained, and `git status` blamed the person who last ran the fetch.
    # Restoring from the index is the whole fix: a tracked file under itests/
    # is by definition aeb's, since upstream sources are gitignored.
    if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        if ! git -C "$ROOT" diff --quiet -- "itests/$dest"; then
            git -C "$ROOT" checkout -- "itests/$dest"
            echo "  -> restored aeb-tracked files upstream had overwritten"
        fi
    fi
    echo "  -> $dest updated"
}

# PIN, do not track HEAD. nx-examples migrated to TypeScript solution-style
# configs in #458: tsconfig `paths` aliases gone in favour of npm-workspace
# package resolution (per-lib package.json `exports` + a `customConditions`
# entry), babel/webpack configs deleted, and libs/shared/product/types now
# re-exporting a `./generated` module produced by an `nx codegen` target.
# aeb's .build.ae files here were authored against the layout BEFORE that, so
# an unpinned fetch silently replaced the subject of the test — 82 of the 88
# recorded upstream files were simply gone, and the itest failed for reasons
# that had nothing to do with aeb. 2cae706 is the parent of #458 and matches
# the recorded file list exactly (233 of 233 present).
#
# Re-migrating to the current upstream layout is worth doing; it is a
# migration, not a fix, and it needs the pin moved in the same commit.
fetch_repo "https://github.com/nrwl/nx-examples.git" "nx-examples" "2cae706f832003717aa6b9b19e447bd09ff08b06"
fetch_repo "https://github.com/spring-projects/spring-data-examples.git" "spring-data-examples" "cd0d2b36"
fetch_repo "https://github.com/adityaathalye/clojure-multiproject-example.git" "clojure-multiproject-example"
fetch_repo "https://github.com/dotnet-architecture/eShopOnWeb.git" "dotnet-architecture-eShopOnWeb"
fetch_repo "https://github.com/fyne-io/fyne.git" "go-multimodule-fyne"

fetch_repo "https://github.com/Oxen-AI/Oxen.git" "rust-multi-module-oxen"
fetch_repo "https://github.com/SystemCraftsman/pants-python-monorepo-demo.git" "python-monorepo-demo"
fetch_repo "https://github.com/mrhdias/store.git" "mrhdias_rust_store"
fetch_repo "https://github.com/adityadroid/flutter-melos-monorepo.git" "flutter-melos-monorepo"
fetch_repo "https://github.com/jooby-project/jooby.git" "jooby"
fetch_repo "https://github.com/pytorch/pytorch.git" "pytorch"
fetch_repo "https://github.com/SeleniumHQ/selenium.git" "selenium"

echo "Done. Upstream sources restored."
