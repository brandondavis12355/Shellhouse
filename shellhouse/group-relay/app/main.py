"""Group relay: the small shared service that lets friends' apps share a
group chat. See README.md for the full API, auth scheme and threat model.

Trust model in one paragraph: the relay authenticates users by Ed25519
signatures, only lets accepted friends into a group, lets members post only
as themselves (`kind=human`), and lets only the group OWNER post `bot` and
`system` messages (the owner's app mirrors its bots' replies here). Clients
must still treat every message text as untrusted input.
"""
import asyncio
import base64
import logging
import os
import re
import secrets
import sqlite3
import time
from typing import List, Optional

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

import auth
import store

logger = logging.getLogger("group-relay")
logging.basicConfig(level=logging.INFO)

MAX_HUMANS_PER_GROUP = int(os.environ.get("RELAY_MAX_HUMANS", "20"))
MAX_GROUPS_PER_OWNER = int(os.environ.get("RELAY_MAX_GROUPS_PER_OWNER", "50"))
MAX_FRIENDS = int(os.environ.get("RELAY_MAX_FRIENDS", "200"))
MAX_ACTIVE_INVITES = 10
INVITE_TTL_SECONDS = 24 * 3600
MAX_MESSAGE_CHARS = 8000
MAX_LONG_POLL_SECONDS = 30
REGISTRATION_TOKEN = os.environ.get("RELAY_REGISTRATION_TOKEN", "")

CONTROL_CHARS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

app = FastAPI(title="Group Relay", docs_url=None, redoc_url=None, openapi_url=None)


@app.on_event("startup")
def _startup() -> None:
    store.init_db()


@app.middleware("http")
async def limit_body_size(request: Request, call_next):
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > auth.MAX_BODY_BYTES:
        return JSONResponse({"detail": "request body too large"}, status_code=413)
    return await call_next(request)


def audit(event: str, **fields) -> None:
    logger.info("%s %s", event, " ".join(f"{k}={v}" for k, v in fields.items()))


def clean_text(value: str, limit: int) -> str:
    return CONTROL_CHARS.sub("", value).strip()[:limit]


def parse(model, body: bytes):
    try:
        return model.model_validate_json(body or b"{}")
    except Exception as exc:  # pydantic ValidationError / bad JSON
        raise HTTPException(status_code=422, detail=f"invalid request: {str(exc)[:200]}")


# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

class RegisterRequest(BaseModel):
    user_id: str
    display_name: str = Field(min_length=1, max_length=40)
    public_key: str   # base64 Ed25519, 32 bytes


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/v1/register")
async def register(request: Request):
    """Create (or rename) an identity. Proof of possession: the request must be
    signed with the very key being registered. If RELAY_REGISTRATION_TOKEN is
    set, callers must also present it in X-Registration-Token (a shared secret
    the relay owner hands to people they want to allow in)."""
    ip = request.client.host if request.client else "?"
    if not auth.limiter.allow(f"register:{ip}", auth.REGISTRATIONS_PER_IP_PER_MINUTE):
        raise HTTPException(status_code=429, detail="too many registrations")
    if REGISTRATION_TOKEN and not auth.constant_time_equals(
        request.headers.get("X-Registration-Token", ""), REGISTRATION_TOKEN
    ):
        raise HTTPException(status_code=403, detail="registration token required")
    body = await request.body()
    req = parse(RegisterRequest, body)
    try:
        derived = auth.user_id_for_key(req.public_key)
    except ValueError:
        raise HTTPException(status_code=422, detail="invalid public key")
    if derived != req.user_id:
        raise HTTPException(status_code=422, detail="user_id must be derived from the public key")
    timestamp = request.headers.get("X-Timestamp", "")
    nonce = request.headers.get("X-Nonce", "")
    signature = request.headers.get("X-Signature", "")
    message = auth.signing_string(request.method, request.url.path, timestamp, nonce, body)
    if not auth.verify_signature(req.public_key, signature, message):
        raise HTTPException(status_code=401, detail="bad signature")
    auth.check_freshness(req.user_id, timestamp, nonce)
    name = clean_text(req.display_name, 40)
    if not name:
        raise HTTPException(status_code=422, detail="display_name required")
    with store.connect() as db:
        existing = store.get_user(db, req.user_id)
        if existing:
            db.execute("UPDATE users SET display_name=? WHERE user_id=?", (name, req.user_id))
        else:
            db.execute(
                "INSERT INTO users (user_id, display_name, public_key, created_at) VALUES (?,?,?,?)",
                (req.user_id, name, req.public_key, store.now()),
            )
    audit("register", user=req.user_id, created=existing is None)
    return {"user_id": req.user_id, "display_name": name}


