#!/usr/bin/perl -0777 -i -p
# Shape A node codemod (v3). Rewrites a whole .ae build node in place to the
# b-free `bldr.build() { … }` grammar. Run per node file:
#   perl shape-a-node-codemod.pl path/to/.build.ae
#
# SAFETY: only touches dot-prefixed build-node files — the caller is responsible
# for globbing `.*.ae` and NOT feeding it regular .ae source. Builder-call `(b)`
# stripping is restricted to the known SDK-module allowlist below, so a genuine
# UFCS data call like `v1.cmpeq(b)` (b = real argument) is never corrupted.

BEGIN {
  # SDK modules (lib/*/) whose `mod.foo(b)` calls carry the build handle.
  # Keep in sync with lib/ dir names. `bldr` handled separately (graph verbs).
  our $SDK = join '|', qw(
    aether agent angular approval bash brew c cache clojure container copy cpp
    dart dotnet elixir erlang fetch gleam go groovy haskell java javascript jest
    kotlin lua maven meta moonbit nim pharo php pnpm provision python ruby rust
    sandbox scala swift ts veto webhook webpack zig
  );
}
our $SDK;

# 1. imports + module rename (build -> bldr), protecting .build.ae filenames
s{(^|[^./A-Za-z0-9_])build\.([a-z_])}{$1bldr.$2}gm;
s{^(\s*)import build$}{$1import bldr}gm;
s{^(\s*)import build \(}{$1import bldr (}gm;

# 2. drop the explicit b from bldr graph verbs + node-facing readers.
s{\bbldr\.(dep|dep_artifact|publish_artifact|prereq|scan|pkg_dep|_get|target_dir|source_dir|root|program_binary_of)\(b,\s*}{$1(}g;
s{\bbldr\.(dep|dep_artifact|publish_artifact|prereq|scan|pkg_dep|_get|target_dir|source_dir|root|program_binary_of)\(b\)}{$1()}g;

# 3. drop the explicit b from SDK builder calls: <sdk>.<fn>(b) / <sdk>.<fn>(b, …).
#    fn names may contain digits (junit5, kotlin_test). ONLY the SDK allowlist,
#    so non-build `data.method(b)` UFCS calls are never touched.
s{\b(($SDK)\.[a-z_][a-z0-9_]*)\(b\)}{$1()}g;
s{\b(($SDK)\.[a-z_][a-z0-9_]*)\(b,\s*}{$1(}g;

# 4. wrap the entrypoint body in bldr.build() { … }. Handles BOTH entrypoint
#    spellings: the modern `aeb(cap) {` and the legacy `main() {`. Only fires
#    when `b = bldr.start()` is the FIRST statement. Skip-guard nodes (a `return`
#    precedes bldr.start()) do NOT match here and are left with their
#    `b = bldr.start()` intact for a HAND-PASS — grep for it after running.
s{(aeb\([a-z_]+\)\s*\{\n)\s*b = bldr\.start\(\)\n(.*?)(\n\})}{
    my ($head,$body,$tail)=($1,$2,$3);
    $body =~ s/^/    /mg;
    "$head    bldr.build() {\n$body\n    }$tail";
}se;
s{(main\(\)\s*\{\n)\s*b = bldr\.start\(\)\n(.*?)(\n\})}{
    my ($head,$body,$tail)=($1,$2,$3);
    $body =~ s/^/    /mg;
    "$head    bldr.build() {\n$body\n    }$tail";
}se;
