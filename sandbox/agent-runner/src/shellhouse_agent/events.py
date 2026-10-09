"""Atomic per-event files and the bounded `tail` reader. Stdlib only (fast startup)."""

from __future__ import annotations

import json
import os
import re
import threading
import time
from typing import Any, Callable, IO

SEQ_RE = re.compile(r"^(\d{8})\.json$")
MAX_EVENT_BYTES = 256 * 1024
TERMINAL_STATES = ("completed", "failed", "aborted")


def redact_obj(obj: Any, secrets: list[str]) -> Any:
    if not secrets:
        return obj
    if isinstance(obj, str):
        for s in secrets:
            if s in obj:
                obj = obj.replace(s, "[redacted]")
        return obj
    if isinstance(obj, list):
        return [redact_obj(x, secrets) for x in obj]
    if isinstance(obj, dict):
        return {k: redact_obj(v, secrets) for k, v in obj.items()}
    return obj


def _shrink(obj: Any, limit: int) -> Any:
    if isinstance(obj, str):
        return obj if len(obj) <= limit else obj[:limit] + f"...[truncated {len(obj) - limit} chars]"
    if isinstance(obj, list):
        return [_shrink(x, limit) for x in obj]
    if isinstance(obj, dict):
        return {k: _shrink(v, limit) for k, v in obj.items()}
    return obj


def list_seqs(events_dir: str) -> list[int]:
    try:
        names = os.listdir(events_dir)
    except OSError:
        return []
    out = []
    for n in names:
        m = SEQ_RE.match(n)
        if m:
            out.append(int(m.group(1)))
    out.sort()
    return out


class EventWriter:
    """Thread-safe. seq is gap-free and strictly increasing; each file appears atomically."""

    def __init__(self, run_dir: str, secrets: list[str] | None = None):
        self.dir = os.path.join(run_dir, "events")
        os.makedirs(self.dir, exist_ok=True)
        self._lock = threading.Lock()
        seqs = list_seqs(self.dir)
        self._seq = seqs[-1] if seqs else 0
        self._secrets = secrets or []

    def emit(self, type: str, **fields: Any) -> int:
        with self._lock:
            self._seq += 1
            seq = self._seq
            ev = {"seq": seq, "ts": round(time.time(), 3), "type": type}
            ev.update(redact_obj(fields, self._secrets))
            text = json.dumps(ev, ensure_ascii=False, separators=(",", ":"), default=str)
            limit = 32768
            while len(text.encode("utf-8")) > MAX_EVENT_BYTES and limit >= 64:
                ev = _shrink(ev, limit)
                ev["truncated"] = True
                text = json.dumps(ev, ensure_ascii=False, separators=(",", ":"), default=str)
                limit //= 2
            tmp = os.path.join(self.dir, f".{seq:08d}.tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, os.path.join(self.dir, f"{seq:08d}.json"))
            return seq


class DeltaCoalescer:
    """Buffers streamed text and emits message_delta at most every `interval` seconds."""

    def __init__(self, emit: Callable[[str], None], interval: float = 0.1, clock: Callable[[], float] = time.monotonic):
        self._emit = emit
        self._interval = interval
        self._clock = clock
        self._buf: list[str] = []
        self._last = None  # type: float | None

    def add(self, text: str) -> None:
        if not text:
            return
        self._buf.append(text)
        now = self._clock()
        if self._last is None:
            self._last = now  # first chunk starts the window
        if now - self._last >= self._interval:
            self.flush()

    def flush(self) -> None:
        if self._buf:
            self._emit("".join(self._buf))
            self._buf = []
        self._last = None


def _is_terminal(ev: dict) -> bool:
    return ev.get("type") == "status" and ev.get("state") in TERMINAL_STATES


def tail(run_dir: str, after: int, max_bytes: int, out: IO[str]) -> None:
    """Print events with seq > after as JSONL, at most max_bytes of event data, then a
    tail_done line. If one event alone exceeds the bound it is replaced by a stub so the
    reader can always make progress."""
    events_dir = os.path.join(run_dir, "events")
    seqs = list_seqs(events_dir)
    todo = [s for s in seqs if s > after]
    used = 0
    last = after
    emitted = 0
    for s in todo:
        path = os.path.join(events_dir, f"{s:08d}.json")
        try:
            with open(path, "rb") as f:
                raw = f.read(max_bytes + 1)
                oversize = len(raw) > max_bytes
        except OSError:
            last = s
            continue
        line = None
        if not oversize:
            try:
                line = json.dumps(json.loads(raw.decode("utf-8")), ensure_ascii=False, separators=(",", ":"))
            except (ValueError, UnicodeDecodeError):
                last = s
                continue
        if line is None or used + len(line.encode("utf-8")) + 1 > max_bytes:
            if emitted > 0:
                break
            # The very first event is too big for the bound: send a stub so the reader advances.
            line = json.dumps({"seq": s, "type": "truncated", "reason": "event larger than max-bytes"},
                              separators=(",", ":"))
        out.write(line + "\n")
        used += len(line.encode("utf-8")) + 1
        emitted += 1
        last = s

    finished = False
    if seqs and last == seqs[-1]:
        try:
            with open(os.path.join(events_dir, f"{seqs[-1]:08d}.json"), "rb") as f:
                finished = _is_terminal(json.loads(f.read(MAX_EVENT_BYTES * 2)))
        except (OSError, ValueError):
            finished = False
    out.write(json.dumps({"tail_done": True, "last_seq": last, "finished": finished}, separators=(",", ":")) + "\n")
    out.flush()
