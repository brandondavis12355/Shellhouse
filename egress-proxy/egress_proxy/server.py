"""Allowlist egress proxy: HTTP CONNECT + plain HTTP forwarding, default deny.

stdlib only. One request per connection (Connection: close) so there is no
pipelining/smuggling surface. See docs/EGRESS.md.
"""
from __future__ import annotations

import asyncio
import hmac
import ipaddress
import json
import logging
import os
import socket
import time
from dataclasses import dataclass, field
from typing import Callable, Optional
from urllib.parse import unquote, parse_qs, urlsplit

from .netinfo import detect_default_subnet
from .policy import AllowlistFile, is_blocked_ip, normalize_host, parse_authority
from .store import DecisionLog, PendingStore

log = logging.getLogger("egress-proxy")

CANARY_MARKER = b"shellhouse-canary-"   # compared case-insensitively
HOP_BY_HOP = {
    "connection", "proxy-connection", "proxy-authorization", "keep-alive", "te",
    "trailer", "upgrade", "transfer-encoding", "host", "proxy-authenticate",
}


def _env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


def _env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


@dataclass
class Config:
    allowlist_file: str = "/data/allowlist.txt"
    log_file: str = "/data/egress.jsonl"
    pending_file: str = "/data/pending.json"
    listen_host: str = "0.0.0.0"
    listen_port: int = 3128
    admin_host: str = "0.0.0.0"
    admin_port: int = 3129
    admin_token: str = ""
    admin_allow_cidrs: tuple = ()
    allowed_ports: frozenset = frozenset({80, 443})
    max_header_bytes: int = 16 * 1024
    max_headers: int = 100
    max_body_bytes: int = 10 * 1024 * 1024
    max_response_bytes: int = 256 * 1024 * 1024
    header_timeout: float = 10.0
    connect_timeout: float = 10.0
    idle_timeout: float = 60.0
    total_timeout: float = 3600.0
    max_conn_per_client: int = 32
    max_conn_total: int = 256
    canary_action: str = "deny"          # "deny" | "flag"
    pending_cap: int = 500
    pending_rate_per_min: int = 20
    admin_max_conn: int = 16
    admin_fail_limit: int = 5
    admin_fail_window: float = 60.0

    @classmethod
    def from_env(cls) -> "Config":
        e = os.environ.get
        cidrs = tuple(c.strip() for c in e("EGRESS_ADMIN_ALLOW_CIDRS", "").split(",") if c.strip())
        ports = frozenset(int(p) for p in e("EGRESS_ALLOWED_PORTS", "80,443").split(",") if p.strip().isdigit())
        return cls(
            allowlist_file=e("EGRESS_ALLOWLIST_FILE", cls.allowlist_file),
            log_file=e("EGRESS_LOG_FILE", cls.log_file),
            pending_file=e("EGRESS_PENDING_FILE", cls.pending_file),
            listen_host=e("EGRESS_LISTEN_HOST", cls.listen_host),
            listen_port=_env_int("EGRESS_LISTEN_PORT", 3128),
            admin_host=e("EGRESS_ADMIN_HOST", cls.admin_host),
            admin_port=_env_int("EGRESS_ADMIN_PORT", 3129),
            admin_token=e("EGRESS_ADMIN_TOKEN", ""),
            admin_allow_cidrs=cidrs,
            allowed_ports=ports or frozenset({80, 443}),
            max_header_bytes=_env_int("EGRESS_MAX_HEADER_BYTES", 16 * 1024),
            max_body_bytes=_env_int("EGRESS_MAX_BODY_BYTES", 10 * 1024 * 1024),
            max_response_bytes=_env_int("EGRESS_MAX_RESPONSE_BYTES", 256 * 1024 * 1024),
            header_timeout=_env_float("EGRESS_HEADER_TIMEOUT", 10),
            connect_timeout=_env_float("EGRESS_CONNECT_TIMEOUT", 10),
            idle_timeout=_env_float("EGRESS_IDLE_TIMEOUT", 60),
            total_timeout=_env_float("EGRESS_TOTAL_TIMEOUT", 3600),
            max_conn_per_client=_env_int("EGRESS_MAX_CONN_PER_CLIENT", 32),
            max_conn_total=_env_int("EGRESS_MAX_CONN_TOTAL", 256),
            canary_action="flag" if e("EGRESS_CANARY_ACTION", "deny").lower() == "flag" else "deny",
            pending_cap=_env_int("EGRESS_PENDING_CAP", 500),
            pending_rate_per_min=_env_int("EGRESS_PENDING_RATE_PER_MIN", 20),
        )


