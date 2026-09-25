from pydantic import BaseModel
from typing import Optional


class CreateTaskRequest(BaseModel):
    goal: str
    model: Optional[str] = None  # override the default local Ollama model
    # False (default) = fresh, disposable computer for this task, destroyed
    # when it finishes. True = attach to the persistent "My AI Computer".
    persistent_computer: bool = False


class TaskResponse(BaseModel):
    id: str
    goal: str
    status: str
    model: Optional[str] = None
    result: Optional[str] = None
    error: Optional[str] = None
    sandbox_id: Optional[str] = None
    vnc_url: Optional[str] = None
    iterations: Optional[int] = None
    tokens_used: Optional[int] = None

    class Config:
        from_attributes = True


class ApprovalDecision(BaseModel):
    approve: bool


class SecretRequest(BaseModel):
    """Inbound only. No response model ever carries a secret value."""
    value: str
    description: Optional[str] = None
