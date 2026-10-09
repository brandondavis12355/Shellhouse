"""smolagents Tool wrappers: policy gating, event emission, result rendering."""

from __future__ import annotations

import json
from typing import Any, Callable

from smolagents import Tool

from .config import BridgeTool
from .core import Cancelled, RunContext
from .sandbox_tools import IMPLS

RESULT_CAP_CHARS = 100_000
OUTCOMES = ("done", "blocked", "needs_user_input", "silent")


def _s(desc: str, nullable: bool = False) -> dict:
    d: dict[str, Any] = {"type": "string", "description": desc}
    if nullable:
        d["nullable"] = True
    return d


def _i(desc: str, nullable: bool = False) -> dict:
    d: dict[str, Any] = {"type": "integer", "description": desc}
    if nullable:
        d["nullable"] = True
    return d


# name -> (description, inputs). Descriptions follow ToolRegistry.swift.
SANDBOX_SPECS: dict[str, tuple[str, dict]] = {
    "list_files": ("List files and directories under a path in the sandbox's /workspace.",
                   {"path": _s("Relative to /workspace. Defaults to /workspace itself.", True)}),
    "read_file": ("Read a text file from the sandbox's /workspace (up to 200,000 bytes).",
                  {"path": _s("File path, relative to /workspace.")}),
    "write_file": ("Overwrite a file in the sandbox's /workspace with the given text content.",
                   {"path": _s("File path, relative to /workspace."), "content": _s("Text to write.")}),
    "run_shell": ("Run a shell command inside the sandbox as the unprivileged desktop user.",
                  {"command": _s("The command line."),
                   "timeout": _i("Seconds, default 120.", True),
                   "use_secrets": {"type": "array", "description": "Not supported by this engine; ignored.", "nullable": True}}),
    "screenshot": ("Capture the sandbox desktop and return it as an image the model can see.",
                   {"filename": _s("Optional; defaults to a timestamped name.", True)}),
    "list_windows": ("List the sandbox desktop's open windows with their positions and titles.", {}),
    "focus_window": ("Raise and focus a window by (partial) title match.", {"title": _s("Window title (partial).")}),
    "open_app": ("Launch an application on the sandbox desktop.",
                 {"app": _s("One of: browser, terminal, files."),
                  "url": _s("Only used when app is 'browser'.", True)}),
    "click": ("Move the mouse to absolute screen coordinates and click.",
              {"x": _i("Screen x."), "y": _i("Screen y."), "button": _i("1=left, 2=middle, 3=right. Default 1.", True)}),
    "type_text": ("Type text into whichever window currently has focus.", {"text": _s("Text to type.")}),
    "press_key": ("Press a key or key combo (xdotool syntax, e.g. 'Return', 'ctrl+l').", {"key": _s("Key or combo.")}),
    "scroll": ("Scroll a page or window up or down, at the current mouse position or at given coordinates. "
               "Each unit is roughly one mouse-wheel click.",
               {"direction": _s("up or down."), "amount": _i("Wheel clicks, default 5.", True),
                "x": _i("Optional; moves the mouse here first.", True),
                "y": _i("Optional; moves the mouse here first.", True)}),
}


def render(result: Any) -> str:
    if isinstance(result, str):
        text = result
    else:
        try:
            text = json.dumps(result, ensure_ascii=False, default=str)
        except (TypeError, ValueError):
            text = str(result)
    if len(text) > RESULT_CAP_CHARS:
        text = text[:RESULT_CAP_CHARS] + f"...[truncated {len(text) - RESULT_CAP_CHARS} chars]"
    return text


def _event_result(result: Any) -> Any:
    return result


