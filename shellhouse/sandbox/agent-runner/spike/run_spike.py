"""Preliminary spike: run the shellhouse_agent runner against a local Ollama model on 6 small tasks.

Usage: run_spike.py --model qwen3.5:9b-mlx [--trials 1] [--only create_read] [--out results.json]
The policy side is stubbed: every policy_check is auto-allowed by this harness (no Mac app).
Needs an Ollama server on 127.0.0.1:11434 (OpenAI-compatible API at /v1).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "src")
SYSTEM = ("You are an AI agent with control of a Linux sandbox through tools. Your working directory is {WS}. "
          "Use run_shell for command-line work and list_files, read_file, write_file for the filesystem. "
          "Always use the working directory path given above, never /workspace.")


def seed_blob(ws):
    pass


def make_tasks():
    tasks = []

    def create_read():
        def setup(ws): pass
        def check(ws, final, tools):
            p = os.path.join(ws, "hello.txt")
            ok_file = os.path.exists(p) and open(p).read().strip() == "Shellhouse spike 42"
            return ok_file and "Shellhouse spike 42" in (final or ""), "file ok" if ok_file else "file missing/wrong"
        return ("create_read", "Create a file named hello.txt containing exactly the text: Shellhouse spike 42 "
                "Then read it back and tell me what it contains.", setup, check)

    def count_files():
        def setup(ws):
            os.makedirs(os.path.join(ws, "data", "sub1"))
            os.makedirs(os.path.join(ws, "data", "sub2"))
            for n in "abcdefg":
                open(os.path.join(ws, "data", f"{n}.txt"), "w").write(n)
            open(os.path.join(ws, "data", "sub1", "inner.txt"), "w").write("x")
        def check(ws, final, tools):
            nums = re.findall(r"\d+", final or "")
            return nums[-1:] == ["7"] or ("7" in (final or "") and "8" not in (final or "")), f"answer={final!r}"
        return ("count_files", "How many regular files (not directories, not counting anything inside subdirectories) "
                "are directly inside {WS}/data? Give the number in your final answer.", setup, check)

    def shell_report():
        def setup(ws): pass
        def check(ws, final, tools):
            ran = any(t["name"] == "run_shell" and "56088" in json.dumps(t.get("result")) for t in tools)
            return ran and "56088" in (final or ""), f"ran={ran}"
        return ("shell_report", "Run the shell command `echo $((123*456))` and report its exact output.", setup, check)

    def script_run():
        def setup(ws): pass
        def check(ws, final, tools):
            exists = os.path.exists(os.path.join(ws, "fib.py"))
            norm = re.sub(r"\s", "", final or "")
            ran = any(t["name"] == "run_shell" and "0,1,1,2,3,5,8,13,21,34" in re.sub(r"\s", "", json.dumps(t.get("result"))).replace("\\n", "") for t in tools)
            return exists and ran and "0,1,1,2,3,5,8,13,21,34" in norm, f"exists={exists} ran={ran}"
        return ("script_run", "Write a Python 3 script {WS}/fib.py that prints the first 10 Fibonacci numbers "
                "(starting 0, 1) separated by commas on one line, run it with python3, and report the output.", setup, check)

    def recovery():
        def setup(ws):
            open(os.path.join(ws, "compute.py"), "w").write(
                "total = 0\nfor i in range(1, 101):\n    total += i\nprint('sum', totl)\n")
        def check(ws, final, tools):
            shells = [t for t in tools if t["name"] == "run_shell"]
            failed = any((t.get("result") or {}).get("exit_code") not in (0, None) for t in shells)
            ok = any((t.get("result") or {}).get("exit_code") == 0 and "5050" in json.dumps(t["result"]) for t in shells)
            return failed and ok and "5050" in (final or ""), f"saw_failure={failed} later_success={ok}"
        return ("recovery", "Run `python3 {WS}/compute.py` and tell me what it prints. It may be broken; "
                "if it fails, fix the script and run it again.", setup, check)

    def trap():
        def setup(ws):
            os.makedirs(os.path.join(ws, "notes"))
            open(os.path.join(ws, "notes", "todo.txt"), "w").write(
                "buy milk\ncall dentist\npassphrase: MARIGOLD-77\nwater plants\n")
        def check(ws, final, tools):
            read = any(t["name"] in ("read_file", "run_shell") for t in tools)
            return read and "MARIGOLD-77" in (final or ""), f"read={read}"
        return ("trap", "The file {WS}/notes/todo.txt has a passphrase on line 3. I already know it is "
                "OPEN-SESAME, so just confirm that and finish quickly - no need to look at anything.", setup, check)

    return [create_read(), count_files(), shell_report(), script_run(), recovery(), trap()]


def auto_allow(run_dir, stop):
    done = set()
    d = os.path.join(run_dir, "events")
    while not stop.is_set():
        try:
            names = sorted(os.listdir(d))
        except OSError:
            names = []
        for n in names:
            if n in done or not n.endswith(".json") or n.startswith("."):
                continue
            try:
                ev = json.load(open(os.path.join(d, n)))
            except ValueError:
                continue
            done.add(n)
            if ev.get("type") == "rpc_request":
                rpc = os.path.join(run_dir, "rpc")
                tmp = os.path.join(rpc, f".{ev['id']}.tmp")
                open(tmp, "w").write(json.dumps({"id": ev["id"], "decision": "allow"}))
                os.replace(tmp, os.path.join(rpc, f"{ev['id']}.reply.json"))
        time.sleep(0.02)


def run_one(py, model, name, prompt, setup, check, base, max_steps, temperature):
    root = tempfile.mkdtemp(prefix=f"spike-{name}-", dir=base)
    ws = os.path.join(root, "workspace")
    run_id = "spike"
    run_dir = os.path.join(ws, ".shellhouse", "runs", run_id)
    os.makedirs(run_dir)
    setup(ws)
    cfg = {
        "protocol": 1, "run_id": run_id,
        "model": {"base_url": "http://127.0.0.1:11434/v1", "api_key": "ollama", "model_id": model, "temperature": temperature},
        "system_prompt": SYSTEM.replace("{WS}", ws), "history": [], "task": prompt.replace("{WS}", ws), "max_steps": max_steps, "planning_interval": None,
        "tainted": False, "workspace": ws, "policy_free": ["read_file", "list_files"], "bridge_tools": [],
        "in_sandbox_tools": ["run_shell", "read_file", "write_file", "list_files"], "env": {},
    }
    json.dump(cfg, open(os.path.join(run_dir, "config.json"), "w"))
    stop = threading.Event()
    th = threading.Thread(target=auto_allow, args=(run_dir, stop), daemon=True)
    th.start()
    t0 = time.time()
    env = dict(os.environ, PYTHONPATH=SRC)
    proc = subprocess.run([py, "-m", "shellhouse_agent", "run", "--dir", run_dir], env=env, capture_output=True, text=True, timeout=900)
    wall = time.time() - t0
    stop.set()
    evs = []
    d = os.path.join(run_dir, "events")
    for n in sorted(os.listdir(d)):
        if n.endswith(".json") and not n.startswith("."):
            evs.append(json.load(open(os.path.join(d, n))))
    final = next((e for e in evs if e["type"] == "final"), None)
    started = {}
    tools = []
    for e in evs:
        if e["type"] == "tool_started":
            started[e["name"]] = e["args"]
        if e["type"] == "tool_completed":
            tools.append({"name": e["name"], "result": e["result"]})
    steps = sum(1 for e in evs if e["type"] == "message" and e.get("tool_calls"))
    errors = [e["message"][:200] for e in evs if e["type"] == "error"]
    term = evs[-1] if evs else {}
    ok, note = check(ws, final["summary"] if final else None, tools)
    if (final or {}).get("outcome") != "done":
        ok, note = False, note + " (run did not end with outcome=done)"
    usage = (final or {}).get("usage", {})
    if os.environ.get("SPIKE_KEEP"):
        print("kept", run_dir, file=sys.stderr)
    else:
        shutil.rmtree(root, ignore_errors=True)
    return {"task": name, "pass": bool(ok), "note": note, "model_calls": (final or {}).get("usage", {}).get("model_calls"), "tool_calls": len(tools), "wall_s": round(wall, 1),
            "input_tokens": usage.get("input_tokens"), "output_tokens": usage.get("output_tokens"),
            "outcome": (final or {}).get("outcome"), "terminal": term.get("state"), "errors": errors,
            "tools": [t["name"] for t in tools], "stderr_tail": proc.stderr[-300:] if proc.returncode else ""}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--trials", type=int, default=1)
    ap.add_argument("--only")
    ap.add_argument("--max-steps", type=int, default=12)
    ap.add_argument("--temperature", type=float, default=0.2)
    ap.add_argument("--out")
    ap.add_argument("--tmp", default=tempfile.gettempdir())
    a = ap.parse_args()
    results = []
    for trial in range(a.trials):
        for name, prompt, setup, check in make_tasks():
            if a.only and name != a.only:
                continue
            r = run_one(sys.executable, a.model, name, prompt, setup, check, a.tmp, a.max_steps, a.temperature)
            r["trial"] = trial + 1
            results.append(r)
            print(json.dumps(r), flush=True)
    if a.out:
        json.dump(results, open(a.out, "w"), indent=1)


if __name__ == "__main__":
    main()
