"""
Tool System
===========
Every tool the model can call is defined once here: a JSON schema (for the
model) plus a Python executor (for us). The model never touches the host —
all execution goes through the active SandboxProvider (Docker container or
Firecracker microVM), and file tools are scoped to that sandbox's /workspace.
"""
import asyncio
import concurrent.futures
import contextvars
import os
import re

import requests
from bs4 import BeautifulSoup

from agent.sandbox.factory import get_provider

WORKSPACE = "/workspace"

# The sandbox a tool call belongs to. Set by the agent runtime for the
# duration of one task, so concurrent tasks on different computers cannot
# accidentally act on each other's desktop. A contextvar is used rather than a
# module global precisely because there is no longer one shared sandbox.
_active_sandbox: contextvars.ContextVar = contextvars.ContextVar(
    "active_sandbox", default=None
)

# The task a tool call belongs to, so evidence is attributed correctly.
_current_task_id: contextvars.ContextVar = contextvars.ContextVar(
    "current_task_id", default=None
)


def set_active_sandbox(handle) -> None:
    """Called by AgentRuntime once the task's computer exists."""
    _active_sandbox.set(handle)


def set_current_task(task_id: str) -> None:
    _current_task_id.set(task_id)


def _sandbox():
    """The provider plus the handle for the sandbox this task owns."""
    handle = _active_sandbox.get()
    if handle is None:
        raise RuntimeError(
            "No sandbox bound to this task. AgentRuntime must call "
            "set_active_sandbox() before dispatching tools."
        )
    return get_provider(), handle


def _run_async(coro):
    """
    Tools are sync-callable; bridge to the provider's async API.

    The runtime dispatches tools from inside a running event loop, so a
    dedicated worker thread with its own loop is used rather than blocking the
    caller's. The executor is module-level so we are not building and tearing
    down a thread pool on every single tool call.
    """
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    return _EXECUTOR.submit(asyncio.run, coro).result()


_EXECUTOR = concurrent.futures.ThreadPoolExecutor(
    max_workers=int(os.environ.get("TOOL_WORKERS", "8")),
    thread_name_prefix="tool",
)


def _safe_rel(path: str) -> str:
    """
    Normalize to a path relative to the sandbox's /workspace, rejecting
    traversal. Returns a relative path because the API no longer touches the
    host filesystem — the manager resolves it inside the sandbox.
    """
    normalized = os.path.normpath("/" + path.lstrip("/"))
    if ".." in normalized.split("/"):
        raise ValueError("Path escapes workspace sandbox")
    return normalized.lstrip("/")


