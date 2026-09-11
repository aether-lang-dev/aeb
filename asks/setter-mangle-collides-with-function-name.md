# ae compiler: a block-setter's mangled name colliding with a function name should be a compile error, not a silent segfault

## What happens
Inside a `<module>.<verb>() { … }` builder block, the compiler resolves a bare
setter call `foo(...)` to the module symbol `<module>_foo` (the documented
block-receiver mangling — LLM.md:370). If the module ALSO defines a real
function literally named `<module>_foo` with a DIFFERENT signature, the call
silently dispatches to that function instead of the intended setter. With a
mismatched arity the result is memory corruption — a `SIGSEGV in map_put_raw`
at node-eval time, no diagnostic.

## Concrete instance (found in lib/ruby, aeb 0.305)
- `lib/ruby` has an `env(_ctx, k, v)` setter (3 args). Inside `ruby.mri(){ env(..) }`
  the compiler mangles `env` → `ruby_env`.
- The rbenv commit added a function `ruby_env(_ctx, manager)` (2 args).
- `env("K","V")` therefore dispatched to `ruby_env` with 3 args → crash.
Renaming the function fixed it, but nothing warned.

## Existing guard that SHOULD have caught it
As of ae 0.178 a **builder** sharing a name with a **function** in its module is
a hard compile error ("duplicate definition of '<name>': a builder and a
function cannot share a name"). That guard covers builder-vs-function. It does
NOT cover **setter-mangled-name vs function-name**: a setter `env` in module
`ruby` produces the mangled reference `ruby_env`, and a function named
`ruby_env` silently wins.

## Ask
Extend the 0.178-style collision check: when a module defines a function whose
name equals `<module>_<setter>` for any setter reachable in that module's
blocks, and the signatures differ, make it a **compile error** with the same
"cannot share a name" message (naming both the setter and the function). At
minimum, the mis-dispatch must not be silent — an arity mismatch at a mangled
call site should diagnose, never corrupt the stack.

## Repro (minimal)
```
// m.ae — a toy module with the collision
env(_ctx: ptr, k: string, v: string) { bldr.env(_ctx, k, v) }
m_env(_ctx: ptr, x: string) { _e = map.put(_ctx, "x", x) }   // collides with mangled env
// a node: m.some_builder() { env("K","V") }  -> dispatches to m_env(3 args) -> SIGSEGV
```
(In the real case module=`ruby`, function=`ruby_env`.)

Found 2026-09-11. Impact: any SDK author adding a `<module>_<x>` function can
silently break the `<x>` setter for every consumer with a hard-to-diagnose
crash. The ruby instance is worked around by renaming; the compiler gap is
general.
