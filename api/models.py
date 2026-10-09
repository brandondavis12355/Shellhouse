import uuid
import datetime as dt

from sqlalchemy import Column, String, Text, DateTime, ForeignKey, Integer
from sqlalchemy.orm import relationship

from database import Base


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


def now():
    return dt.datetime.utcnow()


class Task(Base):
    """A durable unit of work. Everything the agent does is scoped to a task."""
    __tablename__ = "tasks"

    id = Column(String, primary_key=True, default=lambda: new_id("task"))
    goal = Column(Text, nullable=False)
    # State machine: QUEUED -> PLANNING -> EXECUTING -> WAITING_FOR_TOOL ->
    # OBSERVING -> WAITING_FOR_APPROVAL -> VERIFYING -> COMPLETED
    # Failure states: FAILED, CANCELLED, TIMED_OUT, BLOCKED
    status = Column(String, default="QUEUED", nullable=False)
    model = Column(String, nullable=True)
    created_at = Column(DateTime, default=now)
    updated_at = Column(DateTime, default=now, onupdate=now)
    result = Column(Text, nullable=True)
    error = Column(Text, nullable=True)
    messages = Column(Text, nullable=True)  # JSON-encoded conversation, so runs are resumable
    pending_tool_call = Column(Text, nullable=True)  # JSON: the tool call waiting on an approval

    # --- sandbox lifecycle (fix 1) ----------------------------------------
    # Which computer this task is running on, and whether it survives the
    # task. Ephemeral sandboxes are destroyed when the task reaches a
    # terminal state; persistent ones ("My AI Computer") are not.
    sandbox_id = Column(String, nullable=True)
    sandbox_persistent = Column(Integer, default=0)   # 0/1, sqlite-friendly
    vnc_url = Column(String, nullable=True)

    # --- loop control / budgets (fix 2) ------------------------------------
    cancel_requested = Column(Integer, default=0)     # cooperative cancellation flag
    started_at = Column(DateTime, nullable=True)
    iterations = Column(Integer, default=0)
    # Rough accounting. Ollama reports eval counts per response; we sum them.
    tokens_used = Column(Integer, default=0)
    compactions = Column(Integer, default=0)

    events = relationship("TaskEvent", back_populates="task", cascade="all, delete-orphan")
    tool_calls = relationship("ToolCall", back_populates="task", cascade="all, delete-orphan")
    approvals = relationship("Approval", back_populates="task", cascade="all, delete-orphan")


class TaskEvent(Base):
    """Append-only event log. A task should be reconstructable from this table alone."""
    __tablename__ = "task_events"

    id = Column(String, primary_key=True, default=lambda: new_id("evt"))
    task_id = Column(String, ForeignKey("tasks.id"), nullable=False)
    type = Column(String, nullable=False)   # e.g. task.created, model.completed, tool.executed
    payload = Column(Text, nullable=True)   # JSON string
    created_at = Column(DateTime, default=now)

    task = relationship("Task", back_populates="events")


class ToolCall(Base):
    __tablename__ = "tool_calls"

    id = Column(String, primary_key=True, default=lambda: new_id("tc"))
    task_id = Column(String, ForeignKey("tasks.id"), nullable=False)
    tool_name = Column(String, nullable=False)
    arguments = Column(Text, nullable=True)   # JSON string
    result = Column(Text, nullable=True)      # JSON string
    status = Column(String, default="pending")  # pending, allowed, denied, error, done
    created_at = Column(DateTime, default=now)

    task = relationship("Task", back_populates="tool_calls")


class Approval(Base):
    __tablename__ = "approvals"

    id = Column(String, primary_key=True, default=lambda: new_id("apr"))
    task_id = Column(String, ForeignKey("tasks.id"), nullable=False)
    tool_name = Column(String, nullable=False)
    arguments_summary = Column(Text, nullable=True)
    risk = Column(String, default="medium")
    status = Column(String, default="pending")  # pending, approved, denied
    created_at = Column(DateTime, default=now)
    decided_at = Column(DateTime, nullable=True)

    task = relationship("Task", back_populates="approvals")


class Credential(Base):
    """
    Encrypted secret storage (Phase 5). The plaintext never leaves
    agent/secrets.py, and no tool returns a value.
    """
    __tablename__ = "credentials"

    id = Column(String, primary_key=True, default=lambda: new_id("cred"))
    name = Column(String, unique=True, nullable=False)     # e.g. GITHUB_TOKEN
    encrypted_value = Column(Text, nullable=False)          # Fernet token
    description = Column(Text, nullable=True)
    # Short hash of the plaintext, so a rotation can be confirmed without
    # ever revealing the value.
    fingerprint = Column(String, nullable=True)
    created_at = Column(DateTime, default=now)
    updated_at = Column(DateTime, default=now, onupdate=now)

