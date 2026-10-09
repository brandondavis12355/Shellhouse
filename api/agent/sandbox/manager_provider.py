"""
ManagerSandboxProvider
======================
The API's only route to a sandbox: an HTTP client speaking to the Sandbox
Manager over a unix domain socket.

This module holds no host privilege. It cannot start a container, touch
/dev/kvm, create a network device, or read a path outside the sandbox — it can
only ask the manager, which validates every request against its own registry.

If this file is the most trusted thing an attacker reaches after compromising
the agent loop, the blast radius is "can run commands in the sandbox it was
already allowed to run commands in."
"""
import base64
import os
from typing import Optional

import httpx

from agent.sandbox.base import SandboxProvider, SandboxHandle, ExecResult

MANAGER_SOCKET = os.environ.get("MANAGER_SOCKET", "/run/sandbox-manager/manager.sock")
MANAGER_TOKEN = os.environ.get("MANAGER_TOKEN", "")
REQUEST_TIMEOUT = float(os.environ.get("MANAGER_TIMEOUT", "960"))


class ManagerSandboxProvider:
    name = "manager"

    def _client(self) -> httpx.AsyncClient:
        # uds= means every request goes over the unix socket. There is no
        # hostname or port involved, so this client cannot be repointed at a
        # network target by manipulating an env var alone.
        transport = httpx.AsyncHTTPTransport(uds=MANAGER_SOCKET)
        return httpx.AsyncClient(
            transport=transport,
            base_url="http://sandbox-manager",
            timeout=REQUEST_TIMEOUT,
            headers={"X-Manager-Token": MANAGER_TOKEN},
        )

    async def _post(self, path: str, body: dict) -> dict:
        try:
            async with self._client() as client:
                resp = await client.post(path, json=body)
        except (httpx.ConnectError, FileNotFoundError) as exc:
            raise RuntimeError(
                f"Cannot reach the Sandbox Manager at {MANAGER_SOCKET}. "
                f"Is the sandbox-manager service running? ({exc})"
            ) from exc
        if resp.status_code == 401:
            raise RuntimeError(
                "Sandbox Manager rejected our token. MANAGER_TOKEN must match "
                "between the api and sandbox-manager services."
            )
        if resp.status_code >= 400:
            raise RuntimeError(f"Sandbox Manager {path} failed ({resp.status_code}): {resp.text}")
        return resp.json()

    @staticmethod
    def _handle(data: dict) -> SandboxHandle:
        return SandboxHandle(
            id=data["id"],
            provider=data.get("provider", "unknown"),
            workspace_host_path=data.get("workspace_host_path", "/workspace"),
            display=data.get("display", ":1"),
            vnc_url=data.get("vnc_url"),
            ip_address=data.get("ip_address"),
            persistent=data.get("persistent", False),
            metadata=data.get("metadata", {}),
        )

    async def create(self, task_id: str, persistent: bool = False) -> SandboxHandle:
        data = await self._post("/v1/create", {"task_id": task_id, "persistent": persistent})
        return self._handle(data)

    async def start(self, sandbox_id: str) -> SandboxHandle:
        return self._handle(await self._post("/v1/start", {"sandbox_id": sandbox_id}))

    async def exec(
        self,
        sandbox_id: str,
        command: str,
        timeout: int = 120,
        env: Optional[dict] = None,
    ) -> ExecResult:
        data = await self._post("/v1/exec", {
            "sandbox_id": sandbox_id,
            "command": command,
            "timeout": timeout,
            "env": env or {},
        })
        return ExecResult(
            exit_code=data.get("exit_code", 1),
            stdout=data.get("stdout", ""),
            stderr=data.get("stderr", ""),
        )

    async def read_file(self, sandbox_id: str, path: str, max_bytes: int = 200_000) -> bytes:
        data = await self._post("/v1/read_file", {"sandbox_id": sandbox_id, "path": path})
        return base64.b64decode(data["content_b64"])[:max_bytes]

    async def write_file(self, sandbox_id: str, path: str, content: bytes) -> None:
        await self._post("/v1/write_file", {
            "sandbox_id": sandbox_id,
            "path": path,
            "content_b64": base64.b64encode(content).decode(),
        })

    async def pause(self, sandbox_id: str) -> None:
        await self._post("/v1/pause", {"sandbox_id": sandbox_id})

    async def resume(self, sandbox_id: str) -> None:
        await self._post("/v1/resume", {"sandbox_id": sandbox_id})

    async def destroy(self, sandbox_id: str) -> None:
        await self._post("/v1/destroy", {"sandbox_id": sandbox_id})

    async def list_sandboxes(self) -> list[SandboxHandle]:
        data = await self._post("/v1/list", {})
        return [self._handle(item) for item in data.get("sandboxes", [])]

    async def health(self, sandbox_id: str) -> bool:
        try:
            return (await self._post("/v1/health", {"sandbox_id": sandbox_id})).get("ok", False)
        except RuntimeError:
            return False


assert isinstance(ManagerSandboxProvider(), SandboxProvider)
