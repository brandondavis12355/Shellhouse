"""
MCP Client (Phase 6)
====================
Model Context Protocol lets users connect external systems (GitHub, Jira,
Slack, their own servers) without rebuilding the agent. Tools are discovered
at runtime from each configured server and merged into the agent's tool list
with a namespaced name: `mcp__<server>__<tool>`.

Security posture, which matters more here than anywhere else in the codebase:

> "Do not blindly trust third-party MCP servers. Treat them as executable
> integrations with explicit permissions."

Concretely:

1. **Servers are opt-in via config**, never auto-discovered from the network.
2. **Every MCP tool defaults to REQUIRE_APPROVAL.** A third-party server's
   tool is remote code execution with your credentials attached; it does not
   get the same standing as a local `read_file`. A server can be marked
   `trusted: true` in config to allow its read-only tools, and that is a
   deliberate choice the operator makes, not a default.
3. **Tool descriptions from a server are untrusted data.** A malicious server
   can write "ignore your instructions" into a tool description, which lands
   straight in the model's context. Descriptions are length-capped and
   prefixed with a provenance marker so the model sees where they came from.
4. **Credentials go in headers from the local config**, never through the
   model.
5. **Results are treated as untrusted content**, exactly like a fetched web
   page.

Transport: HTTP POST with JSON-RPC 2.0, which covers the "streamable HTTP"
servers this is most likely to meet. stdio servers would need a subprocess
transport; that is noted as unimplemented rather than faked.
"""
import asyncio
import json
import logging
import os
from dataclasses import dataclass, field
from typing import Any, Optional

import httpx

logger = logging.getLogger("mcp")

MCP_CONFIG_PATH = os.environ.get("MCP_CONFIG_PATH", "/data/mcp_servers.json")
MCP_TIMEOUT = float(os.environ.get("MCP_TIMEOUT_SECONDS", "60"))
MAX_DESCRIPTION_CHARS = 400
MAX_RESULT_CHARS = 20_000
PROTOCOL_VERSION = "2025-06-18"


@dataclass
class MCPServer:
    name: str                       # short slug used in the tool namespace
    url: str
    headers: dict[str, str] = field(default_factory=dict)
    trusted: bool = False           # allow read-only tools without approval
    enabled: bool = True
    description: str = ""


@dataclass
class MCPTool:
    server: str
    name: str                       # the tool's own name on the server
    description: str
    input_schema: dict

    @property
    def qualified_name(self) -> str:
        return f"mcp__{self.server}__{self.name}"


