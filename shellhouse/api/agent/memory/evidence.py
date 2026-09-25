"""
Structured Evidence (ADR-007)
=============================
Retrieval that depends only on raw text chunks loses the things that make
findings usable: where a claim came from, when, how confident it is, and what
it relates to. So findings are normalized into evidence objects before they
are stored.

An evidence object separates:

  - the raw source            (url, page, tool that produced it)
  - the normalized finding    (a single claim, in plain language)
  - confidence                (how much to trust it)
  - temporal context          (when it was observed — pricing goes stale)
  - relationships             (supports / contradicts / refines other evidence)

Postgres/SQLite holds the record, Qdrant holds the vector for semantic recall.
"""
import datetime as dt
import json
import uuid
from dataclasses import dataclass, field, asdict
from typing import Optional


VALID_RELATIONS = ("supports", "contradicts", "refines", "supersedes", "relates_to")
VALID_SOURCES = ("browser", "web_search", "fetch_url", "shell", "file", "user", "model")


@dataclass
class Relationship:
    type: str
    target: str

    def __post_init__(self):
        if self.type not in VALID_RELATIONS:
            raise ValueError(
                f"Unknown relationship '{self.type}'. Expected one of {VALID_RELATIONS}"
            )


@dataclass
class Evidence:
    finding: str                                   # the claim, in one sentence
    source: str                                    # which tool produced it
    subject: Optional[str] = None                  # what it is about
    confidence: float = 0.8                        # 0..1
    id: str = field(default_factory=lambda: f"evidence_{uuid.uuid4().hex[:12]}")
    task_id: Optional[str] = None
    timestamp: str = field(
        default_factory=lambda: dt.datetime.now(dt.timezone.utc).isoformat()
    )
    original_reference: dict = field(default_factory=dict)   # url, page, path...
    relationships: list[Relationship] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)

    def __post_init__(self):
        if not self.finding or not self.finding.strip():
            raise ValueError("Evidence needs a finding")
        if self.source not in VALID_SOURCES:
            # Don't reject — an unknown tool name is information, not an error.
            self.source = "model"
        self.confidence = max(0.0, min(1.0, float(self.confidence)))

    # -- representations ----------------------------------------------------

    def embedding_text(self) -> str:
        """
        What actually gets embedded. Includes the subject so that a query
        about a subject retrieves its findings, and excludes the machinery
        (ids, timestamps) which would only add noise to the vector.
        """
        parts = [self.finding]
        if self.subject:
            parts.append(f"Subject: {self.subject}")
        if self.tags:
            parts.append("Tags: " + ", ".join(self.tags))
        ref = self.original_reference.get("url") or self.original_reference.get("path")
        if ref:
            parts.append(f"Source: {ref}")
        return "\n".join(parts)

    def to_payload(self) -> dict:
        """Qdrant payload — everything needed for filtering without a DB hit."""
        return {
            "evidence_id": self.id,
            "task_id": self.task_id,
            "finding": self.finding,
            "subject": self.subject,
            "source": self.source,
            "confidence": self.confidence,
            "timestamp": self.timestamp,
            "tags": self.tags,
            "original_reference": self.original_reference,
            "relationships": [asdict(r) for r in self.relationships],
        }

    def to_dict(self) -> dict:
        d = asdict(self)
        d["relationships"] = [asdict(r) if not isinstance(r, dict) else r
                              for r in self.relationships]
        return d

    def to_context_line(self) -> str:
        """How this evidence appears when injected into the model's context."""
        bits = [self.finding]
        if self.subject:
            bits.insert(0, f"[{self.subject}]")
        ref = self.original_reference.get("url") or self.original_reference.get("path")
        meta = [f"confidence {self.confidence:.2f}", self.timestamp[:10]]
        if ref:
            meta.append(str(ref))
        return " ".join(bits) + f"  ({'; '.join(meta)})"

    @staticmethod
    def from_dict(data: dict) -> "Evidence":
        rels = [
            Relationship(**r) if isinstance(r, dict) else r
            for r in data.get("relationships", [])
        ]
        return Evidence(
            finding=data["finding"],
            source=data.get("source", "model"),
            subject=data.get("subject"),
            confidence=data.get("confidence", 0.8),
            id=data.get("id") or data.get("evidence_id")
               or f"evidence_{uuid.uuid4().hex[:12]}",
            task_id=data.get("task_id"),
            timestamp=data.get("timestamp")
                      or dt.datetime.now(dt.timezone.utc).isoformat(),
            original_reference=data.get("original_reference") or {},
            relationships=rels,
            tags=data.get("tags") or [],
        )


def normalize_tool_result(tool_name: str, arguments: dict, result: dict) -> list[Evidence]:
    """
    Opportunistic evidence extraction from tool output.

    This does NOT try to be clever about what a page "means" — inferring
    claims from raw text is the model's job, via the save_evidence tool. What
    it captures is the provenance layer: that a specific URL was fetched at a
    specific time and what it contained. That alone makes citations possible
    later, which is the part agents most often get wrong.
    """
    out: list[Evidence] = []

    if tool_name == "fetch_url" and not result.get("error"):
        url = result.get("url") or arguments.get("url", "")
        text = (result.get("text") or "")[:600]
        if url and text:
            out.append(Evidence(
                finding=f"Retrieved page content from {url}: {text}",
                source="fetch_url",
                subject=url,
                confidence=0.6,   # raw retrieval, not an interpreted claim
                original_reference={"url": url, "status": result.get("status")},
                tags=["raw_retrieval"],
            ))

    elif tool_name == "web_search" and not result.get("error"):
        for item in (result.get("results") or [])[:5]:
            if item.get("url"):
                out.append(Evidence(
                    finding=f"{item.get('title', 'Result')}: {item.get('snippet', '')}",
                    source="web_search",
                    subject=arguments.get("query"),
                    confidence=0.5,   # a snippet is a lead, not a fact
                    original_reference={"url": item["url"]},
                    tags=["search_result"],
                ))

    return out
