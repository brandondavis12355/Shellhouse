import json

from egress_proxy.store import DecisionLog, PendingStore


def test_pending_dedupe_cap_and_persist(tmp_path):
    p = str(tmp_path / "pending.json")
    s = PendingStore(p, cap=3)
    assert s.record("a.com", 443, "c1") == "new"
    assert s.record("a.com", 80, "c1") == "seen"
    s.record("b.com", 443, "c1"); s.record("c.com", 443, "c1")
    assert s.record("d.com", 443, "c1") == "dropped"
    snap = s.snapshot()
    assert set(snap["pending"]) == {"a.com", "b.com", "c.com"}
    assert snap["pending"]["a.com"]["count"] == 2
    assert snap["pending"]["a.com"]["ports"] == [443, 80]
    assert snap["dropped"] == 1
    s.flush()
    assert set(json.load(open(p))["pending"]) == {"a.com", "b.com", "c.com"}
    assert set(PendingStore(p, cap=3).pending) == {"a.com", "b.com", "c.com"}


def test_deny_mutes_and_allow_unmutes(tmp_path):
    s = PendingStore(str(tmp_path / "p.json"))
    s.record("x.com", 443, "c")
    assert s.resolve("x.com", deny=True)
    assert s.record("x.com", 443, "c") == "muted"
    assert "x.com" not in s.snapshot()["pending"]
    s.resolve("x.com", deny=False)
    assert s.record("x.com", 443, "c") == "new"


def test_corrupt_pending_file_ignored(tmp_path):
    p = tmp_path / "p.json"
    p.write_text("{not json")
    assert PendingStore(str(p)).snapshot()["pending"] == {}


def test_log_fields_and_tail(tmp_path):
    p = str(tmp_path / "l.jsonl")
    lg = DecisionLog(p)
    lg.write(client="1.1.1.1", method="CONNECT", host="a.com", port=443,
             verdict="deny", reason="not_allowlisted")
    lg.write(client="1.1.1.1", method="GET", host="b.com", port=80,
             verdict="deny", reason="canary_token_in_request", canary=True)
    rows = [json.loads(l) for l in open(p)]
    assert set(rows[0]) == {"ts", "client", "method", "host", "port", "verdict", "reason", "canary"}
    assert [e["host"] for e in lg.tail(10, canary_only=True)] == ["b.com"]


def test_log_rotates(tmp_path):
    p = tmp_path / "l.jsonl"
    lg = DecisionLog(str(p), max_bytes=200)
    for i in range(20):
        lg.write(client="c", method="GET", host=f"h{i}.com", port=80, verdict="deny", reason="x")
    assert (tmp_path / "l.jsonl.1").exists()


def test_pending_per_client_rate_limit(tmp_path):
    s = PendingStore(str(tmp_path / "p.json"), rate_per_min=3)
    res = [s.record(f"h{i}.com", 443, "noisy", now=1000.0 + i) for i in range(6)]
    assert res == ["new"] * 3 + ["rate_limited"] * 3
    assert s.record("other.com", 443, "quiet", now=1010.0) == "new"       # others unaffected
    assert s.snapshot()["pending"]["other.com"]["client"] == "quiet"
    assert s.record("late.com", 443, "noisy", now=1100.0) == "new"        # window expired
    assert s.snapshot()["dropped"] == 3
