# Model tiers, thinking, and parallel helpers

Local replies are slow for three separate reasons. Each has its own fix.

## 1. Thinking mode (the big one)

Reasoning models (qwen3.x, deepseek-r1, …) "think" before answering. On `qwen3.5:9b-mlx` a one-line
greeting took ~99 s with thinking on (≈1,400 hidden tokens) and ~1.2 s with it off. The app now sends
`think: false` on every Ollama request (`OllamaBackend(thinking: false)` by default).

## 2. Two model tiers

* **Bot model** – the model chosen per bot; does the real work (agent turns, tools).
* **Fast model** (Settings › Fast model) – a small model, e.g. `qwen3.5:4b`, used for the reply gate,
  the goal-intake check, group small talk, and `ask_helpers`. Empty = use each bot's own model.

Group messages are classified without any model (`AddressingAnalyzer`); small talk and short questions
get one direct fast-model call instead of a full agent run.

## 3. Parallel helpers (`ask_helpers`)

A bot can call `ask_helpers` with up to 4 self-contained prompts. They run concurrently on the fast model
and come back together. Helpers have no tools, files or memory; their output is unverified model text.
The tool has no side effects, so the guardrails allow it even in untrusted runs.

## Ollama settings that decide whether anything runs in parallel

One GPU generates one stream at a time unless Ollama is told to batch. The app sets these only when it
starts `ollama serve` itself. If Ollama is already running (the Ollama app, brew services), set them there:

```bash
launchctl setenv OLLAMA_NUM_PARALLEL 4
launchctl setenv OLLAMA_MAX_LOADED_MODELS 2
```

then quit and reopen Ollama. Higher parallelism multiplies the KV-cache memory used, so lower it if
the machine starts swapping. Check what is loaded with `ollama ps`.