@app.get("/v1/me")
async def me(ident=Depends(auth.authenticate)):
    user_id, _ = ident
    with store.connect(write=False) as db:
        user = store.get_user(db, user_id)
    return {"user_id": user_id, "display_name": user["display_name"]}


# ---------------------------------------------------------------------------
# Invites and friends
# ---------------------------------------------------------------------------

class RedeemRequest(BaseModel):
    code: str = Field(min_length=6, max_length=64)


@app.post("/v1/invites")
async def create_invite(ident=Depends(auth.authenticate)):
    user_id, _ = ident
    code = secrets.token_urlsafe(12)
    with store.connect() as db:
        active = db.execute(
            "SELECT COUNT(*) FROM invites WHERE issuer_id=? AND used_at IS NULL AND expires_at>?",
            (user_id, store.now()),
        ).fetchone()[0]
        if active >= MAX_ACTIVE_INVITES:
            raise HTTPException(status_code=429, detail="too many active invites")
        db.execute(
            "INSERT INTO invites (code_hash, issuer_id, expires_at) VALUES (?,?,?)",
            (store.hash_code(code), user_id, store.now() + INVITE_TTL_SECONDS),
        )
    audit("invite_created", user=user_id)
    return {"code": code, "expires_in_seconds": INVITE_TTL_SECONDS}


@app.post("/v1/invites/redeem")
async def redeem_invite(ident=Depends(auth.authenticate)):
    user_id, body = ident
    req = parse(RedeemRequest, body)
    if not auth.limiter.allow(f"redeem:{user_id}", 10):
        raise HTTPException(status_code=429, detail="too many attempts")
    with store.connect() as db:
        invite = db.execute("SELECT * FROM invites WHERE code_hash=?", (store.hash_code(req.code),)).fetchone()
        # One error for every failure: don't reveal whether a code exists.
        generic = HTTPException(status_code=404, detail="invalid or expired invite")
        if invite is None or invite["used_at"] is not None or invite["expires_at"] < store.now():
            raise generic
        issuer = invite["issuer_id"]
        if issuer == user_id or store.is_blocked(db, issuer, user_id):
            raise generic
        if store.are_friends(db, issuer, user_id):
            raise generic
        count = db.execute(
            "SELECT COUNT(*) FROM friendships WHERE requester_id=? OR addressee_id=?", (user_id, user_id)
        ).fetchone()[0]
        if count >= MAX_FRIENDS:
            raise HTTPException(status_code=409, detail="friend limit reached")
        db.execute("UPDATE invites SET used_at=? WHERE code_hash=?", (store.now(), invite["code_hash"]))
        db.execute(
            "INSERT OR IGNORE INTO friendships (requester_id, addressee_id, status, created_at) VALUES (?,?, 'pending', ?)",
            (user_id, issuer, store.now()),
        )
        issuer_row = store.get_user(db, issuer)
    audit("invite_redeemed", user=user_id, issuer=issuer)
    return {"status": "pending", "friend": {"user_id": issuer, "display_name": issuer_row["display_name"]}}


