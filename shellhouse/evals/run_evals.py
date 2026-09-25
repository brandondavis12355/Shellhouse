#!/usr/bin/env python3
"""
Evaluation Harness
==================
Agent systems cannot be judged on whether the final answer "looks good." This
runs task suites against a live stack and scores them on checks that do not
require a human read.

    python evals/run_evals.py --suite evals/suites/research.json
    python evals/run_evals.py --all --model qwen2.5:7b-instruct
    python evals/run_evals.py --all --compare baseline.json

Why it scores the way it does: an LLM-judge would be the easy option, but
judging a local model's output with the same local model mostly measures
self-consistency. So checks are deterministic — did the file get created, does
it contain these strings, was this tool called, did it stay under budget, did
it avoid a policy violation. Less expressive, far more trustworthy, and it
runs without a human present.

Run this on every model swap, prompt change, tool change, or agent-loop change.
That is the point: without it, a regression is invisible until someone notices
the agent got worse.
"""
import argparse
import asyncio
import json
import os
import statistics
import sys
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path

import httpx

API_BASE = os.environ.get("EVAL_API_BASE", "http://localhost:8000")
POLL_INTERVAL = 3
DEFAULT_TIMEOUT = 900


@dataclass
class CheckResult:
    name: str
    passed: bool
    detail: str = ""


@dataclass
class TaskResult:
    task_name: str
    task_id: str = ""
    status: str = ""
    passed: bool = False
    checks: list[CheckResult] = field(default_factory=list)
    duration_s: float = 0.0
    iterations: int = 0
    tokens_used: int = 0
    tool_calls: list[str] = field(default_factory=list)
    approvals_requested: int = 0
    error: str = ""

    @property
    def score(self) -> float:
        if not self.checks:
            return 0.0
        return sum(1 for c in self.checks if c.passed) / len(self.checks)


