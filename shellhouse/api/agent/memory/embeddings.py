"""
Embeddings
==========
Local only, via Ollama's embedding endpoint. Pull the model once:

    docker exec agent-ollama ollama pull nomic-embed-text

nomic-embed-text is 768-dimensional and small enough to run comfortably on
CPU alongside the chat model. If you change EMBED_MODEL you must also change
EMBED_DIM and recreate the Qdrant collection, since vector size is fixed at
collection creation.
"""
import os
from typing import Optional

import httpx

OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://ollama:11434")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
EMBED_DIM = int(os.environ.get("EMBED_DIM", "768"))
EMBED_TIMEOUT = float(os.environ.get("EMBED_TIMEOUT_SECONDS", "120"))


class Embedder:
    def __init__(self, base_url: str = OLLAMA_BASE_URL, model: str = EMBED_MODEL):
        self.base_url = base_url
        self.model = model

    async def embed(self, texts: list[str]) -> list[list[float]]:
        """
        Embed a batch of texts. Ollama's /api/embed accepts a list and returns
        `embeddings`; the older /api/embeddings is single-input only, so batch
        first and fall back if the endpoint is missing.
        """
        if not texts:
            return []
        async with httpx.AsyncClient(timeout=EMBED_TIMEOUT) as client:
            try:
                resp = await client.post(
                    f"{self.base_url}/api/embed",
                    json={"model": self.model, "input": texts},
                )
                resp.raise_for_status()
                data = resp.json()
                vectors = data.get("embeddings")
                if vectors:
                    return vectors
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code != 404:
                    raise
            # Fallback for older Ollama builds: one call per text.
            out = []
            for text in texts:
                resp = await client.post(
                    f"{self.base_url}/api/embeddings",
                    json={"model": self.model, "prompt": text},
                )
                resp.raise_for_status()
                out.append(resp.json()["embedding"])
            return out

    async def embed_one(self, text: str) -> Optional[list[float]]:
        vectors = await self.embed([text])
        return vectors[0] if vectors else None
