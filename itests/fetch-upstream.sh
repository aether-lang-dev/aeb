#!/usr/bin/env bash
#
# Fetch upstream sources needed by the integration tests.
# Run once from the itests/ directory before running aeb.
#
set -euo pipefail
cd "$(dirname "$0")"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

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
    echo "  -> $dest updated"
}

fetch_repo "https://github.com/nrwl/nx-examples.git" "nx-examples"
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
