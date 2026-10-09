"""
Memory Store
============
Qdrant for semantic retrieval, with the relational record kept alongside it.

Three collections, because the memory classes have different lifetimes and
different retrieval rules — mixing them means a stale page snippet competing
with a durable user preference:

  evidence      findings from tasks, filterable by task/subject/confidence
  user_memory   stable preferences and facts the user explicitly allowed
  knowledge     documents and long-form material

Retrieval is not raw top-k. It applies metadata filters first, then reranks
on (similarity, confidence, recency), because an old high-similarity snippet
about last year's pricing is usually worse than a newer, slightly less similar
one. Recency weighting is configurable and can be turned off for facts that
don't decay.
"""
import datetime as dt
import logging
import os
import uuid
from typing import Optional

from qdrant_client import AsyncQdrantClient, models as qm

from agent.memory.embeddings import Embedder, EMBED_DIM
from agent.memory.evidence import Evidence

logger = logging.getLogger("memory")

QDRANT_URL = os.environ.get("QDRANT_URL", "http://qdrant:6333")

COLLECTION_EVIDENCE = "evidence"
COLLECTION_USER = "user_memory"
COLLECTION_KNOWLEDGE = "knowledge"
ALL_COLLECTIONS = (COLLECTION_EVIDENCE, COLLECTION_USER, COLLECTION_KNOWLEDGE)

# Reranking weights. Similarity dominates; confidence and recency adjust.
W_SIMILARITY = float(os.environ.get("RERANK_W_SIMILARITY", "1.0"))
W_CONFIDENCE = float(os.environ.get("RERANK_W_CONFIDENCE", "0.3"))
W_RECENCY = float(os.environ.get("RERANK_W_RECENCY", "0.2"))
RECENCY_HALFLIFE_DAYS = float(os.environ.get("RERANK_RECENCY_HALFLIFE_DAYS", "30"))


