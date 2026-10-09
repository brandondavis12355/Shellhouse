"""Decision log (JSONL) and the pending/denied host set (pending.json)."""
from __future__ import annotations

import json
import os
import threading
import time
from collections import deque
from typing import Optional


class DecisionLog:
    """Append-only JSONL. Fields: ts, client, method, host, port, verdict,
    reason, canary. Never receives bodies, paths, queries or headers."""

    def __init__(self, path: str, max_bytes: int = 10 * 1024 * 1024):
        self.path = path
        self.max_bytes = max_bytes
        self._lock = threading.Lock()
        self._recent: deque = deque(maxlen=500)

    def write(self, *, client: str, method: str, host: str, port: Optional[int],
              verdict: str, reason: str, canary: bool = False) -> dict:
        entry = {
            "ts": round(time.time(), 3), "client": client, "method": method,
            "host": host[:260], "port": port, "verdict": verdict,
            "reason": reason, "canary": canary,
        }
        line = json.dumps(entry, separators=(",", ":"))
        with self._lock:
            self._recent.append(entry)
            try:
                d = os.path.dirname(self.path)
                if d:
                    os.makedirs(d, exist_ok=True)
                try:
                    if os.path.getsize(self.path) > self.max_bytes:
                        os.replace(self.path, self.path + ".1")
                except OSError:
                    pass
                with open(self.path, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass   # logging must never take the proxy down
        return entry

    def tail(self, n: int = 100, canary_only: bool = False) -> list:
        n = max(1, min(int(n), 500))
        with self._lock:
            items = list(self._recent)
        if canary_only:
            items = [e for e in items if e.get("canary")]
        return items[-n:]


class PendingStore:
    """Hosts that were denied only for not being allowlisted, awaiting an
    operator decision. Deduped by host, capped; denied hosts are muted so
    repeated attempts do not re-surface."""

    def __init__(self, path: str, cap: int = 500, denied_cap: int = 1000,
                 flush_interval: float = 5.0, rate_per_min: int = 20):
        self.path = path
        self.cap = cap
        self.denied_cap = denied_cap
        self.flush_interval = flush_interval
        self.rate_per_min = rate_per_min
        self._new_times: dict = {}      # client -> deque of creation times
        self._lock = threading.Lock()
        self.pending: dict = {}
        self.denied: list = []
        self.dropped = 0
        self._dirty = False
        self._last_flush = 0.0
        self._load()

    def _load(self) -> None:
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                p = data.get("pending")
                if isinstance(p, dict):
                    self.pending = dict(list(p.items())[: self.cap])
                d = data.get("denied")
                if isinstance(d, list):
                    self.denied = [x for x in d if isinstance(x, str)][-self.denied_cap:]
                self.dropped = int(data.get("dropped", 0) or 0)
        except (OSError, ValueError, TypeError):
            pass

    def record(self, host: str, port: int, client: str, now: Optional[float] = None) -> str:
        """Returns "new" | "seen" | "muted" | "dropped" | "rate_limited"."""
        now = now if now is not None else time.time()
        with self._lock:
            if host in self.denied:
                return "muted"
            entry = self.pending.get(host)
            if entry is not None:
                entry["count"] += 1
                entry["last_seen"] = now
                if port not in entry["ports"] and len(entry["ports"]) < 8:
                    entry["ports"].append(port)
                self._dirty = True
                self._maybe_flush(now)
                return "seen"
            # One noisy client must not fill the list for everyone else.
            times = self._new_times.setdefault(client, deque())
            while times and now - times[0] > 60:
                times.popleft()
            if len(times) >= self.rate_per_min:
                self.dropped += 1
                return "rate_limited"
            if len(self._new_times) > 1000:
                self._new_times = {c: t for c, t in self._new_times.items() if t}
            if len(self.pending) >= self.cap:
                self.dropped += 1
                self._dirty = True
                self._maybe_flush(now)
                return "dropped"
            times.append(now)
            self.pending[host] = {
                "first_seen": now, "last_seen": now, "count": 1,
                "ports": [port], "client": client,
            }
            self._dirty = True
            self._flush(now)   # new hosts are persisted immediately
            return "new"

    def resolve(self, host: str, deny: bool) -> bool:
        with self._lock:
            existed = self.pending.pop(host, None) is not None
            if deny:
                if host not in self.denied:
                    self.denied.append(host)
                    self.denied = self.denied[-self.denied_cap:]
                existed = True
            elif host in self.denied:
                self.denied.remove(host)
            self._dirty = True
            self._flush(time.time())
            return existed

    def snapshot(self) -> dict:
        with self._lock:
            return {"pending": {k: dict(v) for k, v in self.pending.items()},
                    "denied": list(self.denied), "dropped": self.dropped,
                    "cap": self.cap}

    def _maybe_flush(self, now: float) -> None:
        if self._dirty and now - self._last_flush >= self.flush_interval:
            self._flush(now)

    def flush(self) -> None:
        with self._lock:
            self._flush(time.time())

    def _flush(self, now: float) -> None:
        data = {"pending": self.pending, "denied": self.denied, "dropped": self.dropped}
        try:
            d = os.path.dirname(self.path)
            if d:
                os.makedirs(d, exist_ok=True)
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f)
            os.replace(tmp, self.path)
            self._dirty = False
            self._last_flush = now
        except OSError:
            pass