class BadRequest(Exception):
    def __init__(self, status: int, reason: str):
        super().__init__(reason)
        self.status = status
        self.reason = reason


_STATUS = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
           404: "Not Found", 408: "Request Timeout", 411: "Length Required",
           413: "Payload Too Large", 417: "Expectation Failed", 429: "Too Many Requests",
           431: "Request Header Fields Too Large", 501: "Not Implemented",
           502: "Bad Gateway", 504: "Gateway Timeout"}


async def read_head(reader: asyncio.StreamReader, cfg: Config):
    """Read and parse a request head. Returns (method, target, version, headers[list of (name,value)])."""
    try:
        raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), cfg.header_timeout)
    except asyncio.TimeoutError:
        raise BadRequest(408, "header_timeout")
    except asyncio.LimitOverrunError:
        raise BadRequest(431, "header_too_large")
    except asyncio.IncompleteReadError:
        raise BadRequest(400, "incomplete_head")
    if len(raw) > cfg.max_header_bytes:
        raise BadRequest(431, "header_too_large")
    try:
        text = raw[:-4].decode("latin-1")
    except Exception:
        raise BadRequest(400, "bad_encoding")
    lines = text.split("\r\n")
    if any(("\n" in l or "\r" in l or "\x00" in l) for l in lines):
        raise BadRequest(400, "bad_line_ending")
    parts = lines[0].split(" ")
    if len(parts) != 3 or not parts[0].isalpha() or not parts[2].startswith("HTTP/1."):
        raise BadRequest(400, "bad_request_line")
    method, target, version = parts
    if not target or any(ord(c) < 33 or ord(c) == 127 for c in target):
        raise BadRequest(400, "bad_target")
    headers = []
    for l in lines[1:]:
        if len(headers) >= cfg.max_headers:
            raise BadRequest(431, "too_many_headers")
        if l[:1] in (" ", "\t"):
            raise BadRequest(400, "obs_fold")
        name, sep, value = l.partition(":")
        if not sep or not name or name != name.strip() or " " in name:
            raise BadRequest(400, "bad_header")
        headers.append((name, value.strip()))
    return method.upper(), target, version, headers


def _contains_canary(*chunks: bytes) -> bool:
    for c in chunks:
        if not c:
            continue
        low = c.lower()
        if CANARY_MARKER in low:
            return True
        try:
            if CANARY_MARKER in unquote(c.decode("latin-1")).lower().encode("latin-1", "ignore"):
                return True
        except Exception:
            pass
    return False


async def _default_resolver(host: str, port: int) -> list:
    loop = asyncio.get_running_loop()
    infos = await loop.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    seen, out = set(), []
    for fam, _t, _p, _c, sa in infos:
        ip = sa[0]
        if ip not in seen:
            seen.add(ip)
            out.append(ip)
    return out


async def _default_connector(ip: str, port: int, timeout: float):
    return await asyncio.wait_for(asyncio.open_connection(ip, port), timeout)


@dataclass
class Decision:
    verdict: str            # "allow" | "deny" | "error"
    reason: str
    ips: list = field(default_factory=list)


