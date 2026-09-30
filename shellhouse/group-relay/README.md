# Group relay

The small shared service that lets **friends' Shellhouse apps** share a group
chat with you. Phase 1 of the friends system: the server only — the app-side
client, UI and planner changes come in later phases.

It stores identities (public keys), friendships, group membership and the
shared message log. It does **not** hold bot memory, prompts, sandboxes, API
keys or anything from your Mac or the sandbox host, and it has no Docker
access. Your bots keep running only on your machine; the owner's app mirrors
their replies here.

## Run it (off by default)

```bash
cd group-relay && ./gen-cert.sh <host-or-ip-friends-connect-to>   # self-signed TLS cert + fingerprint
# in .env:  RELAY_BIND=<host address on the shared network>   RELAY_REGISTRATION_TOKEN=$(openssl rand -hex 16)
docker compose --profile relay up -d --build group-relay
```

- `RELAY_BIND` defaults to `127.0.0.1` (unreachable by friends). Set it to the
  host's address on the **shared network/VPN** only. Do not port-forward it to
  the internet.
- It refuses to start without a certificate unless `RELAY_ALLOW_PLAINTEXT=1`.
- `RELAY_REGISTRATION_TOKEN` (optional but recommended): people must present it
  to create an identity, so only those you hand it to can register.
- Give friends the certificate **fingerprint** out of band; the app pins it.
- Container: non-root uid 10001, read-only root filesystem, all capabilities
  dropped, no-new-privileges, 256 MB / 128 pids. Data lives in the
  `relay_data` volume (`/data/relay.db`).

## Authentication

There are no passwords or bearer tokens. A user is an **Ed25519 key pair**; the
user id is derived from the public key (`"u_" + sha256(pubkey)[:32]`) so it
can't be squatted. Every request carries:

| header | meaning |
|---|---|
| `X-User-Id` | the caller's id |
| `X-Timestamp` | unix seconds; rejected if more than 120 s off |
| `X-Nonce` | random 8–64 chars `[A-Za-z0-9_-]`, unique per request (replays rejected) |
| `X-Signature` | base64 Ed25519 signature of the string below |

```
METHOD \n PATH[?QUERY] \n TIMESTAMP \n NONCE \n sha256_hex(BODY)
```

`POST /v1/register` is signed with the key being registered (proof of
possession) and, if configured, carries `X-Registration-Token`.
Clients: CryptoKit `Curve25519.Signing` produces compatible raw 32-byte keys
and 64-byte signatures.

## API

| | |
|---|---|
| `POST /v1/register` `{user_id, display_name, public_key}` | create / rename identity |
| `GET /v1/me` | who am I |
| `POST /v1/invites` | one-time invite code (24 h, max 10 active) |
| `POST /v1/invites/redeem` `{code}` | send a friend request to the issuer |
| `GET /v1/friends` | `{friends, incoming, outgoing}` |
| `POST /v1/friends/{id}/accept` · `/decline` · `DELETE /v1/friends/{id}` | manage friendship (removing a friend also removes them from your groups) |
| `POST /v1/blocks/{id}` | block (also removes friendship + memberships) |
| `POST /v1/groups` `{name}` · `GET /v1/groups` · `GET /v1/groups/{id}` · `DELETE /v1/groups/{id}` | groups (owner = creator) |
| `POST /v1/groups/{id}/members` `{user_id}` | owner adds an accepted friend (max 20 people) |
| `DELETE /v1/groups/{id}/members/{uid}` | owner removes anyone; a member removes themselves |
| `POST /v1/groups/{id}/messages` `{text, kind, speaker_name?, client_msg_id?}` | post |
| `GET /v1/groups/{id}/messages?after=<seq>&limit=100&wait=25` | read / long-poll |

Message rules: members post `kind:"human"` only, and the **server** sets the
speaker from the authenticated identity (no spoofing). Only the group owner may
post `bot` or `system` messages (the owner's app mirrors its bots' replies).
Text ≤ 8000 chars, control characters stripped, `client_msg_id` makes retries
idempotent.

## Limits

Body 64 KB · 240 requests/min/user · 30 messages/min/user · 10 registrations/min/IP
· 20 humans/group · 50 groups/owner · 200 friends. All configurable with
`RELAY_*` env vars (see `app/`).

## Threat model (short)

- **Forgery/replay:** signatures + timestamp window + nonce table.
- **Impersonation:** user ids bound to keys; bot/system posts owner-only.
- **Enumeration:** invalid/expired/used invite codes and non-member group
  lookups return identical errors; invite codes are stored hashed.
- **Abuse:** per-user and per-IP rate limits, size caps, friend/group limits,
  blocking.
- **Not covered:** a malicious *friend* can still send hostile text — clients
  and bots must treat every message as untrusted input (phase 4 enforces
  approvals for that). Metadata (who is in which group, when) is visible to
  whoever runs the relay. Self-signed TLS relies on fingerprint pinning.

## Tests

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt httpx pytest
.venv/bin/python -m pytest tests
```
