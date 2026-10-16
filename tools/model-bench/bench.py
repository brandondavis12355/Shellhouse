#!/usr/bin/env python3
"""Compare OpenAI-compatible model endpoints on the same prompts: speed (time to first token, decode tokens/s,
prefill on a long prompt) and accuracy (checkable answers, JSON format, tool-call). Standard library only.

  bench.py --name ollama-qwen3.6 --url http://127.0.0.1:11434/v1 --model qwen3.6:35b-mlx
  bench.py --name mlx-qwen3-spec  --url http://127.0.0.1:8081/v1  --model mlx-community/Qwen3-30B-A3B-4bit

Run it once per configuration, then compare the printed tables (or the --json files with --compare).
"""
import argparse, json, statistics, sys, time, urllib.request, uuid

CHAT = "Explain in about 150 words how a hash map handles collisions."
CODE = "Write a Python function merge_intervals(intervals) that merges overlapping [start, end] intervals. Code only."
LONG_FILLER = ("The quarterly report covers shipping volumes, crew scheduling, fuel prices and maintenance windows. "
               "Delays were mostly weather related, with two incidents of equipment failure at regional hubs. ") * 140
SUMMARY = LONG_FILLER + "\n\nIn two sentences, what were the main causes of delays described above?"

QA = [  # (prompt, accepted substrings, all lower-case)
    ("What is 17 * 23? Reply with just the number.", ["391"]),
    ("What is the capital of Australia? One word.", ["canberra"]),
    ("If a train leaves at 14:10 and the trip takes 2h 55m, when does it arrive? Reply as HH:MM.", ["17:05"]),
    ("Sort these numbers ascending and reply with only the list, comma separated: 42, 7, 19, 3, 88", ["3, 7, 19, 42, 88", "3,7,19,42,88"]),
    ("How many letters are in the word 'strawberry'? Reply with just the number.", ["10"]),
    ("Which is larger, 9.11 or 9.9? Reply with just the number.", ["9.9"]),
]
JSON_PROMPT = 'Reply with ONLY a JSON object with keys "city" (string) and "population_millions" (number) for Tokyo. No prose.'
TOOLS = [{"type": "function", "function": {
    "name": "get_weather", "description": "Get the current weather for a city.",
    "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
TOOL_PROMPT = "What's the weather in Paris right now? Use the tool."


def post(url, key, body, stream=False, timeout=600):
    req = urllib.request.Request(url + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
    return urllib.request.urlopen(req, timeout=timeout)


def base_body(model, messages, max_tokens, extra):
    body = {"model": model, "messages": messages, "temperature": 0, "max_tokens": max_tokens,
            # Ignored by servers that don't know them; switches thinking off where supported.
            "reasoning_effort": "none", "chat_template_kwargs": {"enable_thinking": False}}
    body.update(extra)
    return body


def stream_run(args, prompt, max_tokens):
    body = base_body(args.model, [{"role": "user", "content": prompt}], max_tokens, {"stream": True, "stream_options": {"include_usage": True}})
    start = time.time(); first = None; chunks = 0; usage = None; text = []
    with post(args.url, args.key, body, True) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data:") or line.endswith("[DONE]"):
                continue
            data = json.loads(line[5:])
            if data.get("usage"):
                usage = data["usage"]
            for choice in data.get("choices", []):
                piece = (choice.get("delta") or {}).get("content") or ""
                if piece:
                    if first is None:
                        first = time.time()
                    chunks += 1; text.append(piece)
    end = time.time()
    out_tokens = (usage or {}).get("completion_tokens") or chunks
    first = first or end
    return {"ttft": first - start, "total": end - start, "tokens": out_tokens,
            "tps": out_tokens / max(end - first, 1e-6) if out_tokens > 1 else 0.0,
            "prompt_tokens": (usage or {}).get("prompt_tokens"), "text": "".join(text)}


def ask(args, prompt, max_tokens=200, extra=None):
    body = base_body(args.model, [{"role": "user", "content": prompt}], max_tokens, extra or {})
    with post(args.url, args.key, body) as resp:
        return json.load(resp)["choices"][0]["message"]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--name"); p.add_argument("--url"); p.add_argument("--model")
    p.add_argument("--key", default="none"); p.add_argument("--runs", type=int, default=3)
    p.add_argument("--json", help="write results here"); p.add_argument("--compare", nargs="+", help="print a table from result files")
    args = p.parse_args()
    if args.compare:
        return compare(args.compare)
    if not (args.name and args.url and args.model):
        p.error("--name, --url and --model are required unless --compare is used")

    print(f"warming up {args.name} ...", file=sys.stderr)
    stream_run(args, "Say hi.", 8)

    speed = {}
    for label, prompt, cap in [("chat", CHAT, 220), ("code", CODE, 300), ("long_prompt", SUMMARY, 120)]:
        # A unique prefix per run, so a server's prompt cache can't make the prefill look free.
        runs = [stream_run(args, f"[{uuid.uuid4().hex}] " + prompt, cap) for _ in range(args.runs)]
        speed[label] = {"ttft_s": statistics.median(r["ttft"] for r in runs), "tps": statistics.median(r["tps"] for r in runs),
                        "total_s": statistics.median(r["total"] for r in runs), "prompt_tokens": runs[0]["prompt_tokens"]}
        print(f"  {label}: ttft {speed[label]['ttft_s']:.2f}s  {speed[label]['tps']:.1f} tok/s", file=sys.stderr)

    correct = 0
    for q, ok in QA:
        reply = (ask(args, q, 40).get("content") or "").lower()
        correct += any(a in reply for a in ok)
    json_ok = False
    try:
        obj = json.loads((ask(args, JSON_PROMPT, 80).get("content") or "").strip().strip("`").removeprefix("json").strip())
        json_ok = isinstance(obj.get("city"), str) and isinstance(obj.get("population_millions"), (int, float))
    except Exception:
        pass
    tool_ok = False
    try:
        msg = ask(args, TOOL_PROMPT, 100, {"tools": TOOLS})
        calls = msg.get("tool_calls") or []
        tool_ok = bool(calls) and calls[0]["function"]["name"] == "get_weather" and "paris" in calls[0]["function"]["arguments"].lower()
    except Exception:
        pass
    accuracy = {"qa": f"{correct}/{len(QA)}", "json": json_ok, "tool_call": tool_ok}
    result = {"name": args.name, "model": args.model, "speed": speed, "accuracy": accuracy}
    print(json.dumps(result, indent=2))
    if args.json:
        json.dump(result, open(args.json, "w"), indent=2)


def compare(paths):
    rows = [json.load(open(p)) for p in paths]
    print("| config | chat tok/s | code tok/s | chat TTFT | long-prompt TTFT | QA | JSON | tool call |")
    print("|---|---|---|---|---|---|---|---|")
    for r in rows:
        s, a = r["speed"], r["accuracy"]
        print(f"| {r['name']} | {s['chat']['tps']:.1f} | {s['code']['tps']:.1f} | {s['chat']['ttft_s']:.2f}s | {s['long_prompt']['ttft_s']:.2f}s "
              f"| {a['qa']} | {'yes' if a['json'] else 'no'} | {'yes' if a['tool_call'] else 'no'} |")


if __name__ == "__main__":
    main()