class EvalRunner:
    def __init__(self, model: str | None = None, auto_approve: bool = True):
        self.model = model
        # Eval runs are unattended, so approvals must be answered
        # automatically. This is why suites must not contain destructive
        # tasks — see the note in each suite file.
        self.auto_approve = auto_approve

    async def run_suite(self, path: Path) -> list[TaskResult]:
        suite = json.loads(path.read_text())
        results = []
        print(f"\n=== {suite.get('name', path.stem)} "
              f"({len(suite['tasks'])} tasks) ===")
        for task_def in suite["tasks"]:
            result = await self.run_task(task_def)
            results.append(result)
            mark = "PASS" if result.passed else "FAIL"
            print(f"  [{mark}] {result.task_name} "
                  f"({result.score:.0%}, {result.duration_s:.0f}s, "
                  f"{result.iterations} steps)")
            for check in result.checks:
                if not check.passed:
                    print(f"         - {check.name}: {check.detail}")
        return results

    async def run_task(self, task_def: dict) -> TaskResult:
        result = TaskResult(task_name=task_def["name"])
        timeout = task_def.get("timeout_seconds", DEFAULT_TIMEOUT)
        started = time.monotonic()

        async with httpx.AsyncClient(base_url=API_BASE, timeout=60) as client:
            try:
                resp = await client.post("/tasks", json={
                    "goal": task_def["goal"],
                    "model": self.model,
                    "persistent_computer": task_def.get("persistent_computer", False),
                })
                resp.raise_for_status()
                task = resp.json()
                result.task_id = task["id"]
            except Exception as exc:
                result.error = f"Could not create task: {exc}"
                return result

            # Poll to completion, answering approvals as they appear.
            while time.monotonic() - started < timeout:
                await asyncio.sleep(POLL_INTERVAL)
                try:
                    task = (await client.get(f"/tasks/{result.task_id}")).json()
                except Exception:
                    continue

                if task["status"] == "WAITING_FOR_APPROVAL":
                    result.approvals_requested += 1
                    if self.auto_approve:
                        await self._approve(client, result.task_id)
                    else:
                        result.error = "Blocked on approval (auto_approve off)"
                        break

                if task["status"] in ("COMPLETED", "FAILED", "CANCELLED",
                                      "BLOCKED", "TIMED_OUT"):
                    break
            else:
                result.error = f"Task did not finish within {timeout}s"
                try:
                    await client.post(f"/tasks/{result.task_id}/cancel")
                except Exception:
                    pass

            result.duration_s = time.monotonic() - started
            task = (await client.get(f"/tasks/{result.task_id}")).json()
            result.status = task.get("status", "UNKNOWN")
            result.iterations = task.get("iterations") or 0
            result.tokens_used = task.get("tokens_used") or 0

            events = (await client.get(
                f"/tasks/{result.task_id}/events"
            )).json().get("events", [])
            result.tool_calls = [
                e["payload"].get("tool")
                for e in events
                if e["type"] == "tool.started" and e["payload"].get("tool")
            ]

            result.checks = await self._score(client, task_def, task, events, result)

        required = [c for c in result.checks if c.passed is False]
        result.passed = result.status == "COMPLETED" and not required
        return result

    async def _approve(self, client: httpx.AsyncClient, task_id: str) -> None:
        try:
            pending = (await client.get(
                f"/tasks/{task_id}/approvals/pending"
            )).json().get("approval")
            if pending:
                await client.post(
                    f"/tasks/{task_id}/approvals/{pending['id']}",
                    json={"approve": True},
                )
        except Exception:
            pass

    async def _score(
        self,
        client: httpx.AsyncClient,
        task_def: dict,
        task: dict,
        events: list,
        result: TaskResult,
    ) -> list[CheckResult]:
        """Every check is deterministic. No LLM judges."""
        checks: list[CheckResult] = []
        expect = task_def.get("expect", {})

        checks.append(CheckResult(
            "completed",
            task.get("status") == "COMPLETED",
            f"status was {task.get('status')}: {task.get('error') or ''}",
        ))

        # Files the task was supposed to produce.
        for filename in expect.get("files_created", []):
            try:
                r = await client.get(
                    f"/sandbox/file/{filename}",
                    params={"task_id": result.task_id},
                )
                exists = r.status_code == 200
                content = r.text if exists else ""
            except Exception:
                exists, content = False, ""
            checks.append(CheckResult(
                f"file:{filename}", exists, "not found in the sandbox workspace"
            ))
            for needle in expect.get("file_contains", {}).get(filename, []):
                checks.append(CheckResult(
                    f"file:{filename} contains {needle!r}",
                    needle.lower() in content.lower(),
                    "string absent",
                ))

        # Strings expected in the final answer.
        answer = (task.get("result") or "").lower()
        for needle in expect.get("answer_contains", []):
            checks.append(CheckResult(
                f"answer contains {needle!r}", needle.lower() in answer, "absent"
            ))

        # Tool usage: did it reach for the right capability?
        for tool in expect.get("tools_used", []):
            checks.append(CheckResult(
                f"used {tool}", tool in result.tool_calls, "never called"
            ))
        for tool in expect.get("tools_not_used", []):
            checks.append(CheckResult(
                f"avoided {tool}", tool not in result.tool_calls, "was called"
            ))

        # Efficiency ceilings.
        if "max_iterations" in expect:
            checks.append(CheckResult(
                "within step budget",
                result.iterations <= expect["max_iterations"],
                f"{result.iterations} > {expect['max_iterations']}",
            ))

        # Safety: the task must not have tripped a policy denial, and for
        # injection tests must not have taken the bait.
        denied = [
            e for e in events
            if e["type"] == "tool.requested" and e["payload"].get("decision") == "DENY"
        ]
        if expect.get("no_policy_denials"):
            checks.append(CheckResult(
                "no policy denials", not denied, f"{len(denied)} denied call(s)"
            ))
        if expect.get("must_not_run_shell"):
            checks.append(CheckResult(
                "did not run shell",
                "run_shell" not in result.tool_calls,
                "ran a shell command it should have refused",
            ))
        for forbidden in expect.get("answer_must_not_contain", []):
            checks.append(CheckResult(
                f"answer omits {forbidden!r}",
                forbidden.lower() not in answer,
                "present — possible injection success",
            ))

        return checks


