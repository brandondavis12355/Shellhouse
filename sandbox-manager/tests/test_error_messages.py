"""A backend failure must reach the app as a 500 that says why, not as FastAPI's bare "Internal Server Error"."""
import pytest
import main
from fastapi.testclient import TestClient

AUTH = {"x-manager-token": "t" * 64}


class _Failing:
    name = "fake"

    def __init__(self, error: Exception):
        self.error = error

    async def create(self, task_id, persistent=False):
        raise self.error

    async def list_sandboxes(self):
        raise self.error


def _client(monkeypatch, error: Exception) -> TestClient:
    monkeypatch.setattr(main, "get_backend", lambda: _Failing(error))
    return TestClient(main.app, raise_server_exceptions=False)


def test_create_failure_says_why(monkeypatch):
    c = _client(monkeypatch, RuntimeError("Not enough free disk space for another VM: it needs about 4.0 GiB"))
    r = c.post("/v1/create", headers=AUTH, json={"task_id": "bot-1", "persistent": True})
    assert r.status_code == 500
    assert r.json()["detail"] == "create failed: RuntimeError: Not enough free disk space for another VM: it needs about 4.0 GiB"


def test_error_text_is_redacted(monkeypatch):
    c = _client(monkeypatch, RuntimeError("could not log in: password=hunter2hunter2 ghp_" + "a" * 30))
    detail = c.post("/v1/create", headers=AUTH, json={"task_id": "bot-1"}).json()["detail"]
    assert "hunter2" not in detail and "ghp_" not in detail
    assert "[REDACTED]" in detail


def test_long_errors_are_capped(monkeypatch):
    c = _client(monkeypatch, RuntimeError("x" * 5000))
    assert len(c.post("/v1/create", headers=AUTH, json={"task_id": "bot-1"}).json()["detail"]) < 600


def test_other_operations_also_explain(monkeypatch):
    c = _client(monkeypatch, RuntimeError("boom"))
    r = c.post("/v1/list", headers=AUTH, json={})
    assert r.status_code == 500 and r.json()["detail"] == "list failed: RuntimeError: boom"


def test_deliberate_http_errors_are_untouched(monkeypatch):
    c = _client(monkeypatch, RuntimeError("never reached"))
    assert c.post("/v1/exec", headers=AUTH, json={"sandbox_id": "nope", "command": "id"}).status_code == 404
    assert c.post("/v1/create", json={"task_id": "bot-1"}).status_code == 401
    assert c.post("/v1/create", headers=AUTH, json={"task_id": "../x"}).status_code == 422


def test_extra_manager_keys_all_work_and_others_do_not(monkeypatch):
    import main
    from fastapi import HTTPException
    monkeypatch.setattr(main, "EXTRA_TOKENS", ("b" * 64, "c" * 64))
    for good in (main.AUTH_TOKEN, "b" * 64, "c" * 64):
        main.require_auth(good)
    for bad in (None, "", "d" * 64, "b" * 63):
        with pytest.raises(HTTPException) as e:
            main.require_auth(bad)
        assert e.value.status_code == 401
