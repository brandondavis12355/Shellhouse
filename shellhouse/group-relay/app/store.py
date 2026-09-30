"""SQLite storage for the group relay.

Deliberately small and boring: one file, WAL mode, a connection per call, all
writes inside a transaction. The relay holds only what friends' apps need to
share a group chat — identities (public keys), friendships, group membership
and the shared message log. It never stores passwords, private keys, bot
memory, prompts or sandbox data.
"""
import hashlib
import os
import sqlite3
import time
import uuid
from contextlib import contextmanager
from typing import Iterator, Optional

DB_PATH = os.environ.get("RELAY_DB", "/data/relay.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    user_id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    public_key TEXT NOT NULL,
    created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS invites (
    code_hash TEXT PRIMARY KEY,
    issuer_id TEXT NOT NULL,
    expires_at REAL NOT NULL,
    used_at REAL
);
CREATE TABLE IF NOT EXISTS friendships (
    requester_id TEXT NOT NULL,
    addressee_id TEXT NOT NULL,
    status TEXT NOT NULL,              -- pending | accepted
    created_at REAL NOT NULL,
    PRIMARY KEY (requester_id, addressee_id)
);
CREATE TABLE IF NOT EXISTS blocks (
    blocker_id TEXT NOT NULL,
    blocked_id TEXT NOT NULL,
    PRIMARY KEY (blocker_id, blocked_id)
);
CREATE TABLE IF NOT EXISTS groups (
    group_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS members (
    group_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    joined_at REAL NOT NULL,
    PRIMARY KEY (group_id, user_id)
);
CREATE TABLE IF NOT EXISTS messages (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    group_id TEXT NOT NULL,
    kind TEXT NOT NULL,                -- human | bot | system
    speaker_user_id TEXT,
    speaker_name TEXT NOT NULL,
    text TEXT NOT NULL,
    client_msg_id TEXT,
    ts REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_group_seq ON messages (group_id, seq);
CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_dedupe
    ON messages (group_id, speaker_user_id, client_msg_id) WHERE client_msg_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS nonces (
    user_id TEXT NOT NULL,
    nonce TEXT NOT NULL,
    ts REAL NOT NULL,
    PRIMARY KEY (user_id, nonce)
);
"""


def init_db() -> None:
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    # executescript manages its own transactions, so it can't run inside
    # connect()'s BEGIN IMMEDIATE wrapper.
    db = sqlite3.connect(DB_PATH, timeout=10)
    try:
        db.execute("PRAGMA journal_mode=WAL")
        db.executescript(SCHEMA)
    finally:
        db.close()


@contextmanager
def connect(write: bool = True) -> Iterator[sqlite3.Connection]:
    db = sqlite3.connect(DB_PATH, timeout=10, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA foreign_keys=ON")
    try:
        # Reads use a deferred transaction so frequent long-poll checks never
        # take the write lock away from message posts.
        db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
        yield db
        db.execute("COMMIT")
    except BaseException:
        try:
            db.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise
    finally:
        db.close()


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:20]}"


def hash_code(code: str) -> str:
    return hashlib.sha256(code.strip().encode()).hexdigest()


def now() -> float:
    return time.time()


def get_user(db: sqlite3.Connection, user_id: str) -> Optional[sqlite3.Row]:
    return db.execute("SELECT * FROM users WHERE user_id = ?", (user_id,)).fetchone()


def are_friends(db: sqlite3.Connection, a: str, b: str) -> bool:
    row = db.execute(
        "SELECT 1 FROM friendships WHERE status='accepted' AND "
        "((requester_id=? AND addressee_id=?) OR (requester_id=? AND addressee_id=?))",
        (a, b, b, a),
    ).fetchone()
    return row is not None


def is_blocked(db: sqlite3.Connection, a: str, b: str) -> bool:
    """True if either user has blocked the other."""
    row = db.execute(
        "SELECT 1 FROM blocks WHERE (blocker_id=? AND blocked_id=?) OR (blocker_id=? AND blocked_id=?)",
        (a, b, b, a),
    ).fetchone()
    return row is not None


def is_member(db: sqlite3.Connection, group_id: str, user_id: str) -> bool:
    return db.execute(
        "SELECT 1 FROM members WHERE group_id=? AND user_id=?", (group_id, user_id)
    ).fetchone() is not None