class EgressProxy:
    def __init__(self, cfg: Config, resolver: Optional[Callable] = None,
                 connector: Optional[Callable] = None):
        self.cfg = cfg
        self.allow = AllowlistFile(cfg.allowlist_file)
        self.log = DecisionLog(cfg.log_file)
        self.pending = PendingStore(cfg.pending_file, cap=cfg.pending_cap,
                                    rate_per_min=cfg.pending_rate_per_min)
        self.resolver = resolver or _default_resolver
        self.connector = connector or _default_connector
        self._per_client: dict = {}
        self._total = 0

    # -- policy ---------------------------------------------------------

    async def decide(self, host: str, port: int, client: str, method: str,
                     canary: bool = False) -> Decision:
        def out(verdict, reason, ips=None):
            self.log.write(client=client, method=method, host=host, port=port,
                           verdict=verdict, reason=reason, canary=canary)
            return Decision(verdict, reason, ips or [])

        if canary and self.cfg.canary_action == "deny":
            return out("deny", "canary_token_in_request")
        if port not in self.cfg.allowed_ports:
            return out("deny", "port_not_allowed")
        if not self.allow.current().matches(host):
            self.pending.record(host, port, client)
            return out("deny", "not_allowlisted")
        try:
            ips = await asyncio.wait_for(self.resolver(host, port), self.cfg.connect_timeout)
        except Exception:
            return out("error", "dns_failure")
        if not ips:
            return out("error", "dns_failure")
        # Any private/metadata answer poisons the whole name (rebinding).
        if any(is_blocked_ip(ip) for ip in ips):
            return out("deny", "resolved_private_address")
        return out("allow", "allowlisted", ips)

    async def _open_upstream(self, ips: list, port: int):
        last = None
        for ip in ips[:4]:
            # Re-check immediately before connecting: we dial the literal
            # address we validated, never the name (no second resolution).
            if is_blocked_ip(ip):
                continue
            try:
                return await self.connector(ip, port, self.cfg.connect_timeout)
            except (OSError, asyncio.TimeoutError) as exc:
                last = exc
        raise ConnectionError(str(last) if last else "no_usable_address")

    # -- connection handling -------------------------------------------

    @staticmethod
    async def _respond(writer, status: int, reason: str = "", body: str = ""):
        body_b = (body or reason).encode()
        head = (f"HTTP/1.1 {status} {_STATUS.get(status, 'Error')}\r\n"
                f"Content-Type: text/plain\r\nContent-Length: {len(body_b)}\r\n"
                f"X-Egress-Reason: {reason}\r\nConnection: close\r\n\r\n").encode()
        try:
            writer.write(head + body_b)
            await writer.drain()
        except Exception:
            pass

    async def handle_client(self, reader, writer):
        peer = writer.get_extra_info("peername") or ("?", 0)
        client = str(peer[0])
        refused = self._admit_check(client)
        if refused:
            self.log.write(client=client, method="-", host="-", port=None,
                           verdict="deny", reason=refused)
            await self._respond(writer, 429, "connection_limit")
            self._close(writer)
            return
        self._total += 1
        self._per_client[client] = self._per_client.get(client, 0) + 1
        try:
            await asyncio.wait_for(self._serve(reader, writer, client), self.cfg.total_timeout)
        except asyncio.TimeoutError:
            pass
        except Exception:   # never crash the server on one connection
            log.exception("connection error")
        finally:
            self._total -= 1
            n = self._per_client.get(client, 1) - 1
            if n <= 0:
                self._per_client.pop(client, None)
            else:
                self._per_client[client] = n
            self._close(writer)

    def _admit_check(self, client: str) -> Optional[str]:
        """None if the connection may proceed, else the refusal reason.
        Fair share: once the pool is 75% full, a client already holding at
        least an equal share (cap / (active clients + 1)) is refused, so one
        noisy sandbox cannot starve the others."""
        cap = self.cfg.max_conn_total
        mine = self._per_client.get(client, 0)
        if self._total >= cap or mine >= self.cfg.max_conn_per_client:
            return "connection_limit"
        if self._total >= cap * 0.75:
            active = len(self._per_client) + (0 if client in self._per_client else 1)
            if mine >= max(1, cap // (active + 1)):
                return "fair_share_limit"
        return None

    @staticmethod
    def _close(writer):
        try:
            writer.close()
        except Exception:
            pass

    async def _serve(self, reader, writer, client: str):
        try:
            method, target, _ver, headers = await read_head(reader, self.cfg)
            if method == "CONNECT":
                await self._connect(reader, writer, client, target, headers)
            else:
                await self._forward(reader, writer, client, method, target, headers)
        except BadRequest as exc:
            self.log.write(client=client, method="-", host="-", port=None,
                           verdict="deny", reason=f"bad_request:{exc.reason}")
            await self._respond(writer, exc.status, exc.reason)

    async def _connect(self, reader, writer, client, target, headers):
        host, port, why = parse_authority(target, None)
        canary = _contains_canary(target.encode("latin-1", "ignore"))
        if host is None:
            self.log.write(client=client, method="CONNECT", host=target.rsplit("@", 1)[-1][:100], port=None,
                           verdict="deny", reason=why, canary=canary)
            return await self._respond(writer, 403, why)
        d = await self.decide(host, port, client, "CONNECT", canary=canary)
        if d.verdict != "allow":
            return await self._respond(writer, 403 if d.verdict == "deny" else 502, d.reason)
        try:
            ur, uw = await self._open_upstream(d.ips, port)
        except ConnectionError:
            return await self._respond(writer, 502, "upstream_connect_failed")
        try:
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()
            await asyncio.gather(
                self._pump(reader, uw), self._pump(ur, writer), return_exceptions=True)
        finally:
            self._close(uw)

    async def _pump(self, src, dst):
        try:
            while True:
                data = await asyncio.wait_for(src.read(65536), self.cfg.idle_timeout)
                if not data:
                    break
                dst.write(data)
                await dst.drain()
        except Exception:
            pass
        finally:
            try:
                if dst.can_write_eof():
                    dst.write_eof()
            except Exception:
                pass

    async def _forward(self, reader, writer, client, method, target, headers):
        if not target.lower().startswith("http://"):
            self.log.write(client=client, method=method, host="-", port=None,
                           verdict="deny", reason="not_absolute_http_uri")
            return await self._respond(writer, 400, "absolute http:// URI required")
        rest = target[7:]
        cut = len(rest)
        for ch in "/?#":
            i = rest.find(ch)
            if i != -1:
                cut = min(cut, i)
        authority, path = rest[:cut], rest[cut:]
        if not path.startswith("/"):
            path = "/" + path
        path = path.split("#", 1)[0]
        host, port, why = parse_authority(authority, 80)
        raw_head = (target + "\n" + "\n".join(f"{k}: {v}" for k, v in headers)).encode("latin-1", "ignore")

        names = [k.lower() for k, _ in headers]
        if any(k.lower() == "expect" and v.lower() == "100-continue" for k, v in headers):
            return await self._respond(writer, 417, "expect_100_continue_unsupported")
        te = [v for k, v in headers if k.lower() == "transfer-encoding"]
        cls_ = {v for k, v in headers if k.lower() == "content-length"}
        if te:
            return await self._respond(writer, 501, "chunked_request_bodies_unsupported")
        if len(cls_) > 1 or names.count("content-length") > 1:
            return await self._respond(writer, 400, "conflicting_content_length")
        length = 0
        if cls_:
            v = next(iter(cls_))
            if not v.isascii() or not v.isdigit() or len(v) > 12:
                return await self._respond(writer, 400, "bad_content_length")
            length = int(v)
            if length > self.cfg.max_body_bytes:
                self.log.write(client=client, method=method, host=host or "-", port=port,
                               verdict="deny", reason="body_too_large")
                return await self._respond(writer, 413, "body_too_large")
        body = b""
        if length:
            try:
                body = await asyncio.wait_for(reader.readexactly(length), self.cfg.idle_timeout)
            except (asyncio.TimeoutError, asyncio.IncompleteReadError):
                return await self._respond(writer, 400, "body_incomplete")

        canary = _contains_canary(raw_head, body)
        if host is None:
            self.log.write(client=client, method=method, host=authority.rsplit("@", 1)[-1][:100], port=None,
                           verdict="deny", reason=why, canary=canary)
            return await self._respond(writer, 403, why)
        d = await self.decide(host, port, client, method, canary=canary)
        if d.verdict != "allow":
            return await self._respond(writer, 403 if d.verdict == "deny" else 502, d.reason)
        try:
            ur, uw = await self._open_upstream(d.ips, port)
        except ConnectionError:
            return await self._respond(writer, 502, "upstream_connect_failed")
        try:
            host_hdr = host if port == 80 else f"{host}:{port}"
            out = [f"{method} {path} HTTP/1.1", f"Host: {host_hdr}", "Connection: close"]
            out += [f"{k}: {v}" for k, v in headers if k.lower() not in HOP_BY_HOP]
            uw.write(("\r\n".join(out) + "\r\n\r\n").encode("latin-1", "ignore") + body)
            await uw.drain()
            sent = 0
            while True:
                chunk = await asyncio.wait_for(ur.read(65536), self.cfg.idle_timeout)
                if not chunk:
                    break
                sent += len(chunk)
                if sent > self.cfg.max_response_bytes:
                    break
                writer.write(chunk)
                await writer.drain()
        except (asyncio.TimeoutError, OSError):
            pass
        finally:
            self._close(uw)

    # -- servers --------------------------------------------------------

    async def start(self):
        servers = [await asyncio.start_server(
            self.handle_client, self.cfg.listen_host, self.cfg.listen_port,
            limit=self.cfg.max_header_bytes)]
        if self.cfg.admin_token:
            if not self.cfg.admin_allow_cidrs:
                # Sandboxes share this container's networks; only the compose
                # network (the one with the default route) may use the admin API.
                subnet = detect_default_subnet()
                if subnet:
                    self.cfg.admin_allow_cidrs = (subnet,)
                    log.info("admin API restricted to %s", subnet)
            if not self.cfg.admin_allow_cidrs:
                log.error("Admin API disabled: could not detect the compose subnet; "
                          "set EGRESS_ADMIN_ALLOW_CIDRS")
            else:
                admin = AdminApi(self)
                servers.append(await asyncio.start_server(
                    admin.handle, self.cfg.admin_host, self.cfg.admin_port, limit=64 * 1024))
        else:
            log.warning("EGRESS_ADMIN_TOKEN unset: admin interface disabled")
        spec = os.environ.get("EGRESS_VNC_FORWARD", "")
        if spec:
            from .vnc_forward import start_forwarders
            try:
                servers += await start_forwarders(spec, os.environ.get("EGRESS_VNC_ALLOW_CIDRS", ""))
            except ValueError as exc:
                log.error("noVNC forwarding disabled: %s", exc)
        relay_listen, relay_target = os.environ.get("MODEL_RELAY_LISTEN", ""), os.environ.get("MODEL_RELAY_TARGET", "")
        if relay_listen and relay_target:
            from .relay import start_relay
            srv = await start_relay(relay_listen, relay_target, os.environ.get("MODEL_RELAY_ALLOW_CIDRS", ""))
            if srv is not None:
                servers.append(srv)
        return servers


class AdminApi:
    """Token-authenticated JSON-over-HTTP. GET /v1/pending, GET /v1/log,
    GET /v1/allowlist, POST /v1/allow, POST /v1/deny, GET /healthz."""

    MAX_BODY = 4096

    def __init__(self, proxy: EgressProxy):
        self.proxy = proxy
        self._fails: dict = {}      # client ip -> (count, window_start)
        self._conns = 0

    def route(self, method: str, target: str, auth: str, body: bytes, client_ip: str = "",
              now: Optional[float] = None) -> tuple:
        """Pure request -> (status, json-able). Unit-testable."""
        cfg = self.proxy.cfg
        now = time.monotonic() if now is None else now
        sp = urlsplit(target)
        path = sp.path
        if path == "/healthz" and method == "GET":
            return 200, {"ok": True}
        if cfg.admin_allow_cidrs:
            try:
                ip = ipaddress.ip_address(client_ip)
                if not any(ip in ipaddress.ip_network(c, strict=False) for c in cfg.admin_allow_cidrs):
                    return 403, {"error": "client_not_allowed"}
            except ValueError:
                return 403, {"error": "client_not_allowed"}
        count, start = self._fails.get(client_ip, (0, now))
        if now - start > cfg.admin_fail_window:
            count, start = 0, now
        if count >= cfg.admin_fail_limit:
            return 429, {"error": "too_many_failures"}
        token = auth[7:] if auth.lower().startswith("bearer ") else ""
        if not cfg.admin_token or not token or not hmac.compare_digest(
                token.encode("utf-8", "ignore"), cfg.admin_token.encode("utf-8")):
            if len(self._fails) > 1000:
                self._fails.clear()
            self._fails[client_ip] = (count + 1, start)
            return 401, {"error": "unauthorized"}
        self._fails.pop(client_ip, None)
        q = parse_qs(sp.query)
        if method == "GET" and path == "/v1/pending":
            return 200, self.proxy.pending.snapshot()
        if method == "GET" and path == "/v1/log":
            try:
                n = int(q.get("n", ["100"])[0])
            except ValueError:
                n = 100
            canary = q.get("canary", ["0"])[0] in ("1", "true")
            return 200, {"entries": self.proxy.log.tail(n, canary_only=canary)}
        if method == "GET" and path == "/v1/allowlist":
            al = self.proxy.allow.current()
            return 200, {"exact": sorted(al.exact), "wildcards": ["*." + s for s in al.suffixes]}
        if method == "POST" and path in ("/v1/allow", "/v1/deny"):
            try:
                data = json.loads(body or b"{}")
            except ValueError:
                return 400, {"error": "bad_json"}
            if not isinstance(data, dict) or set(data) - {"host"} or not isinstance(data.get("host"), str):
                return 400, {"error": "expected {\"host\": str}"}
            raw = data["host"]
            if path == "/v1/allow":
                try:
                    entry = self.proxy.allow.add(raw)
                except ValueError:
                    return 400, {"error": "invalid_host"}
                al = self.proxy.allow.current()
                for h in list(self.proxy.pending.snapshot()["pending"]):
                    if al.matches(h):
                        self.proxy.pending.resolve(h, deny=False)
                return 200, {"ok": True, "entry": entry}
            host, why = normalize_host(raw)
            if host is None:
                return 400, {"error": "invalid_host"}
            self.proxy.pending.resolve(host, deny=True)
            return 200, {"ok": True, "host": host}
        return 404, {"error": "not_found"}

    async def handle(self, reader, writer):
        if self._conns >= self.proxy.cfg.admin_max_conn:
            writer.close()
            return
        self._conns += 1
        try:
            peer = writer.get_extra_info("peername") or ("", 0)
            try:
                method, target, _v, headers = await read_head(reader, self.proxy.cfg)
                hd = {k.lower(): v for k, v in headers}
                body = b""
                cl = hd.get("content-length", "0")
                if cl.isdigit() and 0 < int(cl) <= self.MAX_BODY:
                    body = await asyncio.wait_for(reader.readexactly(int(cl)), 5)
                elif cl != "0":
                    raise BadRequest(413, "body_too_large")
                status, obj = self.route(method, target, hd.get("authorization", ""), body, str(peer[0]))
            except BadRequest as exc:
                status, obj = exc.status, {"error": exc.reason}
            payload = json.dumps(obj).encode()
            writer.write((f"HTTP/1.1 {status} {_STATUS.get(status, 'OK')}\r\n"
                          f"Content-Type: application/json\r\nContent-Length: {len(payload)}\r\n"
                          f"Connection: close\r\n\r\n").encode() + payload)
            await writer.drain()
        except Exception:
            pass
        finally:
            self._conns -= 1
            try:
                writer.close()
            except Exception:
                pass


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    cfg = Config.from_env()
    proxy = EgressProxy(cfg)

    async def run():
        servers = await proxy.start()
        log.info("egress proxy listening on %s:%s (admin %s)", cfg.listen_host,
                 cfg.listen_port, "on" if cfg.admin_token else "off")
        async def flusher():
            while True:
                await asyncio.sleep(5)
                proxy.pending.flush()
        asyncio.ensure_future(flusher())
        await asyncio.gather(*(s.serve_forever() for s in servers))

    asyncio.run(run())
