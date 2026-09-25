"""
Model Gateway
=============
Single chokepoint the agent runtime uses to talk to a model. Today it has
exactly one backend: a local Ollama server. No code path in this file (or
anywhere else in the project) calls out to a cloud model API.

Swapping in vLLM or another OpenAI-compatible local server later means
adding a new class here that implements the same `chat()` signature — the
runtime never needs to change.
"""
import json
import os
from typing import Any, Optional

import httpx

OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")
DEFAULT_MODEL = os.environ.get("OLLAMA_MODEL", "qwen2.5:7b-instruct")


class ModelGateway:
    """Thin async client for Ollama's /api/chat with tool-calling support."""

    def __init__(self, base_url: str = OLLAMA_BASE_URL):
        self.base_url = base_url
        # Vision prompts and large contexts on CPU inference are slow; the
        # default here is deliberately generous.
        self.timeout = float(os.environ.get("MODEL_TIMEOUT_SECONDS", "600"))

    async def chat(
        self,
        messages: list[dict[str, Any]],
        tools: Optional[list[dict[str, Any]]] = None,
        model: Optional[str] = None,
        temperature: float = 0.2,
    ) -> dict[str, Any]:
        """
        Returns Ollama's `message` dict plus a private `_usage` key the
        runtime strips off for token accounting:
          {"role": "assistant", "content": "...", "tool_calls": [...],
           "_usage": {"prompt_tokens": N, "completion_tokens": N, "total_tokens": N}}

        Tool-calling requires a model that supports it (qwen2.5, llama3.1,
        mistral-nemo, firefunction-v2, etc.) — pull one with:
          docker exec agent-ollama ollama pull qwen2.5:7b-instruct

        Vision works by putting base64 images on a message's `images` array;
        messages are passed through unchanged, so the runtime can attach
        screenshots without this layer knowing about them.
        """
        payload = {
            "model": model or DEFAULT_MODEL,
            "messages": messages,
            "stream": False,
            "options": {"temperature": temperature},
        }
        if tools:
            payload["tools"] = tools

        async with httpx.AsyncClient(timeout=self.timeout) as client:
            resp = await client.post(f"{self.base_url}/api/chat", json=payload)
            resp.raise_for_status()
            data = resp.json()

        message = data.get("message", {"role": "assistant", "content": ""})
        # Ollama reports prompt_eval_count / eval_count on the response body.
        # Surfacing them is what makes the task token budget enforceable.
        prompt_tokens = int(data.get("prompt_eval_count", 0) or 0)
        completion_tokens = int(data.get("eval_count", 0) or 0)
        message["_usage"] = {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
        }
        return message

    async def list_models(self) -> list[str]:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.get(f"{self.base_url}/api/tags")
            resp.raise_for_status()
            data = resp.json()
            return [m["name"] for m in data.get("models", [])]

    async def ensure_model(self, model: str) -> None:
        """Pull a model if it isn't present yet (idempotent, blocks until done)."""
        async with httpx.AsyncClient(timeout=None) as client:
            async with client.stream(
                "POST", f"{self.base_url}/api/pull", json={"model": model, "stream": True}
            ) as resp:
                async for line in resp.aiter_lines():
                    if not line:
                        continue
                    try:
                        json.loads(line)
                    except json.JSONDecodeError:
                        continue
