import os
import time

import pytest

from shellhouse_agent.config import parse_config
from shellhouse_agent.core import RunContext
from shellhouse_agent.events import EventWriter
from shellhouse_agent import sandbox_tools as st
from conftest import make_config


@pytest.fixture
def ctx(tmp_path):
    run_dir, cfg = make_config(tmp_path)
    ws = os.path.realpath(cfg["workspace"])
    c = parse_config(cfg, "run1")
    return RunContext(config=c, run_dir=run_dir, workspace=ws, events=EventWriter(run_dir)), tmp_path


def test_write_read_list_roundtrip(ctx):
    c, tmp = ctx
    assert st.write_file(c, {"path": "sub/dir/a.txt", "content": "héllo"}) == {"path": "sub/dir/a.txt", "bytes": 6}
    assert st.read_file(c, {"path": "sub/dir/a.txt"})["content"] == "héllo"
    assert st.read_file(c, {"path": "/workspace-less-abs"})["error"]  # absolute outside -> rejected
    assert st.list_files(c, {})["entries"] == ["sub/"]
    assert st.list_files(c, {"path": "sub/dir"})["entries"] == ["a.txt"]


def test_absolute_path_inside_workspace_ok(ctx):
    c, tmp = ctx
    p = str(tmp / "workspace" / "abs.txt")
    assert "error" not in st.write_file(c, {"path": p, "content": "1"})
    assert (tmp / "workspace" / "abs.txt").read_text() == "1"


@pytest.mark.parametrize("bad", ["../outside.txt", "a/../../outside.txt", "/etc/passwd", "..", "sub/../../x"])
def test_dotdot_and_absolute_escapes_rejected(ctx, bad):
    c, tmp = ctx
    assert "escapes" in st.read_file(c, {"path": bad})["error"] or "error" in st.read_file(c, {"path": bad})
    assert "error" in st.write_file(c, {"path": bad, "content": "x"})
    assert not (tmp / "outside.txt").exists()


def test_symlink_escapes_rejected(ctx):
    c, tmp = ctx
    secret = tmp / "secret.txt"
    secret.write_text("TOP SECRET")
    outside_dir = tmp / "outdir"
    outside_dir.mkdir()
    ws = tmp / "workspace"
    os.symlink(secret, ws / "link_file")
    os.symlink(outside_dir, ws / "link_dir")
    os.symlink("../secret.txt", ws / "rel_link")
    assert "escapes" in st.read_file(c, {"path": "link_file"})["error"]
    assert "escapes" in st.read_file(c, {"path": "rel_link"})["error"]
    assert "escapes" in st.write_file(c, {"path": "link_file", "content": "pwn"})["error"]
    assert "escapes" in st.write_file(c, {"path": "link_dir/new.txt", "content": "pwn"})["error"]
    assert "escapes" in st.list_files(c, {"path": "link_dir"})["error"]
    assert secret.read_text() == "TOP SECRET" and not (outside_dir / "new.txt").exists()


def test_symlink_inside_workspace_is_fine(ctx):
    c, tmp = ctx
    st.write_file(c, {"path": "real.txt", "content": "ok"})
    os.symlink(tmp / "workspace" / "real.txt", tmp / "workspace" / "alias.txt")
    assert st.read_file(c, {"path": "alias.txt"})["content"] == "ok"


def test_reserved_shellhouse_dir_hidden_and_blocked(ctx):
    c, tmp = ctx
    assert ".shellhouse/" not in st.list_files(c, {})["entries"]
    assert ".shellhouse" not in st.list_files(c, {})["entries"]
    assert "reserved" in st.read_file(c, {"path": ".shellhouse/runs/run1/config.json"})["error"]
    assert "reserved" in st.write_file(c, {"path": ".shellhouse/x", "content": "1"})["error"]


def test_size_caps(ctx):
    c, tmp = ctx
    (tmp / "workspace" / "big.bin").write_bytes(b"a" * 300_000)
    r = st.read_file(c, {"path": "big.bin"})
    assert len(r["content"]) == st.READ_MAX_BYTES and r["truncated"] is True
    assert "too large" in st.write_file(c, {"path": "w.txt", "content": "a" * (st.WRITE_MAX_BYTES + 1)})["error"]
    for i in range(st.LIST_MAX_ENTRIES + 5):
        (tmp / "workspace" / f"f{i}").write_text("")
    r = st.list_files(c, {})
    assert len(r["entries"]) == st.LIST_MAX_ENTRIES and r["truncated"] is True


def test_read_rejects_special_files(ctx):
    c, tmp = ctx
    os.mkfifo(tmp / "workspace" / "fifo")
    assert "error" in st.read_file(c, {"path": "fifo"})  # must not block
    assert "error" in st.read_file(c, {"path": "."})


