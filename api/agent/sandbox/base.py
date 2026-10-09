"""
SandboxProvider
===============
The single abstraction that keeps the agent runtime from caring whether its
computer is a Docker container, a Firecracker microVM, or something else.

ADR-002 from the architecture doc: Docker is right for development,
Firecracker (or equivalent VM isolation) is right for hostile multi-tenant
workloads. Nothing above this interface should ever reference either.

On the API side this interface is implemented once, by ManagerSandboxProvider,
which forwards to the privileged Sandbox Manager over a unix socket. The
concrete Docker and Firecracker backends live in that service, not here — the
API process holds no host privilege at all. See docs/SECURITY.md.
"""
from dataclasses import dataclass, field
from typing import Protocol, Optional, runtime_checkable


@dataclass
class ExecResult:
    exit_code: int
    stdout: str
    stderr: str

    def to_dict(self) -> dict:
        return {"exit_code": self.exit_code, "stdout": self.stdout, "stderr": self.stderr}


@dataclass
class SandboxHandle:
    """Everything the rest of the system needs to know about one computer."""
    id: str
    provider: str                      # "docker" | "firecracker"
    workspace_host_path: str           # where the API can read/write its files
    display: str = ":1"                # X display the desktop runs on
    vnc_url: Optional[str] = None      # what the UI embeds to watch it
    ip_address: Optional[str] = None   # guest IP, for VM providers
    persistent: bool = False
    metadata: dict = field(default_factory=dict)


@runtime_checkable
class SandboxProvider(Protocol):
    """Lifecycle + execution contract for an agent computer."""

    name: str

    async def create(self, task_id: str, persistent: bool = False) -> SandboxHandle:
        """Provision a computer (or attach to a persistent one). Idempotent per task_id."""
        ...

    async def start(self, sandbox_id: str) -> SandboxHandle:
        ...

    async def exec(
        self,
        sandbox_id: str,
        command: str,
        timeout: int = 120,
        env: Optional[dict] = None,
    ) -> ExecResult:
        """
        Run a shell command inside the sandbox as the unprivileged desktop user.

        `env` carries secret values injected at execution time (see
        agent/secrets.py). Implementations must never log these values.
        """
        ...

    async def read_file(self, sandbox_id: str, path: str, max_bytes: int = 200_000) -> bytes:
        ...

    async def write_file(self, sandbox_id: str, path: str, content: bytes) -> None:
        ...

    async def pause(self, sandbox_id: str) -> None:
        ...

    async def resume(self, sandbox_id: str) -> None:
        ...

    async def destroy(self, sandbox_id: str) -> None:
        """Tear down. For ephemeral sandboxes this must reclaim all resources."""
        ...

    async def health(self, sandbox_id: str) -> bool:
        ...

    async def list_sandboxes(self) -> list["SandboxHandle"]:
        """Every sandbox currently running."""
        ...