def _shq(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


# ---------------------------------------------------------------------------
# Tool executors
# ---------------------------------------------------------------------------

def tool_list_files(arguments: dict) -> dict:
    rel = _safe_rel(arguments.get("path", "."))
    res = tool_run_shell({"command": f"ls -1A {_shq(rel or '.')}", "timeout": 30})
    if res.get("exit_code") != 0:
        return {"error": f"No such path: {arguments.get('path', '.')}"}
    return {"entries": [line for line in res["stdout"].splitlines() if line]}


def tool_read_file(arguments: dict) -> dict:
    rel = _safe_rel(arguments["path"])
    provider, handle = _sandbox()
    try:
        data = _run_async(provider.read_file(handle.id, rel, max_bytes=200_000))
    except FileNotFoundError:
        return {"error": f"No such file: {arguments['path']}"}
    except Exception as exc:
        return {"error": str(exc)}
    return {"content": data.decode(errors="replace")}


def tool_write_file(arguments: dict) -> dict:
    rel = _safe_rel(arguments["path"])
    content = arguments.get("content", "")
    provider, handle = _sandbox()
    _run_async(provider.write_file(handle.id, rel, content.encode()))
    return {"written": rel, "bytes": len(content)}


def tool_run_shell(arguments: dict) -> dict:
    """
    Executes inside the agent's sandbox, via the Sandbox Manager. This
    process has no ability to run anything on the host; the manager will only
    dispatch into a sandbox it created itself.

    `use_secrets` names credentials to inject as environment variables for
    this one command. The values are fetched from the encrypted store and
    handed to the manager directly — they never enter the model's context,
    the command string, or the audit log. Any value that leaks back through
    stdout/stderr (e.g. `curl -v` echoing a header) is masked before the
    result is returned to the model.
    """
    command = arguments["command"]
    timeout = int(arguments.get("timeout", 120))
    requested = arguments.get("use_secrets") or []

    env: dict[str, str] = {}
    values_to_mask: list[str] = []
    if requested:
        from database import SessionLocal
        from agent import secrets as secret_store
        if secret_store.is_enabled():
            db = SessionLocal()
            try:
                env = secret_store.resolve_env(db, list(requested))
                values_to_mask = list(env.values())
            except Exception as exc:
                return {"error": f"Could not resolve secrets: {exc}"}
            finally:
                db.close()
        else:
            return {
                "error": "Secret storage is not configured (no SECRETS_KEY); "
                         "cannot inject the requested credentials."
            }

    provider, handle = _sandbox()
    result = _run_async(
        provider.exec(handle.id, command, timeout=timeout, env=env or None)
    )
    out = result.to_dict()

    if values_to_mask:
        from agent import secrets as secret_store
        out["stdout"] = secret_store.mask_values(out.get("stdout", ""), values_to_mask)
        out["stderr"] = secret_store.mask_values(out.get("stderr", ""), values_to_mask)
        out["injected_secrets"] = sorted(env.keys())
    return out


def tool_web_search(arguments: dict) -> dict:
    """Free, open-source DuckDuckGo search — no API key required."""
    from ddgs import DDGS

    query = arguments["query"]
    max_results = min(int(arguments.get("max_results", 5)), 10)
    results = []
    with DDGS() as ddgs:
        for r in ddgs.text(query, max_results=max_results):
            results.append({
                "title": r.get("title"),
                "url": r.get("href"),
                "snippet": r.get("body"),
            })
    return {"results": results}


def tool_fetch_url(arguments: dict) -> dict:
    """Fetch a page and extract readable text. Treated as UNTRUSTED DATA by the runtime,
    never as instructions — see agent/runtime.py."""
    url = arguments["url"]
    resp = requests.get(url, timeout=20, headers={"User-Agent": "local-agent/0.1"})
    resp.raise_for_status()
    soup = BeautifulSoup(resp.text, "html.parser")
    for tag in soup(["script", "style", "nav", "footer"]):
        tag.decompose()
    text = re.sub(r"\n{3,}", "\n\n", soup.get_text("\n"))
    return {"url": url, "status": resp.status_code, "text": text.strip()[:30_000]}


# ---------------------------------------------------------------------------
# Computer use: drive the sandbox's X desktop via xdotool / scrot
# ---------------------------------------------------------------------------

def _x_exec(command: str) -> dict:
    """Run a command inside the sandbox against the desktop's X display."""
    _, handle = _sandbox()
    return tool_run_shell({"command": f"DISPLAY={handle.display} {command}"})


def tool_screenshot(arguments: dict) -> dict:
    """Capture the desktop. Saved into /workspace so the API can serve it to the UI."""
    name = arguments.get("filename", "screenshot.png")
    if not name.endswith(".png"):
        name += ".png"
    name = os.path.basename(name)  # no path traversal via filename
    res = _x_exec(f"scrot -o -F /workspace/{name}")
    if res.get("exit_code") != 0:
        return {"error": res.get("stderr") or "screenshot failed"}
    size_res = tool_run_shell({"command": f"stat -c %s /workspace/{name}", "timeout": 15})
    try:
        size = int(size_res.get("stdout", "0").strip())
    except ValueError:
        size = 0
    return {
        "screenshot": name,
        "bytes": size,
        # The UI renders this path; the model just gets a confirmation.
        "view_url": f"/sandbox/file/{name}",
        "note": "Screenshot captured. Use list_windows or click/type to interact.",
    }


def tool_list_windows(arguments: dict) -> dict:
    """List open windows with geometry, so the agent can target them semantically."""
    res = _x_exec("wmctrl -lG")
    windows = []
    for line in (res.get("stdout") or "").splitlines():
        parts = line.split(None, 7)
        if len(parts) >= 8:
            windows.append({
                "id": parts[0],
                "x": int(parts[2]), "y": int(parts[3]),
                "width": int(parts[4]), "height": int(parts[5]),
                "title": parts[7],
            })
    return {"windows": windows}


def tool_focus_window(arguments: dict) -> dict:
    title = arguments["title"].replace('"', '')
    res = _x_exec(f'wmctrl -a "{title}"')
    if res.get("exit_code") != 0:
        return {"error": f"No window matching '{title}'"}
    return {"focused": title}


def tool_click(arguments: dict) -> dict:
    x = int(arguments["x"])
    y = int(arguments["y"])
    button = int(arguments.get("button", 1))
    res = _x_exec(f"xdotool mousemove {x} {y} click {button}")
    if res.get("exit_code") != 0:
        return {"error": res.get("stderr") or "click failed"}
    return {"clicked": {"x": x, "y": y, "button": button}}


def tool_type_text(arguments: dict) -> dict:
    text = arguments["text"]
    # Write via a file + xdotool --file to avoid shell-quoting hazards entirely
    payload_path = "/workspace/.type_buffer"
    provider, handle = _sandbox()
    _run_async(provider.write_file(handle.id, ".type_buffer", text.encode()))
    res = _x_exec(f"xdotool type --delay 20 --file {payload_path}")
    if res.get("exit_code") != 0:
        return {"error": res.get("stderr") or "type failed"}
    return {"typed_chars": len(text)}


def tool_press_key(arguments: dict) -> dict:
    """Press a key or chord, e.g. 'Return', 'ctrl+c', 'alt+Tab', 'super'."""
    key = arguments["key"]
    if not re.fullmatch(r"[A-Za-z0-9_+\-]+", key):
        return {"error": "Invalid key spec"}
    res = _x_exec(f"xdotool key {key}")
    if res.get("exit_code") != 0:
        return {"error": res.get("stderr") or "key press failed"}
    return {"pressed": key}


def tool_open_app(arguments: dict) -> dict:
    """Launch one of the desktop apps available on the agent's computer."""
    app = arguments["app"]
    launchers = {
        "browser": "chromium --no-sandbox --disable-dev-shm-usage --new-window",
        "chromium": "chromium --no-sandbox --disable-dev-shm-usage --new-window",
        "terminal": "xfce4-terminal --working-directory=/workspace",
        "files": "thunar /workspace",
        "thunar": "thunar /workspace",
    }
    if app not in launchers:
        return {"error": f"Unknown app '{app}'. Options: browser, terminal, files"}
    url = arguments.get("url", "")
    cmd = launchers[app]
    if url and app in ("browser", "chromium"):
        if not url.startswith(("http://", "https://")):
            return {"error": "url must start with http:// or https://"}
        cmd += f" '{url}'"
    _x_exec(f"nohup {cmd} >/dev/null 2>&1 &")
    return {"launched": app, "url": url or None}


TOOL_EXECUTORS = {
    "list_files": tool_list_files,
    "read_file": tool_read_file,
    "write_file": tool_write_file,
    "run_shell": tool_run_shell,
    "web_search": tool_web_search,
    "fetch_url": tool_fetch_url,
    # computer use
    "screenshot": tool_screenshot,
    "list_windows": tool_list_windows,
    "focus_window": tool_focus_window,
    "click": tool_click,
    "type_text": tool_type_text,
    "press_key": tool_press_key,
    "open_app": tool_open_app,
}

# ---------------------------------------------------------------------------
# Tool schemas exposed to the model (Ollama/OpenAI-style function schema)
# ---------------------------------------------------------------------------

TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": "list_files",
            "description": "List files/directories inside the sandbox workspace.",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string", "description": "Relative path, default '.'"}},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a text file from the sandbox workspace.",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write/overwrite a text file in the sandbox workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_shell",
            "description": (
                "Run a shell command inside your isolated sandbox. Requires "
                "user approval. To use a credential, reference it as $NAME in "
                "the command and list the name in use_secrets; you will never "
                "see its value."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string"},
                    "timeout": {"type": "integer", "description": "Seconds, default 120"},
                    "use_secrets": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Names from list_secrets to inject as env vars",
                    },
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the web (DuckDuckGo) and return titles/urls/snippets.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "max_results": {"type": "integer"},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "fetch_url",
            "description": "Fetch a URL and return its readable text content.",
            "parameters": {
                "type": "object",
                "properties": {"url": {"type": "string"}},
                "required": ["url"],
            },
        },
    },
    # --- computer use: the graphical desktop --------------------------------
    {
        "type": "function",
        "function": {
            "name": "screenshot",
            "description": "Capture the current state of your desktop as a PNG. Use this to see what is on screen before clicking.",
            "parameters": {
                "type": "object",
                "properties": {"filename": {"type": "string", "description": "Optional output name, default screenshot.png"}},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_windows",
            "description": "List open desktop windows with their titles and on-screen geometry. Prefer this over guessing coordinates.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "focus_window",
            "description": "Bring a window to the front by (partial) title match.",
            "parameters": {
                "type": "object",
                "properties": {"title": {"type": "string"}},
                "required": ["title"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "open_app",
            "description": "Launch a desktop application: 'browser' (Chromium, optionally at a url), 'terminal', or 'files' (Thunar).",
            "parameters": {
                "type": "object",
                "properties": {
                    "app": {"type": "string", "enum": ["browser", "terminal", "files"]},
                    "url": {"type": "string", "description": "Only for app=browser"},
                },
                "required": ["app"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "click",
            "description": "Move the mouse to absolute screen coordinates and click. Take a screenshot first to find the target.",
            "parameters": {
                "type": "object",
                "properties": {
                    "x": {"type": "integer"},
                    "y": {"type": "integer"},
                    "button": {"type": "integer", "description": "1=left, 2=middle, 3=right"},
                },
                "required": ["x", "y"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "type_text",
            "description": "Type text into the currently focused window.",
            "parameters": {
                "type": "object",
                "properties": {"text": {"type": "string"}},
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "press_key",
            "description": "Press a key or chord, e.g. 'Return', 'Tab', 'ctrl+c', 'alt+Tab'.",
            "parameters": {
                "type": "object",
                "properties": {"key": {"type": "string"}},
                "required": ["key"],
            },
        },
    },
]


# ---------------------------------------------------------------------------
# Memory tools (Phase 4)
# ---------------------------------------------------------------------------

def tool_save_evidence(arguments: dict) -> dict:
    """
    Record a normalized finding with provenance. This is how the agent builds
    a citable trail rather than a pile of page text.
    """
    from agent.memory.evidence import Evidence, Relationship
    from agent.memory.store import get_store

    try:
        rels = [
            Relationship(type=r["type"], target=r["target"])
            for r in (arguments.get("relationships") or [])
        ]
        evidence = Evidence(
            finding=arguments["finding"],
            source=arguments.get("source", "model"),
            subject=arguments.get("subject"),
            confidence=float(arguments.get("confidence", 0.8)),
            task_id=_current_task_id.get(),
            original_reference=arguments.get("original_reference") or {},
            relationships=rels,
            tags=arguments.get("tags") or [],
        )
    except (KeyError, ValueError) as exc:
        return {"error": f"Invalid evidence: {exc}"}

    try:
        _run_async(get_store().add_evidence([evidence]))
    except Exception as exc:
        return {"error": f"Could not store evidence: {exc}"}
    return {"evidence_id": evidence.id, "stored": True}


def tool_search_memory(arguments: dict) -> dict:
    """Semantic recall across evidence, user memory, and knowledge."""
    from agent.memory.store import get_store

    query = arguments.get("query", "").strip()
    if not query:
        return {"error": "query is required"}
    try:
        hits = _run_async(get_store().search(
            query=query,
            limit=int(arguments.get("limit", 6)),
            subject=arguments.get("subject"),
            min_confidence=float(arguments.get("min_confidence", 0.0)),
            task_id=arguments.get("task_id"),
        ))
    except Exception as exc:
        return {"error": f"Memory search failed: {exc}"}

    return {
        "results": [
            {
                "evidence_id": h.get("evidence_id"),
                "finding": h.get("finding"),
                "subject": h.get("subject"),
                "confidence": h.get("confidence"),
                "timestamp": h.get("timestamp"),
                "reference": h.get("original_reference"),
                "score": round(h.get("rerank_score", 0), 4),
            }
            for h in hits
        ]
    }


def tool_remember(arguments: dict) -> dict:
    """
    Store a durable user preference or fact.

    Requires approval by policy: the user should decide what becomes permanent
    memory, rather than every passing statement being retained.
    """
    from agent.memory.store import get_store

    text = arguments.get("text", "").strip()
    if not text:
        return {"error": "text is required"}
    try:
        mem_id = _run_async(get_store().add_user_memory(text, arguments.get("tags")))
    except Exception as exc:
        return {"error": f"Could not store memory: {exc}"}
    return {"memory_id": mem_id, "stored": True}


# ---------------------------------------------------------------------------
# Secrets (Phase 5) — names only, never values
# ---------------------------------------------------------------------------

def tool_list_secrets(arguments: dict) -> dict:
    """
    Tell the agent which credentials EXIST. There is deliberately no tool that
    returns a value: such a tool's output would land in the model's context by
    definition. To use a credential, reference it as $NAME in a run_shell
    command and list it in `use_secrets` — the value is injected as an
    environment variable at execution time.
    """
    from database import SessionLocal
    from agent import secrets as secret_store

    if not secret_store.is_enabled():
        return {"secrets": [], "note": "Secret storage is not configured (no SECRETS_KEY)."}
    db = SessionLocal()
    try:
        names = secret_store.list_secret_names(db)
    finally:
        db.close()
    return {
        "secrets": names,
        "usage": (
            "Reference a secret as $NAME inside a run_shell command and pass "
            "its name in use_secrets. Never ask for or echo the value."
        ),
    }


# ---------------------------------------------------------------------------
# MCP (Phase 6)
# ---------------------------------------------------------------------------

def tool_mcp_dispatch(tool_name: str, arguments: dict) -> dict:
    """Route an mcp__server__tool call to the MCP client."""
    from agent.mcp.client import get_client
    return _run_async(get_client().call(tool_name, arguments))


MEMORY_TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": "save_evidence",
            "description": (
                "Record a specific finding with its source, so it can be cited "
                "and recalled later. Use this for each discrete fact you learn "
                "(a price, a version, a policy), not for whole pages."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "finding": {"type": "string", "description": "The claim, in one sentence"},
                    "subject": {"type": "string", "description": "What it is about"},
                    "source": {
                        "type": "string",
                        "enum": ["browser", "web_search", "fetch_url", "shell", "file", "user", "model"],
                    },
                    "confidence": {"type": "number", "description": "0..1"},
                    "original_reference": {
                        "type": "object",
                        "description": "Provenance, e.g. {\"url\": \"...\", \"page\": 4}",
                    },
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "relationships": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "type": {
                                    "type": "string",
                                    "enum": ["supports", "contradicts", "refines",
                                             "supersedes", "relates_to"],
                                },
                                "target": {"type": "string", "description": "another evidence_id"},
                            },
                        },
                    },
                },
                "required": ["finding"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_memory",
            "description": (
                "Recall previously stored findings, documents, and user "
                "preferences by meaning. Check this before researching "
                "something you may already know."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "subject": {"type": "string"},
                    "limit": {"type": "integer"},
                    "min_confidence": {"type": "number"},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "remember",
            "description": (
                "Store a durable fact or preference about the user. Requires "
                "their approval. Use only for things worth keeping across "
                "tasks, not for task-specific findings (use save_evidence)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "tags": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_secrets",
            "description": (
                "List which credentials are available by NAME. Values are "
                "never returned. To use one, reference $NAME in a run_shell "
                "command and name it in use_secrets."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
    },
]

TOOL_EXECUTORS.update({
    "save_evidence": tool_save_evidence,
    "search_memory": tool_search_memory,
    "remember": tool_remember,
    "list_secrets": tool_list_secrets,
})

TOOL_SCHEMAS.extend(MEMORY_TOOL_SCHEMAS)
