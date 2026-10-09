import json
import os
import threading
import time
import uuid

os.environ.setdefault("SHELLHOUSE_POLL_S", "0.02")

import pytest  # noqa: E402
from smolagents.models import ChatMessage, ChatMessageStreamDelta, MessageRole, Model  # noqa: E402
from smolagents.monitoring import TokenUsage  # noqa: E402


def call(name, **args):
    """A ChatMessage carrying one tool call."""
    return calls((name, args))


def calls(*items, content=""):
    tcs = [
        {"id": f"c{uuid.uuid4().hex[:6]}", "type": "function",
         "function": {"name": n, "arguments": json.dumps(a)}}
        for n, a in items
    ]
    return ChatMessage(role=MessageRole.ASSISTANT, content=content, tool_calls=tcs,
                       token_usage=TokenUsage(input_tokens=10, output_tokens=5))


def finish(answer="ok", outcome="done"):
    return call("final_answer", answer=answer, outcome=outcome)


class ScriptedModel(Model):
    """Returns pre-baked ChatMessages in order. No network, no LLM."""

    def __init__(self, script):
        super().__init__(model_id="scripted")
        self.script = list(script)
        self.seen = []

    def _next(self, messages):
        self.seen.append(messages)
        item = self.script.pop(0)
        return item(messages) if callable(item) else item

    def generate(self, messages, stop_sequences=None, response_format=None, tools_to_call_from=None, **kw):
        return self._next(messages)


class StreamingScriptedModel(ScriptedModel):
    def __init__(self, script, chunks=("Hel", "lo ", "wor", "ld")):
        super().__init__(script)
        self.chunks = chunks

    def generate_stream(self, messages, stop_sequences=None, response_format=None, tools_to_call_from=None, **kw):
        msg = self._next(messages)
        for c in self.chunks:
            yield ChatMessageStreamDelta(content=c)
        from smolagents.models import ChatMessageToolCallFunction, ChatMessageToolCallStreamDelta
        for i, tc in enumerate(msg.tool_calls or []):
            yield ChatMessageStreamDelta(tool_calls=[ChatMessageToolCallStreamDelta(
                index=i, id=tc.id, type="function",
                function=ChatMessageToolCallFunction(name=tc.function.name, arguments=tc.function.arguments))])
        yield ChatMessageStreamDelta(content="", token_usage=msg.token_usage)


def make_config(tmp_path, **over):
    run_id = over.pop("run_id", "run1")
    run_dir = tmp_path / "workspace" / ".shellhouse" / "runs" / run_id
    ws = tmp_path / "workspace"
    run_dir.mkdir(parents=True, exist_ok=True)
    cfg = {
        "protocol": 1, "run_id": run_id,
        "model": {"base_url": "http://127.0.0.1:9/v1", "api_key": "sk-test-secret-token-123", "model_id": "m",
                  "temperature": 0.0},
        "system_prompt": "You are a test bot.", "history": [], "task": "do the thing", "max_steps": 8,
        "planning_interval": None, "tainted": False, "workspace": str(ws),
        "policy_free": ["read_file", "list_files"], "bridge_tools": [],
        "in_sandbox_tools": ["run_shell", "read_file", "write_file", "list_files"], "env": {},
        "rpc_timeout_s": 5,
    }
    cfg.update(over)
    (run_dir / "config.json").write_text(json.dumps(cfg))
    return str(run_dir), cfg


def read_events(run_dir):
    d = os.path.join(run_dir, "events")
    out = []
    for n in sorted(os.listdir(d)):
        if n.endswith(".json") and not n.startswith("."):
            out.append(json.load(open(os.path.join(d, n))))
    return out


class FakeMac:
    """Background thread answering rpc_request events like the Mac app would."""

    def __init__(self, run_dir, decide):
        self.run_dir = run_dir
        self.decide = decide  # (event) -> dict reply fields, or None to stay silent
        self.seen = []
        self._stop = threading.Event()
        self.t = threading.Thread(target=self._loop, daemon=True)

    def __enter__(self):
        self.t.start()
        return self

    def __exit__(self, *a):
        self._stop.set()
        self.t.join(2)

    def _loop(self):
        done = set()
        d = os.path.join(self.run_dir, "events")
        while not self._stop.is_set():
            try:
                names = sorted(os.listdir(d))
            except OSError:
                names = []
            for n in names:
                if n in done or not n.endswith(".json") or n.startswith("."):
                    continue
                done.add(n)
                try:
                    ev = json.load(open(os.path.join(d, n)))
                except ValueError:
                    done.discard(n)
                    continue
                if ev.get("type") == "rpc_request":
                    self.seen.append(ev)
                    reply = self.decide(ev)
                    if reply is not None:
                        reply = dict(reply, id=ev["id"])
                        rpc = os.path.join(self.run_dir, "rpc")
                        os.makedirs(rpc, exist_ok=True)
                        tmp = os.path.join(rpc, f".{ev['id']}.tmp")
                        open(tmp, "w").write(json.dumps(reply))
                        os.replace(tmp, os.path.join(rpc, f"{ev['id']}.reply.json"))
            time.sleep(0.01)


@pytest.fixture
def run_agent(tmp_path):
    from shellhouse_agent.runner import run

    def _run(script, model_cls=ScriptedModel, **over):
        run_dir, cfg = make_config(tmp_path, **over)
        model = model_cls(script)
        rc = run(run_dir, model_factory=lambda c: model)
        return run_dir, read_events(run_dir), model, rc

    return _run
