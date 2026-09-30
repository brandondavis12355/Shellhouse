import time

import auth
import main
import store
from conftest import Identity


# ----- identity & auth ------------------------------------------------------

def test_register_and_me(client, make_user):
    alice = make_user("Alice")
    response = alice.call("GET", "/v1/me")
    assert response.status_code == 200 and response.json()["display_name"] == "Alice"


def test_user_id_must_derive_from_key(client):
    mallory = Identity(client, "Mallory")
    payload = {"user_id": "u_" + "0" * 32, "display_name": "x", "public_key": mallory.public_key}
    assert mallory.call("POST", "/v1/register", payload).status_code == 422


def test_register_requires_proof_of_possession(client):
    alice, mallory = Identity(client, "Alice"), Identity(client, "Mallory")
    payload = {"user_id": alice.user_id, "display_name": "Alice", "public_key": alice.public_key}
    # Signed with the wrong key.
    assert mallory.call("POST", "/v1/register", payload).status_code == 401


def test_unsigned_and_unknown_requests_rejected(client, make_user):
    make_user("Alice")
    assert client.get("/v1/me").status_code == 401
    stranger = Identity(client, "Stranger")
    assert stranger.call("GET", "/v1/me").status_code == 401   # never registered


def test_bad_signature_rejected(client, make_user):
    alice, bob = make_user("Alice"), make_user("Bob")
    headers = bob.headers("GET", "/v1/me", user_id=alice.user_id)   # Bob signs as Alice
    assert client.get("/v1/me", headers=headers).status_code == 401


def test_tampered_body_or_path_rejected(client, make_user):
    alice = make_user("Alice")
    body = b'{"name": "Legit"}'
    headers = alice.headers("POST", "/v1/groups", body)
    assert client.post("/v1/groups", content=b'{"name": "Evil"}', headers=headers).status_code == 401
    headers = alice.headers("GET", "/v1/groups")
    assert client.get("/v1/me", headers=headers).status_code == 401   # signed for a different path


def test_replayed_request_rejected(client, make_user):
    alice = make_user("Alice")
    headers = alice.headers("GET", "/v1/me")
    assert client.get("/v1/me", headers=headers).status_code == 200
    assert client.get("/v1/me", headers=headers).status_code == 401


def test_stale_timestamp_rejected(client, make_user):
    alice = make_user("Alice")
    assert alice.call("GET", "/v1/me", timestamp=time.time() - 600).status_code == 401
    assert alice.call("GET", "/v1/me", timestamp=time.time() + 600).status_code == 401


def test_registration_token_enforced(client, monkeypatch):
    monkeypatch.setattr(main, "REGISTRATION_TOKEN", "letmein")
    alice = Identity(client, "Alice")
    assert alice.register().status_code == 403
    payload = {"user_id": alice.user_id, "display_name": "Alice", "public_key": alice.public_key}
    import json
    body = json.dumps(payload).encode()
    headers = alice.headers("POST", "/v1/register", body)
    headers["X-Registration-Token"] = "letmein"
    assert client.post("/v1/register", content=body, headers=headers).status_code == 200


def test_body_size_cap(client, make_user):
    alice = make_user("Alice")
    huge = {"name": "x" * (auth.MAX_BODY_BYTES + 10)}
    assert alice.call("POST", "/v1/groups", huge).status_code == 413


def test_rate_limit(client, make_user, monkeypatch):
    monkeypatch.setattr(auth, "REQUESTS_PER_MINUTE", 3)
    alice = make_user("Alice")
    codes = [alice.call("GET", "/v1/me").status_code for _ in range(6)]
    assert 429 in codes


# ----- invites & friends ----------------------------------------------------

def test_invite_flow_requires_accept(client, make_user):
    alice, bob = make_user("Alice"), make_user("Bob")
    code = alice.call("POST", "/v1/invites").json()["code"]
    assert bob.call("POST", "/v1/invites/redeem", {"code": code}).json()["status"] == "pending"
    assert alice.call("GET", "/v1/friends").json()["incoming"][0]["user_id"] == bob.user_id
    assert alice.call("GET", "/v1/friends").json()["friends"] == []
    assert alice.call("POST", f"/v1/friends/{bob.user_id}/accept").status_code == 200
    assert bob.call("GET", "/v1/friends").json()["friends"][0]["display_name"] == "Alice"


def test_invite_is_single_use_and_not_self_redeemable(client, make_user):
    alice, bob, carol = make_user("Alice"), make_user("Bob"), make_user("Carol")
    code = alice.call("POST", "/v1/invites").json()["code"]
    assert alice.call("POST", "/v1/invites/redeem", {"code": code}).status_code == 404
    assert bob.call("POST", "/v1/invites/redeem", {"code": code}).status_code == 200
    assert carol.call("POST", "/v1/invites/redeem", {"code": code}).status_code == 404


def test_invite_expiry_and_garbage_codes(client, make_user):
    alice, bob = make_user("Alice"), make_user("Bob")
    code = alice.call("POST", "/v1/invites").json()["code"]
    with store.connect() as db:
        db.execute("UPDATE invites SET expires_at = ?", (time.time() - 1,))
    assert bob.call("POST", "/v1/invites/redeem", {"code": code}).status_code == 404
    assert bob.call("POST", "/v1/invites/redeem", {"code": "not-a-real-code"}).status_code == 404


