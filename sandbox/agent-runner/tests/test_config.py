import copy
import json

import pytest

from shellhouse_agent.config import ConfigError, parse_config
from shellhouse_agent.runner import run
from conftest import make_config, read_events, ScriptedModel


@pytest.fixture
def base(tmp_path):
    _, cfg = make_config(tmp_path)
    return cfg


def mod(base, **kw):
    c = copy.deepcopy(base)
    for k, v in kw.items():
        c[k] = v
    return c


def test_valid(base):
    c = parse_config(base, "run1")
    assert c.run_id == "run1" and c.max_steps == 8 and c.rpc_timeout_s == 5 and "sk-test-secret-token-123" in c.secrets


@pytest.mark.parametrize("proto", [0, 2, "1", None, True, 1.5])
def test_rejects_other_protocol_versions(base, proto):
    with pytest.raises(ConfigError, match="protocol"):
        parse_config(mod(base, protocol=proto))


def test_rejects_unknown_and_missing_keys(base):
    with pytest.raises(ConfigError, match="unknown keys"):
        parse_config(mod(base, extra="x"))
    c = copy.deepcopy(base)
    del c["task"]
    with pytest.raises(ConfigError, match="missing"):
        parse_config(c)


@pytest.mark.parametrize("key,val", [
    ("run_id", "../x"), ("max_steps", 0), ("max_steps", "5"), ("max_steps", True), ("planning_interval", 0),
    ("tainted", "no"), ("workspace", "relative/path"), ("task", "  "), ("history", [{"role": "system", "content": "x"}]),
    ("history", [{"role": "user"}]), ("in_sandbox_tools", ["rm_rf"]), ("in_sandbox_tools", ["run_shell", "run_shell"]),
    ("env", {"bad-key": "x"}), ("env", {"A": 1}), ("policy_free", "read_file"), ("rpc_timeout_s", -1),
    ("vision", "yes"),
])
def test_rejects_bad_values(base, key, val):
    with pytest.raises(ConfigError):
        parse_config(mod(base, **{key: val}))


def test_rejects_bad_model(base):
    for bad in ({"base_url": "file:///etc/passwd", "api_key": "k", "model_id": "m", "temperature": 0},
                {"base_url": "http://h/v1", "api_key": "k", "model_id": "", "temperature": 0},
                {"base_url": "http://h/v1", "api_key": "k", "model_id": "m", "temperature": 9},
                {"base_url": "http://h/v1", "api_key": "k", "model_id": "m"}):
        with pytest.raises(ConfigError):
            parse_config(mod(base, model=bad))


def test_run_id_must_match_directory(base):
    with pytest.raises(ConfigError, match="directory"):
        parse_config(base, "other")


def test_bridge_tool_validation(base):
    ok = {"name": "remember", "description": "d", "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}
    parse_config(mod(base, bridge_tools=[ok]))
    with pytest.raises(ConfigError):
        parse_config(mod(base, bridge_tools=[dict(ok, name="run_shell")]))  # collides
    with pytest.raises(ConfigError):
        parse_config(mod(base, bridge_tools=[dict(ok, name="final_answer")]))
    with pytest.raises(ConfigError):
        parse_config(mod(base, bridge_tools=[dict(ok, name="bad name")]))
    with pytest.raises(ConfigError):
        parse_config(mod(base, bridge_tools=[dict(ok, parameters={"properties": {}, "required": ["nope"]})]))


def test_runner_fails_cleanly_on_bad_config(tmp_path):
    run_dir, cfg = make_config(tmp_path, protocol=2)
    called = []
    rc = run(run_dir, model_factory=lambda c: called.append(1))
    evs = read_events(run_dir)
    assert rc == 2 and not called
    assert evs[0]["type"] == "error" and "protocol" in evs[0]["message"] and evs[-1]["state"] == "failed"


def test_runner_fails_cleanly_on_garbage_json(tmp_path):
    run_dir, _ = make_config(tmp_path)
    open(run_dir + "/config.json", "w").write("{not json")
    assert run(run_dir) == 2
    assert read_events(run_dir)[-1]["state"] == "failed"


def test_runner_fails_on_missing_workspace(tmp_path):
    run_dir, _ = make_config(tmp_path, workspace=str(tmp_path / "nope"))
    assert run(run_dir, model_factory=lambda c: ScriptedModel([])) == 2


def test_config_scrubbed_after_load(tmp_path):
    run_dir, _ = make_config(tmp_path, env={"K": "valuevaluevalue"})
    run(run_dir, model_factory=lambda c: ScriptedModel([]))  # fails at model, after scrub
    txt = open(run_dir + "/config.json").read()
    assert "sk-test-secret-token-123" not in txt and "valuevaluevalue" not in txt


def test_cli_run_invalid_config_exit_code(tmp_path):
    import os, subprocess, sys
    run_dir, _ = make_config(tmp_path, protocol=9)
    src = os.path.join(os.path.dirname(__file__), "..", "src")
    p = subprocess.run([sys.executable, "-m", "shellhouse_agent", "run", "--dir", run_dir],
                       env=dict(os.environ, PYTHONPATH=src), capture_output=True, text=True, timeout=60)
    assert p.returncode == 2
    assert read_events(run_dir)[-1]["state"] == "failed"
    t = subprocess.run([sys.executable, "-m", "shellhouse_agent", "tail", "--dir", run_dir, "--after", "0", "--max-bytes", "5000"],
                       env=dict(os.environ, PYTHONPATH=src), capture_output=True, text=True, timeout=60)
    assert json.loads(t.stdout.splitlines()[-1]) == {"tail_done": True, "last_seq": 2, "finished": True}
