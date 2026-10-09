import json
import os
import threading
import time

import pytest

from conftest import (FakeMac, StreamingScriptedModel, ScriptedModel, call, calls, finish, make_config,
                      read_events)
from shellhouse_agent.runner import run


def types(evs):
    return [e["type"] for e in evs]


def _allow_all(ev):
    return {"decision": "allow"}


def test_basic_run_with_policy_allow(tmp_path):
    run_dir, _ = make_config(tmp_path)
    model = ScriptedModel([call("write_file", path="a.txt", content="hi"),
                           call("read_file", path="a.txt"), finish("wrote it")])
    with FakeMac(run_dir, _allow_all) as mac:
        rc = run(run_dir, model_factory=lambda c: model)
    evs = read_events(run_dir)
    assert rc == 0
    # seq is contiguous from 1 and ts present
    assert [e["seq"] for e in evs] == list(range(1, len(evs) + 1))
    assert all("ts" in e for e in evs)
    assert (tmp_path / "workspace" / "a.txt").read_text() == "hi"
    # only write_file was policy-checked; read_file is policy-free
    assert [(e["kind"], e["name"]) for e in mac.seen] == [("policy_check", "write_file")]
    fin = [e for e in evs if e["type"] == "final"][0]
    assert fin["summary"] == "wrote it" and fin["outcome"] == "done"
    assert evs[-1] == {**evs[-1], "type": "status", "state": "completed"}
    # tool_started precedes rpc_request precedes tool_completed for write_file
    order = [(e["type"], e.get("name")) for e in evs if e["type"] in ("tool_started", "rpc_request", "tool_completed")]
    assert order[:3] == [("tool_started", "write_file"), ("rpc_request", "write_file"), ("tool_completed", "write_file")]
    # pid file written
    assert int(open(os.path.join(run_dir, "pid")).read()) == os.getpid()
    # api key never appears in any event or the scrubbed config
    blob = json.dumps(evs) + open(os.path.join(run_dir, "config.json")).read()
    assert "sk-test-secret-token-123" not in blob


def test_no_temp_files_left_and_atomic_names(tmp_path):
    run_dir, _ = make_config(tmp_path)
    run(run_dir, model_factory=lambda c: ScriptedModel([finish("x")]))
    names = os.listdir(os.path.join(run_dir, "events"))
    assert all(n.endswith(".json") and len(n) == len("00000001.json") for n in names)


def test_policy_deny_does_not_execute(tmp_path):
    run_dir, _ = make_config(tmp_path)
    model = ScriptedModel([call("write_file", path="evil.txt", content="x"),
                           finish("could not", "blocked")])
    with FakeMac(run_dir, lambda ev: {"decision": "deny", "reason": "not today"}):
        run(run_dir, model_factory=lambda c: model)
    evs = read_events(run_dir)
    assert not (tmp_path / "workspace" / "evil.txt").exists()
    done = [e for e in evs if e["type"] == "tool_completed"][0]
    assert done["result"] == {"error": "denied: not today"}
    assert [e for e in evs if e["type"] == "final"][0]["outcome"] == "blocked"
    assert evs[-1]["state"] == "aborted" and evs[-1]["detail"] == "blocked"
    # the model saw the denial as the observation
    last_prompt = json.dumps([m.content if hasattr(m, "content") else m for m in model.seen[-1]], default=str)
    assert "denied: not today" in last_prompt


def test_policy_timeout_is_deny(tmp_path):
    run_dir, _ = make_config(tmp_path, rpc_timeout_s=0.3)
    model = ScriptedModel([call("write_file", path="t.txt", content="x"), finish("gave up", "blocked")])
    t0 = time.time()
    run(run_dir, model_factory=lambda c: model)  # nobody answers
    assert time.time() - t0 < 5
    evs = read_events(run_dir)
    res = [e for e in evs if e["type"] == "tool_completed"][0]["result"]
    assert res["error"].startswith("denied: timed out")
    assert not (tmp_path / "workspace" / "t.txt").exists()


def test_partial_reply_file_is_tolerated(tmp_path):
    run_dir, _ = make_config(tmp_path)
    model = ScriptedModel([call("write_file", path="p.txt", content="ok"), finish("fine")])

    def partial(ev):
        rpc = os.path.join(run_dir, "rpc")
        os.makedirs(rpc, exist_ok=True)
        path = os.path.join(rpc, f"{ev['id']}.reply.json")
        full = json.dumps({"id": ev["id"], "decision": "allow"})
        with open(path, "w") as f:
            f.write(full[:10])
            f.flush()
            time.sleep(0.2)
            f.write(full[10:])
        return None

    with FakeMac(run_dir, partial):
        run(run_dir, model_factory=lambda c: model)
    assert (tmp_path / "workspace" / "p.txt").read_text() == "ok"


