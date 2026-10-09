import asyncio
import json
import logging
import os

from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from sqlalchemy.orm import Session

import models
import schemas
from database import Base, engine, SessionLocal, get_db
from agent.model_gateway import ModelGateway
from agent.queue import TaskQueue

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("agent-api")

Base.metadata.create_all(bind=engine)

app = FastAPI(title="Local AI Computer - Agent API")

app.add_middleware(
    CORSMiddleware,
    # Only the bundled web UI may call this API from a browser. A wildcard
    # lets ANY web page you visit fetch() the local API (create tasks,
    # approve tool calls). Override with WEB_ORIGINS="https://a,https://b".
    allow_origins=[o.strip() for o in os.environ.get("WEB_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000").split(",") if o.strip()],
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=["Content-Type", "Authorization"],
)


# Agent execution happens in the worker process, not here. The API only
# enqueues; a task therefore survives an API restart, which is the whole
# point of persisting its state.
queue = TaskQueue()


@app.on_event("startup")
async def _startup():
    try:
        r = await queue.connect()
        await r.ping()
        logger.info("Connected to Redis")
    except Exception as exc:
        logger.warning("Redis not reachable at startup: %s", exc)


@app.on_event("shutdown")
async def _shutdown():
    await queue.close()


@app.get("/health")
async def health():
    """Liveness plus the state of each dependency, so a broken stack is obvious."""
    out = {"ok": True, "queue": None, "memory": None}
    try:
        out["queue"] = await queue.stats()
    except Exception as exc:
        out["queue"] = {"error": str(exc)}
        out["ok"] = False
    try:
        from agent.memory.store import get_store
        out["memory"] = await get_store().stats()
    except Exception as exc:
        out["memory"] = {"error": str(exc)}
    return out


@app.get("/sandbox/info")
def sandbox_info(task_id: str | None = None, db: Session = Depends(get_db)):
    """
    Tells the UI where to embed the live desktop stream. With a task_id, it
    returns that task's own computer — each task gets its own noVNC port now,
    so the UI cannot assume a single fixed URL.
    """
    if task_id:
        task = db.get(models.Task, task_id)
        if task and task.vnc_url:
            return {
                "novnc_url": task.vnc_url,
                "container": task.sandbox_id,
                "persistent": bool(task.sandbox_persistent),
            }
    return {
        "novnc_url": os.environ.get(
            "NOVNC_URL", "http://localhost:6080/vnc.html?autoconnect=1&resize=scale"
        ),
        "container": os.environ.get("SANDBOX_CONTAINER_NAME", "agent-sandbox"),
    }


@app.get("/sandbox/file/{filename}")
async def sandbox_file(filename: str, task_id: str | None = None, db: Session = Depends(get_db)):
    """
    Serve a file out of a sandbox's workspace (used for agent screenshots).
    Reads through the Sandbox Manager rather than the host filesystem, because
    a per-task sandbox's workspace is not necessarily a path this container
    can see.
    """
    safe_name = os.path.basename(filename)

    sandbox_id = None
    if task_id:
        task = db.get(models.Task, task_id)
        sandbox_id = task.sandbox_id if task else None
    if not sandbox_id:
        sandbox_id = os.environ.get("SANDBOX_CONTAINER_NAME", "agent-sandbox")

    from agent.sandbox.factory import get_provider
    try:
        data = await get_provider().read_file(sandbox_id, safe_name, max_bytes=8_000_000)
    except Exception:
        raise HTTPException(404, "File not found in that sandbox's workspace")
    media = "image/png" if safe_name.lower().endswith(".png") else "application/octet-stream"
    return Response(content=data, media_type=media)


@app.get("/sandbox/files")
async def sandbox_files(task_id: str | None = None, db: Session = Depends(get_db)):
    """List a sandbox's workspace, the way the file manager shows it."""
    sandbox_id = None
    if task_id:
        task = db.get(models.Task, task_id)
        sandbox_id = task.sandbox_id if task else None
    if not sandbox_id:
        sandbox_id = os.environ.get("SANDBOX_CONTAINER_NAME", "agent-sandbox")

    from agent.sandbox.factory import get_provider
    try:
        res = await get_provider().exec(
            sandbox_id,
            "find . -maxdepth 1 -not -name '.*' -printf '%y\\t%s\\t%f\\n' | sort -k3",
            timeout=30,
        )
    except Exception:
        return {"entries": []}
    entries = []
    for line in res.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[2] != ".":
            kind, size, name = parts
            entries.append({
                "name": name,
                "is_dir": kind == "d",
                "size": int(size) if kind == "f" and size.isdigit() else None,
            })
    return {"entries": entries}


