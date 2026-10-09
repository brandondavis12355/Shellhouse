"""Pure policy logic: host normalization, allowlist matching, IP blocking.

No I/O except reading the allowlist file. Everything here is unit-tested.
"""
from __future__ import annotations

import ipaddress
import os
import re
import threading
from dataclasses import dataclass
from typing import Optional, Tuple

_LABEL_RE = re.compile(r"^[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?$")
MAX_HOST_LEN = 253

# Extra ranges ipaddress.is_global does not reliably cover or that embed IPv4.
_EXTRA_BLOCKED = [
    ipaddress.ip_network(n)
    for n in (
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
        "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16",
        "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4",
        "::1/128", "::/128", "fc00::/7", "fe80::/10", "ff00::/8",
        "::/96",          # deprecated IPv4-compatible addresses
        "64:ff9b::/96",   # NAT64: can embed a private v4
        "64:ff9b:1::/48", # local-use NAT64
        "2002::/16",      # 6to4: embeds a v4
        "2001::/32",      # Teredo
    )
]


def is_blocked_ip(ip) -> bool:
    """True if connecting to this address could reach a private, loopback,
    link-local, metadata or otherwise non-public network."""
    if isinstance(ip, str):
        try:
            ip = ipaddress.ip_address(ip)
        except ValueError:
            return True  # unparseable -> fail closed
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped is not None:
            return is_blocked_ip(ip.ipv4_mapped)
        if ip.sixtofour is not None and is_blocked_ip(ip.sixtofour):
            return True
    if not ip.is_global:
        return True
    return any(ip in net for net in _EXTRA_BLOCKED if net.version == ip.version)


def normalize_host(raw: str) -> Tuple[Optional[str], str]:
    """Return (canonical_ascii_host, "") or (None, reason).

    Lowercases, strips ONE trailing dot, converts IDN to punycode, and rejects
    anything that is not a plain DNS name: IP literals (including decimal /
    hex / short forms), userinfo, brackets, percent-escapes, whitespace.
    """
    if not isinstance(raw, str) or not raw:
        return None, "empty_host"
    host = raw.strip()
    if host != raw or not host:
        return None, "bad_host"
    if any(c in host for c in "@/\\?#%[]:\x00 \t\r\n"):
        return None, "bad_host_chars"
    if host.endswith("."):
        host = host[:-1]
    if not host or host.startswith(".") or ".." in host:
        return None, "bad_host"
    try:
        host = host.encode("idna").decode("ascii")
    except UnicodeError:
        return None, "bad_idna"
    host = host.lower()
    if len(host) > MAX_HOST_LEN:
        return None, "host_too_long"
    labels = host.split(".")
    if not all(_LABEL_RE.match(l) for l in labels):
        return None, "bad_host"
    # IP literals in any spelling: a real TLD is never all digits nor 0x...
    last = labels[-1]
    if last.isdigit() or last.startswith("0x"):
        return None, "ip_literal"
    try:
        ipaddress.ip_address(host)
        return None, "ip_literal"
    except ValueError:
        pass
    return host, ""


def parse_authority(auth: str, default_port: Optional[int]) -> Tuple[Optional[str], Optional[int], str]:
    """Split `host[:port]` (no userinfo allowed, IPv6 brackets -> rejected as
    IP literal). Returns (host, port, reason)."""
    if "@" in auth:
        return None, None, "userinfo"
    if auth.startswith("["):
        return None, None, "ip_literal"
    host, sep, port_s = auth.partition(":")
    if ":" in port_s:
        return None, None, "bad_authority"
    port = default_port
    if sep:
        if not port_s.isascii() or not port_s.isdigit() or len(port_s) > 5:
            return None, None, "bad_port"
        port = int(port_s)
    if port is None or not (0 < port < 65536):
        return None, None, "bad_port"
    nh, why = normalize_host(host)
    if nh is None:
        return None, None, why
    return nh, port, ""


def _norm_entry(entry: str) -> Optional[Tuple[bool, str]]:
    """Parse an allowlist line -> (is_wildcard, canonical) or None if invalid."""
    entry = entry.strip()
    wildcard = False
    if entry.startswith("*."):
        wildcard = True
        entry = entry[2:]
    host, why = normalize_host(entry)
    if host is None:
        return None
    if wildcard and host.count(".") < 1:
        return None   # `*.com` is refused: too broad
    return wildcard, host


@dataclass
class Allowlist:
    """Exact hosts + `*.suffix` wildcards. A wildcard matches subdomains at
    any depth but NOT the apex (`*.example.com` does not match `example.com`);
    list the apex separately if wanted."""
    exact: frozenset = frozenset()
    suffixes: tuple = ()

    @classmethod
    def parse(cls, text: str) -> "Allowlist":
        exact, suffixes = set(), set()
        for line in text.splitlines():
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parsed = _norm_entry(line)
            if parsed is None:
                continue
            (suffixes if parsed[0] else exact).add(parsed[1])
        return cls(frozenset(exact), tuple(sorted(suffixes)))

    def matches(self, host: str) -> bool:
        if host in self.exact:
            return True
        return any(host.endswith("." + s) for s in self.suffixes)


class AllowlistFile:
    """Allowlist backed by a file; re-read when mtime/size changes."""

    def __init__(self, path: str):
        self.path = path
        self._sig = None
        self._list = Allowlist()
        self._lock = threading.Lock()

    def current(self) -> Allowlist:
        try:
            st = os.stat(self.path)
            sig = (st.st_mtime_ns, st.st_size)
        except OSError:
            sig = None
        with self._lock:
            if sig != self._sig:
                self._sig = sig
                if sig is None:
                    self._list = Allowlist()      # missing file -> deny all
                else:
                    try:
                        with open(self.path, "r", encoding="utf-8") as f:
                            self._list = Allowlist.parse(f.read())
                    except (OSError, UnicodeError):
                        self._list = Allowlist()
            return self._list

    def add(self, entry: str) -> str:
        """Append a validated entry. Returns canonical text. Raises ValueError."""
        parsed = _norm_entry(entry)
        if parsed is None:
            raise ValueError("invalid allowlist entry")
        canonical = ("*." if parsed[0] else "") + parsed[1]
        with self._lock:
            try:
                with open(self.path, "r", encoding="utf-8") as f:
                    existing = f.read()
            except OSError:
                existing = ""
            lines = [l.split("#", 1)[0].strip() for l in existing.splitlines()]
            if canonical not in lines:
                if existing and not existing.endswith("\n"):
                    existing += "\n"
                tmp = self.path + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write(existing + canonical + "\n")
                os.replace(tmp, self.path)
            self._sig = None   # force reload next call
        return canonical


def check_port(port: int, allowed: frozenset) -> bool:
    return port in allowed
