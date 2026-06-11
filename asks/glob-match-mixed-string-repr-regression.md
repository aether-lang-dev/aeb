# Regression: `string.glob_match` wrong when its two args have mixed string representations

> **RESOLVED in ae 0.233.0** (verified green on 0.235.0). Fixed upstream by
> routing the second string argument through the magic-aware `str_data`/
> `str_len` accessors, so `string_*` externs behave identically regardless of
> which side carries the wrapped representation (CHANGELOG 0.233.0; regression
> coverage upstream in `tests/regression/test_string_extern_mixed_repr.ae`,
> spanning `glob_match`, `starts_with`, `ends_with`, `equals`, `contains`,
> `index_of`). aeb's suite is green again with no aeb-side change. Retained as
> the filed report / trail.

**Filed by**: aeb project (sibling claude), 2026-06-11
**Toolchain**: `ae 0.234.0` (linux-x86_64). Was GREEN on `ae 0.230.0`; broke
after the in-session bump to 0.234. Suspected origin: the 0.231.0 **String-ABI
unification** ("plain-`char*` string ops now return a magic refcounted
`AetherString`" + the raw-cast accessor migration).
**Severity**: breaks the build. 3 aeb tests fail (`test_veto`,
`test_veto_policy`, `test_webhook_gate`) — both the supply-chain veto AST scan
and the webhook `on()` gate evaluate globs via `string.glob_match`.

## Symptom

`string.glob_match(pattern, s)` returns the correct result **only when both
arguments have the same string representation** (both string-literals, or both
heap/computed strings). A **mixed** call — one literal, one heap-allocated
(e.g. a `string.substring` result or a function parameter) — returns the wrong
answer (a true match reports 0).

## Minimal reproducer

```aether
import std.string
extern println(s: string)
_pr(label: string, r: int) {
    if r == 1 { println(string.concat(label, ": MATCH")) }
    else { println(string.concat(label, ": no")) }
}
main() {
    h = string.substring("xxmainxx", 2, 6)   // heap-allocated "main"
    _pr("lit/lit  ", string.glob_match("main", "main"))   // MATCH  (correct)
    _pr("heap/lit ", string.glob_match(h, "main"))        // no     (WRONG)
    _pr("lit/heap ", string.glob_match("main", h))        // no     (WRONG)
    _pr("heap/heap", string.glob_match(h, h))             // MATCH  (correct)
    _pr("glob l/h ", string.glob_match("m*n", h))         // no     (WRONG)
}
```

Observed on 0.234.0:
```
lit/lit  : MATCH
heap/lit : no
lit/heap : no
heap/heap: MATCH
glob l/h : no
```

`string.substring`, `string.starts_with`, etc. themselves are fine — the glob
extracted by substring prints correctly; only the `glob_match` call misbehaves.

## Likely cause

`string_glob_match_raw(const char* pattern, const char* s, int flags)` (in
`std/string/aether_string.c`) takes raw `const char*`. The #297 auto-unwrap
(`aether_string_data(arg)` injected at C-extern string-param call sites) appears
to be applied **non-uniformly across the two string params of the same call**:
when the args differ in representation, one is unwrapped to its `char*` data and
the other is passed as the raw magic-`AetherString` pointer, so `fnmatch` reads
a struct header as a C string and the match fails. Same-representation calls
unwrap consistently (both or neither), so they work.

This is the same call-site-unwrap machinery as CHANGELOG 0.x "Module-imported
externs now trigger the #297 auto-unwrap at call sites" — the gap here is a
**two-string-argument extern where the per-argument unwrap decision isn't made
independently/uniformly**.

## Expected

`glob_match(pattern, s)` returns the same result regardless of whether either
argument is a string-literal or a heap/computed string. Every other two-string
extern (`string.equals`, `string.starts_with`, `string.contains`, …) should be
audited for the same mixed-representation hazard.

## aeb-side impact / interim

No clean aeb workaround: forcing the heap arg through `concat(x,"")`/`trim`
doesn't help (it's already heap → still mixed vs a literal arg); the only thing
that "works" is making BOTH args the same representation (e.g. wrap the literal
arg in `concat(lit,"")` so both are heap), which is a fragile hack we'd rather
not litter across call sites. Preferring an upstream fix. Until then aeb on
0.234 has 3 failing tests; 0.230 is green.
