# `string.seq_filter(seq, named_fn)` segfaults — the predicate must be a closure literal

> **STATUS: FIXED (2026-09-15).** `bldr._nl_to_colon` now passes a closure
> literal. Found live-verifying selaenium's bindings.

## Resolution (lib/bldr/module.ae, `_nl_to_colon`)

`string.seq_filter` reads its second argument as an `AeSeqClosure` — a
`{fn, env}` pair — and calls `clo.fn`:

    StringSeq* string_seq_filter(StringSeq* s, void* pred) {
        if (!pred) return NULL;
        AeSeqClosure clo = *(AeSeqClosure*)pred;     /* <-- struct, not code */
        int (*test)(void*, const char*) = (...)clo.fn;

`_nl_to_colon` passed a **bare function name**:

    _drop_empty(x: string) -> int { ... }
    kept = string.seq_filter(parts, _drop_empty)      // raw code pointer

so `*(AeSeqClosure*)pred` read the first 16 bytes of `_drop_empty`'s machine
code as `{fn, env}` and called the result. SIGSEGV, every time that line runs.

Every other `seq_each`/`seq_map` call site in the SDK already passed a closure
literal (`lib/python/module.ae:494`, `lib/dotnet/module.ae:762`,
`lib/ts/module.ae:294`, `lib/bldr/module.ae:1827`, …); this was the lone
exception. The stdlib's own regression test uses the literal form too
(aether `tests/regression/test_seq_combinators.ae:92`).

Fixed by inlining the predicate and deleting the now-unused `_drop_empty`:

    kept = string.seq_filter(parts, | x: string | {
            if string.length(x) == 0 { return 0 }
            return 1
        })

## How it presented

`_nl_to_colon` builds the `-cp` classpath string, so it took down the Java
node in selaenium:

    $ aeb java/.tests.ae
      build:   java   0.09s [miss] FAILED
    make: *** [target/.aeb/bldr.mk:4: java_.build.ae] Error 139

Error 139 is SIGSEGV. `target/.aeb/logs/java.log` was **empty** — the crash beat
any output, so the only diagnostic was a bare "FAILED". Which of the java
build/test targets died varied with make's `-j4` scheduling, which made it look
intermittent. Backtrace from the core dump:

    #0  string_seq_filter     (_ae_build_all + 0x47058)
    #1  bldr__nl_to_colon     (_ae_build_all + 0x1326b)
    #2  java__D_build_D_ae    (_ae_build_all + 0x21052)

`aeb java/.tests.ae` now passes: 54 found, 53 successful, 0 failed.

## Still worth doing separately

- A build step killed by a signal reports `FAILED` with an empty log. Surfacing
  "killed by SIGSEGV" (rc >= 128) in the node summary would have turned an
  afternoon of bisecting into one line.
- `string_seq_filter` cannot validate a raw pointer at runtime, but the
  **compiler** could reject a named function where a closure is expected —
  the signature is `pred: ptr`, so nothing catches this at the call site today.