def test_only_addressee_can_accept(client, make_user):
    alice, bob, eve = make_user("Alice"), make_user("Bob"), make_user("Eve")
    code = alice.call("POST", "/v1/invites").json()["code"]
    bob.call("POST", "/v1/invites/redeem", {"code": code})
    assert eve.call("POST", f"/v1/friends/{bob.user_id}/accept").status_code == 404
    assert bob.call("POST", f"/v1/friends/{alice.user_id}/accept").status_code == 404   # requester can't self-accept


def test_block_removes_friend_and_prevents_reinvite(client, make_user, befriend):
    alice, bob = make_user("Alice"), make_user("Bob")
    befriend(alice, bob)
    assert alice.call("POST", f"/v1/blocks/{bob.user_id}").status_code == 200
    assert alice.call("GET", "/v1/friends").json()["friends"] == []
    code = alice.call("POST", "/v1/invites").json()["code"]
    assert bob.call("POST", "/v1/invites/redeem", {"code": code}).status_code == 404


# ----- groups ---------------------------------------------------------------

def _group(owner):
    return owner.call("POST", "/v1/groups", {"name": "Team"}).json()["group_id"]


def test_only_friends_can_be_added_and_only_by_owner(client, make_user, befriend):
    alice, bob, carol = make_user("Alice"), make_user("Bob"), make_user("Carol")
    befriend(alice, bob)
    gid = _group(alice)
    assert alice.call("POST", f"/v1/groups/{gid}/members", {"user_id": carol.user_id}).status_code == 403   # not a friend
    assert alice.call("POST", f"/v1/groups/{gid}/members", {"user_id": bob.user_id}).status_code == 200
    befriend(bob, carol)
    assert bob.call("POST", f"/v1/groups/{gid}/members", {"user_id": carol.user_id}).status_code == 403     # not owner


def test_group_size_limit(client, make_user, befriend):
    alice = make_user("Alice")
    gid = _group(alice)
    added = []
    for i in range(6):
        friend = make_user(f"F{i}")
        befriend(alice, friend)
        added.append(alice.call("POST", f"/v1/groups/{gid}/members", {"user_id": friend.user_id}).status_code)
    # RELAY_MAX_HUMANS=4 in tests: owner + 3 friends, then full.
    assert added[:3] == [200, 200, 200] and set(added[3:]) == {409}


def test_non_members_cannot_see_or_probe_groups(client, make_user):
    alice, eve = make_user("Alice"), make_user("Eve")
    gid = _group(alice)
    assert eve.call("GET", f"/v1/groups/{gid}").status_code == 404
    assert eve.call("GET", f"/v1/groups/{gid}/messages").status_code == 404
    assert eve.call("POST", f"/v1/groups/{gid}/messages", {"text": "hi"}).status_code == 404
    assert eve.call("GET", "/v1/groups/g_doesnotexist").status_code == 404   # same response: no id probing


def test_removing_friend_removes_them_from_owners_groups(client, make_user, befriend):
    alice, bob = make_user("Alice"), make_user("Bob")
    befriend(alice, bob)
    gid = _group(alice)
    alice.call("POST", f"/v1/groups/{gid}/members", {"user_id": bob.user_id})
    assert bob.call("GET", f"/v1/groups/{gid}").status_code == 200
    alice.call("DELETE", f"/v1/friends/{bob.user_id}")
    assert bob.call("GET", f"/v1/groups/{gid}").status_code == 404


def test_member_can_leave_owner_cannot(client, make_user, befriend):
    alice, bob = make_user("Alice"), make_user("Bob")
    befriend(alice, bob)
    gid = _group(alice)
    alice.call("POST", f"/v1/groups/{gid}/members", {"user_id": bob.user_id})
    assert alice.call("DELETE", f"/v1/groups/{gid}/members/{alice.user_id}").status_code == 409
    assert bob.call("DELETE", f"/v1/groups/{gid}/members/{bob.user_id}").status_code == 200


# ----- messages -------------------------------------------------------------

def _two_member_group(make_user, befriend):
    alice, bob = make_user("Alice"), make_user("Bob")
    befriend(alice, bob)
    gid = _group(alice)
    alice.call("POST", f"/v1/groups/{gid}/members", {"user_id": bob.user_id})
    return alice, bob, gid


def test_post_and_read_messages_with_server_assigned_speaker(client, make_user, befriend):
    alice, bob, gid = _two_member_group(make_user, befriend)
    bob.call("POST", f"/v1/groups/{gid}/messages", {"text": "hello", "speaker_name": "Alice"})   # spoofing attempt ignored
    messages = alice.call("GET", f"/v1/groups/{gid}/messages").json()["messages"]
    assert messages[0]["speaker_name"] == "Bob" and messages[0]["speaker_user_id"] == bob.user_id
    assert messages[0]["kind"] == "human"


