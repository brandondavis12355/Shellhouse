"""Run context shared by tools and the runner: cancel handling and the RPC client."""

from __future__ import annotations

import json
import os
import signal
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

from .config import Config
from .events import EventWriter, redact_obj

POLL_S = float(os.environ.get("SHELLHOUSE_POLL_S", "0.1"))  # protocol: <= 250 ms
MAX_REPLY_BYTES = 1024 * 1024


class Cancelled(BaseException):
    """Raised (BaseException so smolagents' `except Exception` cannot swallow it)."""


@dataclass
class Reply:
    decision: str  # allow | deny
    reason: str | None = None
    result: Any = None


@dataclass
class RunContext:
    config: Config
    run_dir: str
    workspace: str  # realpath
    events: EventWriter
    poll_s: float = POLL_S
    pending_images: list = field(default_factory=list)
    _pgids: set = field(default_factory=set)
    _lock: threading.Lock = field(default_factory=threading.Lock)

    # ---- cancel -----------------------------------------------------------
    @property
    def cancel_path(self) -> str:
        return os.path.join(self.run_dir, "cancel")

    def cancelled(self) -> bool:
        return os.path.exists(self.cancel_path)

    def check_cancel(self) -> None:
        if self.cancelled():
            raise Cancelled()

    # ---- child process tracking ---------------------------------------------
    def track_pgid(self, pgid: int) -> None:
        with self._lock:
            self._pgids.add(pgid)

    def untrack_pgid(self, pgid: int) -> None:
        with self._lock:
            self._pgids.discard(pgid)

    def kill_children(self) -> None:
        with self._lock:
            pgids = list(self._pgids)
        for pg in pgids:
            try:
                os.killpg(pg, signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                pass

    def redact(self, obj: Any) -> Any:
        return redact_obj(obj, self.config.secrets)

    # ---- RPC ------------------------------------------------------------------
    def rpc_request(self, kind: str, name: str, args: dict) -> Reply:
        rpc_dir = os.path.join(self.run_dir, "rpc")
        os.makedirs(rpc_dir, exist_ok=True)
        rid = uuid.uuid4().hex[:12]
        self.events.emit("rpc_request", id=rid, kind=kind, name=name, args=args)
        self.events.emit("status", state="waiting_policy", detail=name)
        path = os.path.join(rpc_dir, f"{rid}.reply.json")
        deadline = time.monotonic() + self.config.rpc_timeout_s
        reply: Reply | None = None
        while reply is None:
            self.check_cancel()
            data = None
            try:
                st = os.stat(path)
                if st.st_size > MAX_REPLY_BYTES:
                    reply = Reply("deny", "reply too large")
                    break
                with open(path, "rb") as f:
                    data = json.loads(f.read().decode("utf-8"))
            except FileNotFoundError:
                data = None
            except (ValueError, UnicodeDecodeError, OSError):
                data = None  # partially written: retry
            if data is not None:
                if (isinstance(data, dict) and data.get("id") == rid and data.get("decision") in ("allow", "deny")):
                    reason = data.get("reason")
                    reply = Reply(data["decision"], reason if isinstance(reason, str) else None, data.get("result"))
                else:
                    reply = Reply("deny", "malformed policy reply")
                break
            if time.monotonic() >= deadline:
                reply = Reply("deny", f"timed out waiting for a reply after {int(self.config.rpc_timeout_s)}s")
                break
            time.sleep(self.poll_s)
        self.events.emit("status", state="executing")
        return reply