def test_malformed_reply_is_deny(tmp_path):
    run_dir, _ = make_config(tmp_path)
    model = ScriptedModel([call("write_file", path="m.txt", content="x"), finish("no", "blocked")])
    with FakeMac(run_dir, lambda ev: {"decision": "maybe"}):
        run(run_dir, model_factory=lambda c: model)
    assert not (tmp_path / "workspace" / "m.txt").exists()


def test_bridge_call_returns_reply_result(tmp_path):
    bridge = [{"name": "recall_memory", "description": "Search memory.",
               "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "limit": {"type": "integer"}},
                              "required": ["query"]}}]
    run_dir, _ = make_config(tmp_path, bridge_tools=bridge)
    model = ScriptedModel([call("recall_memory", query="colour"), finish("the answer is teal")])
    with FakeMac(run_dir, lambda ev: {"decision": "allow", "result": {"facts": ["favourite colour: teal"]}}) as mac:
        run(run_dir, model_factory=lambda c: model)
    evs = read_events(run_dir)
    assert mac.seen[0]["kind"] == "bridge_call" and mac.seen[0]["args"] == {"query": "colour"}
    tc = [e for e in evs if e["type"] == "tool_completed"][0]
    assert tc["result"] == {"facts": ["favourite colour: teal"]}
    prompt = json.dumps([str(m.content) for m in model.seen[-1]])
    assert "favourite colour: teal" in prompt


def test_bridge_deny(tmp_path):
    bridge = [{"name": "message_bot", "description": "x", "parameters": {"type": "object", "properties": {}}}]
    run_dir, _ = make_config(tmp_path, bridge_tools=bridge)
    model = ScriptedModel([call("message_bot"), finish("blocked", "blocked")])
    with FakeMac(run_dir, lambda ev: {"decision": "deny", "reason": "tainted run"}):
        run(run_dir, model_factory=lambda c: model)
    tc = [e for e in read_events(run_dir) if e["type"] == "tool_completed"][0]
    assert tc["result"] == {"error": "denied: tainted run"}


def test_cancel_before_tool(tmp_path):
    run_dir, _ = make_config(tmp_path)
    model = ScriptedModel([call("write_file", path="c.txt", content="x"), finish("never")])
    # cancel while the runner waits for a policy reply that never comes
    threading.Timer(0.3, lambda: open(os.path.join(run_dir, "cancel"), "w").close()).start()
    t0 = time.time()
    rc = run(run_dir, model_factory=lambda c: model)
    assert time.time() - t0 < 4 and rc == 0
    evs = read_events(run_dir)
    assert evs[-1]["type"] == "status" and evs[-1]["state"] == "aborted" and evs[-1]["detail"] == "cancelled"
    assert "final" not in types(evs)
    assert not (tmp_path / "workspace" / "c.txt").exists()


def test_cancel_kills_running_shell(tmp_path):
    run_dir, _ = make_config(tmp_path)
    marker = tmp_path / "workspace" / "alive"
    model = ScriptedModel([call("run_shell", command=f"sleep 30 & echo $! > {marker}; wait"), finish("never")])
    threading.Timer(0.5, lambda: open(os.path.join(run_dir, "cancel"), "w").close()).start()
    t0 = time.time()
    with FakeMac(run_dir, _allow_all):
        run(run_dir, model_factory=lambda c: model)
    assert time.time() - t0 < 5
    time.sleep(0.2)
    pid = int(marker.read_text())
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)  # grandchild in the process group was killed too
    assert read_events(run_dir)[-1]["detail"] == "cancelled"


def test_cancel_file_present_at_start(tmp_path):
    run_dir, _ = make_config(tmp_path)
    open(os.path.join(run_dir, "cancel"), "w").close()
    run(run_dir, model_factory=lambda c: ScriptedModel([finish("x")]))
    assert read_events(run_dir)[-1]["detail"] == "cancelled"


def test_max_steps_gives_blocked_final(tmp_path):
    run_dir, _ = make_config(tmp_path, max_steps=2)
    model = ScriptedModel([call("list_files"), call("list_files"),
                           ChatMessageText("I ran out of steps")])
    run(run_dir, model_factory=lambda c: model)
    evs = read_events(run_dir)
    fin = [e for e in evs if e["type"] == "final"][0]
    assert fin["outcome"] == "blocked" and fin["reason"] == "max_steps"
    assert evs[-1]["state"] == "aborted" and evs[-1]["detail"] == "max_steps"


