"""CLI: `python3 -m shellhouse_agent run|tail --dir <run_dir> ...`"""

from __future__ import annotations

import argparse
import os
import sys


VENV_PYTHON = "/opt/shellhouse-agent/bin/python"


def venv_python_to_use(env: dict[str, str], current_prefix: str, exists) -> str | None:
    """Which interpreter `run` must switch to, or None to stay on the current one.

    System python3 in the image has none of smolagents' dependencies; they live
    in the venv. Decided by the interpreter's *prefix* (the venv's python is a
    symlink to the system python3, so comparing executable paths is useless) and
    never by probing an import (a stray `smolagents` directory on the path made
    that probe pass while the real dependencies were still missing).
    """
    if env.get("SHELLHOUSE_AGENT_REEXECED") == "1" or env.get("SHELLHOUSE_AGENT_NO_REEXEC") == "1":
        return None
    py = env.get("SHELLHOUSE_AGENT_PYTHON", VENV_PYTHON)
    if not exists(py):
        return None
    venv_root = os.path.dirname(os.path.dirname(py))
    if os.path.realpath(current_prefix) == os.path.realpath(venv_root):
        return None
    return py


def _reexec_into_venv_if_needed() -> None:
    py = venv_python_to_use(dict(os.environ), sys.prefix, os.path.exists)
    if py:
        os.environ["SHELLHOUSE_AGENT_REEXECED"] = "1"   # never loop
        os.execv(py, [py, "-m", "shellhouse_agent"] + sys.argv[1:])


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="shellhouse_agent")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="run the agent for a prepared run directory")
    r.add_argument("--dir", required=True)
    t = sub.add_parser("tail", help="print events after a sequence number as JSONL")
    t.add_argument("--dir", required=True)
    t.add_argument("--after", type=int, default=0)
    t.add_argument("--max-bytes", type=int, default=262144)
    a = p.parse_args(argv)
    if a.cmd == "tail":
        from .events import tail

        tail(os.path.abspath(a.dir), max(0, a.after), max(1, a.max_bytes), sys.stdout)
        return 0
    _reexec_into_venv_if_needed()
    from .runner import run

    return run(a.dir)
