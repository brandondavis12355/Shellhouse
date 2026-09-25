#!/usr/bin/env python3
"""
Guest Agent
===========
Runs INSIDE the Linux VM. Listens on vsock and executes what the host asks.

This is the guest side of GuestAgentClient.swift. It is the only thing in the
guest that the host talks to, and it replaces sshd entirely — no keys, no
guest networking required.

Protocol: newline-delimited JSON, one request and one response per connection.

    {"op": "ping"}
    {"op": "exec", "command": "...", "timeout": 120, "env": {...}}
    {"op": "read_file", "path": "notes.md", "maxBytes": 200000}
    {"op": "write_file", "path": "notes.md", "contentsBase64": "..."}

Install in the guest image as a systemd unit (see install notes at the bottom).

Deliberate design notes:

- **Runs as the unprivileged `box` user, not root.** The host's requests are
  agent-driven and therefore semi-trusted at best; there is no reason for this
  to have root. Anything needing root in the guest should be an explicit,
  auditable exception rather than the default.
- **All file paths are confined to /workspace.** The host validates too, but a
  second check here means a bug on one side isn't sufficient to escape.
- **`env` values are passed to the child process, never interpolated into a
  shell string.** Secrets therefore don't appear in the guest's process list,
  in shell history, or in any log.
- **Output is capped** so a runaway command can't exhaust host memory through
  the response channel.
"""
import base64
import json
import os
import socket
import subprocess
import sys
import threading
import traceback

VSOCK_PORT = int(os.environ.get("GUEST_AGENT_PORT", "5555"))
WORKSPACE = "/workspace"
MAX_OUTPUT = 1_000_000          # per stream, bytes
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_REQUEST_BYTES = 64 * 1024 * 1024
DEFAULT_TIMEOUT = 120

# AF_VSOCK is Linux-only and needs kernel vsock support (CONFIG_VSOCKETS).
VMADDR_CID_ANY = 0xFFFFFFFF


def safe_path(path: str) -> str:
    """Confine to /workspace. Rejects traversal and absolute escapes."""
    candidate = os.path.normpath(os.path.join(WORKSPACE, path.lstrip("/")))
    if not (candidate == WORKSPACE or candidate.startswith(WORKSPACE + "/")):
        raise ValueError(f"path escapes workspace: {path}")
    return candidate


def op_ping(_req: dict) -> dict:
    return {"ok": True}


def op_exec(req: dict) -> dict:
    command = req.get("command")
    if not command:
        return {"error": "command is required"}

    timeout = float(req.get("timeout") or DEFAULT_TIMEOUT)

    # Start from the session environment so DISPLAY etc. are present, then
    # overlay whatever the host injected (typically secrets).
    env = os.environ.copy()
    env.setdefault("DISPLAY", ":0")
    env.setdefault("HOME", os.path.expanduser("~"))
    for key, value in (req.get("env") or {}).items():
        # Only accept sane variable names; a crafted name must not be able to
        # become anything other than a variable.
        if key.replace("_", "").isalnum() and key[0].isalpha():
            env[str(key)] = str(value)

    try:
        proc = subprocess.run(
            ["bash", "-lc", command],
            cwd=WORKSPACE,
            env=env,
            capture_output=True,
            timeout=timeout,
        )
        return {
            "exitCode": proc.returncode,
            "stdout": proc.stdout[:MAX_OUTPUT].decode("utf-8", "replace"),
            "stderr": proc.stderr[:MAX_OUTPUT].decode("utf-8", "replace"),
        }
    except subprocess.TimeoutExpired:
        return {
            "exitCode": 124,
            "stdout": "",
            "stderr": f"Command timed out after {int(timeout)}s",
        }
    except Exception as exc:
        return {"exitCode": 1, "stdout": "", "stderr": f"exec failed: {exc}"}