def ChatMessageText(text):
    from smolagents.models import ChatMessage, MessageRole
    return ChatMessage(role=MessageRole.ASSISTANT, content=text)


def test_plain_text_does_not_end_task_and_empty_finish_rejected(tmp_path):
    run_dir, _ = make_config(tmp_path)
    model = ScriptedModel([ChatMessageText("I'll get right on it"),
                           finish("", "done"),
                           finish("real answer", "done")])
    run(run_dir, model_factory=lambda c: model)
    evs = read_events(run_dir)
    errs = [e for e in evs if e["type"] == "error"]
    assert len(errs) == 2 and all(e["fatal"] is False for e in errs)
    assert [e for e in evs if e["type"] == "final"][0]["summary"] == "real answer"


def test_silent_and_needs_user_input_outcomes(tmp_path):
    run_dir, _ = make_config(tmp_path)
    run(run_dir, model_factory=lambda c: ScriptedModel([finish("Which account?", "needs_user_input")]))
    evs = read_events(run_dir)
    assert evs[-1]["state"] == "aborted" and evs[-1]["detail"] == "needs_user_input"


def test_model_failure_is_fatal_error(tmp_path):
    class Boom(ScriptedModel):
        def generate(self, *a, **k):
            raise RuntimeError("connection refused to sk-test-secret-token-123")

    run_dir, _ = make_config(tmp_path)
    rc = run(run_dir, model_factory=lambda c: Boom([]))
    evs = read_events(run_dir)
    assert rc == 1
    err = [e for e in evs if e["type"] == "error"][-1]
    assert err["fatal"] is True and "connection refused" in err["message"]
    assert "sk-test-secret-token-123" not in err["message"]
    assert evs[-1]["state"] == "failed"


def test_history_is_replayed_to_model(tmp_path):
    run_dir, _ = make_config(tmp_path, history=[{"role": "user", "content": "my name is Zed"},
                                                {"role": "assistant", "content": "Nice to meet you Zed"}],
                             task="what is my name?")
    model = ScriptedModel([finish("Zed")])
    run(run_dir, model_factory=lambda c: model)
    flat = json.dumps([str(m.content) for m in model.seen[0]])
    assert "my name is Zed" in flat and "Nice to meet you Zed" in flat and "what is my name?" in flat
    assert "You are a test bot." in flat  # system prompt reaches the model


def test_streaming_deltas_are_coalesced(tmp_path):
    run_dir, _ = make_config(tmp_path)
    run(run_dir, model_factory=lambda c: StreamingScriptedModel([finish("x")]))
    evs = read_events(run_dir)
    d = [e for e in evs if e["type"] == "message_delta"]
    # 4 chunks arrive back-to-back (<100ms): coalesced into a single delta, text preserved
    assert len(d) == 1 and d[0]["text"] == "Hello world"
    m = [e for e in evs if e["type"] == "message"][0]
    assert m["tool_calls"][0]["name"] == "final_answer"


def test_parallel_tool_calls_keep_events_consistent(tmp_path):
    run_dir, _ = make_config(tmp_path)
    (tmp_path / "workspace" / "f.txt").write_text("x")
    model = ScriptedModel([calls(("list_files", {}), ("read_file", {"path": "f.txt"})), finish("ok")])
    run(run_dir, model_factory=lambda c: model)
    evs = read_events(run_dir)
    assert [e["seq"] for e in evs] == list(range(1, len(evs) + 1))
    assert len([e for e in evs if e["type"] == "tool_completed"]) == 2


def test_coerces_string_integers(tmp_path):
    run_dir, _ = make_config(tmp_path)
    model = ScriptedModel([call("run_shell", command="echo hi", timeout="5"), finish("ok")])
    with FakeMac(run_dir, _allow_all):
        run(run_dir, model_factory=lambda c: model)
    tc = [e for e in read_events(run_dir) if e["type"] == "tool_completed"][0]
    assert tc["result"]["exit_code"] == 0 and tc["result"]["stdout"].strip() == "hi"


def test_planning_interval_emits_plan(tmp_path):
    run_dir, _ = make_config(tmp_path, planning_interval=3)
    plan = ChatMessageText("1. do it")
    model = ScriptedModel([plan, finish("ok")])
    run(run_dir, model_factory=lambda c: model)
    evs = read_events(run_dir)
    assert evs[0]["state"] == "planning"
    assert any(e["type"] == "message" and e.get("kind") == "plan" for e in evs)
