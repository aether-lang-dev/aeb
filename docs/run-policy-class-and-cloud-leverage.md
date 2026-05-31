# Run policy class, cloud leverage, and job fan-out

Status: **design draft** — no implementation yet. This is the larger
write-up requested after the CI-duties discussion; it supersedes the
sketch in `asks/run-policy-class.md` (keep that ask as the one-paragraph
pointer, this doc as the design).

## The thing being modelled

Two `aeb` invocations can run **on the same hardware** (even the same
GitHub Actions runner) and still be in **different policy classes**. The
class — not the location — governs:

- which **cache namespace** the run may read and write,
- whether the run is **entitled** to enqueue more work of a given class,
  promote artifacts, or borrow remote compute,
- whether the run's **green is authoritative** (others may rely on it) or
  merely **advisory** (confidence for one developer).

The axis is *authority and shared-state*, **not** local-vs-cloud. A dev
borrowing cloud compute is still pre-integration; a CI entrypoint running
on a laptop runner is still CI. Conflating "where it runs" with "what it's
allowed to do" is the mistake this model exists to prevent.

## Policy classes

| Class | Authority | Cache | Entitlements |
|-------|-----------|-------|--------------|
| `ci` | the integration gate; green is a fact others build on | the **authoritative** shared namespace (read+write) | may enqueue ci-class work, promote/publish artifacts, write the shared cache |
| `pre-integration` | a developer *before* the integration line; green is advisory | a **separate, isolated** namespace; never the ci one | may borrow remote compute **if granted**; may NOT write the ci cache, promote, or enqueue ci-class work |

"Pre-integration" names the run by its **position relative to the
integration boundary**, not by a pipeline phase: results of this class do
not cross the integration line into shared truth, *regardless of whether
the work was done locally or on borrowed cloud metal*. (Martin's concern
that the term reads as a "phase": it's a **class/policy** — an authority +
isolation contract — and the phase reading is just the common special
case.)

### Class vs. grant are two axes

Do not collapse "local dev, no cloud" and "dev borrowing GHA" into
different *classes*. They are the same class (`pre-integration`) with a
different **grant**:

- **class** ∈ { `ci`, `pre-integration` } — authority + cache isolation.
- **remote-compute grant** ∈ { yes, no } — may this run offload to cloud
  infra? Orthogonal to class.

So "local dev, no offload" = `pre-integration` + grant=no; "dev borrowing
GHA" = `pre-integration` + grant=yes — **same cache isolation, same
non-authority, different compute.** A pure third `local` class is not
needed; it's `pre-integration` with grant=no. (OPEN QUESTION 1 — confirm
this two-axis model vs. a distinct `local` class.)

## The trust model: purpose-in-the-token → verify → veto

Provenance of this design: Paul Hammant, *"A Purpose in a Token"*
(2021-01-29, paulhammant.com). The post argues that a token's
**purpose/policy should live legibly *inside the token itself*** — placed
in the middle where you find it again across your systems — and ideally be
**hierarchical and constrained at issuance** (`env/dev/phammant/1/redis`,
`adhoc/phammant/exprmnt7/spark12`), chosen from a constrained set
(dropdown / REST), not free-typed. It closes with Wingerd & Seiwald's 1998
rule *"branch only when necessary, on incompatible policy, late"* — which
applies to forking shared state (cache namespaces) too.

Applied here, the policy **claim and the credential are the same artifact**:
the token aeb presents to the cloud / cache / queue *carries its class +
principal + scope embedded and legible*. This is stronger than a bare
`--policy` flag plus a separate opaque credential.

**A passed-in `--policy` is at most a *selector among held tokens*, never
an authority.** The dangerous failure is a pre-integration run electing
itself `ci-class`. The token model defeats it at two layers:

