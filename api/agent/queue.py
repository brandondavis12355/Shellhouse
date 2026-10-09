"""
Task Queue
==========
Durable job handoff between the API and the agent workers.

The problem this solves: tasks used to run via `asyncio.create_task` inside a
request handler, so they died with the API process and nothing replayed the
state being carefully persisted to Postgres/SQLite. "Never run long-running
agent execution directly inside a request handler."

Design:

  API  --enqueue-->  [pending list]  --claim-->  worker
                                                   |
                                     [processing list + lease key]
                                                   |
                                  ack (remove) or lease expiry (requeue)

A claim is a `BLMOVE` from `pending` to `processing`, which is atomic: a job
cannot be lost between the two lists even if the worker dies mid-move. The
worker then holds a lease key it must refresh; if the worker dies, the lease
expires and a sweeper moves the job back to `pending`.

At-least-once delivery, so job handlers must be idempotent. They are: running
a task that already completed is a no-op, because the runtime checks state
before doing work.
"""
import json
import os
import time
import uuid
from dataclasses import dataclass, asdict
from typing import Optional

import redis.asyncio as redis

REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")

KEY_PENDING = "agent:jobs:pending"
KEY_PROCESSING = "agent:jobs:processing"
KEY_LEASE = "agent:jobs:lease:"      # + job_id
KEY_DEAD = "agent:jobs:dead"

# How long a worker's claim is valid before the sweeper assumes it died. The
# worker refreshes this while it works, so it only needs to exceed the
# heartbeat interval by a comfortable margin.
LEASE_SECONDS = int(os.environ.get("JOB_LEASE_SECONDS", "120"))
HEARTBEAT_SECONDS = int(os.environ.get("JOB_HEARTBEAT_SECONDS", "30"))
MAX_ATTEMPTS = int(os.environ.get("JOB_MAX_ATTEMPTS", "3"))


@dataclass
class Job:
    id: str
    type: str                     # "run" | "resume"
    task_id: str
    approved: Optional[bool] = None   # for type="resume"
    model: Optional[str] = None
    attempts: int = 0
    enqueued_at: float = 0.0

    def to_json(self) -> str:
        return json.dumps(asdict(self))

    @staticmethod
    def from_json(raw: str) -> "Job":
        return Job(**json.loads(raw))


class TaskQueue:
    def __init__(self, url: str = REDIS_URL):
        self._url = url
        self._redis: Optional[redis.Redis] = None

    async def connect(self) -> redis.Redis:
        if self._redis is None:
            self._redis = redis.from_url(self._url, decode_responses=True)
        return self._redis

    async def close(self) -> None:
        if self._redis is not None:
            await self._redis.aclose()
            self._redis = None

    # -- producer ------------------------------------------------------------

    async def enqueue_run(self, task_id: str, model: Optional[str] = None) -> str:
        return await self._enqueue(Job(
            id=f"job_{uuid.uuid4().hex[:12]}",
            type="run",
            task_id=task_id,
            model=model,
            enqueued_at=time.time(),
        ))

    async def enqueue_resume(self, task_id: str, approved: bool) -> str:
        return await self._enqueue(Job(
            id=f"job_{uuid.uuid4().hex[:12]}",
            type="resume",
            task_id=task_id,
            approved=approved,
            enqueued_at=time.time(),
        ))

    async def _enqueue(self, job: Job) -> str:
        r = await self.connect()
        # LPUSH + BRPOPLPUSH gives FIFO ordering.
        await r.lpush(KEY_PENDING, job.to_json())
        return job.id

    # -- consumer ------------------------------------------------------------

    async def claim(self, timeout: int = 5) -> Optional[Job]:
        """
        Atomically move one job from pending to processing and take a lease.
        Blocks up to `timeout` seconds. Returns None on timeout.
        """
        r = await self.connect()
        raw = await r.brpoplpush(KEY_PENDING, KEY_PROCESSING, timeout=timeout)
        if raw is None:
            return None
        job = Job.from_json(raw)
        await r.set(KEY_LEASE + job.id, raw, ex=LEASE_SECONDS)
        return job

    async def heartbeat(self, job: Job) -> None:
        """Refresh the lease. Called periodically while the job runs."""
        r = await self.connect()
        await r.set(KEY_LEASE + job.id, job.to_json(), ex=LEASE_SECONDS)

    async def ack(self, job: Job) -> None:
        """Job finished (successfully or with a recorded failure). Remove it."""
        r = await self.connect()
        pipe = r.pipeline()
        pipe.lrem(KEY_PROCESSING, 1, job.to_json())
        pipe.delete(KEY_LEASE + job.id)
        await pipe.execute()

    async def retry(self, job: Job) -> bool:
        """
        Put a job back for another attempt. Returns False if it has exhausted
        its attempts, in which case it lands on the dead list for inspection
        rather than vanishing.
        """
        r = await self.connect()
        await self.ack(job)
        job.attempts += 1
        if job.attempts >= MAX_ATTEMPTS:
            await r.lpush(KEY_DEAD, job.to_json())
            return False
        await r.lpush(KEY_PENDING, job.to_json())
        return True

    # -- recovery ------------------------------------------------------------

    async def sweep_stale(self) -> list[Job]:
        """
        Requeue jobs whose worker died: present in `processing` but with no
        live lease. Safe to run from multiple workers — the LREM is what
        decides the winner, so a job is only requeued once.
        """
        r = await self.connect()
        requeued: list[Job] = []
        for raw in await r.lrange(KEY_PROCESSING, 0, -1):
            try:
                job = Job.from_json(raw)
            except (json.JSONDecodeError, TypeError):
                await r.lrem(KEY_PROCESSING, 1, raw)
                continue
            if await r.exists(KEY_LEASE + job.id):
                continue  # still being worked on
            removed = await r.lrem(KEY_PROCESSING, 1, raw)
            if not removed:
                continue  # another sweeper got it first
            job.attempts += 1
            if job.attempts >= MAX_ATTEMPTS:
                await r.lpush(KEY_DEAD, raw)
            else:
                await r.lpush(KEY_PENDING, job.to_json())
                requeued.append(job)
        return requeued

    async def stats(self) -> dict:
        r = await self.connect()
        return {
            "pending": await r.llen(KEY_PENDING),
            "processing": await r.llen(KEY_PROCESSING),
            "dead": await r.llen(KEY_DEAD),
        }
