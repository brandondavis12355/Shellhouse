"""
Backend selection lives HERE, in the privileged service — not in the API.

This is deliberate. The API cannot choose its own isolation level, because
the API is the component being defended. Whoever operates the host decides
whether agents run in a container or a microVM, and the API just gets a
sandbox.

    SANDBOX_BACKEND=docker        # shared-kernel container (local default)
    SANDBOX_BACKEND=firecracker   # per-task microVM
"""
import os
from functools import lru_cache

from providers.base import SandboxProvider

BACKEND_NAME = os.environ.get("SANDBOX_BACKEND", "docker").lower()


@lru_cache(maxsize=1)
def get_backend() -> SandboxProvider:
    if BACKEND_NAME == "firecracker":
        from providers.firecracker_backend import FirecrackerBackend
        return FirecrackerBackend()
    if BACKEND_NAME == "docker":
        from providers.docker_backend import DockerBackend
        return DockerBackend()
    raise ValueError(
        f"Unknown SANDBOX_BACKEND '{BACKEND_NAME}'. Expected 'docker' or 'firecracker'."
    )