1. **Issuance constraint is the primary defense (not runtime veto).** A
   principal can only be *issued* a token whose embedded scope they're
   entitled to. A dev principal is issued `preint/phammant/*`; the issuer
   will not mint `ci/aether/main` to them (your "constrained from a
   dropdown" point). So aeb can present only what it holds, and the token's
   embedded scope is the hard ceiling — a laptop simply never possesses a
   token that *claims* ci. Self-election is structurally impossible, not
   merely policed.

2. **The embedded purpose makes verify+veto trivial.** The cloud reads the
   legible scope from the token's middle, checks the signature, and accepts
   or **vetoes**. Example tokens (purpose in the middle, per the post):
   ```
   965c5c93…-ci/aether/main-479d84fd…
   e89c15ae…-preint/phammant/feature-x-e1b05214…
   ```
   No out-of-band lookup of "what is this caller allowed to do" — the
   token says so, and the signature proves it wasn't forged.

3. **aeb never self-elects and never self-issues.** It *forwards* the token
   it was handed (from CI runner OIDC, or the dev's issued credential) and
   presents it; the embedded scope IS the claim; the signature IS the
   proof. aeb is mechanism-agnostic about the crypto, but the contract is:
   **scope must be embedded and legible in the token**, not inferred from
   spoofable env vars like `GITHUB_ACTIONS=1`.

4. **Veto is the backstop, not the gate.** Because issuance already bounds
   the claim, the runtime veto mainly catches stale/revoked/expired tokens.
   When it fires it must **degrade, not abort**: a rejected ci-claim
   becomes a pre-integration run (isolated cache, advisory green) with a
   clear log line. It fails the *promotion*, not the build.

5. **Local-only effects are advisory and free.** Which *local* cache
   partition and local behaviour aeb picks follows the held token's
   embedded scope without needing remote verification — it only becomes
   load-bearing (and vetoable) when it reaches a shared/remote resource.

The asymmetry that makes this safe: **claiming a *lower* authority is
always allowed; claiming a *higher* authority requires proof.** A CI run
may voluntarily act pre-integration (it just won't write the shared
cache). A pre-integration run claiming `ci` is rejected at the boundary
unless it authenticates.

```
aeb --policy=ci  (on a laptop)
   └─ local cache: uses the ci-partition path locally (harmless)
   └─ shared ci cache write?  → resource demands credential
                              → laptop has none → VETO → falls back to
                                pre-integration namespace, run proceeds,
                                green is advisory (NOT authoritative)
```

The veto must **degrade, not abort**: a rejected ci-claim becomes a
pre-integration run (isolated cache, advisory green), with a clear log
line ("policy ci claimed but not authenticated; proceeding as
pre-integration"). It does not fail the build — it fails the *promotion*.

## Cache partitioning (the concrete teeth)

The cache namespace **is the token's embedded hierarchical purpose**. The
same legible path a human reads in the token's middle
(`ci/aether/main`, `preint/phammant/feature-x`,
`adhoc/phammant/exprmnt7`) is the cache root path. One scheme gives
cross-class, cross-principal, and per-experiment isolation, and it's
decodable by eye — a *purpose nobody can mistake*, not a salt nobody can
decode. Separate roots (not a key-salt) so isolation is visible,
independently prunable, and independently securable (the ci root is a
different backing store — shared/remote — than a dev's local one; it can
be read-only to dev principals). The single chokepoint is `lib/cache`
`dir()` (today `$AEB_CACHE_DIR` else `$HOME/.aeb/cache`), which resolves a
purpose-partitioned root.

**How many partitions — fork only on incompatible policy (Wingerd &
Seiwald, 1998).** Do NOT partition for partitioning's sake. Fork the
namespace exactly along the seams where policy is genuinely *incompatible*,
late and deliberately: `ci` vs `preint` is incompatible (a hard wall);
two `preint` runs of the *same* principal on the same inputs are NOT
incompatible and may share. The token's embedded hierarchy shows where the
legitimate seams are — partition there, nowhere finer than the policy
actually requires.

**Invariant: a pre-integration run never reads OR writes the ci cache.**
Not write (could poison what CI trusts), not read (could trust something
CI never integrated). Cross-class is a wall, not a preference. Cross-
*principal* within a class is likewise isolated (one dev's preint cache is
not another's), per the embedded principal in the purpose path.

## Cloud leverage / job fan-out

The "borrow GHA to go faster" capability, IF it exists, is **governed by
the grant + class**, and aeb is the **callee, never the control plane**:

- aeb does **not** own triggers (the `on:` block — that's the CI system's;
  aeb has no daemon to watch a remote ref), and does **not** own the
  matrix as a thing it *waits on*. A model where aeb-on-laptop spins up N
  runners, polls them, and aggregates is **rejected** — that is rebuilding
  the Actions control plane inside aeb, the exact over-reach the
  generic-vs-domain line forbids.
- What IS in scope: aeb as the **`run:` step inside a cell** that some
  outer system (GHA matrix, or a dev's granted offload) already
  provisioned. GitHub owns *when/where/with-what-installed*; aeb owns
  *what happens in the cell*. This needs ~zero new aeb code now that exit
  codes are correct (the silent-green fix) — a `run: aeb --since` step is
  already a truthful CI participant.
- A pre-integration **fan-out** (dev splits their pre-push check across
  several granted cloud workers) is permissible **only** within the
  pre-integration cache partition and **only** under grant=yes, and the
  cloud may veto the offload request as inauthentic exactly as it vetoes a
  cache write. It buys speed + confidence; it never writes ci truth and
  never shares cache with ci or with another principal's pre-integration
  runs (cross-principal isolation, not just cross-class).

The litmus test for "can aeb own this duty," unchanged from the CI
discussion: **does it happen inside a single `aeb` invocation, or does it
require something outside aeb to invoke aeb?** Provisioning, triggers, and
the matrix are *about invoking aeb* → outside, vetoable, not aeb's to own.
Cache-partition selection, claim-presentation, and the per-cell build are
*inside* → aeb's, governed by the conferred class.

## What aeb implements vs. what the resource owns

- **aeb implements**: reading the *held token* from context; partitioning
  the *local* cache by the token's embedded purpose; forwarding+presenting
  the token when reaching a shared resource; degrading gracefully on veto
  (token rejected → run pre-integration); never self-electing, never
  self-issuing a token.
- **The token issuer owns** (the primary control): minting tokens whose
  embedded scope is constrained to what the principal is entitled to (a
  dev gets `preint/<them>/*`, never `ci/*`), per "constrained from a
  dropdown / REST at issuance."
- **The resource (cloud / shared cache / queue) owns** (the backstop):
  reading the embedded scope, checking the signature, and vetoing
  stale/revoked/over-scoped tokens. The crypto mechanism (OIDC, signed
  envelope) is the resource's; aeb is mechanism-agnostic **except** for
  the one contract it requires: **the scope must be embedded and legible
  in the token**, not inferred from spoofable env.

aeb must not invent or self-issue authority. It *honours a token's
embedded purpose locally* and *presents the token for remote
verification* — it is neither issuer nor verifier.

## Open questions (decide before implementing)

1. Two-axis (class × grant) vs. a distinct `local` third class.
   (Leaning: two-axis.)
2. ~~Cache isolation by key-salt vs. separate roots.~~ **RESOLVED** by the
   token-purpose model: separate roots named by the token's embedded
   hierarchical purpose; fork only on incompatible policy (Wingerd &
   Seiwald). See Cache partitioning above.
3. ~~Credential mechanism — forwarded token vs aeb envelope.~~ **RESOLVED**:
   the token carries its purpose embedded + legible (the 2021 post);
   aeb is mechanism-agnostic about crypto but requires the embedded-scope
   contract. aeb forwards; issuer constrains; resource verifies.
4. Does `--policy` belong as a flag? **Reshaped**: not a class *assertion*
   (the token's embedded scope is the class). At most a *selector among
   held tokens* (your "dropdown"), and it can never exceed what the chosen
   token encodes. Leaning: allow it as a selector, since a false selection
   simply presents a token whose scope vetoes itself.
5. Token format / where exactly the purpose sits, and whether aeb mandates
   the "purpose in the middle" placement (the post's preference, for
   find-it-again legibility) or only requires it be present + signed.
6. Does aeb need to *parse* the embedded purpose to choose a local cache
   root, and if so does that create a parse-trust issue before the
   signature is checked? (Likely: parse for *local* partition choice is
   advisory/harmless; only the remote resource's post-signature parse is
   authoritative.)

## Relationship to existing aeb pieces

- `lib/cache` `dir()` — the single chokepoint to make class-partitioned.
- `lib/build` `_detect_ci()` — the existing (weak, env-sniffing) context
  signal; the policy claim subsumes/strengthens it. Today it returns
  `github`/`ci`/`local`; the policy model maps "is this a CI principal"
  to class, but the *authority* of that mapping must come from a verified
  credential, not the env var alone (env vars are spoofable on a laptop —
  which is precisely why the cloud must veto, not trust `GITHUB_ACTIONS=1`).
- The `_detect_ci` env sniff is fine for *advisory* local behaviour
  (telemetry labels, webhook gates) but must NOT be the gate for shared
  cache writes or promotion — those require the verified token.

## References

- Paul Hammant, *"A Purpose in a Token"*, 2021-01-29 —
  https://paulhammant.com/2021/01/29/a-purpose-in-a-token/ — purpose/policy
  embedded legibly in the token, hierarchical, constrained at issuance.
  The origin of this doc's claim-is-the-token model.
- Laura Wingerd & Christopher Seiwald, *High-Level Best Practices in
  Software Configuration Management* (Perforce, 1998) — "branch only when
  necessary, on incompatible policy, late" — applied here to forking cache
  namespaces only along genuinely incompatible policy seams.