def op_read_file(req: dict) -> dict:
    try:
        path = safe_path(req.get("path", ""))
    except ValueError as exc:
        return {"error": str(exc)}
    if not os.path.isfile(path):
        return {"error": f"no such file: {req.get('path')}"}
    limit = min(int(req.get("maxBytes") or MAX_FILE_BYTES), MAX_FILE_BYTES)
    try:
        with open(path, "rb") as handle:
            data = handle.read(limit)
    except OSError as exc:
        return {"error": f"read failed: {exc}"}
    return {"contentsBase64": base64.b64encode(data).decode()}


def op_write_file(req: dict) -> dict:
    try:
        path = safe_path(req.get("path", ""))
    except ValueError as exc:
        return {"error": str(exc)}
    try:
        data = base64.b64decode(req.get("contentsBase64") or "", validate=True)
    except Exception:
        return {"error": "contentsBase64 is not valid base64"}
    if len(data) > MAX_FILE_BYTES:
        return {"error": "file too large"}
    try:
        os.makedirs(os.path.dirname(path) or WORKSPACE, exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data)
    except OSError as exc:
        return {"error": f"write failed: {exc}"}
    return {"ok": True, "bytes": len(data)}


HANDLERS = {
    "ping": op_ping,
    "exec": op_exec,
    "read_file": op_read_file,
    "write_file": op_write_file,
}


def handle_connection(conn: socket.socket) -> None:
    try:
        buffer = b""
        while not buffer.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            buffer += chunk
            if len(buffer) > MAX_REQUEST_BYTES:
                conn.sendall(b'{"error":"request too large"}\n')
                return

        if not buffer.strip():
            return

        try:
            request = json.loads(buffer.decode("utf-8", "replace"))
        except json.JSONDecodeError as exc:
            conn.sendall(json.dumps({"error": f"bad JSON: {exc}"}).encode() + b"\n")
            return

        handler = HANDLERS.get(request.get("op"))
        if handler is None:
            response = {"error": f"unknown op: {request.get('op')!r}"}
        else:
            try:
                response = handler(request)
            except Exception:
                traceback.print_exc()
                response = {"error": "handler raised; see guest agent log"}

        conn.sendall(json.dumps(response).encode() + b"\n")
    except Exception:
        traceback.print_exc()
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main() -> int:
    if not hasattr(socket, "AF_VSOCK"):
        print(
            "AF_VSOCK unavailable. The guest kernel needs CONFIG_VSOCKETS and "
            "CONFIG_VIRTIO_VSOCKETS, and Python must be 3.7+.",
            file=sys.stderr,
        )
        return 1

    server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((VMADDR_CID_ANY, VSOCK_PORT))
    server.listen(16)
    print(f"guest agent listening on vsock port {VSOCK_PORT}", flush=True)

    os.makedirs(WORKSPACE, exist_ok=True)

    while True:
        try:
            conn, _ = server.accept()
        except KeyboardInterrupt:
            break
        except OSError as exc:
            print(f"accept failed: {exc}", file=sys.stderr, flush=True)
            continue
        # A thread per connection: connections are short-lived and one blocked
        # exec must not stall ping or file operations.
        threading.Thread(target=handle_connection, args=(conn,), daemon=True).start()

    return 0


if __name__ == "__main__":
    sys.exit(main())

# ---------------------------------------------------------------------------
# Install in the guest image:
#
#   sudo install -m 0755 guest-agent.py /usr/local/bin/guest-agent
#   sudo tee /etc/systemd/system/guest-agent.service <<'UNIT'
#   [Unit]
#   Description=AI computer guest agent (vsock)
#   After=multi-user.target
#
#   [Service]
#   Type=simple
#   # Unprivileged on purpose: host requests are agent-driven.
#   User=box
#   Environment=DISPLAY=:0
#   ExecStart=/usr/local/bin/guest-agent
#   Restart=always
#   RestartSec=2
#
#   [Install]
#   WantedBy=multi-user.target
#   UNIT
#   sudo systemctl enable guest-agent
#
# Verify from the host once the VM is up:
#   the Swift GuestAgentClient.ping() should return true within ~15s of boot.
# ---------------------------------------------------------------------------
