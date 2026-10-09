"""Model relay: raw TCP forwarder to ONE fixed private target.

Lets sandboxes on internal networks reach the Mac-side model proxy (reverse
SSH forward bound on the Linux host's docker-bridge address) without opening
any general route. The target is fixed by operator env, validated once at
startup and never influenced by the client; payloads are never inspected or
logged. Off unless MODEL_RELAY_LISTEN and MODEL_RELAY_TARGET are both set.
"""
from __future__ import annotations

import asyncio
import ipaddress
import logging
import socket
from typing import Optional

from .netinfo import detect_default_subnet

log = logging.getLogger("egress-proxy.relay")


class RelayConfigError(ValueError):
    pass


def split_hostport(spec: str, what: str):
    host, sep, port_s = spec.rpartition(":")
    if not sep or not host or not port_s.isdigit() or not (0 < int(port_s) < 65536):
        raise RelayConfigError(f"{what} must be host:port, got {spec!r}")
    return host, int(port_s)


def validate_target_ip(ip_s: str) -> str:
    """Target must be a private IPv4 that is not loopback/link-local/
    metadata/unspecified/multicast/public."""
    try:
        ip = ipaddress.ip_address(ip_s)
    except ValueError:
        raise RelayConfigError(f"relay target {ip_s!r} is not an IP address")
    if ip.version != 4:
        raise RelayConfigError("relay target must be IPv4")
    if (ip.is_loopback or ip.is_link_local or ip.is_unspecified or ip.is_multicast
            or ip.is_reserved or not ip.is_private):
        raise RelayConfigError(f"relay target {ip} must be a private (RFC1918) address")
    if ip in ipaddress.ip_network("100.64.0.0/10"):
        raise RelayConfigError("relay target must not be in 100.64.0.0/10")
    return str(ip)


def resolve_target_once(spec: str, resolver=socket.getaddrinfo) -> tuple:
    host, port = split_hostport(spec, "MODEL_RELAY_TARGET")
    try:
        ipaddress.ip_address(host)
        ip = host
    except ValueError:
        infos = resolver(host, port, family=socket.AF_INET, type=socket.SOCK_STREAM)
        if not infos:
            raise RelayConfigError(f"cannot resolve relay target {host!r}")
        ip = infos[0][4][0]
    return validate_target_ip(ip), port


class ConnLimiter:
    """Global + per-client caps with fair share (same rule as the main proxy)."""

    def __init__(self, total: int, per_client: int):
        self.cap, self.per_client = total, per_client
        self.total = 0
        self.by_client: dict = {}

    def check(self, client: str) -> Optional[str]:
        mine = self.by_client.get(client, 0)
        if self.total >= self.cap or mine >= self.per_client:
            return "connection_limit"
        if self.total >= self.cap * 0.75:
            active = len(self.by_client) + (0 if client in self.by_client else 1)
            if mine >= max(1, self.cap // (active + 1)):
                return "fair_share_limit"
        return None

    def acquire(self, client: str):
        self.total += 1
        self.by_client[client] = self.by_client.get(client, 0) + 1

    def release(self, client: str):
        self.total -= 1
        n = self.by_client.get(client, 1) - 1
        if n <= 0:
            self.by_client.pop(client, None)
        else:
            self.by_client[client] = n


def client_allowed(ip_s: str, allow_cidrs, default_subnet: Optional[str]) -> bool:
    """Explicit CIDR list wins. Otherwise: any private address EXCEPT the
    compose default network (that is where the host and other services are;
    sandbox networks are the other private ranges)."""
    try:
        ip = ipaddress.ip_address(ip_s)
    except ValueError:
        return False
    if allow_cidrs:
        return any(ip in n for n in allow_cidrs)
    if not ip.is_private or ip.is_loopback:
        return False
    if default_subnet and ip in ipaddress.ip_network(default_subnet, strict=False):
        return False
    return True


class ModelRelay:
    def __init__(self, target_ip: str, target_port: int, allow_cidrs=(), default_subnet=None,
                 max_conn_total: int = 32, max_conn_per_client: int = 8,
                 idle_timeout: float = 120.0, total_timeout: float = 1800.0,
                 max_request_bytes: int = 16 * 1024 * 1024,
                 max_response_bytes: int = 64 * 1024 * 1024,
                 connect_timeout: float = 5.0, opener=asyncio.open_connection):
        self.target = (target_ip, target_port)
        self.allow_cidrs = tuple(ipaddress.ip_network(c, strict=False) for c in allow_cidrs)
        self.default_subnet = default_subnet
        self.limiter = ConnLimiter(max_conn_total, max_conn_per_client)
        self.idle, self.total_timeout = idle_timeout, total_timeout
        self.max_req, self.max_resp = max_request_bytes, max_response_bytes
        self.connect_timeout = connect_timeout
        self.opener = opener
        self.stats = {"accepted": 0, "refused": 0, "closed": 0}

    async def handle(self, reader, writer):
        client = str((writer.get_extra_info("peername") or ("?", 0))[0])
        reason = None
        if not client_allowed(client, self.allow_cidrs, self.default_subnet):
            reason = "client_not_allowed"
        else:
            reason = self.limiter.check(client)
        if reason:
            self.stats["refused"] += 1
            log.info("relay refused client=%s reason=%s", client, reason)
            writer.close()
            return
        self.limiter.acquire(client)
        self.stats["accepted"] += 1
        log.info("relay connect client=%s open=%d", client, self.limiter.total)
        up_w = None
        try:
            ur, up_w = await asyncio.wait_for(self.opener(*self.target), self.connect_timeout)
            await asyncio.wait_for(asyncio.gather(
                self._pump(reader, up_w, self.max_req),
                self._pump(ur, writer, self.max_resp)), self.total_timeout)
        except Exception:
            pass
        finally:
            self.limiter.release(client)
            self.stats["closed"] += 1
            log.info("relay disconnect client=%s open=%d", client, self.limiter.total)
            for w in (writer, up_w):
                try:
                    if w is not None:
                        w.close()
                except Exception:
                    pass

    async def _pump(self, src, dst, cap: int):
        sent = 0
        try:
            while True:
                data = await asyncio.wait_for(src.read(65536), self.idle)
                if not data:
                    break
                sent += len(data)
                if sent > cap:
                    break      # byte cap hit: drop the connection
                dst.write(data)
                await dst.drain()
        except Exception:
            pass
        finally:
            try:
                dst.close()    # either direction ending ends the session
            except Exception:
                pass


async def start_relay(listen: str, target: str, allow_cidrs: str = "", **kw):
    """Returns a server, or None when disabled/misconfigured (logged, never raises)."""
    if not listen or not target:
        return None
    try:
        lhost, lport = split_hostport(listen, "MODEL_RELAY_LISTEN")
        ip, port = resolve_target_once(target)
        cidrs = [c.strip() for c in allow_cidrs.split(",") if c.strip()]
        for c in cidrs:
            ipaddress.ip_network(c, strict=False)
    except (RelayConfigError, ValueError, OSError) as exc:
        log.error("model relay disabled: %s", exc)
        return None
    relay = ModelRelay(ip, port, cidrs, detect_default_subnet() if not cidrs else None, **kw)
    server = await asyncio.start_server(relay.handle, lhost, lport)
    server.relay = relay
    log.info("model relay listening on %s:%s -> %s:%s", lhost, lport, ip, port)
    return server
