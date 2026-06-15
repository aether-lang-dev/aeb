# `aeb-remote` `_lease_node` fails ("no leasable agent") though the agent /ping returns 200 to curl

**Filed by**: aeb Claude, 2026-06-15, validating ladder Rung 3 (the requester
token→image dispatch) against the live bazzite agent.
**Severity**: medium — blocks the *live* end-to-end proof of any
`aeb --use-remote-agents` dispatch from this host. Rung-3 image-derivation code
itself is implemented + unit-tested (commit `7ae2435`); this is the lease
TRANSPORT, orthogonal to the feature.

## Symptom

`aeb-remote <target>` (fresh build, has the Rung-3 `--prereqs`/`AEB_SELF` code)
against the live agent prints:

```
aeb --use-remote-agents: no leasable agent in pool (all busy/unreachable/unauthorized)
```

…and exits before ever reaching the dispatch (so the `prereq → image` line
never prints). `_lease_node` → `_ping_node` is returning 0 for the only pool
node.

## What rules OUT the obvious causes

Same host (this Chromebook, 192.168.0.187 = the agent's `--allow-from`), same
freshly-minted token, **direct curl to the same endpoint returns 200**:

```
curl -s -H "X-AEB-Token: $TOK" http://192.168.0.57:9440/ping
{"agent":"aeb-agent","platform":"linux","accept":"preint/*","busy":false,
 "max_jobs":1,"auth":"required","aeb_version":"…","aether_version":"…"}
# → HTTP 200
```

- **Not the IP gate**: curl from this host gets 200 (a blocked IP gets 403; we
  confirmed bazzite-localhost gets 403, this host does not).
- **Not auth**: the token verifies (200, not 401).
- **Not scope**: agent `accept:"preint/*"`; `_scope_glob_match("preint/*",
  "preint")` returns 1 by its own comment ("matches 'preint' and
  'preint/anything'"). Tested both `preint` and `preint/phammant/rust` tokens —
  both curl-ping 200.
- **Not busy**: `busy:false` in the live /ping JSON.
- **Not a stale binary**: `strings tools/aeb-remote` shows the Rung-3 `AEB_SELF`
  / `--prereqs` strings, so the fresh code is in there.

## Localization

The divergence is **curl GET /ping → 200** vs **`_ping_node`'s std.http client
GET /ping → treated as a miss**. So the failure is in the requester-side
`std.http.client` GET path (or how `_ping_node` reads its response), NOT the
agent and NOT auth/scope/IP. `lib/agent/_ping_node` (≈950) builds the request
with `client.request("GET", …)` + `set_header("X-AEB-Token", …)` then inspects
`response_status`/`_json_field`. Candidate causes:

1. `client.send_request` returning a non-empty `err` (→ `_ping_node` returns 0)
   for a GET-with-header that curl handles fine — a std.http client v2 quirk.
   zsync's LLM.md already flags std.http client fragility (no TLS-verify-skip,
   header/Range edge cases).
2. `response_status` not parsing 200 from this agent's response framing.
3. The header name/case or token not surviving the client's request build.

Next step: add a one-shot stderr trace in `_ping_node` (the `err` string + the
raw `code`) and run once against the live agent — that pins which of the three
it is in a single dispatch. (Kept out of the committed code; a debug build.)

## Impact / workaround

Rung-3 image derivation is proven by unit tests (`tests/test_prereq_image_map.ae`,
13 assertions) + code review of the dispatch wiring. The live green-light is
gated on this.

**Manual-curl proof DONE (2026-06-15):** a hand-rolled `curl -X POST …/dispatch`
carrying `"image":"aeb-tc:rust-1.75"` (bypassing `_lease_node`) was **accepted +
authenticated + acted on** by the live agent — HTTP 409 `prep-failed`, NOT an
image rejection. So **the agent honours the Rung-3 `image` field end to end**:
auth + `accept` scope + `--allow-image aeb-tc:*` gate + image-routing all pass.
The `prep-failed` is a SEPARATE agent-config issue (see below), not the image
path. This confirms the only gap to live-green is this `_ping_node` client bug.

## Second, independent blocker found: agent workdir has no `origin`

The live agent's `--workdir/--repo /home/bazzite/gms-rung1` is a git tree with
**no `origin` remote** (`error: No such remote 'origin'`), so it can't
`git fetch` the dispatched base commit → `prep-failed`. Fix is operator-side:
the agent's workdir must have an origin pointing at the gms repo (so
`patch`/`advance` provisioning can fetch the requested `ref@hash`). Orthogonal
to both the `_ping_node` bug and the Rung-3 feature; noted here so the live
proof setup is reproducible.

## Cross-ref

- `lib/agent/module.ae` `_ping_node` (≈950), `_lease_node` (≈982)
- `tools/aeb-remote.ae` (the Rung-3 requester)
- `docs/agent-container-ladder.md` (Rung 3 — this blocks its live proof)
- `../zsync` LLM.md (std.http client v2 fragility notes)
