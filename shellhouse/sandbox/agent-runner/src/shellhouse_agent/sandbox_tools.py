"""In-sandbox tool implementations (ports of Sources/AgentCore/Tools/ToolRegistry.swift).

Each impl takes (ctx, args: dict) and returns a JSON-able dict. Errors are returned as
{"error": ...}, never raised (except Cancelled). All filesystem tools are confined to the
workspace via realpath; the runner's own `.shellhouse` state dir is off limits to them.
"""

from __future__ import annotations

import io
import os
import re
import shutil
import signal
import subprocess
import threading
import time
from typing import Any, Callable

from .core import Cancelled, RunContext

READ_MAX_BYTES = 200_000          # same as Swift read_file maxBytes
WRITE_MAX_BYTES = 2_000_000
LIST_MAX_ENTRIES = 1_000
SHELL_OUTPUT_CAP = 20_000         # chars returned to the model per stream
SHELL_READ_CAP = 1_000_000        # bytes retained per stream before discarding
SHELL_DEFAULT_TIMEOUT = 120.0
SHELL_MAX_TIMEOUT = 1800.0
SCREENSHOT_MAX_BYTES = 10_000_000
RESERVED_DIR = ".shellhouse"

_KEY_RE = re.compile(r"^[A-Za-z0-9_+\-]+$")


# ---------------------------------------------------------------- confinement
class PathError(Exception):
    pass


def resolve_in_workspace(ctx: RunContext, path: Any, *, allow_root: bool = True) -> str:
    """Return the real absolute path for `path`, or raise PathError.

    Relative paths are relative to the workspace; absolute paths must already be inside it.
    Symlinks and `..` are resolved with realpath BEFORE the containment check, so a link that
    points outside is rejected. The reserved `.shellhouse` tree is always rejected.
    """
    if not isinstance(path, str):
        raise PathError("path must be a string")
    if "\0" in path:
        raise PathError("invalid path")
    ws = ctx.workspace
    # The model is told its workspace is /workspace; honor that spelling even when the
    # configured workspace lives elsewhere (tests, dev machines).
    if ws != "/workspace" and (path == "/workspace" or path.startswith("/workspace/")):
        path = path[len("/workspace"):].lstrip("/") or "."
    if path in ("", "."):
        cand = ws
    elif os.path.isabs(path):
        cand = path
    else:
        cand = os.path.join(ws, path)
    real = os.path.realpath(cand)
    if real != ws and not real.startswith(ws + os.sep):
        raise PathError("path escapes /workspace")
    if real == ws and not allow_root:
        raise PathError("path must name a file inside /workspace")
    rel = os.path.relpath(real, ws)
    if rel == RESERVED_DIR or rel.startswith(RESERVED_DIR + os.sep):
        raise PathError("path is reserved")
    return real


# ---------------------------------------------------------------- filesystem
def list_files(ctx: RunContext, args: dict) -> dict:
    try:
        real = resolve_in_workspace(ctx, args.get("path") or "")
    except PathError as e:
        return {"error": str(e)}
    try:
        names = []
        with os.scandir(real) as it:
            for e in it:
                if real == ctx.workspace and e.name == RESERVED_DIR:
                    continue
                if e.name == ".type_text_tmp":
                    continue
                try:
                    is_dir = e.is_dir(follow_symlinks=False)
                except OSError:
                    is_dir = False
                names.append(e.name + ("/" if is_dir else ""))
    except NotADirectoryError:
        return {"error": "not a directory"}
    except OSError as e:
        return {"error": e.strerror or "cannot list"}
    names.sort()
    truncated = len(names) > LIST_MAX_ENTRIES
    out: dict[str, Any] = {"path": args.get("path") or "", "entries": names[:LIST_MAX_ENTRIES]}
    if truncated:
        out["truncated"] = True
        out["total"] = len(names)
    return out