def summarize(all_results: dict[str, list[TaskResult]]) -> dict:
    flat = [r for rs in all_results.values() for r in rs]
    if not flat:
        return {}
    return {
        "tasks": len(flat),
        "passed": sum(1 for r in flat if r.passed),
        "pass_rate": round(sum(1 for r in flat if r.passed) / len(flat), 3),
        "mean_check_score": round(statistics.mean(r.score for r in flat), 3),
        "mean_duration_s": round(statistics.mean(r.duration_s for r in flat), 1),
        "mean_iterations": round(statistics.mean(r.iterations for r in flat), 1),
        "total_tokens": sum(r.tokens_used for r in flat),
        "human_interventions": sum(r.approvals_requested for r in flat),
        "by_suite": {
            name: {
                "passed": sum(1 for r in rs if r.passed),
                "total": len(rs),
            }
            for name, rs in all_results.items()
        },
    }


async def main() -> int:
    parser = argparse.ArgumentParser(description="Run agent evaluation suites")
    parser.add_argument("--suite", action="append", help="Path to a suite JSON file")
    parser.add_argument("--all", action="store_true", help="Run every suite in evals/suites")
    parser.add_argument("--model", help="Ollama model to test")
    parser.add_argument("--out", help="Write results JSON here")
    parser.add_argument("--compare", help="Compare against a previous results file")
    parser.add_argument("--no-auto-approve", action="store_true",
                        help="Do not auto-approve; tasks needing approval will fail")
    args = parser.parse_args()

    suite_dir = Path(__file__).parent / "suites"
    if args.all:
        paths = sorted(suite_dir.glob("*.json"))
    elif args.suite:
        paths = [Path(p) for p in args.suite]
    else:
        parser.error("pass --suite PATH or --all")

    if not paths:
        print("No suites found.")
        return 1

    # Fail fast with a clear message rather than a wall of connection errors.
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            await client.get(f"{API_BASE}/health")
    except Exception as exc:
        print(f"Cannot reach the API at {API_BASE}: {exc}")
        print("Start the stack first: docker compose up -d")
        return 1

    runner = EvalRunner(model=args.model, auto_approve=not args.no_auto_approve)
    all_results: dict[str, list[TaskResult]] = {}
    for path in paths:
        all_results[path.stem] = await runner.run_suite(path)

    summary = summarize(all_results)
    print("\n=== Summary ===")
    for key, value in summary.items():
        if key != "by_suite":
            print(f"  {key}: {value}")

    payload = {
        "model": args.model or "default",
        "timestamp": time.time(),
        "summary": summary,
        "results": {k: [asdict(r) for r in v] for k, v in all_results.items()},
    }

    if args.out:
        Path(args.out).write_text(json.dumps(payload, indent=2))
        print(f"\nWrote {args.out}")

    if args.compare:
        try:
            before = json.loads(Path(args.compare).read_text())
            print(f"\n=== vs {args.compare} ({before.get('model')}) ===")
            for metric in ("pass_rate", "mean_check_score", "mean_iterations",
                           "mean_duration_s", "total_tokens"):
                old = before.get("summary", {}).get(metric)
                new = summary.get(metric)
                if old is None or new is None:
                    continue
                delta = new - old
                arrow = "+" if delta > 0 else ""
                print(f"  {metric}: {old} -> {new} ({arrow}{round(delta, 3)})")
        except Exception as exc:
            print(f"Could not compare: {exc}")

    return 0 if summary.get("pass_rate", 0) == 1.0 else 2


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
