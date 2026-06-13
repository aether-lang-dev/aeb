# Run policy class, cloud leverage, and job fan-out

Status: **design draft; walking skeleton landed.** This is the larger
write-up requested after the CI-duties discussion. A first running slice
exists — `aeb agent` (`tools/aeb-agent`) + `agent.dispatch` (`lib/agent`),
covering the sovereign-agent shape (accept/busy/reject → run → terse
verdict → fold into `any_failed`). What's implemented vs. still design:

- **Implemented (skeleton):** the standalone `aeb-agent` binary (a sysop
  capability probe, not an `aeb agent` subcommand), scope decision
  (accept/busy/reject), bare-host run, **`run_on=podman` run** (the dispatched
  build's compile delegates into a `--ctr-image` toolchain container via the
  aeb-ctr two-phase duality — proven on a host with no aetherc/gcc),
  **`run_on=vm` run** (rsync the prepared tree to an SSH-reachable VM, run
  `aeb <target>` there on the VM's own toolchain, rsync the artifacts JSON back;
  the VM target is an `~/.ssh/config` alias that owns key/ProxyJump, fail-closed
  without `--vm-host` — proven end-to-end), originator
  dispatch + verdict fold, the composable scope-tree data model,
  fail-back-on-busy/reject/unreachable, **agent OS self-report** (the auth-gated
  `/ping` reports `platform` — runs natively on Windows). Synchronous wire
  (HTTP), scope from CLI flags. **Naive `--tokens` auth**: a flat bearer-token
  file, fail-closed (no file → refuse all). This is the interim, shared-secret
  stand-in for the trust model below — it authenticates "you hold the secret,"
  nothing more.
- **Still design (this doc):** the real policy class + token/purpose trust
  model (claim→verify→veto, purpose-in-the-token, issuance constraint —
  the `--tokens` file is the naive placeholder for this), cache
  partitioning by embedded purpose, fire-async + webhook-back +
  `details_url` split, the VM-host **spawn/loan** layer (virsh start/clone —
  `run_on=vm` dispatches to an *already-reachable* VM; provisioning one on
  demand is still design), the `.ae` closure-DSL agent config (skeleton uses
  flags).

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

### The model: agent self-orchestrates; originator fires-and-reconciles

The key insight (and the correction to an earlier-draft over-flat
rejection): the control-plane concern only arises if the **originating
aeb supervises the remote runs**. It does not. The **agent owns the
orchestration of its own request** — accept / "busy, try again later" /
reject, run, lifecycle, results. The originator fires a request and is
done driving. There is no fleet scheduler in aeb because the supervising
lives on each agent, locally, where it belongs.

The proof that this is a peer relationship and not a control plane: **the
agent can say "busy, try again later" or "reject".** A thing that can
decline or defer is sovereign over its own queue — the opposite of a
worker a scheduler commands. aeb is a *requester of a sovereign peer*,
exactly as it is a requester of `gcc` or a one-shot `container.run` today.

So a fan-out target (e.g. `.local_then_repeat_on_mac_win_lin.ae`) is the
greppable, declarative *intent* to fan out; the run **context (env)**
confers *whether it may, where the agents are, and with what token*. The
target is the request; the context is the grant. `.all_tests_locally.ae`
never leaves the machine and raises none of this.

### Protocol (v1 decisions)

- **Topology from env, no middleman, no discovery service.** The
  originator gets the **full agent list from env vars** (e.g.
  `AEB_AGENT_MAC=host:port`, `AEB_AGENT_LINUX=...`). aeb fires directly at
  each; nothing brokers in between.
- **Agents self-report OS under authentication.** The env-var *label* is
  only a hint; the originator asks each agent its platform and the agent's
  **authenticated** answer is ground truth (same claim→verify spine: a
  hint is not a fact until the peer proves it). This is how the originator
  maps "which agent covered which platform."
- **Correlation = a GUID per request.** The originator **listens on a
  socket for the duration of the intention ONLY** — opened when the
  fan-out target starts, closed when it resolves. NOT a persistent daemon;
  aeb has no long-lived service. The GUID ties the fire, the terse
  callback, and the follow-up detail-pull together (and lets a
  re-fire-after-busy avoid double-counting).
