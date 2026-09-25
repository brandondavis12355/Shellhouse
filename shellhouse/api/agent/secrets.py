"""
Secret Manager (Phase 5)
========================
The rule: the model learns that a credential EXISTS, never what it is.

    model sees:      "GITHUB_TOKEN is available"
    model never sees: "GITHUB_TOKEN=ghp_..."

How values actually reach the work: they are injected as environment
variables into the sandbox process at execution time, by the privileged
Sandbox Manager, after the policy engine has approved the call. They never
pass through a prompt, a tool argument, or a tool result.

Storage is an encrypted column in the local database — Fernet (AES-128-CBC +
HMAC) with a key from SECRETS_KEY. That is appropriate for a single-user local
deployment and explicitly NOT a substitute for Vault or 1Password in a shared
one; the key sits in .env next to the database.

Deliberate omissions:
  - No `get_secret` tool. There is no tool that returns a secret value,
    because such a tool's output would land in the model's context by
    definition. This is the whole design.
  - Values are masked in the audit log and in tool results.
"""
import base64
import hashlib
import logging
import os
import re
from typing import Optional

from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy.orm import Session

import models

logger = logging.getLogger("secrets")

SECRETS_KEY = os.environ.get("SECRETS_KEY", "")

# Env var names only: uppercase, digits, underscore. Prevents a crafted name
# from becoming a shell injection when exported.
NAME_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")


class SecretsUnavailable(RuntimeError):
    pass


def _fernet() -> Fernet:
    if not SECRETS_KEY:
        raise SecretsUnavailable(
            "SECRETS_KEY is not set. Generate one with:\n"
            "  python -c \"from cryptography.fernet import Fernet; "
            "print(Fernet.generate_key().decode())\"\n"
            "and add it to .env. Without it, secret storage is disabled."
        )
    key = SECRETS_KEY.strip()
    try:
        # Accept either a proper Fernet key or any passphrase (derived).
        return Fernet(key.encode())
    except (ValueError, TypeError):
        derived = base64.urlsafe_b64encode(hashlib.sha256(key.encode()).digest())
        return Fernet(derived)


def is_enabled() -> bool:
    return bool(SECRETS_KEY)


# ---------------------------------------------------------------------------
# CRUD
# ---------------------------------------------------------------------------

def put_secret(
    db: Session, name: str, value: str, description: str = ""
) -> models.Credential:
    if not NAME_PATTERN.match(name):
        raise ValueError(
            f"Invalid secret name '{name}'. Use uppercase letters, digits and "
            "underscores, starting with a letter (e.g. GITHUB_TOKEN)."
        )
    if not value:
        raise ValueError("Secret value cannot be empty")

    token = _fernet().encrypt(value.encode()).decode()
    existing = (
        db.query(models.Credential).filter(models.Credential.name == name).first()
    )
    if existing:
        existing.encrypted_value = token
        existing.description = description or existing.description
        existing.updated_at = models.now()
        db.add(existing)
        db.commit()
        return existing

    row = models.Credential(
        name=name,
        encrypted_value=token,
        description=description,
        # A stable fingerprint lets you confirm a rotation happened without
        # ever revealing the value.
        fingerprint=hashlib.sha256(value.encode()).hexdigest()[:12],
    )
    db.add(row)
    db.commit()
    return row


def list_secret_names(db: Session) -> list[dict]:
    """
    Safe metadata only. This is what the model is allowed to know, and it is
    what the `list_secrets` tool returns.
    """
    rows = db.query(models.Credential).order_by(models.Credential.name).all()
    return [
        {
            "name": r.name,
            "description": r.description or "",
            "fingerprint": r.fingerprint,
            "updated_at": r.updated_at.isoformat() if r.updated_at else None,
        }
        for r in rows
    ]


def delete_secret(db: Session, name: str) -> bool:
    row = db.query(models.Credential).filter(models.Credential.name == name).first()
    if row is None:
        return False
    db.delete(row)
    db.commit()
    return True


def _decrypt(row: models.Credential) -> Optional[str]:
    try:
        return _fernet().decrypt(row.encrypted_value.encode()).decode()
    except InvalidToken:
        logger.error(
            "Could not decrypt secret %s. SECRETS_KEY has probably changed; "
            "the stored value is unrecoverable and must be re-added.",
            row.name,
        )
        return None


def resolve_env(db: Session, names: list[str]) -> dict[str, str]:
    """
    Decrypt the named secrets for injection into a sandbox execution.

    This is the ONLY function that returns plaintext, and its return value
    must go straight to the Sandbox Manager's `env` parameter. It must never
    be logged, returned in a tool result, or placed in a message.
    """
    if not names:
        return {}
    if not is_enabled():
        raise SecretsUnavailable("SECRETS_KEY is not configured")

    wanted = {n for n in names if NAME_PATTERN.match(n)}
    rows = (
        db.query(models.Credential)
        .filter(models.Credential.name.in_(wanted))
        .all()
    )
    out: dict[str, str] = {}
    for row in rows:
        value = _decrypt(row)
        if value is not None:
            out[row.name] = value
    missing = wanted - set(out)
    if missing:
        logger.warning("Requested secrets not found: %s", ", ".join(sorted(missing)))
    return out


# ---------------------------------------------------------------------------
# Leak prevention
# ---------------------------------------------------------------------------

def mask_values(text: str, values: list[str]) -> str:
    """
    Redact secret values from text before it goes anywhere the model or a log
    can see.

    This is a backstop, not the primary control — the primary control is never
    putting values where they could leak. But a command like
    `curl -H "Authorization: $GITHUB_TOKEN" -v` will echo the expanded value
    into stderr, and that stderr becomes a tool result the model reads.
    """
    if not values:
        return text
    out = text
    for value in values:
        if value and len(value) >= 6:   # don't redact trivially short strings
            out = out.replace(value, "[REDACTED]")
    return out


def scan_for_leaks(text: str, db: Session) -> list[str]:
    """
    Names of any stored secrets whose value appears in `text`. Used to warn
    the user when a tool result contained a credential.
    """
    if not is_enabled():
        return []
    found = []
    for row in db.query(models.Credential).all():
        value = _decrypt(row)
        if value and len(value) >= 6 and value in text:
            found.append(row.name)
    return found
