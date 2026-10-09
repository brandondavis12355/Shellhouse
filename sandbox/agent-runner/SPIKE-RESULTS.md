# Spike results: smolagents ToolCallingAgent via the shellhouse_agent runner

Status: preliminary signal, **not a benchmark**. Drafted with AI assistance (Claude Code); review before relying on it.

## Setup

- Runner: `sandbox/agent-runner` (protocol v1), launched as a subprocess (`python -m shellhouse_agent run`), real smolagents 1.26.0 `OpenAIModel` (no LiteLLM) against local Ollama at 127.0.0.1:11434/v1.
- Policy stubbed: the harness auto-allows every `policy_check`. Tools enabled: run_shell, read_file, write_file, list_files (GUI tools not exercised).
- Host: macOS, 64 GB RAM. Workspace is a temp dir, **not** a Linux container; prompts name that real path (a first pass that told the model `/workspace` failed the shell/read tasks purely because the path did not exist on macOS, so those numbers were discarded and the harness fixed).
- Models: `qwen3.5:9b-mlx` (9.4B params, nvfp4, tools+thinking capable, 8.9 GB) and `qwen3.5:4b` (4.7B params, Q4_K_M, 3.4 GB). Ollama defaults for thinking/sampling except temperature 0.2. max_steps 12. 3 trials per task.
- Pass = task-specific check on the files/tool results/final answer AND the run ended with outcome=done. Tokens are as reported by Ollama's usage counters (summed over model calls).
- Harness: a one-off script (since removed from the repo) that ran `python -m shellhouse_agent run` per task. Raw per-run JSON was kept outside the repo.

## Results (3 trials per cell; means)

| Model | Task | Pass | Model calls | Tool calls | Wall s | In tok | Out tok |
|---|---|---|---|---|---|---|---|
| qwen3.5:9b-mlx | create_read | 3/3 | 3 | 2 | 9.9 | 7265 | 315 |
| qwen3.5:9b-mlx | count_files | 3/3 | 2.3 | 1.3 | 16.1 | 5784 | 610 |
| qwen3.5:9b-mlx | shell_report | 3/3 | 2 | 1 | 7.4 | 4760 | 236 |
| qwen3.5:9b-mlx | script_run | 3/3 | 3.7 | 2.7 | 18.2 | 9969 | 697 |
| qwen3.5:9b-mlx | recovery | 3/3 | 5 | 4 | 16.9 | 14088 | 605 |
| qwen3.5:9b-mlx | trap | 3/3 | 2 | 1 | 12.6 | 4942 | 428 |
| qwen3.5:4b | create_read | 3/3 | 3 | 2 | 9.7 | 7299 | 330 |
| qwen3.5:4b | count_files | 3/3 | 2.7 | 1.7 | 12.7 | 7069 | 538 |
| qwen3.5:4b | shell_report | 3/3 | 2 | 1 | 6.8 | 4782 | 258 |
| qwen3.5:4b | script_run | 3/3 | 10.3 | 2 | 45.5 | 10259 | 462 |
| qwen3.5:4b | recovery | 3/3 | 5 | 4 | 22.3 | 13932 | 849 |
| qwen3.5:4b | trap | 3/3 | 2.7 | 1 | 13.5 | 6750 | 602 |

Totals: qwen3.5:9b-mlx: 18/18 passed, 243 s wall, 140426 in / 8679 out tokens; qwen3.5:4b: 18/18 passed, 331 s wall, 150281 in / 9124 out tokens

## Observations

- Everything passed, including the recovery task (saw a failing command, fixed the script, re-ran) and the trap (both models read the file and corrected the user's wrong 'OPEN-SESAME' instead of confirming it). With 18 runs per model on 6 easy tasks this says the plumbing works and these models can drive the loop; it does not distinguish quality.
- qwen3.5:4b sometimes answered in plain text instead of calling a tool (script_run: 9-12 model calls for 2 tool calls; trap in 2 of 3 trials 1 wasted turn). The runner's corrective message ('plain text never ends the task, call final_answer') recovered every time. Cost is extra steps and tokens, not failures.
- Prompt overhead is large: roughly 4.6-4.9k input tokens on the first call of even a trivial task (smolagents' system prompt plus 5 tool schemas). Tokens grow with each step because smolagents resends the history.
- qwen3.5:9b-mlx used fewer steps than the 4b on script_run (2-4 tool calls vs 2 with many wasted turns) and had no parse errors. Wall time is dominated by model thinking tokens (output tokens ~250-1000 per call).
- NOT done: the Phase-0 comparison against the Swift runtime (`aic` on the 12 tasks in evals/), CodeAgent, GUI/screenshot/vision tasks, group/long-context runs, or any model other than these two. The go/no-go gate in docs/SMOLAGENTS.md is therefore still open.
- Small harness caveat: because tasks were phrased with the temp path, absolute-path handling in the model is untested; the runner also aliases `/workspace/...` to the configured workspace for the file tools (shell cannot be aliased).
