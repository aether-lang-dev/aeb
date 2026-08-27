#!/usr/bin/perl -0777 -i -p
# Full Shape A node codemod (v2). Reads a whole .ae node, rewrites in place.
# 1. imports + module rename (build -> bldr), protecting .build.ae filenames
s{(^|[^./A-Za-z0-9_])build\.([a-z_])}{$1bldr.$2}gm;
s{^(\s*)import build$}{$1import bldr}gm;
s{^(\s*)import build \(}{$1import bldr (}gm;
# 2. drop the explicit b from graph verbs: bldr.dep(b, -> dep( ; bldr.dep(b) -> dep()
s{\bbldr\.(dep|dep_artifact|publish_artifact|prereq|scan|pkg_dep|_get|target_dir|source_dir|root|program_binary_of)\(b,\s*}{$1(}g;
s{\bbldr\.(dep|dep_artifact|publish_artifact|prereq|scan|pkg_dep|_get|target_dir|source_dir|root|program_binary_of)\(b\)}{$1()}g;
# 3. drop the explicit b from SDK builder calls mod.foo(b) / mod.foo(b, ...)
#    fn names may contain digits (junit5, kotlin_test); modules are [a-z_]+.
s{(\b[a-z_]+\.[a-z_][a-z0-9_]*)\(b\)}{$1()}g;
s{(\b[a-z_]+\.[a-z_][a-z0-9_]*)\(b,\s*}{$1(}g;
# 4. wrap the aeb(cap){ b = bldr.start() <body> } in bldr.build() { <body> }.
#    Only fires when b = bldr.start() is the FIRST statement (skip-guard nodes,
#    where a return precedes bldr.start(), are left for a hand-pass and flagged).
s{(aeb\([a-z_]+\)\s*\{\n)\s*b = bldr\.start\(\)\n(.*?)(\n\})}{
    my ($head,$body,$tail)=($1,$2,$3);
    $body =~ s/^/    /mg;
    "$head    bldr.build() {\n$body\n    }$tail";
}se;
