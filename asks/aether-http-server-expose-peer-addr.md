# Aether `std/http` server: expose the TCP peer address to handlers (`http_request_remote_addr`)

> **STATUS: RESOLVED upstream in Aether v0.256.0** (CHANGELOG `## [0.256.0]`).
> Shipped `http.request_remote_addr(req) -> string` (trusted `getpeername`
> peer IP, distinct from spoofable X-Forwarded-For) — exactly this ask — PLUS a
> sibling batch: `request_remote_port`, `request_local_addr`, `request_local_port`,
> `request_scheme`, `request_is_tls`, `request_http_version` (the changelog cites
> "the aeb-agent ask's follow-up triage"). All populated in the dispatcher hot
> path, one extra `getsockname` per request, IPv4+IPv6 via `sockaddr_storage`.
> **Consumed:** aeb-agent now has `--allow-from <ip>[,...]` — an exact-IP source
> allow-list checked before auth, fail-closed, using `http_request_remote_addr`
> (the trusted peer addr). See `docs/aeb-agent-operating.md` § security posture.

**Upstream issue:** resolved in v0.256.0 (never needed a separate filing — the
Aether maintainers picked it up from triage).

**Filed by:** the `aeb-agent` work (this repo). aeb-agent is an auth-gated HTTP
build server; we wanted an **in-agent source-IP allow-list** (`--allow-from
<cidr>`) as defense-in-depth on top of lease/token auth, and found the handler
has no trustworthy way to learn the client's IP.
**Aether:** `github.com/aether-lang-org/aether`, source `std/net/aether_http_server.c`
(server impl) + `std/http/module.ae` (the externs surface).
**Severity:** feature gap, not a bug. Not blocking — bind-address + host firewall
+ auth already cover the threat model — but the data is *right there* and a
small plumbing change would unlock a clean in-app control.

## The gap

A request handler (`(req, res, ud)`) can read headers, method, path, query, and
body — but **not the real TCP peer address** of the connection. The externs in
`std/http/module.ae` are:

```
http_request_method/path/body/query, http_get_header/query_param/path_param,
http_request_header_count/name/value, …
```

…no `http_request_remote_addr` (or `_remote_ip` / `_peer`). The only client-IP
signal available to a handler is the **`X-Forwarded-For` header** (used by
`std/http/middleware`), which is **client-supplied and trivially spoofable** —
fine behind a trusted reverse proxy that overwrites it, but **not** a basis for
an access-control decision on a directly-exposed listener. So an app cannot
implement a trustworthy source-IP allow/deny list today.

## The data already exists — it's just dropped before the request object

The accept loop already captures the peer address; it simply isn't threaded into
the request. In `std/net/aether_http_server.c`:

```c
// ~line 3490
struct sockaddr_in client_addr;
socklen_t client_len = sizeof(client_addr);
int client_fd = accept(server->socket_fd, (struct sockaddr*)&client_addr, &client_len);   // 3492
...
handle_client_connection(server, client_fd);   // 3499/3501  — only the fd is passed
...
http_pool_submit(pool, client_fd);             // 3503        — only the fd is passed
```

(Same shape in the MSG_PEEK accept path around line 3304–3306.) `client_addr` is
populated by `accept()` and then discarded: the connection handlers receive only
`client_fd`, so by the time the `HttpRequest` is built the peer address is gone.
(As a fallback, `getpeername(client_fd, …)` recovers it from the fd even without
threading `client_addr` through.)

## What's wanted

Carry the accepted peer address into the request object and expose it via one
new extern, mirroring the existing accessors:

```
extern http_request_remote_addr(req: ptr) -> string   // e.g. "192.168.122.179"
```

returning the **socket** peer IP (the trustworthy one from `accept`/
`getpeername`), NOT an `X-Forwarded-For` interpretation. A companion
`http_request_remote_port(req) -> int` would be nice-to-have but the IP is the
load-bearing part.

Sketch of the change (C side):
- thread `client_addr` (or call `getpeername(client_fd, …)` lazily) into the
  per-connection state that builds `HttpRequest`;
- store the `inet_ntop`'d string on the request struct;
- add the `http_request_remote_addr` FFI returning it (empty string if
  unavailable — e.g. a Unix-domain socket).

Keep it IPv4+IPv6 (`sockaddr_storage` / `inet_ntop` over `AF_INET`/`AF_INET6`);
the current accept path uses `sockaddr_in`, so IPv6 may want widening — or the
extern can document IPv4-for-now.

## Why X-Forwarded-For isn't a substitute

It's set by the client. An attacker connecting directly sends
`X-Forwarded-For: <any-allowed-ip>` and a header-based allow-list waves them
through — a control that *looks* enforced but isn't. A real allow-list must read
the kernel's notion of the peer (the socket address), which only the server
process can obtain. That's precisely the value this extern would surface.

## What this unblocks (the consumer)

`aeb-agent --allow-from <cidr-list>`: reject a dispatch whose peer IP isn't in
the operator's allow-list, *before* auth — fail-closed, defense-in-depth under
lease auth. Today aeb-agent restricts source only via `--host` (bind to
loopback / one interface) plus an external firewall; an in-app CIDR allow-list
needs this extern. (See this repo's `docs/aeb-agent-operating.md` § security
posture, and `docs/run-policy-class-and-cloud-leverage.md`.)

Generally useful well beyond aeb: rate-limit keying on real IP, audit logging,
geo/abuse blocking, "admin endpoints from localhost only" — all need the socket
peer address, not a spoofable header.

## What is NOT being asked

- Not asking to change or trust `X-Forwarded-For` (that's the proxy middleware's
  job, and it's correctly separate).
- Not asking for TLS client-cert identity (a different, larger feature).
- Not asking aeb-side for anything — this is purely an Aether stdlib FFI surface
  addition; the `--allow-from` consumer is trivial once the accessor exists.
