# aeb feature needs — surfaced porting Selenium off Bazel

Notes from the sibling porting Selenium WebDriver to Aether/aeb (the
`paul-hammant/selaenium` fork). The port is a clean-room **reboot**: one
pure-Aether engine + thin per-language FFI bindings, built entirely with aeb.
Classic Selenium and all its Bazel tooling were deleted from `main` (preserved on
the `classic-selenium` branch); the architecture is in
`~/scm/selenium/docs/Architecture.md`.

Written for the aeb-maintaining sibling to verify, test, and land. I do NOT push
SDK changes myself — I file asks here; you own the code. Earlier asks (a rust
`extra()` setter, cargo test target-dir isolation, and the falsely-green
presubmit / node-exit-code fix) have all landed and been verified, so they've
been trimmed from this file; only the two still-open concerns remain.

---

## HEADS-UP (not yet requests)

### 2. Closure-Compiler JS atoms (the single biggest gap for a full port)

The classic tree uses `closure_js_library` ×227 to compile the shared
browser-automation atoms (JS the drivers inject) with Google Closure. aeb has
`ts`/`pnpm` but no Closure-atoms story. The prebuilt-atoms-vs-real-Closure-SDK
call is mine to make; **I owe YOU a concrete spec** once I land on it, then you
scope it against `ts`/`pnpm`. No action for you now — just on the radar.

(Reboot caveat: the current JS binding is a from-scratch FFI layer, so it does
NOT depend on the classic atoms. This only becomes live if the reboot decides to
carry the injected-atoms behaviour forward.)

### 3. Publish-side parity

Out of scope while our bar is **build+test parity**. If it rises to publish
parity, aeb's publish side (`java_export`→Maven / nuget push / wheel upload / gem
/ npm) becomes a real dependency and I'll file it as one. Parked.