class MCPClient:
    """One client for all configured servers."""

    def __init__(self, config_path: str = MCP_CONFIG_PATH):
        self.config_path = config_path
        self.servers: dict[str, MCPServer] = {}
        self.tools: dict[str, MCPTool] = {}     # qualified_name -> tool
        self._sessions: dict[str, str] = {}     # server -> session id
        self._request_id = 0

    # -- config --------------------------------------------------------------

    def load_config(self) -> None:
        """
        Read the server list. Absent config means no MCP, which is a valid and
        safe state — not an error.
        """
        if not os.path.exists(self.config_path):
            logger.info("No MCP config at %s; MCP disabled", self.config_path)
            self.servers = {}
            return
        try:
            with open(self.config_path) as f:
                raw = json.load(f)
        except (json.JSONDecodeError, OSError) as exc:
            logger.error("Could not read MCP config: %s", exc)
            return

        servers = {}
        for entry in raw.get("servers", []):
            try:
                name = str(entry["name"]).strip()
                if not name.replace("_", "").replace("-", "").isalnum():
                    logger.warning("Skipping MCP server with unsafe name: %r", name)
                    continue
                servers[name] = MCPServer(
                    name=name,
                    url=entry["url"],
                    headers=entry.get("headers", {}) or {},
                    trusted=bool(entry.get("trusted", False)),
                    enabled=bool(entry.get("enabled", True)),
                    description=entry.get("description", ""),
                )
            except KeyError as exc:
                logger.warning("Skipping malformed MCP server entry: missing %s", exc)
        self.servers = servers
        logger.info("Loaded %d MCP server(s)", len(servers))

    # -- JSON-RPC ------------------------------------------------------------

    def _next_id(self) -> int:
        self._request_id += 1
        return self._request_id

    async def _rpc(
        self, server: MCPServer, method: str, params: Optional[dict] = None
    ) -> dict:
        payload = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": method,
            "params": params or {},
        }
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            **server.headers,
        }
        session = self._sessions.get(server.name)
        if session:
            headers["Mcp-Session-Id"] = session

        async with httpx.AsyncClient(timeout=MCP_TIMEOUT) as client:
            resp = await client.post(server.url, json=payload, headers=headers)
            resp.raise_for_status()

            new_session = resp.headers.get("Mcp-Session-Id")
            if new_session:
                self._sessions[server.name] = new_session

            body = resp.text.strip()

        # Streamable-HTTP servers may answer with SSE framing even for a
        # single response, so handle both shapes.
        if body.startswith("event:") or body.startswith("data:"):
            for line in body.splitlines():
                if line.startswith("data:"):
                    body = line[5:].strip()
                    break

        try:
            data = json.loads(body)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"MCP server {server.name} returned non-JSON: {exc}")

        if "error" in data:
            err = data["error"]
            raise RuntimeError(
                f"MCP {server.name}.{method} error "
                f"{err.get('code')}: {err.get('message')}"
            )
        return data.get("result", {})

    # -- lifecycle -----------------------------------------------------------

    async def initialize(self, server: MCPServer) -> None:
        await self._rpc(server, "initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "local-ai-computer", "version": "0.1"},
        })
        # The spec expects this notification after a successful initialize.
        try:
            await self._rpc(server, "notifications/initialized")
        except Exception:
            pass  # not all servers implement it; not fatal

    async def discover(self) -> dict[str, MCPTool]:
        """
        Connect to every enabled server and list its tools. One unreachable
        server must not take the others down, so failures are logged per
        server and discovery continues.
        """
        self.load_config()
        discovered: dict[str, MCPTool] = {}

        for server in self.servers.values():
            if not server.enabled:
                continue
            try:
                await self.initialize(server)
                result = await self._rpc(server, "tools/list")
            except Exception as exc:
                logger.warning("MCP server %s unavailable: %s", server.name, exc)
                continue

            for entry in result.get("tools", []):
                name = entry.get("name")
                if not name:
                    continue
                # A server-supplied description reaches the model's context.
                # Cap it and mark its provenance so the model can weigh it as
                # third-party text rather than as system instruction.
                raw_desc = str(entry.get("description", ""))[:MAX_DESCRIPTION_CHARS]
                tool = MCPTool(
                    server=server.name,
                    name=name,
                    description=f"[via MCP server '{server.name}'] {raw_desc}",
                    input_schema=entry.get("inputSchema") or {"type": "object",
                                                              "properties": {}},
                )
                discovered[tool.qualified_name] = tool

            logger.info(
                "MCP %s: %d tool(s)",
                server.name,
                sum(1 for t in discovered.values() if t.server == server.name),
            )

        self.tools = discovered
        return discovered

    async def call(self, qualified_name: str, arguments: dict) -> dict:
        tool = self.tools.get(qualified_name)
        if tool is None:
            return {"error": f"Unknown MCP tool '{qualified_name}'"}
        server = self.servers.get(tool.server)
        if server is None or not server.enabled:
            return {"error": f"MCP server '{tool.server}' is not available"}

        try:
            result = await self._rpc(server, "tools/call", {
                "name": tool.name,
                "arguments": arguments,
            })
        except Exception as exc:
            return {"error": f"MCP call failed: {exc}"}

        # Flatten MCP content blocks into text the model can read.
        chunks: list[str] = []
        for block in result.get("content", []):
            if block.get("type") == "text":
                chunks.append(block.get("text", ""))
            elif block.get("type") == "resource":
                res = block.get("resource", {})
                chunks.append(f"[resource {res.get('uri', '')}] {res.get('text', '')}")
            else:
                chunks.append(f"[{block.get('type')} content omitted]")

        text = "\n".join(chunks)[:MAX_RESULT_CHARS]
        return {
            "server": tool.server,
            "tool": tool.name,
            "is_error": bool(result.get("isError")),
            # Named `untrusted_content` on purpose: this text came from a
            # third party and is data, not instructions.
            "untrusted_content": text,
        }

    # -- schema export -------------------------------------------------------

    def tool_schemas(self) -> list[dict]:
        """MCP tools in the same function-schema shape as the built-in tools."""
        return [
            {
                "type": "function",
                "function": {
                    "name": tool.qualified_name,
                    "description": tool.description,
                    "parameters": tool.input_schema,
                },
            }
            for tool in self.tools.values()
        ]

    def is_read_only_hint(self, qualified_name: str) -> bool:
        """
        Heuristic used only to decide whether a *trusted* server's tool can
        skip approval. Name-based and deliberately conservative: anything not
        obviously a read is treated as a write.
        """
        tool = self.tools.get(qualified_name)
        if tool is None:
            return False
        name = tool.name.lower()
        read_prefixes = ("get", "list", "search", "read", "fetch", "query", "describe")
        write_markers = ("create", "update", "delete", "remove", "send", "post",
                         "write", "set", "add", "merge", "close", "deploy", "pay")
        if any(marker in name for marker in write_markers):
            return False
        return name.startswith(read_prefixes)


_client: Optional[MCPClient] = None


def get_client() -> MCPClient:
    global _client
    if _client is None:
        _client = MCPClient()
    return _client
