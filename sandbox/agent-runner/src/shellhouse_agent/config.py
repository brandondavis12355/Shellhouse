"""Strict validation of config.json. Never evaluates anything from the config."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlparse

MAX_CONFIG_BYTES = 4 * 1024 * 1024

IN_SANDBOX_TOOL_NAMES = (
    "run_shell",
    "read_file",
    "write_file",
    "list_files",
    "screenshot",
    "list_windows",
    "focus_window",
    "open_app",
    "click",
    "type_text",
    "press_key",
    "scroll",
)

_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
_RUN_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_ENV_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,127}$")
_JSON_TYPES = {"string", "integer", "number", "boolean", "array", "object"}

_TOP_REQUIRED = {
    "protocol", "run_id", "model", "system_prompt", "history", "task", "max_steps",
    "planning_interval", "tainted", "workspace", "policy_free", "bridge_tools",
    "in_sandbox_tools", "env",
}
# Additive optional keys (documented in PROTOCOL.md).
_TOP_OPTIONAL = {"rpc_timeout_s", "vision"}
_MODEL_KEYS = {"base_url", "api_key", "model_id", "temperature"}


class ConfigError(ValueError):
    pass


@dataclass
class BridgeTool:
    name: str
    description: str
    properties: dict[str, dict[str, Any]]
    required: list[str]


@dataclass
class Config:
    run_id: str
    base_url: str
    api_key: str
    model_id: str
    temperature: float | None
    system_prompt: str
    history: list[dict[str, str]]
    task: str
    max_steps: int
    planning_interval: int | None
    tainted: bool
    workspace: str
    policy_free: set[str]
    bridge_tools: list[BridgeTool]
    in_sandbox_tools: list[str]
    env: dict[str, str]
    rpc_timeout_s: float = 1800.0
    vision: bool = False
    secrets: list[str] = field(default_factory=list)


def _req(cond: bool, msg: str) -> None:
    if not cond:
        raise ConfigError(msg)


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _is_num(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def parse_config(raw: Any, expected_run_id: str | None = None) -> Config:
    _req(isinstance(raw, dict), "config must be a JSON object")
    keys = set(raw)
    _req(raw.get("protocol") == 1 and not isinstance(raw.get("protocol"), bool),
         f"unsupported protocol version: {raw.get('protocol')!r} (this runner speaks 1)")
    missing = _TOP_REQUIRED - keys
    _req(not missing, f"missing keys: {sorted(missing)}")
    unknown = keys - _TOP_REQUIRED - _TOP_OPTIONAL
    _req(not unknown, f"unknown keys: {sorted(unknown)}")

    run_id = raw["run_id"]
    _req(isinstance(run_id, str) and _RUN_ID.match(run_id) is not None, "run_id must match [A-Za-z0-9_-]{1,64}")
    if expected_run_id is not None:
        _req(run_id == expected_run_id, "run_id does not match the run directory name")

    m = raw["model"]
    _req(isinstance(m, dict), "model must be an object")
    _req(set(m) == _MODEL_KEYS, f"model keys must be exactly {sorted(_MODEL_KEYS)}")
    _req(isinstance(m["base_url"], str), "model.base_url must be a string")
    u = urlparse(m["base_url"])
    _req(u.scheme in ("http", "https") and bool(u.hostname), "model.base_url must be an http(s) URL")
    _req(isinstance(m["api_key"], str), "model.api_key must be a string")
    _req(isinstance(m["model_id"], str) and 0 < len(m["model_id"]) <= 256, "model.model_id must be a non-empty string")
    t = m["temperature"]
    _req(t is None or (_is_num(t) and 0 <= t <= 2), "model.temperature must be null or a number in [0, 2]")

    _req(isinstance(raw["system_prompt"], str), "system_prompt must be a string")
    _req(isinstance(raw["task"], str) and raw["task"].strip() != "", "task must be a non-empty string")

    hist = raw["history"]
    _req(isinstance(hist, list), "history must be an array")
    for i, h in enumerate(hist):
        _req(isinstance(h, dict) and set(h) == {"role", "content"}, f"history[{i}] must be {{role, content}}")
        _req(h["role"] in ("user", "assistant"), f"history[{i}].role must be user|assistant")
        _req(isinstance(h["content"], str), f"history[{i}].content must be a string")

    ms = raw["max_steps"]
    _req(_is_int(ms) and 1 <= ms <= 500, "max_steps must be an integer in [1, 500]")
    pi = raw["planning_interval"]
    _req(pi is None or (_is_int(pi) and 1 <= pi <= 500), "planning_interval must be null or an integer >= 1")
    _req(isinstance(raw["tainted"], bool), "tainted must be a boolean")
    ws = raw["workspace"]
    _req(isinstance(ws, str) and os.path.isabs(ws) and "\0" not in ws, "workspace must be an absolute path")

    pf = raw["policy_free"]
    _req(isinstance(pf, list) and all(isinstance(x, str) for x in pf), "policy_free must be an array of strings")

    ist = raw["in_sandbox_tools"]
    _req(isinstance(ist, list) and all(isinstance(x, str) for x in ist), "in_sandbox_tools must be an array of strings")
    for n in ist:
        _req(n in IN_SANDBOX_TOOL_NAMES, f"unknown in-sandbox tool: {n!r}")
    _req(len(set(ist)) == len(ist), "in_sandbox_tools has duplicates")

    bt = raw["bridge_tools"]
    _req(isinstance(bt, list), "bridge_tools must be an array")
    bridge: list[BridgeTool] = []
    seen = set(ist)
    for i, b in enumerate(bt):
        _req(isinstance(b, dict) and set(b) == {"name", "description", "parameters"}, f"bridge_tools[{i}] must be {{name, description, parameters}}")
        name = b["name"]
        _req(isinstance(name, str) and _IDENT.match(name) is not None, f"bridge_tools[{i}].name must be an identifier")
        _req(name != "final_answer" and name not in seen, f"bridge tool name {name!r} collides with another tool")
        seen.add(name)
        _req(isinstance(b["description"], str), f"bridge_tools[{i}].description must be a string")
        p = b["parameters"]
        _req(isinstance(p, dict), f"bridge_tools[{i}].parameters must be a JSON-schema object")
        props = p.get("properties", {})
        _req(isinstance(props, dict), f"bridge_tools[{i}].parameters.properties must be an object")
        req = p.get("required", [])
        _req(isinstance(req, list) and all(isinstance(x, str) for x in req), f"bridge_tools[{i}].parameters.required must be string[]")
        norm: dict[str, dict[str, Any]] = {}
        for pname, pschema in props.items():
            _req(isinstance(pname, str) and _IDENT.match(pname) is not None, f"bridge tool {name}: bad parameter name {pname!r}")
            _req(isinstance(pschema, dict), f"bridge tool {name}.{pname}: schema must be an object")
            ty = pschema.get("type", "any")
            if isinstance(ty, str) and ty in _JSON_TYPES:
                st = ty
            else:
                st = "any"
            desc = pschema.get("description", "")
            _req(isinstance(desc, str), f"bridge tool {name}.{pname}: description must be a string")
            if "enum" in pschema and isinstance(pschema["enum"], list):
                desc = (desc + f" One of: {', '.join(map(str, pschema['enum']))}.").strip()
            norm[pname] = {"type": st, "description": desc or pname}
        for r in req:
            _req(r in norm, f"bridge tool {name}: required parameter {r!r} not declared")
        bridge.append(BridgeTool(name, b["description"], norm, list(req)))

    env = raw["env"]
    _req(isinstance(env, dict), "env must be an object")
    for k, v in env.items():
        _req(isinstance(k, str) and _ENV_KEY.match(k) is not None, f"env key {k!r} is not a valid variable name")
        _req(isinstance(v, str) and "\0" not in v, f"env[{k}] must be a string")

    rpc_t = raw.get("rpc_timeout_s", 1800)
    _req(_is_num(rpc_t) and 0 < rpc_t <= 86400, "rpc_timeout_s must be a number in (0, 86400]")
    vision = raw.get("vision", False)
    _req(isinstance(vision, bool), "vision must be a boolean")

    secrets = [m["api_key"]] + [v for v in env.values()]
    secrets = [s for s in secrets if len(s) >= 8]
    return Config(
        run_id=run_id, base_url=m["base_url"], api_key=m["api_key"], model_id=m["model_id"],
        temperature=None if t is None else float(t), system_prompt=raw["system_prompt"],
        history=[dict(h) for h in hist], task=raw["task"], max_steps=ms, planning_interval=pi,
        tainted=raw["tainted"], workspace=ws, policy_free=set(pf), bridge_tools=bridge,
        in_sandbox_tools=list(ist), env=dict(env), rpc_timeout_s=float(rpc_t), vision=vision,
        secrets=secrets,
    )


def load_config(run_dir: str) -> Config:
    path = os.path.join(run_dir, "config.json")
    try:
        size = os.stat(path).st_size
    except OSError as e:
        raise ConfigError(f"cannot read config.json: {e.strerror}") from e
    if size > MAX_CONFIG_BYTES:
        raise ConfigError("config.json too large")
    try:
        with open(path, "rb") as f:
            raw = json.loads(f.read(MAX_CONFIG_BYTES + 1).decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        raise ConfigError(f"config.json is not valid JSON: {e}") from e
    return parse_config(raw, expected_run_id=os.path.basename(os.path.normpath(run_dir)))


def scrub_config_file(run_dir: str) -> None:
    """Replace secrets in config.json on disk once loaded, so the (untrusted) model's
    own tools cannot read the per-run token from the file. Best effort."""
    path = os.path.join(run_dir, "config.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = json.load(f)
        raw["model"]["api_key"] = "[scrubbed-by-runner]"
        raw["env"] = {k: "[scrubbed-by-runner]" for k in raw.get("env", {})}
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(raw, f)
        os.replace(tmp, path)
    except Exception:
        pass
