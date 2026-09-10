# `get.sh` skips on presence and ignores an explicit `AEB_REF` — a pin bump silently doesn't upgrade

> **STATUS: FIXED (2026-09-10).** get.sh now honors an explicit AEB_REF over
> mere presence, normalizes two/three-part tags, and fails loudly on an
> unresolvable ref.

## Resolution (get.sh, aeb_ensure + aebget_aeb_tag)

- **Honor an explicit AEB_REF over presence.** When aeb is present, aeb_ensure
  now compares the installed version to the requested AEB_REF (normalized to the
  X.Y.0 shape): equal (or no AEB_REF) → skip; **requested != installed → install
  the requested ref**. An *upgrade* to an explicitly-newer pin just happens; a
  *downgrade* is gated behind `AEB_FORCE=1` (default keeps the newer, says so).
- **Tag-shape normalization.** aebget_aeb_tag accepts `v0.301`, `v0.301.0`,
  `0.301`, `0.301.0` and maps them ALL to the real two-part tag `v0.301` (it
  used to return a three-part spelling verbatim → nonexistent tag).
- **Fail loudly on an unresolvable ref.** A new _aebget_assert_ref runs after an
  AEB_REF-driven install and `die`s if the landed version != requested (with
  "aeb tags are two-part (v0.301, not v0.301.0)"), so a typo/bad ref errors
  instead of looking like success.

Verified on a v0.300 box: `AEB_REF=v0.301 ./get.sh` → installs v0.301,
`aeb --version` reports v0.301; `AEB_REF=v0.301` on a v0.301 box → skips
(idempotent); `AEB_REF=v0.999.0` → 404s on binary + source then dies exit 1;
`v0.301.0` resolves to v0.301; downgrade kept unless AEB_FORCE=1. The same
honor-the-pin logic is NOT yet applied to `ae_ensure`'s AETHER_REF (ae already
upgrades when below AE_PIN; an explicit-AETHER_REF-differs-but-satisfies-floor
case remains presence-ish) — noted as a minor follow-up, not part of this fix.

Original report follows.

---

> **STATUS: BUG (2026-09-10).** Small fix, real footgun.

**Filed by:** libphonenumber-ae Claude, 2026-09-10, upgrading a box from aeb
v0.300 to v0.301 (to pick up the zig-cc fallback) so I could verify a pin bump
in `ci/versions.env` before committing it.

## Reproduction (clean, today)

Box has `aeb v0.300` on PATH. I want v0.301, and I say so explicitly:

```
$ AEB_REF=v0.301 AE_PIN=0.653.0 PREFIX=$HOME/.local bash ./get.sh
aeb-get: ae 0.662.0 already on PATH (>= 0.653.0) — skipping
aeb-get: aeb 0.300.0 already on PATH — skipping        # <-- ignored AEB_REF=v0.301
aeb-get: using aeb: /home/paul/.local/bin/aeb
aeb-get: done. Pin this in CI with: AE_PIN=0.653.0 AEB_REF=v0.301
$ aeb --version
aeb v0.300      # still old
```

get.sh checked only whether *an* aeb exists, skipped, and reported "done" — even
though I passed a *different, newer* `AEB_REF` than what's installed.

## Why it matters

The whole point of `AEB_REF` is to pin a specific version. The natural upgrade
workflow — *bump the pin in `ci/versions.env`, re-run bootstrap* — silently
no-ops: the user believes they upgraded, `aeb --version` says otherwise, and any
"needs >= v0.301" behavior is quietly absent. That's the same "version string
says one thing, behavior is another" shape the tree already worries about in
`cache-key-omits-toolchain-identity.md`, but one layer earlier — at install,
not at cache.

It also makes a pin bump un-verifiable without leaving the tool: to actually get
v0.301 I had to bypass get.sh entirely — `gh release download` the platform
tarball, `sha256sum -c`, and run the bundle's own `install.sh` (which upgraded
cleanly and reported `aeb v0.301`). The bundle mechanics are solid; it's the
front-door installer that won't honor the pin.

## The fix

When `AEB_REF` is **explicitly set** and differs from the installed version,
honor it — upgrade (or at minimum warn loudly and non-zero, rather than print
"skipping … done"). Suggested shape:

- No `AEB_REF` set, aeb present → skip (today's behaviour, correct — idempotent).
- `AEB_REF` set and == installed → skip (correct).
- **`AEB_REF` set and != installed → install the requested ref.** Optionally
  gate a *downgrade* behind `AEB_FORCE=1`, but an *upgrade* to an explicitly
  requested newer pin should just happen — that's what the user asked for.

Same logic applies to `AE_PIN` for `ae`.

## Secondary nit — tag shape differs between `ae` and `aeb`

`aeb` tags are two-part (`v0.301`); `ae` tags are three-part (`vX.Y.Z`). The
v0.301 change was described to me as "0.301.0", so I first pinned
`AEB_REF=v0.301.0` — which resolves to no tag, and (because of the skip-on-
presence bug above) *looked* like it succeeded. A user copying a pin between the
two sibling repos, or from a release note, will hit this. Either make the tag
shapes consistent, or have get.sh normalise/accept both `v0.301` and `v0.301.0`
(and fail loudly on a ref that resolves to nothing, rather than skipping).

## Not-a-bug (noted for completeness)

get.sh only auto-installs when invoked as a file literally named `get.sh` (it
keys on `$0`) — running it via `bash "$tmp"` correctly produces no install.
That guard against pipe-into-sh is deliberate and fine; it's not part of this
ask. The bug is specifically the presence-check-vs-explicit-pin behaviour when
get.sh IS run as a file.

## Acceptance sketch

- Box with aeb v0.300, `AEB_REF=v0.301 ./get.sh` → installs v0.301, `aeb
  --version` reports v0.301.
- Box with aeb v0.301, `AEB_REF=v0.301 ./get.sh` → skips (unchanged).
- `AEB_REF=v0.999.0` (nonexistent) → fails loudly with "no such ref", not a
  silent skip.
