"""
SandboxProvider
===============
The single abstraction that keeps the agent runtime from caring whether its
computer is a Docker container, a Firecracker microVM, or something else.

ADR-002 from the architecture doc: Docker is right for development,
Firecracker (or equivalent VM isolation) is right for hostile multi-tenant
workloads. Nothing above this interface should ever reference either.
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

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "provider": self.provider,
            "workspace_host_path": self.workspace_host_path,
            "display": self.display,
            "vnc_url": self.vnc_url,
            "ip_address": self.ip_address,
            "persistent": self.persistent,
            "metadata": self.metadata,
        }


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

    async def destroy(self, sandbox_id: str, force: bool = False) -> None:
        """Tear down. For ephemeral sandboxes this must reclaim all resources.

        `force`: destroy even a persistent (per-task) sandbox that would
        otherwise survive this call — the explicit "delete this bot's
        computer" action, not routine cleanup.
        """
        ...

    async def health(self, sandbox_id: str) -> bool:
        ...

    async def reconcile(self) -> list[SandboxHandle]:
        """
        Adopt sandboxes that already exist on the host from a previous run of
        the manager, and reap ones that are unusable. Called at startup so
        containers/VMs are never leaked by a manager restart.
        """
        ...

    async def list_sandboxes(self) -> list[SandboxHandle]:
        """Every sandbox currently running under this backend."""
        ...
