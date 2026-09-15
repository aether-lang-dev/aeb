# `python.install()` ignored every pip exit code — a failed install reported nothing

> **STATUS: FIXED (2026-09-15).** Every pip invocation in `python.install()` is
> checked now and fails the node, naming the package. Found in selaenium.

## Resolution (lib/python/module.ae, `builder install()`)

All five pip call sites discarded `bldr._sh`'s return code:

    bldr._sh(pip_install_requirements_cmd(pip_bin, req_path))
    bldr._sh(pip_install_cmd(pip_bin, pkg))
    bldr._sh(pip_install_cmd(pip_bin, _pip_spec(pline)))     // in a seq_each closure
    bldr._sh(pip_install_cmd(pip_bin, path.join(root, wline))) // in a seq_each closure

Since the commands also run `pip install -q`, a failed install produced
`installing deps (pip)` followed by **nothing at all** — indistinguishable from
success — and the node carried on to run a suite whose dependencies were absent.
The failure then surfaced as an unrelated-looking test error
(`No module named pytest`) in a different log file.

Each site now checks the code, names what failed, and fails the node:

    tests:python: installing deps (pip)
    tests:python: install FAILED — pip could not install 'aeb-no-such-package-xyzzy-9999'
    tests:python: FAILED — pip install failed

The two dep-artifact paths were restructured to collect their lines with
`bldr._append_lines` and install in a plain loop, because `bldr.fail` + `return`
inside a `seq_each` callback returns from the *closure*, not the builder, so it
could not stop the walk or fail the node.

## Verified

- A deliberately bogus `pip("aeb-no-such-package-xyzzy-9999")` now reddens the
  node (it previously sailed past).
- selaenium's real python node is unaffected: 65/65 PASS.
- 24 selaenium nodes green on the patched build.

## Follow-up worth doing separately

A failed `python.install()` marks the node failed but does **not** stop the
`python.pytest()` builder in the same block, so the log still ends with
`tests: python: tests PASSED` under a node that reports FAILED. Short-circuiting
subsequent builders once the node is marked failed is a block-execution change
affecting every SDK, so it is deliberately not bundled here.
