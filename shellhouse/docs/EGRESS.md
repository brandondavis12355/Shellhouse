# Egress control (L0, opt-in)

Default-deny HTTP(S) egress for sandboxes, plus canary decoys. **Off by default**: with `SANDBOX_EGRESS_MODE` unset (or `open`) nothing below changes. Status: unit-tested in pure Python (`egress-proxy/tests`); **never run against real Docker** (see "Unverified").

## How it works

- `egress-proxy/` is a stdlib-only asyncio proxy (HTTP CONNECT + plain HTTP), default deny.
- With `SANDBOX_EGRESS_MODE=allowlist` the manager creates each **new** sandbox on its own `internal=True` network (`agent-egress-<task>`, no route to the internet), attaches the proxy container to it (alias `egress-proxy`), and sets `HTTP(S)_PROXY`, `NO_PROXY` and `CHROMIUM_FLAGS` in the sandbox. Network creation failure aborts sandbox creation (fails closed, never falls back to open).
- The proxy resolves the name itself, rejects the request if **any** answer is private/loopback/link-local/metadata/CGNAT/NAT64/6to4/Teredo, then dials the validated IP literal (no second resolution, so no DNS-rebinding window). IP-literal hosts in any spelling (`127.1`, `0x7f.1`, decimal, `[::1]`), userinfo (`allowed.com@evil.com`), and ports other than 80/443 are denied.
- Allowlist file: exact hosts and `*.suffix` (any depth, **not** the apex; list `example.com` too if wanted; `*.com` is refused). Case, one trailing dot and IDN (to punycode) are normalised. Hot-reloaded on mtime/size change. Missing file = deny all.
- Denied-because-unlisted hosts go to `pending.json` (deduped, capped at 500; denied-by-operator hosts are muted). Every decision is a line in `egress.jsonl`: `ts, client, method, host, port, verdict, reason, canary`. Paths, queries, bodies and headers are never logged.

## Enable

1. `.env`: `EGRESS_ADMIN_TOKEN=$(openssl rand -hex 32)`, `SANDBOX_EGRESS_MODE=allowlist`, `EGRESS_VNC_FORWARD=6100-6131` and `EGRESS_VNC_ALLOW_CIDRS=<gateway of the compose default network>/32` (`docker network inspect <project>_default`) if you want noVNC (forwarding is off by default; if enabled without the CIDRs it logs an error and stays off).
2. Start the proxy, then seed its allowlist: `docker compose --profile egress up -d --build egress-proxy && docker cp egress-proxy/allowlist.example.txt agent-egress-proxy:/data/allowlist.txt`. Without a file everything is denied.
3. Recreate the manager so it sees the new env: `docker compose up -d sandbox-manager`.
4. **Existing sandboxes are not changed.** Recreate a bot's computer (Delete bot, or remove the container; the per-bot workspace volume survives) to move it onto the internal network. The legacy compose `agent-sandbox` ("spike") is not covered.

## Operate

Manager endpoints (same `X-Manager-Token` auth, audit-logged, `extra: forbid`):

- `POST /v1/egress/pending` `{}` -> `{pending:{host:{count,first_seen,last_seen,ports,client}}, denied, dropped, cap}`
- `POST /v1/egress/decide` `{"host":"pypi.org"|"*.pypi.org","decision":"allow"|"deny"}`. Allow appends to `allowlist.txt` (live within a request); deny mutes.

Direct proxy admin (token in `Authorization: Bearer`): `GET /v1/pending`, `GET /v1/log?n=100&canary=1`, `GET /v1/allowlist`, `POST /v1/allow|deny`, on port 3129. The proxy sits on every sandbox network, so the admin API is restricted by source: `EGRESS_ADMIN_ALLOW_CIDRS` (comma list) or, if unset, the subnet of the container's default-route interface (the compose network; auto-detection is unverified on real Docker, and if it fails the admin API stays off). It also has a connection cap (16) and throttles repeated bad tokens (5 failures/60s per client -> 429). Pending entries are rate-limited per client IP (20 new hosts/min) and record the client.