@app.get("/v1/friends")
async def list_friends(ident=Depends(auth.authenticate)):
    user_id, _ = ident
    with store.connect(write=False) as db:
        rows = db.execute(
            "SELECT f.requester_id, f.addressee_id, f.status, u.user_id AS other_id, u.display_name "
            "FROM friendships f JOIN users u ON u.user_id = CASE WHEN f.requester_id=? THEN f.addressee_id ELSE f.requester_id END "
            "WHERE f.requester_id=? OR f.addressee_id=?",
            (user_id, user_id, user_id),
        ).fetchall()
    friends, incoming, outgoing = [], [], []
    for row in rows:
        entry = {"user_id": row["other_id"], "display_name": row["display_name"]}
        if row["status"] == "accepted":
            friends.append(entry)
        elif row["addressee_id"] == user_id:
            incoming.append(entry)
        else:
            outgoing.append(entry)
    return {"friends": friends, "incoming": incoming, "outgoing": outgoing}


@app.post("/v1/friends/{other_id}/accept")
async def accept_friend(other_id: str, ident=Depends(auth.authenticate)):
    user_id, _ = ident
    with store.connect() as db:
        if store.is_blocked(db, user_id, other_id):
            raise HTTPException(status_code=404, detail="no such request")
        cur = db.execute(
            "UPDATE friendships SET status='accepted' WHERE requester_id=? AND addressee_id=? AND status='pending'",
            (other_id, user_id),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="no such request")
    audit("friend_accepted", user=user_id, other=other_id)
    return {"ok": True}


@app.post("/v1/friends/{other_id}/decline")
async def decline_friend(other_id: str, ident=Depends(auth.authenticate)):
    user_id, _ = ident
    with store.connect() as db:
        db.execute(
            "DELETE FROM friendships WHERE requester_id=? AND addressee_id=? AND status='pending'",
            (other_id, user_id),
        )
    return {"ok": True}


def _drop_friendship_and_memberships(db: sqlite3.Connection, a: str, b: str) -> None:
    db.execute(
        "DELETE FROM friendships WHERE (requester_id=? AND addressee_id=?) OR (requester_id=? AND addressee_id=?)",
        (a, b, b, a),
    )
    # A removed friend can't stay in the other's groups.
    db.execute(
        "DELETE FROM members WHERE user_id=? AND group_id IN (SELECT group_id FROM groups WHERE owner_id=?)", (b, a)
    )
    db.execute(
        "DELETE FROM members WHERE user_id=? AND group_id IN (SELECT group_id FROM groups WHERE owner_id=?)", (a, b)
    )


@app.delete("/v1/friends/{other_id}")
async def remove_friend(other_id: str, ident=Depends(auth.authenticate)):
    user_id, _ = ident
    with store.connect() as db:
        _drop_friendship_and_memberships(db, user_id, other_id)
    audit("friend_removed", user=user_id, other=other_id)
    return {"ok": True}


@app.post("/v1/blocks/{other_id}")
async def block_user(other_id: str, ident=Depends(auth.authenticate)):
    user_id, _ = ident
    if other_id == user_id:
        raise HTTPException(status_code=422, detail="can't block yourself")
    with store.connect() as db:
        if store.get_user(db, other_id) is None:
            raise HTTPException(status_code=404, detail="unknown user")
        db.execute("INSERT OR IGNORE INTO blocks (blocker_id, blocked_id) VALUES (?,?)", (user_id, other_id))
        _drop_friendship_and_memberships(db, user_id, other_id)
    audit("blocked", user=user_id, other=other_id)
    return {"ok": True}


# ---------------------------------------------------------------------------
# Groups
# ---------------------------------------------------------------------------

class CreateGroupRequest(BaseModel):
    name: str = Field(min_length=1, max_length=60)


class AddMemberRequest(BaseModel):
    user_id: str


def _require_member(db: sqlite3.Connection, group_id: str, user_id: str) -> sqlite3.Row:
    group = db.execute("SELECT * FROM groups WHERE group_id=?", (group_id,)).fetchone()
    # Same response for "doesn't exist" and "not yours": don't leak group ids.
    if group is None or not store.is_member(db, group_id, user_id):
        raise HTTPException(status_code=404, detail="no such group")
    return group


