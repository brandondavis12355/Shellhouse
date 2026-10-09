"""Find the subnet of the container's default-route interface (the compose
network; per-sandbox internal networks have no default route). Linux only."""
from __future__ import annotations

import ipaddress
import socket
import struct
from typing import Optional


def default_iface(route_text: str) -> Optional[str]:
    """Interface of the default route from /proc/net/route text."""
    for line in route_text.splitlines()[1:]:
        f = line.split()
        if len(f) >= 4 and f[1] == "00000000" and int(f[3], 16) & 2:   # dest 0, RTF_GATEWAY
            return f[0]
    return None


def detect_default_subnet() -> Optional[str]:
    """UNVERIFIED on real Docker. Returns e.g. '172.18.0.0/16' or None."""
    try:
        import fcntl
        with open("/proc/net/route") as fh:
            iface = default_iface(fh.read())
        if not iface:
            return None
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        ifreq = struct.pack("256s", iface.encode()[:15])
        addr = socket.inet_ntoa(fcntl.ioctl(s.fileno(), 0x8915, ifreq)[20:24])     # SIOCGIFADDR
        mask = socket.inet_ntoa(fcntl.ioctl(s.fileno(), 0x891B, ifreq)[20:24])     # SIOCGIFNETMASK
        return str(ipaddress.ip_network(f"{addr}/{mask}", strict=False))
    except Exception:
        return None