Containment checks: an existing sandbox is reused in allowlist mode only if it is attached solely to managed `internal` egress networks; otherwise creation is refused with an error (recreate it). An existing network of the expected name must be managed and `Internal`. A half-failed create removes its container and network. Handle metadata reports `egress: allowlist|open`. Connection fairness: per-client cap plus a fair-share rule once the pool is 75% full. `Expect: 100-continue` gets 417.

Settings (env on the proxy): `EGRESS_ALLOWED_PORTS` (80,443), `EGRESS_MAX_HEADER_BYTES` (16K), `EGRESS_MAX_BODY_BYTES` (10M), `EGRESS_MAX_RESPONSE_BYTES` (256M), `EGRESS_HEADER_TIMEOUT` (10s), `EGRESS_CONNECT_TIMEOUT` (10s), `EGRESS_IDLE_TIMEOUT` (60s), `EGRESS_TOTAL_TIMEOUT` (3600s), `EGRESS_MAX_CONN_PER_CLIENT` (32), `EGRESS_MAX_CONN_TOTAL` (256), `EGRESS_PENDING_CAP` (500), `EGRESS_CANARY_ACTION` (`deny` default, or `flag`).

## Resource limits

All new sandboxes get mem/cpu/pids limits (`SANDBOX_MEM_LIMIT` etc.). Persistent sandboxes keep using those same limits unless you **opt in** with `SANDBOX_PERSISTENT_LIMITS=1` (default off, so nothing changes for existing setups); they then use `SANDBOX_PERSISTENT_MEM_LIMIT` (4g), `_CPU_LIMIT` (4), `_PIDS_LIMIT` (1024), optional `_STORAGE_LIMIT` (e.g. `20G`; needs overlay2 on xfs with pquota, otherwise container creation fails, so it is off by default). `shm_size` stays 1g for Chromium.

## Canaries

`sandbox/bin/seed-canaries.sh` plants fake credentials with unique `SHELLHOUSE-CANARY-<hex>` tokens (mode 600) at `~/.aws/credentials`, `~/.ssh/id_ed25519`, `~/.config/gcloud/application_default_credentials.json`, `/workspace/.env.production`. Idempotent (never rewrites an existing canary). It never overwrites any other existing file (prints a warning and skips), never follows symlinks (file or parent directory), and creates files with noclobber. `CANARY_DRY_RUN=1` prints what it would create and changes nothing. The Swift policy engine owns the tripwire on those paths.

- It ships in the image via `COPY sandbox/bin/` (needs an image rebuild). Not wired into `start-desktop.sh`/`Dockerfile` (outside this change). Two ways to run it: set `SANDBOX_SEED_CANARIES=1` on the manager (it execs the script once after creating a new sandbox, after the `/workspace` symlink exists), or add `seed-canaries.sh` to `start-desktop.sh` after the seed-workspace step. Existing sandboxes: `docker exec -u box <name> seed-canaries.sh`.
- The proxy checks plain-HTTP request lines, headers and bodies (and the CONNECT host name) for the token, case-insensitive and URL-decoded, and by default **denies** and flags (`canary:true` in the log). **It cannot see inside TLS/CONNECT tunnels**: exfiltration over HTTPS to an allowlisted host is not detected by this. Base64/encoded tokens are also missed.

## Chromium

`CHROMIUM_FLAGS=--proxy-server=...` is set only in allowlist mode; unset otherwise. Chromium also reads `*_proxy`. Plain-HTTP WebSockets/`Upgrade` and chunked request bodies are not supported by the proxy (501/stripped).

## noVNC in allowlist mode

Docker cannot publish ports from internal networks. The proxy container publishes loopback `6100-6131` and forwards port N to the sandbox alias `sbx-N:6080`. It only accepts peers in `EGRESS_VNC_ALLOW_CIDRS` (required; otherwise it refuses to start), because it is on every sandbox network and would otherwise let one sandbox reach another's noVNC.

## Cannot see / does not do