@app.post("/v1/groups")
async def create_group(ident=Depends(auth.authenticate)):
    user_id, body = ident
    req = parse(CreateGroupRequest, body)
    name = clean_text(req.name, 60)
    if not name:
        raise HTTPException(status_code=422, detail="name required")
    with store.connect() as db:
        owned = db.execute("SELECT COUNT(*) FROM groups WHERE owner_id=?", (user_id,)).fetchone()[0]
        if owned >= MAX_GROUPS_PER_OWNER:
            raise HTTPException(status_code=409, detail="group limit reached")
        group_id = store.new_id("g")
        db.execute("INSERT INTO groups (group_id, name, owner_id, created_at) VALUES (?,?,?,?)",
                   (group_id, name, user_id, store.now()))
        db.execute("INSERT INTO members (group_id, user_id, joined_at) VALUES (?,?,?)", (group_id, user_id, store.now()))
    audit("group_created", user=user_id, group=group_id)
    return {"group_id": group_id, "name": name, "owner_id": user_id}


@app.get("/v1/groups")
async def list_groups(ident=Depends(auth.authenticate)):
    user_id, _ = ident
    with store.connect(write=False) as db:
        rows = db.execute(
            "SELECT g.group_id, g.name, g.owner_id FROM groups g JOIN members m ON m.group_id=g.group_id "
            "WHERE m.user_id=? ORDER BY g.created_at", (user_id,)
        ).fetchall()
    return {"groups": [dict(row) for row in rows]}


@app.get("/v1/groups/{group_id}")
async def get_group(group_id: str, ident=Depends(auth.authenticate)):
    user_id, _ = ident
    with store.connect(write=False) as db:
        group = _require_member(db, group_id, user_id)
        members = db.execute(
            "SELECT u.user_id, u.display_name FROM members m JOIN users u ON u.user_id=m.user_id "
            "WHERE m.group_id=? ORDER BY m.joined_at", (group_id,)
        ).fetchall()
    return {"group_id": group_id, "name": group["name"], "owner_id": group["owner_id"],
            "members": [dict(m) for m in members]}


@app.post("/v1/groups/{group_id}/members")
async def add_member(group_id: str, ident=Depends(auth.authenticate)):
    user_id, body = ident
    req = parse(AddMemberRequest, body)
    with store.connect() as db:
        group = _require_member(db, group_id, user_id)
        if group["owner_id"] != user_id:
            raise HTTPException(status_code=403, detail="only the owner can add members")
        if store.get_user(db, req.user_id) is None or not store.are_friends(db, user_id, req.user_id) \
                or store.is_blocked(db, user_id, req.user_id):
            raise HTTPException(status_code=403, detail="only friends can be added")
        count = db.execute("SELECT COUNT(*) FROM members WHERE group_id=?", (group_id,)).fetchone()[0]
        if count >= MAX_HUMANS_PER_GROUP:
            raise HTTPException(status_code=409, detail=f"group is full ({MAX_HUMANS_PER_GROUP} people)")
        db.execute("INSERT OR IGNORE INTO members (group_id, user_id, joined_at) VALUES (?,?,?)",
                   (group_id, req.user_id, store.now()))
    audit("member_added", user=user_id, group=group_id, added=req.user_id)
    return {"ok": True}


@app.delete("/v1/groups/{group_id}/members/{member_id}")
async def remove_member(group_id: str, member_id: str, ident=Depends(auth.authenticate)):
    user_id, _ = ident
    with store.connect() as db:
        group = _require_member(db, group_id, user_id)
        if member_id == group["owner_id"]:
            raise HTTPException(status_code=409, detail="the owner can't leave; delete the group instead")
        if user_id != group["owner_id"] and member_id != user_id:
            raise HTTPException(status_code=403, detail="only the owner can remove others")
        db.execute("DELETE FROM members WHERE group_id=? AND user_id=?", (group_id, member_id))
    audit("member_removed", user=user_id, group=group_id, removed=member_id)
    return {"ok": True}


