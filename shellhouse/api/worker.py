"""
Agent Worker
============
Runs the agent loop outside the request path. Start as many as your host can
feed; each claims jobs independently.

  python worker.py

Two recovery mechanisms, because there are two ways work gets lost:

1. **Queue-level:** a worker dies mid-job, its lease expires, and
   `sweep_stale()` returns the job to pending. Another worker picks it up.
2. **Database-level:** a task is sitting in a non-terminal state with no job
   anywhere (e.g. the queue was flushed, or the task was created by an older
   build that ran tasks in-process). `recover_orphaned_tasks()` finds those on
   startup and re-enqueues them. This is what finally makes the persisted
   task state mean something.

Tasks parked on WAITING_FOR_APPROVAL are deliberately NOT recovered — they are
waiting on a human, not on a worker, and re-running them would re-ask the
model instead of honoring the pending decision.
"""
import asyncio
import logging
import os
import signal
import sys

import models
from database import Base, engine, SessionLocal
from agent.queue import TaskQueue, Job, HEARTBEAT_SECONDS
from agent.runtime import AgentRuntime

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s [worker] %(message)s",
)
logger = logging.getLogger("worker")

WORKER_ID = os.environ.get("HOSTNAME", "worker") + "-" + str(os.getpid())
SWEEP_INTERVAL = int(os.environ.get("JOB_SWEEP_INTERVAL", "60"))
CONCURRENCY = int(os.environ.get("WORKER_CONCURRENCY", "2"))

# States that mean "this task should be running but isn't".
RECOVERABLE_STATES = ("QUEUED", "PLANNING", "EXECUTING", "WAITING_FOR_TOOL", "OBSERVING")

_shutdown = asyncio.Event()


def _emit(task_id: str, event_type: str, payload: dict) -> None:
    # Events are already persisted to task_events by the runtime; the UI polls
    # that table. A Redis pub/sub broadcaster would slot in here for true
    # push-based streaming.
    pass


async def recover_orphaned_tasks(queue: TaskQueue) -> int:
    """Re-enqueue tasks left mid-flight by a crash or restart."""
    db = SessionLocal()
    try:
        orphans = (
            db.query(models.Task)
            .filter(models.Task.status.in_(RECOVERABLE_STATES))
            .filter(models.Task.cancel_requested == 0)
            .all()
        )
        for task in orphans:
            logger.info("Recovering task %s (was %s)", task.id, task.status)
            db.add(models.TaskEvent(
                task_id=task.id,
                type="task.recovered",
                payload=f'{{"previous_status": "{task.status}", "worker": "{WORKER_ID}"}}',
            ))
            task.status = "QUEUED"
            db.add(task)
            db.commit()
            await queue.enqueue_run(task.id, model=task.model)
        return len(orphans)
    finally:
        db.close()


async def _heartbeat_loop(queue: TaskQueue, job: Job, done: asyncio.Event) -> None:
    """Keep the job's lease alive for as long as we're working on it."""
    while not done.is_set():
        try:
            await asyncio.wait_for(done.wait(), timeout=HEARTBEAT_SECONDS)
        except asyncio.TimeoutError:
            try:
                await queue.heartbeat(job)
            except Exception as exc:
                logger.warning("Heartbeat failed for %s: %s", job.id, exc)


async def handle_job(queue: TaskQueue, job: Job) -> None:
    db = SessionLocal()
    done = asyncio.Event()
    hb = asyncio.create_task(_heartbeat_loop(queue, job, done))
    try:
        task = db.get(models.Task, job.task_id)
        if task is None:
            logger.warning("Job %s references unknown task %s", job.id, job.task_id)
            await queue.ack(job)
            return

        # Idempotency: a re-delivered job for a finished task is a no-op.
        if task.status in ("COMPLETED", "FAILED", "CANCELLED", "BLOCKED", "TIMED_OUT"):
            logger.info("Task %s already %s; acking job", task.id, task.status)
            await queue.ack(job)
            return

        runtime = AgentRuntime(db, emit=_emit, model_override=job.model)
        if job.type == "resume":
            await runtime.resume_after_approval(job.task_id, bool(job.approved))
        else:
            await runtime.run(job.task_id)

        await queue.ack(job)
        logger.info("Finished job %s (task %s)", job.id, job.task_id)

    except Exception:
        logger.exception("Job %s crashed", job.id)
        # Decide between retry and permanent failure. An infrastructure blip
        # deserves a retry; a task that has already burned its budget does not.
        retried = await queue.retry(job)
        if not retried:
            try:
                task = db.get(models.Task, job.task_id)
                if task and task.status not in (
                    "COMPLETED", "FAILED", "CANCELLED", "BLOCKED", "TIMED_OUT"
                ):
                    task.status = "FAILED"
                    task.error = (
                        "Worker failed repeatedly on this task; see worker logs."
                    )
                    db.add(task)
                    db.commit()
            except Exception:
                logger.exception("Could not mark task %s failed", job.task_id)
    finally:
        done.set()
        hb.cancel()
        db.close()


async def _sweeper(queue: TaskQueue) -> None:
    while not _shutdown.is_set():
        try:
            requeued = await queue.sweep_stale()
            if requeued:
                logger.info("Requeued %d stale job(s)", len(requeued))
        except Exception as exc:
            logger.warning("Sweep failed: %s", exc)
        try:
            await asyncio.wait_for(_shutdown.wait(), timeout=SWEEP_INTERVAL)
        except asyncio.TimeoutError:
            pass


async def _consumer(queue: TaskQueue, slot: int) -> None:
    logger.info("Consumer %s-%d ready", WORKER_ID, slot)
    while not _shutdown.is_set():
        try:
            job = await queue.claim(timeout=5)
        except Exception as exc:
            logger.warning("Claim failed: %s", exc)
            await asyncio.sleep(2)
            continue
        if job is None:
            continue
        logger.info("Claimed %s (%s task=%s)", job.id, job.type, job.task_id)
        await handle_job(queue, job)


async def main() -> None:
    Base.metadata.create_all(bind=engine)
    queue = TaskQueue()

    # Wait for Redis before doing anything else.
    for attempt in range(30):
        try:
            r = await queue.connect()
            await r.ping()
            break
        except Exception as exc:
            logger.info("Waiting for Redis (%s)", exc)
            await asyncio.sleep(2)
    else:
        logger.error("Redis never became reachable; exiting")
        sys.exit(1)

    recovered = await recover_orphaned_tasks(queue)
    if recovered:
        logger.info("Recovered %d interrupted task(s)", recovered)

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, _shutdown.set)
        except NotImplementedError:
            pass  # not available on all platforms

    workers = [asyncio.create_task(_consumer(queue, i)) for i in range(CONCURRENCY)]
    sweeper = asyncio.create_task(_sweeper(queue))

    await _shutdown.wait()
    logger.info("Shutting down; finishing in-flight work")
    for w in workers:
        w.cancel()
    sweeper.cancel()
    await queue.close()


if __name__ == "__main__":
    asyncio.run(main())