# ---- run_shell
def test_shell_basic_cwd_and_minimal_env(ctx, monkeypatch):
    monkeypatch.setenv("LEAKY_PARENT_VAR", "should-not-appear")
    c, tmp = ctx
    c.config.env["MY_FLAG"] = "1"
    r = st.run_shell(c, {"command": "pwd; echo $MY_FLAG; echo ${LEAKY_PARENT_VAR:-unset}; echo err >&2; exit 3"})
    assert r["exit_code"] == 3
    out = r["stdout"].split()
    assert out[0] == c.workspace and out[1] == "1" and out[2] == "unset"
    assert r["stderr"].strip() == "err"


def test_shell_timeout_kills_process_group(ctx):
    c, tmp = ctx
    t0 = time.time()
    r = st.run_shell(c, {"command": "sleep 30 & echo $! > pidfile; echo started; sleep 30", "timeout": 1})
    assert time.time() - t0 < 6
    assert r["timed_out"] is True and "timed out" in r["error"] and "started" in r["stdout"]
    time.sleep(0.2)
    pid = int((tmp / "workspace" / "pidfile").read_text())
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)


def test_shell_output_cap(ctx):
    c, _ = ctx
    r = st.run_shell(c, {"command": "head -c 5000000 /dev/zero | tr '\\0' 'a'"})
    assert r["exit_code"] == 0
    assert len(r["stdout"]) < st.SHELL_OUTPUT_CAP + 200 and "truncated" in r["stdout"]


def test_shell_no_stdin_and_background_does_not_hang(ctx):
    c, _ = ctx
    t0 = time.time()
    r = st.run_shell(c, {"command": "cat; (sleep 5 >/dev/null 2>&1 &) ; echo done", "timeout": 20})
    assert time.time() - t0 < 6 and r["stdout"].strip() == "done"


def test_shell_secret_redaction(tmp_path):
    run_dir, cfg = make_config(tmp_path, env={"API_TOKEN": "tok-abcdefghijkl"})
    c = RunContext(config=parse_config(cfg, "run1"), run_dir=run_dir,
                   workspace=os.path.realpath(cfg["workspace"]), events=EventWriter(run_dir))
    r = st.run_shell(c, {"command": "echo $API_TOKEN"})
    assert "tok-abcdefghijkl" not in r["stdout"] and "[redacted]" in r["stdout"]


def test_shell_bad_args(ctx):
    c, _ = ctx
    assert "error" in st.run_shell(c, {})
    assert "error" in st.run_shell(c, {"command": "   "})


# ---- GUI tools degrade gracefully (macOS: no scrot/xdotool/wmctrl)
def test_gui_tools_degrade_without_binaries(ctx, monkeypatch):
    c, _ = ctx
    monkeypatch.setattr(st.shutil, "which", lambda n: None)
    for fn, args in [(st.screenshot, {}), (st.list_windows, {}), (st.focus_window, {"title": "x"}),
                     (st.open_app, {"app": "terminal"}), (st.click, {"x": 1, "y": 2}),
                     (st.type_text, {"text": "hi"}), (st.press_key, {"key": "Return"}),
                     (st.scroll, {"direction": "down"})]:
        r = fn(c, args)
        assert "error" in r and "not available" in r["error"], (fn.__name__, r)
    assert not (c.workspace and os.path.exists(os.path.join(c.workspace, ".type_text_tmp")))


def test_gui_argument_validation(ctx, monkeypatch):
    c, _ = ctx
    assert "invalid key" in st.press_key(c, {"key": "ctrl+l; rm -rf /"})["error"]
    assert "error" in st.scroll(c, {"direction": "sideways"})
    assert "error" in st.open_app(c, {"app": "browser", "url": "--remote-debugging-port=1"})
    assert "unknown app" in st.open_app(c, {"app": "calculator"})["error"]
    assert "requires" in st.click(c, {"x": 1})["error"]


def test_virtual_workspace_prefix_alias(ctx):
    c, tmp = ctx
    assert "error" not in st.write_file(c, {"path": "/workspace/v/a.txt", "content": "1"})
    assert (tmp / "workspace" / "v" / "a.txt").read_text() == "1"
    assert st.read_file(c, {"path": "/workspace/v/a.txt"})["content"] == "1"
    assert st.list_files(c, {"path": "/workspace"})["entries"] == ["v/"]
    assert "escapes" in st.read_file(c, {"path": "/workspace/../etc/passwd"})["error"]
    assert "error" in st.read_file(c, {"path": "/workspacefoo/x"})