- **Fire-async → terse webhook back → sync-pull details.** aeb fires a
  scant request (GUID + token + target + originator callback socket). The
  agent runs it and **webhooks back a terse outcome**. aeb then makes a
  **follow-up sync call** to pull the full structured detail. Reuses what
  exists: `lib/webhook` (the outbound-trigger SDK — aeb is already "the
  producer side of a webhook-centric system") for the fire and the
  agent's callback, and aeb's existing structured build data
  (`AEB_TELEMETRY_JSON` / `AEB_TESTS_JSON` / `AEB_ARTIFACTS_JSON`, per-node
  logs, rc marks) as what the detail-pull serves.
- **Skinny webhook payload (chosen — start minimal).** The terse callback
  carries only: `guid`, `status` ∈ {`accepted`,`busy`,`rejected`,`done`},
  `result` ∈ {`pass`,`fail`} (when `done`), and a `details_url` to sync-
  pull the rest. Everything heavier (the telemetry/tests/artifacts JSON,
  per-node logs, intermediate event stream) is behind the `details_url`,
  fetched only if/when the originator wants it. Grow the payload later
  only if a real need appears; do not front-load it.
- **Busy/backpressure: fail back to the user (v1).** A "busy" or an
  unreachable agent **fails the fan-out target back to the user** — no
  retry/backoff machinery yet. (Future: retry policy, or drop-that-
  platform-with-a-logged-skip per the no-silent-cap rule. v1 is the
  simple, honest behaviour: can't reach a declared agent → fail loud.)
- **Verdict folds into `any_failed`.** Each agent's `done/fail` (or a
  busy/reject/unreachable, per above) reddens the originator's build via
  the same `build.fail`/`any_failed` path the local nodes use.

### Still aeb's, still not aeb's

- aeb does **not** own triggers (the `on:` block — no daemon to watch a
  remote ref) or runner/OS provisioning or the matrix-as-a-thing-it-
  supervises. Those invoke aeb; they are not aeb's.
- aeb **does** own: firing the request, presenting the token, opening the
  duration-scoped correlation socket, consuming the terse callback,
  pulling+folding the detail. All inside the fan-out target's run.
- The agent (a separate daemon on oldnuc / macmini — NOT part of aeb the
  CLI) owns: authenticating the token + its own OS claim, accept/busy/
  reject, running aeb locally as the per-cell callee, holding its
  policy-class-partitioned cache, webhooking back, serving `details_url`.

The litmus test, refined: **does aeb *supervise* the remote run, or merely
*request* it and *reconcile* its reported verdict?** Supervising a fleet
(schedule/poll/aggregate) → control plane → rejected. Firing a request to
a sovereign agent and folding back its self-reported outcome → ordinary
client behaviour → fine. The agent's ability to refuse is what keeps aeb
on the right side of that line.

### The peer relationship is uniform and composable (an agent fans out / containerises *as it goes*)

A consequence worth stating outright, because it makes a whole class of
topologies fall out for free: **an agent handling a dispatch is just running
`aeb <target>` locally — so that run can itself fan out to other agents, or
spin up containers, exactly as a desktop `aeb` can.** There is nothing
special about being *inside* an agent. The same `aeb` that requests a
sovereign peer (another agent) or a one-shot `container.run` on a laptop does
so identically when it is itself the callee of a dispatch.

So:

- **Agent → other agents (transitive fan-out).** An agent's `aeb <target>`
  run can hit a fan-out target and lease+dispatch to *its own* peer pool — the
  same `_lease_node` + dispatch path the originator uses. The agent is **both
  a sovereign-peer-server and a requester of sovereign peers**; the
  relationship is recursive. Crucially this stays out of control-plane
  territory by the *same* litmus test applied at *each hop*: every callee can
  refuse, every caller only fires-and-reconciles. A chain of "request a
  sovereign peer, fold its verdict" is still a chain of client calls, not a
  scheduler — no hop supervises a fleet. (Loop/credit safety — bounding
  re-dispatch depth so a misconfig can't fan out unboundedly — is the one new
  concern, and it lives in the *token/grant* the dispatch carries, not in a
  central supervisor.)

- **Agent → containers (provision/isolate as it goes).** An agent's run can
  use `container.run` / `aeb-ctr` (the compile-in-container path already
  shipped) for a step whose toolchain the agent lacks or wants isolated — the
  same way a laptop build does. This is exactly the seam the
  [`build-prerequisites-and-provisioning.md`](build-prerequisites-and-provisioning.md)
  design plugs into: an `--allow-provision` agent that meets an unmet `prereq`
  layers the toolchain into a container *during its dispatch handling*, then
  runs the contained build. "Utilise containers as it goes" is not a new agent
  mode — it is the agent doing, mid-dispatch, what aeb already does with
  containers anywhere.

The unifying rule: **aeb is the same requester-of-sovereign-peers at every
node of the topology** (laptop, agent, agent-of-an-agent), and a container is
just one more sovereign peer it can request. The grid is not a hierarchy aeb
commands; it is a mesh of peers, each running aeb, each able to refuse, each
able to request others — and that uniformity is what lets fan-out and
containerisation compose to arbitrary depth without ever introducing a
control plane.

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

### Fan-out protocol — v1 decisions (settled)

7. ~~Correlation / idempotency.~~ **RESOLVED**: a GUID per request;
   originator listens on a socket for the **duration of the intention
   only** (not a persistent daemon).
8. ~~Backpressure semantics.~~ **RESOLVED (v1)**: "busy"/unreachable **fails
   back to the user** — no retry/backoff yet. (Future: retry, or
   drop-platform-with-logged-skip per no-silent-cap.)
9. ~~Terse-vs-detailed split.~~ **RESOLVED**: skinny webhook
   (`guid`, `status`, `result`, `details_url`); everything heavier behind
   the sync `details_url`. Grow only on real need.
10. ~~Topology / discovery.~~ **RESOLVED**: full agent list from env vars,
    no middleman; agents self-report OS under authentication (label is a
    hint, authenticated `platform()` is the fact).

### Fan-out — still open

11. Agent daemon protocol surface (the wire format of the fire request and
    the `details_url` response) — and whether it's literally HTTP +
    `lib/webhook` or a thinner socket protocol for the
    duration-scoped originator listener.
12. Authentication handshake specifics for the agent's OS self-report and
    the token presentation (ties to OQ3/OQ5 — the token mechanism).
13. The new dispatch primitive's DSL shape — e.g.
    `agent.dispatch(b) { endpoint(env "AEB_AGENT_MAC") token(...) target(".tests.ae") }`
    — fixed-arity setters, verdict folds into `any_failed`.
14. **Transitive-fan-out depth bounding.** Since an agent's run can itself
    re-dispatch (see "The peer relationship is uniform and composable"), a
    misconfigured or hostile chain could fan out unboundedly. The bound must
    travel in the *token/grant* the dispatch carries (a remaining-hops /
    fan-out-credit counter decremented per hop, refused at zero) — never a
    central supervisor, which would reintroduce the control plane. Settle the
    counter's shape and whether it's per-token or per-correlation.

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