class ShellhouseTool(Tool):
    """A gated tool. forward() = emit tool_started -> (policy_check|bridge_call) -> run -> tool_completed."""

    skip_forward_signature_validation = True
    output_type = "string"

    def __init__(self, ctx: RunContext, name: str, description: str, inputs: dict,
                 impl: Callable[[RunContext, dict], Any] | None, mode: str):
        # mode: "sandbox_free" | "sandbox_checked" | "bridge"
        super().__init__()
        self.ctx = ctx
        self.name = name
        self.description = description
        self.inputs = inputs
        self._impl = impl
        self._mode = mode

    def forward(self, *args, **kwargs):
        ctx = self.ctx
        if args:
            for key, val in zip(self.inputs.keys(), args):
                kwargs.setdefault(key, val)
        params = {k: v for k, v in kwargs.items() if v is not None}
        ctx.check_cancel()
        ctx.events.emit("tool_started", name=self.name, args=params)
        try:
            result: Any
            if self._mode == "sandbox_free":
                result = self._impl(ctx, params)
            else:
                kind = "bridge_call" if self._mode == "bridge" else "policy_check"
                reply = ctx.rpc_request(kind, self.name, params)
                if reply.decision != "allow":
                    result = {"error": f"denied: {reply.reason or 'not permitted'}"}
                elif self._mode == "bridge":
                    result = reply.result if reply.result is not None else {"ok": True}
                else:
                    result = self._impl(ctx, params)
        except Cancelled:
            raise
        except Exception as e:  # tool bugs must not kill the run
            result = {"error": f"{type(e).__name__}: {e}"}
        ctx.events.emit("tool_completed", name=self.name, result=_event_result(result))
        return render(result)


class FinalAnswerTool(Tool):
    """Replaces smolagents' final_answer: carries an outcome, rejects empty answers."""

    name = "final_answer"
    description = (
        "Ends the task. Call this with the complete result the moment you have it, or the moment "
        "you are genuinely blocked. Plain text alone never ends the task. outcome is one of: "
        "done (the task is actually accomplished), blocked (you cannot proceed; explain why in answer), "
        "needs_user_input (you need the user to answer something; put the question in answer), "
        "silent (nothing worth telling the user). Default outcome is done."
    )
    inputs = {
        "answer": {"type": "string", "description": "The complete result, or why you are blocked."},
        "outcome": {"type": "string", "description": "done | blocked | needs_user_input | silent", "nullable": True},
    }
    output_type = "string"

    def __init__(self):
        super().__init__()
        self.captured: tuple[str, str] | None = None

    def forward(self, answer: str, outcome: str | None = None) -> str:
        outcome = outcome or "done"
        if outcome not in OUTCOMES:
            raise ValueError(f"outcome must be one of {', '.join(OUTCOMES)}")
        if not isinstance(answer, str):
            answer = render(answer)
        if outcome != "silent" and not answer.strip():
            raise ValueError("final_answer needs a non-empty `answer`: the actual result, or a clear "
                             "explanation of why you are blocked. Call it again with that filled in.")
        self.captured = (answer, outcome)
        return answer


def build_tools(ctx: RunContext) -> tuple[list[Tool], FinalAnswerTool]:
    cfg = ctx.config
    tools: list[Tool] = []
    for name in cfg.in_sandbox_tools:
        desc, inputs = SANDBOX_SPECS[name]
        mode = "sandbox_free" if name in cfg.policy_free else "sandbox_checked"
        tools.append(ShellhouseTool(ctx, name, desc, dict(inputs), IMPLS[name], mode))
    for b in cfg.bridge_tools:
        tools.append(make_bridge_tool(ctx, b))
    final = FinalAnswerTool()
    tools.append(final)
    return tools, final


def make_bridge_tool(ctx: RunContext, b: BridgeTool) -> ShellhouseTool:
    inputs: dict[str, dict] = {}
    for pname, schema in b.properties.items():
        d: dict[str, Any] = {"type": schema["type"], "description": schema["description"]}
        if pname not in b.required:
            d["nullable"] = True
        inputs[pname] = d
    return ShellhouseTool(ctx, b.name, b.description, inputs, None, "bridge")