def _point_id(external_id: str) -> str:
    """
    Qdrant point ids must be UUIDs or unsigned ints. Our ids are readable
    strings like `evidence_a1b2c3`, so derive a stable UUID from them — the
    original stays in the payload.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, external_id))


class MemoryStore:
    def __init__(self, url: str = QDRANT_URL):
        self.url = url
        self._client: Optional[AsyncQdrantClient] = None
        self.embedder = Embedder()
        self._ready = False

    def _c(self) -> AsyncQdrantClient:
        if self._client is None:
            self._client = AsyncQdrantClient(url=self.url, timeout=30)
        return self._client

    async def ensure_collections(self) -> None:
        """Idempotent. Safe to call on every startup."""
        if self._ready:
            return
        client = self._c()
        existing = {c.name for c in (await client.get_collections()).collections}
        for name in ALL_COLLECTIONS:
            if name in existing:
                continue
            await client.create_collection(
                collection_name=name,
                vectors_config=qm.VectorParams(size=EMBED_DIM, distance=qm.Distance.COSINE),
            )
            # Indexes on the fields we actually filter by. Without these,
            # filtered search degrades badly as the collection grows.
            for field_name, schema in (
                ("task_id", qm.PayloadSchemaType.KEYWORD),
                ("subject", qm.PayloadSchemaType.KEYWORD),
                ("source", qm.PayloadSchemaType.KEYWORD),
                ("tags", qm.PayloadSchemaType.KEYWORD),
                ("confidence", qm.PayloadSchemaType.FLOAT),
            ):
                try:
                    await client.create_payload_index(
                        collection_name=name,
                        field_name=field_name,
                        field_schema=schema,
                    )
                except Exception:
                    pass  # index may already exist
            logger.info("Created Qdrant collection %s", name)
        self._ready = True

    # -- writes --------------------------------------------------------------

    async def add_evidence(self, items: list[Evidence]) -> int:
        if not items:
            return 0
        await self.ensure_collections()
        vectors = await self.embedder.embed([e.embedding_text() for e in items])
        points = [
            qm.PointStruct(
                id=_point_id(e.id),
                vector=vector,
                payload=e.to_payload(),
            )
            for e, vector in zip(items, vectors)
        ]
        await self._c().upsert(collection_name=COLLECTION_EVIDENCE, points=points)
        return len(points)

    async def add_user_memory(self, text: str, tags: Optional[list[str]] = None) -> str:
        """
        Stable user preferences/facts. Deliberately a separate, explicit call:
        not every statement in a conversation should become permanent memory.
        """
        await self.ensure_collections()
        vector = await self.embedder.embed_one(text)
        mem_id = f"mem_{uuid.uuid4().hex[:12]}"
        await self._c().upsert(
            collection_name=COLLECTION_USER,
            points=[qm.PointStruct(
                id=_point_id(mem_id),
                vector=vector,
                payload={
                    "evidence_id": mem_id,
                    "finding": text,
                    "source": "user",
                    "confidence": 1.0,
                    "tags": tags or [],
                    "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
                },
            )],
        )
        return mem_id

    # -- reads ---------------------------------------------------------------

    async def search(
        self,
        query: str,
        collections: tuple[str, ...] = ALL_COLLECTIONS,
        limit: int = 6,
        task_id: Optional[str] = None,
        subject: Optional[str] = None,
        min_confidence: float = 0.0,
        candidate_multiplier: int = 4,
        apply_recency: bool = True,
    ) -> list[dict]:
        """
        Retrieve, then rerank. Over-fetches by `candidate_multiplier` so the
        reranker has something to work with — reranking the top-6 of a top-6
        search does nothing.
        """
        await self.ensure_collections()
        vector = await self.embedder.embed_one(query)
        if vector is None:
            return []

        conditions = []
        if task_id:
            conditions.append(
                qm.FieldCondition(key="task_id", match=qm.MatchValue(value=task_id))
            )
        if subject:
            conditions.append(
                qm.FieldCondition(key="subject", match=qm.MatchValue(value=subject))
            )
        if min_confidence > 0:
            conditions.append(
                qm.FieldCondition(key="confidence", range=qm.Range(gte=min_confidence))
            )
        query_filter = qm.Filter(must=conditions) if conditions else None

        candidates: list[dict] = []
        for name in collections:
            try:
                hits = await self._c().search(
                    collection_name=name,
                    query_vector=vector,
                    query_filter=query_filter,
                    limit=limit * candidate_multiplier,
                    with_payload=True,
                )
            except Exception as exc:
                logger.warning("Search failed on %s: %s", name, exc)
                continue
            for hit in hits:
                payload = hit.payload or {}
                candidates.append({
                    "collection": name,
                    "score": float(hit.score),
                    **payload,
                })

        return self._rerank(candidates, limit=limit, apply_recency=apply_recency)

    @staticmethod
    def _rerank(candidates: list[dict], limit: int, apply_recency: bool) -> list[dict]:
        now = dt.datetime.now(dt.timezone.utc)

        def recency_factor(item: dict) -> float:
            if not apply_recency:
                return 1.0
            stamp = item.get("timestamp")
            if not stamp:
                return 0.5
            try:
                when = dt.datetime.fromisoformat(stamp)
                if when.tzinfo is None:
                    when = when.replace(tzinfo=dt.timezone.utc)
            except ValueError:
                return 0.5
            age_days = max(0.0, (now - when).total_seconds() / 86400)
            # Exponential decay with a configurable half-life.
            return 0.5 ** (age_days / RECENCY_HALFLIFE_DAYS)

        # Deduplicate: the same finding can land in more than one collection.
        seen: dict[str, dict] = {}
        for item in candidates:
            key = (item.get("finding") or "")[:200]
            if key not in seen or item["score"] > seen[key]["score"]:
                seen[key] = item

        for item in seen.values():
            item["rerank_score"] = (
                W_SIMILARITY * item["score"]
                + W_CONFIDENCE * float(item.get("confidence", 0.5))
                + W_RECENCY * recency_factor(item)
            )

        ranked = sorted(seen.values(), key=lambda i: i["rerank_score"], reverse=True)
        return ranked[:limit]

    async def forget(self, evidence_id: str) -> bool:
        """User-facing memory control: remove one item everywhere."""
        await self.ensure_collections()
        removed = False
        for name in ALL_COLLECTIONS:
            try:
                await self._c().delete(
                    collection_name=name,
                    points_selector=qm.PointIdsList(points=[_point_id(evidence_id)]),
                )
                removed = True
            except Exception:
                continue
        return removed

    async def forget_task(self, task_id: str) -> None:
        """Drop everything a single task learned."""
        await self.ensure_collections()
        await self._c().delete(
            collection_name=COLLECTION_EVIDENCE,
            points_selector=qm.FilterSelector(filter=qm.Filter(must=[
                qm.FieldCondition(key="task_id", match=qm.MatchValue(value=task_id))
            ])),
        )

    async def stats(self) -> dict:
        await self.ensure_collections()
        out = {}
        for name in ALL_COLLECTIONS:
            try:
                info = await self._c().get_collection(name)
                out[name] = info.points_count
            except Exception:
                out[name] = None
        return out


_store: Optional[MemoryStore] = None


def get_store() -> MemoryStore:
    global _store
    if _store is None:
        _store = MemoryStore()
    return _store
