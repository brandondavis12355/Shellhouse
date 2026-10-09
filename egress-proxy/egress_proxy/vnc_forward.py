"""noVNC forwarder for allowlist mode.

Docker cannot publish ports from an `internal` network, so the host cannot
reach a sandbox's noVNC directly. This proxy container is attached to every
sandbox's internal network and (in compose) publishes loopback ports
6100-6131; port N is forwarded to `sbx-N:6080` (an alias the manager gives
the sandbox on its own network).

Isolation: this proxy is on every sandbox network, so without a source check
sandbox A could dial proxy:<B's port> and reach sandbox B. Therefore the
forwarder REFUSES to start unless EGRESS_VNC_ALLOW_CIDRS lists the only
source addresses allowed (the compose network gateway, as seen by published
ports), and drops every other peer. Unverified on real Docker.
"""
from __future__ import annotations

import asyncio
import ipaddress
import logging

log = logging.getLogger("egress-proxy.vnc")


def parse_range(spec: str):
    a, _, b = spec.partition("-")
    lo, hi = int(a), int(b or a)
    if not (1024 <= lo <= hi <= 65535) or hi - lo > 255:
        raise ValueError("bad EGRESS_VNC_FORWARD range")
    return range(lo, hi + 1)


def peer_allowed(peer_ip: str, cidrs) -> bool:
    try:
        ip = ipaddress.ip_address(peer_ip)
    except ValueError:
        return False
    return any(ip in n for n in cidrs)


def make_handler(port: int, cidrs, idle: float = 3600.0, target_fmt: str = "sbx-{port}",
                 target_port: int = 6080, opener=asyncio.open_connection):
    async def handler(reader, writer):
        peer = (writer.get_extra_info("peername") or ("", 0))[0]
        if not peer_allowed(peer, cidrs):
            writer.close()
            return
        try:
            ur, uw = await asyncio.wait_for(opener(target_fmt.format(port=port), target_port), 5)
        except Exception:
            writer.close()
            return

        async def pump(src, dst):
            try:
                while True:
                    data = await asyncio.wait_for(src.read(65536), idle)
                    if not data:
                        break
                    dst.write(data)
                    await dst.drain()
            except Exception:
                pass
            finally:
                try:
                    dst.close()
                except Exception:
                    pass
        await asyncio.gather(pump(reader, uw), pump(ur, writer))
    return handler


async def start_forwarders(spec: str, allow_cidrs: str, host: str = "0.0.0.0"):
    cidrs = [ipaddress.ip_network(c.strip(), strict=False) for c in allow_cidrs.split(",") if c.strip()]
    if not cidrs:
        raise ValueError("EGRESS_VNC_ALLOW_CIDRS is required when EGRESS_VNC_FORWARD is set")
    servers = []
    for p in parse_range(spec):
        servers.append(await asyncio.start_server(make_handler(p, cidrs), host, p))
    return servers