def read_file(ctx: RunContext, args: dict) -> dict:
    p = args.get("path")
    if not isinstance(p, str):
        return {"error": "read_file requires 'path'"}
    try:
        real = resolve_in_workspace(ctx, p, allow_root=False)
    except PathError as e:
        return {"error": str(e)}
    try:
        fd = os.open(real, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    except OSError as e:
        return {"error": e.strerror or "cannot open"}
    try:
        st = os.fstat(fd)
        import stat as _stat
        if not _stat.S_ISREG(st.st_mode):
            return {"error": "not a regular file"}
        with os.fdopen(fd, "rb", closefd=False) as f:
            data = f.read(READ_MAX_BYTES + 1)
    finally:
        os.close(fd)
    out: dict[str, Any] = {"path": p, "content": data[:READ_MAX_BYTES].decode("utf-8", errors="replace")}
    if len(data) > READ_MAX_BYTES:
        out["truncated"] = True
    return out


def write_file(ctx: RunContext, args: dict) -> dict:
    p, content = args.get("path"), args.get("content")
    if not isinstance(p, str) or not isinstance(content, str):
        return {"error": "write_file requires 'path' and 'content'"}
    raw = content.encode("utf-8")
    if len(raw) > WRITE_MAX_BYTES:
        return {"error": f"content too large ({len(raw)} bytes; max {WRITE_MAX_BYTES})"}
    try:
        real = resolve_in_workspace(ctx, p, allow_root=False)
    except PathError as e:
        return {"error": str(e)}
    parent = os.path.dirname(real)
    try:
        os.makedirs(parent, exist_ok=True)
        rp = os.path.realpath(parent)  # re-check after creating parents
        if rp != ctx.workspace and not rp.startswith(ctx.workspace + os.sep):
            return {"error": "path escapes /workspace"}
        if os.path.isdir(real):
            return {"error": "is a directory"}
        tmp = os.path.join(parent, f".shellhouse-write-{os.getpid()}-{threading.get_ident()}.tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
        with os.fdopen(fd, "wb") as f:
            f.write(raw)
        os.replace(tmp, real)
    except OSError as e:
        return {"error": e.strerror or "write failed"}
    return {"path": p, "bytes": len(raw)}


# ---------------------------------------------------------------- shell
def base_env(ctx: RunContext) -> dict[str, str]:
    env = {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "HOME": os.environ.get("HOME", "/home/box"),
        "LANG": "C.UTF-8",
        "TERM": "dumb",
        "DISPLAY": os.environ.get("DISPLAY", ":1"),
    }
    env.update(ctx.config.env)
    return env


def _cap(text: str, limit: int, dropped_bytes: int = 0) -> str:
    if len(text) <= limit and not dropped_bytes:
        return text
    return text[:limit] + f"\n...[output truncated; showing first {min(len(text), limit)} chars]"


class _Pump(threading.Thread):
    def __init__(self, stream):
        super().__init__(daemon=True)
        self.stream = stream
        self.buf = bytearray()
        self.dropped = 0

    def run(self):
        try:
            while True:
                chunk = self.stream.read(65536)
                if not chunk:
                    return
                room = SHELL_READ_CAP - len(self.buf)
                if room > 0:
                    self.buf.extend(chunk[:room])
                self.dropped += max(0, len(chunk) - max(room, 0))
        except (OSError, ValueError):
            return


def run_shell(ctx: RunContext, args: dict) -> dict:
    command = args.get("command")
    if not isinstance(command, str) or not command.strip():
        return {"error": "run_shell requires 'command'"}
    t = args.get("timeout")
    try:
        timeout = float(t) if t is not None else SHELL_DEFAULT_TIMEOUT
    except (TypeError, ValueError):
        timeout = SHELL_DEFAULT_TIMEOUT
    timeout = max(1.0, min(timeout, SHELL_MAX_TIMEOUT))
    shell = shutil.which("bash") or "/bin/sh"
    try:
        proc = subprocess.Popen(
            [shell, "-c", command], cwd=ctx.workspace, env=base_env(ctx),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as e:
        return {"error": f"cannot start shell: {e.strerror}"}
    pgid = proc.pid  # new session => pgid == pid
    ctx.track_pgid(pgid)
    out_p, err_p = _Pump(proc.stdout), _Pump(proc.stderr)
    out_p.start()
    err_p.start()
    deadline = time.monotonic() + timeout
    timed_out = False
    cancelled = False
    try:
        while True:
            try:
                proc.wait(timeout=min(0.1, max(0.0, deadline - time.monotonic())))
                break
            except subprocess.TimeoutExpired:
                pass
            if ctx.cancelled():
                cancelled = True
                break
            if time.monotonic() >= deadline:
                timed_out = True
                break
        if timed_out or cancelled:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        out_p.join(timeout=2.0)
        err_p.join(timeout=2.0)
    finally:
        ctx.untrack_pgid(pgid)
        for s in (proc.stdout, proc.stderr):
            try:
                s.close()
            except OSError:
                pass
    if cancelled:
        raise Cancelled()
    stdout = ctx.redact(_cap(bytes(out_p.buf).decode("utf-8", errors="replace"), SHELL_OUTPUT_CAP, out_p.dropped))
    stderr = ctx.redact(_cap(bytes(err_p.buf).decode("utf-8", errors="replace"), SHELL_OUTPUT_CAP, err_p.dropped))
    if timed_out:
        return {"error": f"command timed out after {int(timeout)}s and was killed", "timed_out": True,
                "stdout": stdout, "stderr": stderr}
    return {"exit_code": proc.returncode, "stdout": stdout, "stderr": stderr}


# ---------------------------------------------------------------- GUI helpers
def _run(ctx: RunContext, argv: list[str], timeout: float) -> tuple[int, str, str] | dict:
    """Run a fixed argv (no shell). Returns (rc, stdout, stderr) or an {"error"} dict."""
    exe = shutil.which(argv[0])
    if exe is None:
        return {"error": f"{argv[0]} is not available in this environment"}
    try:
        p = subprocess.run([exe] + argv[1:], capture_output=True, timeout=timeout, env=base_env(ctx),
                           stdin=subprocess.DEVNULL, cwd=ctx.workspace, start_new_session=True)
    except subprocess.TimeoutExpired:
        return {"error": f"{argv[0]} timed out"}
    except OSError as e:
        return {"error": f"{argv[0]} failed: {e.strerror}"}
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def _fail(rc_out) -> dict | None:
    if isinstance(rc_out, dict):
        return rc_out
    rc, _o, err = rc_out
    if rc != 0:
        return {"error": err.strip() or f"exit code {rc}"}
    return None


def _sanitize_filename(name: Any) -> str | None:
    if not isinstance(name, str) or not name:
        return None
    base = os.path.basename(name)
    if not base or base in (".", "..") or base.startswith("."):
        return None
    return base


def capture_screenshot(ctx: RunContext, filename_hint: Any = None) -> dict | None:
    """scrot into the workspace, JPEG-compress a copy for the model (same pixel size)."""
    filename = _sanitize_filename(filename_hint) or f"screenshot-{int(time.time())}.png"
    real = os.path.join(ctx.workspace, filename)
    if os.path.islink(real):
        return None
    r = _run(ctx, ["scrot", "-o", real], 20)
    if isinstance(r, dict) or r[0] != 0:
        return None
    try:
        with open(real, "rb") as f:
            data = f.read(SCREENSHOT_MAX_BYTES + 1)
    except OSError:
        return None
    if len(data) > SCREENSHOT_MAX_BYTES:
        return None
    if ctx.config.vision:
        try:
            from PIL import Image  # Pillow is a smolagents dependency

            img = Image.open(io.BytesIO(data)).convert("RGB")
            ctx.pending_images.append(img)
        except Exception:
            pass
    return {"filename": filename, "bytes": len(data)}


def _with_shot(ctx: RunContext, name: str) -> dict:
    shot = capture_screenshot(ctx)
    if shot is None:
        return {"ok": True, "screenshot_error": f"{name} succeeded but the verification screenshot failed"}
    return {"ok": True, "screenshot": shot["filename"]}


# ---------------------------------------------------------------- GUI tools
def screenshot(ctx: RunContext, args: dict) -> dict:
    if shutil.which("scrot") is None:
        return {"error": "scrot is not available in this environment"}
    shot = capture_screenshot(ctx, args.get("filename"))
    if shot is None:
        return {"error": "scrot failed or the captured file couldn't be read back"}
    return shot


def list_windows(ctx: RunContext, args: dict) -> dict:
    r = _run(ctx, ["wmctrl", "-lG"], 15)
    f = _fail(r)
    if f:
        return f
    windows = []
    for line in r[1].splitlines():
        parts = line.split(None, 7)
        if len(parts) != 8:
            continue
        windows.append({"id": parts[0], "x": parts[2], "y": parts[3], "width": parts[4],
                        "height": parts[5], "title": parts[7]})
    return {"windows": windows}


def focus_window(ctx: RunContext, args: dict) -> dict:
    title = args.get("title")
    if not isinstance(title, str) or not title:
        return {"error": "focus_window requires 'title'"}
    f = _fail(_run(ctx, ["wmctrl", "-a", title], 10))
    return f or {"ok": True}


def open_app(ctx: RunContext, args: dict) -> dict:
    app = args.get("app")
    if not isinstance(app, str):
        return {"error": "open_app requires 'app'"}
    if app == "browser":
        argv = ["chromium"]
        url = args.get("url")
        if isinstance(url, str) and url:
            if not re.match(r"^(https?://|about:)", url):
                return {"error": "url must start with http://, https:// or about:"}
            argv.append(url)
    elif app == "terminal":
        argv = ["xfce4-terminal", "--working-directory=/workspace"]
    elif app == "files":
        argv = ["thunar", "/workspace"]
    else:
        return {"error": f"unknown app '{app}', expected browser|terminal|files"}
    exe = shutil.which(argv[0])
    if exe is None:
        return {"error": f"{argv[0]} is not available in this environment"}
    try:
        subprocess.Popen([exe] + argv[1:], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True, env=base_env(ctx), cwd=ctx.workspace)
    except OSError as e:
        return {"error": e.strerror or "launch failed"}
    return {"ok": True, "app": app}


def _int(v: Any) -> int | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(v)
    return None


def click(ctx: RunContext, args: dict) -> dict:
    x, y = _int(args.get("x")), _int(args.get("y"))
    if x is None or y is None:
        return {"error": "click requires 'x' and 'y'"}
    button = _int(args.get("button")) or 1
    if not 1 <= button <= 9:
        return {"error": "invalid button"}
    helper = "/usr/local/bin/ai-click.py"
    if os.path.exists(helper) and shutil.which("python3"):
        r = _run(ctx, ["python3", helper, str(x), str(y), str(button)], 15)
    else:
        r = _run(ctx, ["xdotool", "mousemove", str(x), str(y), "click", str(button)], 15)
    f = _fail(r)
    return f or _with_shot(ctx, "click")


def type_text(ctx: RunContext, args: dict) -> dict:
    text = args.get("text")
    if not isinstance(text, str):
        return {"error": "type_text requires 'text'"}
    if shutil.which("xdotool") is None:
        return {"error": "xdotool is not available in this environment"}
    tmp = os.path.join(ctx.workspace, ".type_text_tmp")
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        r = _run(ctx, ["xdotool", "type", "--file", tmp], 15)
    except OSError as e:
        return {"error": e.strerror or "write failed"}
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    f = _fail(r)
    return f or _with_shot(ctx, "type_text")


def press_key(ctx: RunContext, args: dict) -> dict:
    key = args.get("key")
    if not isinstance(key, str):
        return {"error": "press_key requires 'key'"}
    if not _KEY_RE.match(key):
        return {"error": f"invalid key name '{key}'"}
    f = _fail(_run(ctx, ["xdotool", "key", key], 10))
    return f or {"ok": True}


def scroll(ctx: RunContext, args: dict) -> dict:
    d = args.get("direction")
    if d not in ("up", "down"):
        return {"error": "scroll requires direction: 'up' or 'down'"}
    amount = max(1, min(_int(args.get("amount")) or 5, 100))
    button = "4" if d == "up" else "5"
    x, y = _int(args.get("x")), _int(args.get("y"))
    if x is not None and y is not None:
        f = _fail(_run(ctx, ["xdotool", "mousemove", str(x), str(y)], 10))
        if f:
            return f
    f = _fail(_run(ctx, ["xdotool", "click", "--repeat", str(amount), "--delay", "20", button], 10))
    return f or _with_shot(ctx, "scroll")


IMPLS: dict[str, Callable[[RunContext, dict], dict]] = {
    "run_shell": run_shell, "read_file": read_file, "write_file": write_file, "list_files": list_files,
    "screenshot": screenshot, "list_windows": list_windows, "focus_window": focus_window,
    "open_app": open_app, "click": click, "type_text": type_text, "press_key": press_key, "scroll": scroll,
}
