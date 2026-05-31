# aeb-agent container

A Debian container that builds the whole stack from scratch — Aether
toolchain → aeb → the remote build agent — and runs `aeb-agent` on 9440,
reachable off-box and fail-closed.

This is also the soup-to-nuts reference for "aeb on a clean Debian box":
the `Containerfile` is the documented, runnable bootstrap.

## Build + run

```sh
# 1. a token file (one bearer token per line)
printf 'ping-secret-123\n' > agent.tokens

# 2. build the image
podman build -t aeb-agent itests/agent-container

# 3. run it — publish 9440, mount the tokens
podman run -d --name aeb-agent -p 9440:9440 \
    -v "$PWD/agent.tokens:/etc/aeb/agent.tokens:ro" \
    aeb-agent
```

Pin toolchains for reproducibility:

```sh
podman build --build-arg AEB_REF=v0.042 --build-arg AETHER_REF=v0.203.0 \
    -t aeb-agent itests/agent-container
```

## Ping it from another host

```sh
HOST=<podman-host-ip>     # the host running podman, NOT the container's internal IP
curl http://$HOST:9440/health                                   # -> ok   (unauthenticated reachability)
curl -H 'X-AEB-Token: ping-secret-123' http://$HOST:9440/ping   # -> capability JSON (authenticated)
curl -w ' [%{http_code}]' http://$HOST:9440/ping                # -> {"error":"unauthorized"} [401]  (fail-closed)
```

## Gotchas (the two that bite every time)

1. **Publish the port.** `-p 9440:9440` must be at `podman run` time —
   it can't be added to a running container (recreate, or bridge with
   `socat`). Without it, the host refuses :9440 even though the agent is
   up inside.
2. **Bind 0.0.0.0.** The `CMD` already passes `--host 0.0.0.0`; if you
   override the command, keep it — the agent's default is loopback, which
   a published port can't reach.

`connection refused` on :9440 from outside = one of those two. `/health`
working but `/ping` 401 = working agent, you just need the token.

## What the build proves

- aeb's soup-to-nuts bootstrap on a clean Debian (gcc 14 / trixie — the
  strict-gcc target).
- The dogfood install: `aeb tools/agent/.install.ae` builds the agent
  *with aeb* (`.install` deps `.dist`) and places binary + wrapper.