@app.get("/models")
async def list_models():
    gateway = ModelGateway()
    try:
        return {"models": await gateway.list_models()}
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Could not reach Ollama: {exc}")


@app.post("/tasks", response_model=schemas.TaskResponse)
async def create_task(req: schemas.CreateTaskRequest, db: Session = Depends(get_db)):
    task = models.Task(
        goal=req.goal,
        model=req.model,
        status="QUEUED",
        sandbox_persistent=1 if req.persistent_computer else 0,
    )
    db.add(task)
    db.commit()
    db.refresh(task)
    try:
        job_id = await queue.enqueue_run(task.id, model=req.model)
    except Exception as exc:
        task.status = "FAILED"
        task.error = f"Could not enqueue task: {exc}"
        db.add(task)
        db.commit()
        raise HTTPException(503, f"Task queue unavailable: {exc}")

    db.add(models.TaskEvent(
        task_id=task.id, type="task.queued", payload=json.dumps({"job_id": job_id})
    ))
    db.commit()
    db.refresh(task)
    return task


@app.get("/tasks", response_model=list[schemas.TaskResponse])
def list_tasks(db: Session = Depends(get_db)):
    return db.query(models.Task).order_by(models.Task.created_at.desc()).limit(100).all()


@app.get("/tasks/{task_id}", response_model=schemas.TaskResponse)
def get_task(task_id: str, db: Session = Depends(get_db)):
    task = db.get(models.Task, task_id)
    if not task:
        raise HTTPException(404, "Task not found")
    return task


@app.get("/tasks/{task_id}/events")
def get_events(task_id: str, since: int = 0, db: Session = Depends(get_db)):
    """Simple polling endpoint: pass the last event index you've seen as `since`."""
    events = (
        db.query(models.TaskEvent)
        .filter(models.TaskEvent.task_id == task_id)
        .order_by(models.TaskEvent.created_at.asc())
        .all()
    )
    out = []
    for i, e in enumerate(events[since:], start=since):
        out.append({
            "index": i,
            "type": e.type,
            "payload": json.loads(e.payload) if e.payload else {},
            "created_at": e.created_at.isoformat(),
        })
    return {"events": out, "next": since + len(out)}


@app.get("/tasks/{task_id}/approvals/pending")
def get_pending_approval(task_id: str, db: Session = Depends(get_db)):
    approval = (
        db.query(models.Approval)
        .filter(models.Approval.task_id == task_id, models.Approval.status == "pending")
        .order_by(models.Approval.created_at.desc())
        .first()
    )
    if not approval:
        return {"approval": None}
    return {
        "approval": {
            "id": approval.id,
            "tool_name": approval.tool_name,
            "arguments_summary": approval.arguments_summary,
            "risk": approval.risk,
        }
    }


@app.post("/tasks/{task_id}/approvals/{approval_id}")
async def decide_approval(task_id: str, approval_id: str, decision: schemas.ApprovalDecision, db: Session = Depends(get_db)):
    approval = db.get(models.Approval, approval_id)
    if not approval or approval.task_id != task_id:
        raise HTTPException(404, "Approval not found")
    if approval.status != "pending":
        raise HTTPException(409, "Approval already decided")

    approval.status = "approved" if decision.approve else "denied"
    db.add(approval)
    db.commit()

    try:
        await queue.enqueue_resume(task_id, decision.approve)
    except Exception as exc:
        raise HTTPException(503, f"Task queue unavailable: {exc}")
    return {"ok": True, "status": approval.status}


@app.post("/tasks/{task_id}/cancel", response_model=schemas.TaskResponse)
def cancel_task(task_id: str, db: Session = Depends(get_db)):
    """
    Request cancellation. This sets a flag the agent loop checks at the top of
    every iteration and before every tool call, so the task stops at the next
    safe point rather than being killed mid-tool-call. The loop also releases
    the task's sandbox on the way out.

    A task waiting on approval has no running loop to notice the flag, so it
    is marked cancelled directly and its sandbox reaped here.
    """
    task = db.get(models.Task, task_id)
    if not task:
        raise HTTPException(404, "Task not found")
    if task.status in ("COMPLETED", "FAILED", "CANCELLED", "BLOCKED", "TIMED_OUT"):
        return task

    task.cancel_requested = 1
    db.add(task)
    db.commit()

    if task.status == "WAITING_FOR_APPROVAL":
        task.status = "CANCELLED"
        task.error = "Cancelled by user while awaiting approval"
        db.add(task)
        db.commit()
        asyncio.create_task(_reap_sandbox(task_id))

    db.refresh(task)
    return task


