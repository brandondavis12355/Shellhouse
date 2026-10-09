import base64
import json
import os
import sys
import tempfile
import time
import uuid

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

_tmp = tempfile.mkdtemp()
os.environ["RELAY_DB"] = os.path.join(_tmp, "relay.db")
os.environ.setdefault("RELAY_MAX_HUMANS", "4")

import auth  # noqa: E402
import main  # noqa: E402
import store  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402


class Identity:
    """A test client identity that signs requests exactly as the app will."""

    def __init__(self, client: TestClient, name: str):
        self.client = client
        self.name = name
        self.key = Ed25519PrivateKey.generate()
        raw = self.key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.public_key = base64.b64encode(raw).decode()
        self.user_id = auth.user_id_for_key(self.public_key)

    def headers(self, method, path, body=b"", timestamp=None, nonce=None, user_id=None):
        timestamp = str(timestamp if timestamp is not None else time.time())
        nonce = nonce or uuid.uuid4().hex
        message = auth.signing_string(method, path, timestamp, nonce, body)
        return {
            "X-User-Id": user_id or self.user_id,
            "X-Timestamp": timestamp,
            "X-Nonce": nonce,
            "X-Signature": base64.b64encode(self.key.sign(message)).decode(),
            "Content-Type": "application/json",
        }

    def call(self, method, path, payload=None, **header_overrides):
        body = json.dumps(payload).encode() if payload is not None else b""
        headers = self.headers(method, path, body, **header_overrides)
        return self.client.request(method, path, content=body, headers=headers)

    def register(self, **kw):
        payload = {"user_id": self.user_id, "display_name": self.name, "public_key": self.public_key}
        return self.call("POST", "/v1/register", payload, **kw)


@pytest.fixture()
def client():
    # Fresh database and rate limits per test.
    if os.path.exists(store.DB_PATH):
        os.remove(store.DB_PATH)
    store.init_db()
    auth.limiter._hits.clear()
    return TestClient(main.app)


@pytest.fixture()
def make_user(client):
    def _make(name):
        ident = Identity(client, name)
        assert ident.register().status_code == 200
        return ident
    return _make


@pytest.fixture()
def befriend(make_user):
    def _befriend(a, b):
        code = a.call("POST", "/v1/invites").json()["code"]
        assert b.call("POST", "/v1/invites/redeem", {"code": code}).status_code == 200
        assert a.call("POST", f"/v1/friends/{b.user_id}/accept").status_code == 200
    return _befriend