TLS contents; DNS from the host; anything not going through the proxy if a process ignores proxy env (it simply fails, since the network is internal); non-HTTP protocols (SSH, git://, raw TCP are blocked, not proxied); host-level controls (the proxy and manager hosts keep their own egress). Approving a broad host (e.g. a paste or file-sharing site) re-opens exfiltration to it. Per-connection byte caps for tunnels are not implemented.

## Unverified without Docker

Internal-network behaviour and embedded DNS aliases; `network.connect` idempotency error text; disconnect/reconnect to add the `sbx-N` alias; published-port forwarding and the source address seen by the forwarder; Debian's chromium wrapper honouring `CHROMIUM_FLAGS`; `storage_opt` support; container restart keeping the proxy attached (manager re-attaches persistent sandboxes at reconcile). Test once on a Linux host with a throwaway task before relying on it.

## Model relay (smolagents pilot in allowlist mode)

Internal sandbox networks have no route to the Docker host, so the Mac-side model proxy (reached by a reverse SSH forward on the Linux host) is unreachable from them. The relay is a second listener on the egress-proxy container: raw TCP to ONE fixed target, nothing else.

Setup (all opt-in; unset = relay off):

1. **Linux host sshd** (`/etc/ssh/sshd_config`): `GatewayPorts clientspecified`, then reload sshd. Without it the `-R` bind address below is ignored and the forward binds to loopback only.
2. **Reverse forward from the Mac**, binding to the docker bridge gateway (`docker network inspect bridge` -> Gateway, typically `172.17.0.1`): `ssh -R 172.17.0.1:<port>:127.0.0.1:<model-proxy-port> user@linux-host`. In the Mac app this is the **Docker bridge address** field (the app builds the `-R`).
3. **`.env`**: `MODEL_RELAY_LISTEN=0.0.0.0:18434`, `MODEL_RELAY_TARGET=172.17.0.1:<port>` (the same address and port as the forward). Optional `MODEL_RELAY_ALLOW_CIDRS`. Then `docker compose --profile egress up -d egress-proxy`.
4. **Mac app**, "Address sandboxes use" (optional field): `egress-proxy:18434`, so sandboxes call `http://egress-proxy:18434/v1`. The sandbox `NO_PROXY` includes `egress-proxy`, so this goes direct to the relay and not through the allowlist.

Safeguards: the target is resolved once at startup and must be a private IPv4 (public, loopback, link-local/metadata, CGNAT, IPv6, multicast are rejected; on any error the relay stays off and logs why, the proxy still runs). Clients choose nothing: no protocol parsing, always the same target. Clients must be private addresses outside the compose default network (or inside `MODEL_RELAY_ALLOW_CIDRS` when set). Caps: 32 connections total, 8 per client, fair share above 75% full; 120s idle, 1800s total; 16 MB request and 64 MB response per connection (hit = connection dropped). Only connect/disconnect/refusal counts are logged, never payloads.

Residual risk: a compromised sandbox can send anything to the model proxy through the relay, so the model proxy must stay authenticated (per-run token, no admin routes). A sandbox can also reach the relay port of the proxy container on any sandbox network it shares. Unverified on real Docker: the `GatewayPorts` behaviour, the gateway address being reachable from the egress-proxy container, and CIDR default detection.

## Known gaps

- **SNI domain fronting / Host mismatch:** for CONNECT the proxy checks only the requested host name; it cannot see the TLS SNI or inner HTTP Host. An allowlisted CDN that routes by SNI/Host can be used to reach other tenants.
- **Allowlisting multi-tenant hosts permits exfiltration:** `github.com`, `*.github.io`, `*.githubusercontent.com`, `*.amazonaws.com` and similar let an attacker-controlled tenant receive data. Prefer exact hosts; review approvals of shared platforms.
- **DNS tunnelling:** sandboxes sit on internal networks but still use Docker's embedded resolver, which may forward queries upstream. Whether that leaks data (e.g. `<data>.attacker.com` lookups) is **UNVERIFIED** and must be tested on a real host before trusting this control.
- **Model proxy access needs the model relay** (next section). The egress proxy itself refuses private addresses by design, so allowlisting the gateway cannot work and must not be made to work by relaxing the IP block.
- No tunnel byte caps; no WebSocket upgrade or chunked request bodies; TLS contents invisible (canaries only work on plain HTTP).

## Tests

`cd egress-proxy && python -m pytest tests` (needs pytest; manager tests also need fastapi, httpx, docker from `sandbox-manager/requirements.txt`). AI-assisted (Claude); review before circulating.
