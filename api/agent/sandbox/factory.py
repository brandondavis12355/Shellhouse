"""
Provider selection (API side)
=============================
There is exactly one option here, and that is the point.

The API talks to sandboxes only through the Sandbox Manager's unix socket. It
does not get a Docker client, a KVM handle, or a choice about its own
isolation level — the host operator makes that call by setting
SANDBOX_BACKEND on the manager service.

If you are tempted to add a "local docker, skip the manager" branch back into
this file for convenience: that branch is exactly the thing that re-grants
the agent loop root-equivalent host access, and it will get used by accident.
Run the manager instead; it's one small container.
"""
from functools import lru_cache

from agent.sandbox.base import SandboxProvider


@lru_cache(maxsize=1)
def get_provider() -> SandboxProvider:
    from agent.sandbox.manager_provider import ManagerSandboxProvider
    return ManagerSandboxProvider()