async def _reap_sandbox(task_id: str) -> None:
    """Release an ephemeral sandbox for a task whose loop is not running."""
    db = SessionLocal()
    try:
        task = db.get(models.Task, task_id)
        if task and task.sandbox_id and not task.sandbox_persistent:
            from agent.sandbox.factory import get_provider
            try:
                await get_provider().destroy(task.sandbox_id)
            except Exception:
                logger.warning("Could not reap sandbox %s", task.sandbox_id)
    finally:
        db.close()


@app.get("/sandboxes")
async def list_sandboxes():
    """Computers currently running, for the UI's picker."""
    from agent.sandbox.factory import get_provider
    try:
        handles = await get_provider().list_sandboxes()
    except Exception as exc:
        raise HTTPException(502, f"Sandbox Manager unavailable: {exc}")
    return {
        "sandboxes": [
            {
                "id": h.id,
                "provider": h.provider,
                "vnc_url": h.vnc_url,
                "persistent": h.persistent,
                "metadata": h.metadata,
            }
            for h in handles
        ]
    }


# ---------------------------------------------------------------------------
# Memory controls (Phase 4)
# ---------------------------------------------------------------------------

@app.get("/memory/search")
async def memory_search(q: str, limit: int = 10, subject: str | None = None):
    from agent.memory.store import get_store
    try:
        hits = await get_store().search(q, limit=limit, subject=subject)
    except Exception as exc:
        raise HTTPException(502, f"Memory unavailable: {exc}")
    return {"results": hits}


@app.get("/memory/stats")
async def memory_stats():
    from agent.memory.store import get_store
    try:
        return await get_store().stats()
    except Exception as exc:
        raise HTTPException(502, f"Memory unavailable: {exc}")


@app.delete("/memory/{evidence_id}")
async def memory_forget(evidence_id: str):
    """User-facing memory control: delete one item."""
    from agent.memory.store import get_store
    ok = await get_store().forget(evidence_id)
    return {"deleted": ok}


@app.delete("/memory/task/{task_id}")
async def memory_forget_task(task_id: str):
    """Drop everything a single task learned."""
    from agent.memory.store import get_store
    await get_store().forget_task(task_id)
    return {"deleted": True}


# ---------------------------------------------------------------------------
# Secrets (Phase 5) — names in and out, values in only
# ---------------------------------------------------------------------------

@app.get("/secrets")
def secrets_list(db: Session = Depends(get_db)):
    """Metadata only. There is no endpoint that returns a secret value."""
    from agent import secrets as secret_store
    if not secret_store.is_enabled():
        return {
            "enabled": False,
            "secrets": [],
            "note": "Set SECRETS_KEY in .env to enable credential storage.",
        }
    return {"enabled": True, "secrets": secret_store.list_secret_names(db)}


@app.put("/secrets/{name}")
def secrets_put(name: str, body: schemas.SecretRequest, db: Session = Depends(get_db)):
    from agent import secrets as secret_store
    try:
        row = secret_store.put_secret(db, name, body.value, body.description or "")
    except secret_store.SecretsUnavailable as exc:
        raise HTTPException(503, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    return {"name": row.name, "fingerprint": row.fingerprint, "stored": True}


@app.delete("/secrets/{name}")
def secrets_delete(name: str, db: Session = Depends(get_db)):
    from agent import secrets as secret_store
    return {"deleted": secret_store.delete_secret(db, name)}


# ---------------------------------------------------------------------------
# MCP (Phase 6)
# ---------------------------------------------------------------------------

@app.get("/mcp/servers")
async def mcp_servers():
    from agent.mcp.client import get_client
    client = get_client()
    client.load_config()
    return {
        "servers": [
            {
                "name": s.name,
                "url": s.url,
                "enabled": s.enabled,
                "trusted": s.trusted,
                "description": s.description,
                # Header names only — these carry API keys.
                "auth_headers": sorted(s.headers.keys()),
            }
            for s in client.servers.values()
        ]
    }


@app.post("/mcp/discover")
async def mcp_discover():
    """Reconnect to every configured server and refresh the tool list."""
    from agent.mcp.client import get_client
    client = get_client()
    try:
        tools = await client.discover()
    except Exception as exc:
        raise HTTPException(502, f"MCP discovery failed: {exc}")
    return {
        "tools": [
            {
                "name": name,
                "server": tool.server,
                "description": tool.description,
                "policy": __import__(
                    "agent.policy", fromlist=["evaluate"]
                ).evaluate(name),
            }
            for name, tool in tools.items()
        ]
    }


# ---------------------------------------------------------------------------
# Queue visibility
# ---------------------------------------------------------------------------

@app.get("/queue/stats")
async def queue_stats():
    try:
        return await queue.stats()
    except Exception as exc:
        raise HTTPException(502, f"Queue unavailable: {exc}")
