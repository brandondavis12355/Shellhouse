"""
Policy Engine
=============
Every tool call is classified before it executes. This is the enforceable
security boundary between "the model decided to do X" and "X actually ran."
"""

ALLOW = "ALLOW"
REQUIRE_APPROVAL = "REQUIRE_APPROVAL"
DENY = "DENY"

# Default policy table (mirrors the architecture doc's permission table).
DEFAULT_POLICY = {
    # read-only / low risk
    "list_files": ALLOW,
    "read_file": ALLOW,
    "write_file": ALLOW,
    "web_search": ALLOW,
    "fetch_url": ALLOW,

    # Computer use: observing the desktop is free, and acting on it is allowed
    # because it is confined to the sandbox VM's own GUI. Tighten any of these
    # to REQUIRE_APPROVAL if you ever log the agent into real accounts.
    "screenshot": ALLOW,
    "list_windows": ALLOW,
    "focus_window": ALLOW,
    "open_app": ALLOW,
    "click": ALLOW,
    "type_text": ALLOW,
    "press_key": ALLOW,

    # Memory: recording and recalling task findings is routine. Writing a
    # DURABLE user memory is not — the user decides what is kept about them.
    "save_evidence": ALLOW,
    "search_memory": ALLOW,
    "remember": REQUIRE_APPROVAL,

    # Credential NAMES are safe to reveal; there is no tool that returns a value.
    "list_secrets": ALLOW,

    # Arbitrary command execution always pauses for a human.
    "run_shell": REQUIRE_APPROVAL,
}


def evaluate(tool_name: str) -> str:
    """
    Classify a tool call.

    MCP tools are namespaced `mcp__<server>__<tool>` and are handled
    separately, because a third-party server's tool is remote code execution
    with your credentials attached. They default to REQUIRE_APPROVAL. A server
    explicitly marked `trusted` in the MCP config may run its read-only-looking
    tools without approval — that is an operator decision, not a default, and
    the read-only test is name-based and conservative.
    """
    if tool_name.startswith("mcp__"):
        return _evaluate_mcp(tool_name)
    return DEFAULT_POLICY.get(tool_name, REQUIRE_APPROVAL)  # unknown tool -> ask a human


def _evaluate_mcp(tool_name: str) -> str:
    try:
        from agent.mcp.client import get_client
        client = get_client()
        tool = client.tools.get(tool_name)
        if tool is None:
            return DENY  # not a tool we discovered; don't call it
        server = client.servers.get(tool.server)
        if server is None or not server.enabled:
            return DENY
        if server.trusted and client.is_read_only_hint(tool_name):
            return ALLOW
        return REQUIRE_APPROVAL
    except Exception:
        # If the MCP layer can't be consulted, err toward asking the human.
        return REQUIRE_APPROVAL