@app.delete("/v1/groups/{group_id}")
async def delete_group(group_id: str, ident=Depends(auth.authenticate)):
    user_id, _ = ident
    with store.connect() as db:
        group = _require_member(db, group_id, user_id)
        if group["owner_id"] != user_id:
            raise HTTPException(status_code=403, detail="only the owner can delete the group")
        db.execute("DELETE FROM messages WHERE group_id=?", (group_id,))
        db.execute("DELETE FROM members WHERE group_id=?", (group_id,))
        db.execute("DELETE FROM groups WHERE group_id=?", (group_id,))
    audit("group_deleted", user=user_id, group=group_id)
    return {"ok": True}


# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------

class PostMessageRequest(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_MESSAGE_CHARS)
    kind: str = "human"                      # human | bot | system
    speaker_name: Optional[str] = None       # bot/system only (owner-supplied label)
    client_msg_id: Optional[str] = Field(default=None, max_length=64)


@app.post("/v1/groups/{group_id}/messages")
async def post_message(group_id: str, ident=Depends(auth.authenticate)):
    user_id, body = ident
    req = parse(PostMessageRequest, body)
    if req.kind not in ("human", "bot", "system"):
        raise HTTPException(status_code=422, detail="kind must be human, bot or system")
    if not auth.limiter.allow(f"msg:{user_id}", auth.MESSAGES_PER_MINUTE):
        raise HTTPException(status_code=429, detail="message rate limit exceeded")
    text = clean_text(req.text, MAX_MESSAGE_CHARS)
    if not text:
        raise HTTPException(status_code=422, detail="text required")
    with store.connect() as db:
        group = _require_member(db, group_id, user_id)
        user = store.get_user(db, user_id)
        if req.kind == "human":
            speaker_user_id, speaker_name = user_id, user["display_name"]
        else:
            # Only the owner's app mirrors bot/system messages; members can
            # never impersonate a bot or the system.
            if group["owner_id"] != user_id:
                raise HTTPException(status_code=403, detail="only the group owner can post bot or system messages")
            speaker_user_id = user_id
            speaker_name = clean_text(req.speaker_name or ("System" if req.kind == "system" else "Bot"), 40) or "Bot"
        try:
            cur = db.execute(
                "INSERT INTO messages (group_id, kind, speaker_user_id, speaker_name, text, client_msg_id, ts) "
                "VALUES (?,?,?,?,?,?,?)",
                (group_id, req.kind, speaker_user_id, speaker_name, text, req.client_msg_id, store.now()),
            )
            seq = cur.lastrowid
            duplicate = False
        except sqlite3.IntegrityError:
            row = db.execute(
                "SELECT seq FROM messages WHERE group_id=? AND speaker_user_id=? AND client_msg_id=?",
                (group_id, speaker_user_id, req.client_msg_id),
            ).fetchone()
            seq, duplicate = row["seq"], True
    return {"seq": seq, "duplicate": duplicate}


def _fetch_messages(group_id: str, after: int, limit: int) -> List[dict]:
    with store.connect(write=False) as db:
        rows = db.execute(
            "SELECT seq, kind, speaker_user_id, speaker_name, text, ts FROM messages "
            "WHERE group_id=? AND seq>? ORDER BY seq LIMIT ?", (group_id, after, limit)
        ).fetchall()
    return [dict(row) for row in rows]


@app.get("/v1/groups/{group_id}/messages")
async def get_messages(group_id: str, after: int = 0, limit: int = 100, wait: int = 0,
                       ident=Depends(auth.authenticate)):
    """Messages after `after` (a seq number). With wait>0 it long-polls: holds
    the request open up to `wait` seconds (max 30) until something arrives."""
    user_id, _ = ident
    limit = max(1, min(limit, 200))
    wait = max(0, min(wait, MAX_LONG_POLL_SECONDS))
    with store.connect(write=False) as db:
        _require_member(db, group_id, user_id)
    deadline = time.monotonic() + wait
    while True:
        messages = _fetch_messages(group_id, max(after, 0), limit)
        if messages or time.monotonic() >= deadline:
            latest = messages[-1]["seq"] if messages else max(after, 0)
            return {"messages": messages, "latest_seq": latest}
        await asyncio.sleep(0.5)
        with store.connect(write=False) as db:   # membership can be revoked mid-poll
            _require_member(db, group_id, user_id)
