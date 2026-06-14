# Aether actors need a synchronous `call` (ask/reply), like `gen_server:call`

**Upstream issue:** https://github.com/aether-lang-org/aether/issues/736 (filed 2026-06-14)

**Provenance:** building aeb-agent's capacity-aware build-slot gate (one build at a
time per slot, `503 busy` when full). The idiomatic solution is an actor that
OWNS the slot state and which handlers ask to claim/release — but Aether actors
have **no synchronous reply**: `std.actors` is a name registry, message send is
fire-and-forget `!`, and there is no `call` that blocks the caller until the
actor replies. So a handler can't get a "busy vs claimed" answer back.

**Consequence for aeb-agent:** we ship a **filesystem lock** (atomic `mkdir`,
cleared at startup) for the build-slot gate now — robust (crash-safe via
startup-cleanup) but the "we don't have OTP" answer. Once Aether has `call`, the
slot can move to an actor-owned in-memory counter (the idiomatic way), and the
lockdir becomes optional.

**What's wanted:** `actor_call(ref, msg) -> reply` — send + block until a receive
arm replies, with a timeout (cf. OTP `gen_server:call/2,3`). Follow-ups that make
it fully OTP-shaped: caller-death monitors (auto-release on claimant death) and
supervision (crashed state-owner restarts clean). The synchronous `call` is the
load-bearing piece.

See [[run-on-vm-green]]/[[agent-lease-auth]] for the agent work this supports;
the http_request_remote_addr accessor (asks/aether-http-server-expose-peer-addr,
shipped v0.256) is the precedent for an aeb-triage ask landing upstream.