def test_only_owner_can_post_bot_or_system(client, make_user, befriend):
    alice, bob, gid = _two_member_group(make_user, befriend)
    assert bob.call("POST", f"/v1/groups/{gid}/messages", {"text": "x", "kind": "bot", "speaker_name": "Helper"}).status_code == 403
    assert bob.call("POST", f"/v1/groups/{gid}/messages", {"text": "x", "kind": "system"}).status_code == 403
    assert alice.call("POST", f"/v1/groups/{gid}/messages", {"text": "x", "kind": "bot", "speaker_name": "Helper"}).status_code == 200
    bad = alice.call("POST", f"/v1/groups/{gid}/messages", {"text": "x", "kind": "admin"})
    assert bad.status_code == 422


def test_cursor_paging_and_dedupe(client, make_user, befriend):
    alice, bob, gid = _two_member_group(make_user, befriend)
    first = bob.call("POST", f"/v1/groups/{gid}/messages", {"text": "one", "client_msg_id": "m1"}).json()
    again = bob.call("POST", f"/v1/groups/{gid}/messages", {"text": "one", "client_msg_id": "m1"}).json()
    assert again["duplicate"] is True and again["seq"] == first["seq"]
    bob.call("POST", f"/v1/groups/{gid}/messages", {"text": "two"})
    page = alice.call("GET", f"/v1/groups/{gid}/messages?after={first['seq']}").json()
    assert [m["text"] for m in page["messages"]] == ["two"] and page["latest_seq"] == page["messages"][0]["seq"]


def test_message_limits_and_sanitizing(client, make_user, befriend):
    alice, bob, gid = _two_member_group(make_user, befriend)
    assert bob.call("POST", f"/v1/groups/{gid}/messages", {"text": "x" * (main.MAX_MESSAGE_CHARS + 1)}).status_code == 422
    assert bob.call("POST", f"/v1/groups/{gid}/messages", {"text": ""}).status_code == 422
    bob.call("POST", f"/v1/groups/{gid}/messages", {"text": "a\x00b\x07c"})
    assert alice.call("GET", f"/v1/groups/{gid}/messages").json()["messages"][0]["text"] == "abc"


def test_message_rate_limit(client, make_user, befriend, monkeypatch):
    monkeypatch.setattr(auth, "MESSAGES_PER_MINUTE", 3)
    alice, bob, gid = _two_member_group(make_user, befriend)
    codes = [bob.call("POST", f"/v1/groups/{gid}/messages", {"text": f"m{i}"}).status_code for i in range(6)]
    assert codes.count(200) == 3 and 429 in codes


def test_removed_member_loses_access_to_history(client, make_user, befriend):
    alice, bob, gid = _two_member_group(make_user, befriend)
    alice.call("POST", f"/v1/groups/{gid}/messages", {"text": "secret", "kind": "system"})
    alice.call("DELETE", f"/v1/groups/{gid}/members/{bob.user_id}")
    assert bob.call("GET", f"/v1/groups/{gid}/messages").status_code == 404


def test_long_poll_returns_promptly_when_message_arrives(client, make_user, befriend):
    import threading
    alice, bob, gid = _two_member_group(make_user, befriend)
    threading.Timer(0.7, lambda: bob.call("POST", f"/v1/groups/{gid}/messages", {"text": "late"})).start()
    started = time.monotonic()
    result = alice.call("GET", f"/v1/groups/{gid}/messages?after=0&wait=10").json()
    assert [m["text"] for m in result["messages"]] == ["late"]
    assert time.monotonic() - started < 5


def test_delete_group_removes_everything(client, make_user, befriend):
    alice, bob, gid = _two_member_group(make_user, befriend)
    bob.call("POST", f"/v1/groups/{gid}/messages", {"text": "hi"})
    assert bob.call("DELETE", f"/v1/groups/{gid}").status_code == 403
    assert alice.call("DELETE", f"/v1/groups/{gid}").status_code == 200
    assert alice.call("GET", f"/v1/groups/{gid}").status_code == 404
    with store.connect() as db:
        assert db.execute("SELECT COUNT(*) FROM messages").fetchone()[0] == 0


def test_retention_keeps_only_newest_messages(client, make_user, befriend, monkeypatch):
    monkeypatch.setattr(main, "MAX_MESSAGES_PER_GROUP", 5)
    monkeypatch.setattr(auth, "MESSAGES_PER_MINUTE", 1000)
    alice, bob, gid = _two_member_group(make_user, befriend)
    for i in range(12):
        bob.call("POST", f"/v1/groups/{gid}/messages", {"text": f"m{i}"})
    messages = alice.call("GET", f"/v1/groups/{gid}/messages?limit=200").json()["messages"]
    assert [m["text"] for m in messages] == [f"m{i}" for i in range(7, 12)]
    # Another group's history is untouched by this group's pruning.
    other = _group(alice)
    alice.call("POST", f"/v1/groups/{other}/messages", {"text": "keep me"})
    for i in range(8):
        bob.call("POST", f"/v1/groups/{gid}/messages", {"text": f"x{i}"})
    assert [m["text"] for m in alice.call("GET", f"/v1/groups/{other}/messages").json()["messages"]] == ["keep me"]
