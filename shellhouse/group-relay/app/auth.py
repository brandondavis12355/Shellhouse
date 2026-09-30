"""Request authentication and rate limiting.

Every request (except /healthz and the initial /v1/register proof) is signed
with the caller's Ed25519 key:

    signature = Ed25519-sign(privkey,
        METHOD + "\n" + PATH_WITH_QUERY + "\n" + TIMESTAMP + "\n" + NONCE + "\n" + sha256_hex(BODY))

sent as headers X-User-Id, X-Timestamp (unix seconds), X-Nonce (random, unique
per request) and X-Signature (base64). A request is rejected if the signature
is wrong, the timestamp is more than 120 s off, or the nonce was seen before
(replay). There are no passwords or bearer tokens to steal; a user's identity
IS their key, and a user_id is derived from the public key so it can't be
squatted.
"""
import base64
import collections
import hashlib
import hmac
import os
import re
import sqlite3
import threading
import time
from typing import Deque, Dict, Tuple

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from fastapi import HTTPException, Request

import store

MAX_SKEW_SECONDS = 120
NONCE_RETENTION_SECONDS = 600
MAX_BODY_BYTES = 64 * 1024
USER_ID_PATTERN = re.compile(r"^u_[0-9a-f]{32}$")
NONCE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{8,64}$")


def user_id_for_key(public_key_b64: str) -> str:
    raw = base64.b64decode(public_key_b64, validate=True)
    if len(raw) != 32:
        raise ValueError("public key must be 32 bytes")
    return "u_" + hashlib.sha256(raw).hexdigest()[:32]


def signing_string(method: str, path_with_query: str, timestamp: str, nonce: str, body: bytes) -> bytes:
    body_hash = hashlib.sha256(body).hexdigest()
    return f"{method.upper()}\n{path_with_query}\n{timestamp}\n{nonce}\n{body_hash}".encode()


def verify_signature(public_key_b64: str, signature_b64: str, message: bytes) -> bool:
    try:
        key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key_b64, validate=True))
        key.verify(base64.b64decode(signature_b64, validate=True), message)
        return True
    except (InvalidSignature, ValueError):
        return False


class RateLimiter:
    """Sliding-window counter per key, in memory (the relay is one process)."""

    def __init__(self) -> None:
        self._hits: Dict[str, Deque[float]] = collections.defaultdict(collections.deque)
        self._lock = threading.Lock()

    def allow(self, key: str, limit: int, window: float = 60.0) -> bool:
        cutoff = time.monotonic() - window
        with self._lock:
            hits = self._hits[key]
            while hits and hits[0] < cutoff:
                hits.popleft()
            if len(hits) >= limit:
                return False
            hits.append(time.monotonic())
            return True


limiter = RateLimiter()
REQUESTS_PER_MINUTE = int(os.environ.get("RELAY_REQUESTS_PER_MINUTE", "240"))
MESSAGES_PER_MINUTE = int(os.environ.get("RELAY_MESSAGES_PER_MINUTE", "30"))
REGISTRATIONS_PER_IP_PER_MINUTE = int(os.environ.get("RELAY_REGISTRATIONS_PER_IP_PER_MINUTE", "10"))


def _header(request: Request, name: str) -> str:
    value = request.headers.get(name, "")
    if not value:
        raise HTTPException(status_code=401, detail=f"missing {name}")
    return value


def check_freshness(user_id: str, timestamp: str, nonce: str) -> None:
    try:
        ts = float(timestamp)
    except ValueError:
        raise HTTPException(status_code=401, detail="bad timestamp")
    if abs(time.time() - ts) > MAX_SKEW_SECONDS:
        raise HTTPException(status_code=401, detail="timestamp outside allowed window")
    if not NONCE_PATTERN.match(nonce):
        raise HTTPException(status_code=401, detail="bad nonce")
    with store.connect() as db:
        db.execute("DELETE FROM nonces WHERE ts < ?", (time.time() - NONCE_RETENTION_SECONDS,))
        try:
            db.execute("INSERT INTO nonces (user_id, nonce, ts) VALUES (?, ?, ?)", (user_id, nonce, time.time()))
        except sqlite3.IntegrityError:
            raise HTTPException(status_code=401, detail="replayed request")


async def authenticate(request: Request) -> Tuple[str, bytes]:
    """Returns (user_id, raw_body) for a correctly signed request."""
    user_id = _header(request, "X-User-Id")
    timestamp = _header(request, "X-Timestamp")
    nonce = _header(request, "X-Nonce")
    signature = _header(request, "X-Signature")
    if not USER_ID_PATTERN.match(user_id):
        raise HTTPException(status_code=401, detail="bad user id")
    body = await request.body()
    with store.connect(write=False) as db:
        user = store.get_user(db, user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="unknown user")
    path = request.url.path + (f"?{request.url.query}" if request.url.query else "")
    message = signing_string(request.method, path, timestamp, nonce, body)
    if not verify_signature(user["public_key"], signature, message):
        raise HTTPException(status_code=401, detail="bad signature")
    check_freshness(user_id, timestamp, nonce)
    if not limiter.allow(f"user:{user_id}", REQUESTS_PER_MINUTE):
        raise HTTPException(status_code=429, detail="rate limit exceeded")
    return user_id, body


def constant_time_equals(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode(), b.encode())
