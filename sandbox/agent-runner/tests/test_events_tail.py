import io
import json
import os
import threading

from shellhouse_agent.events import DeltaCoalescer, EventWriter, tail


def run_tail(run_dir, after=0, max_bytes=10_000):
    buf = io.StringIO()
    tail(str(run_dir), after, max_bytes, buf)
    lines = [json.loads(x) for x in buf.getvalue().splitlines()]
    return lines[:-1], lines[-1]


def test_seq_gapless_under_concurrency(tmp_path):
    w = EventWriter(str(tmp_path))
    ts = [threading.Thread(target=lambda: [w.emit("x", n=i) for i in range(25)]) for _ in range(8)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    names = sorted(os.listdir(tmp_path / "events"))
    assert names == [f"{i:08d}.json" for i in range(1, 201)]
    for n in names:
        json.load(open(tmp_path / "events" / n))  # every file is complete JSON


def test_seq_resumes_after_restart(tmp_path):
    EventWriter(str(tmp_path)).emit("a")
    assert EventWriter(str(tmp_path)).emit("b") == 2


def test_oversize_event_is_shrunk(tmp_path):
    w = EventWriter(str(tmp_path))
    w.emit("big", blob="x" * 2_000_000)
    ev = json.load(open(tmp_path / "events" / "00000001.json"))
    assert ev["truncated"] is True and len(json.dumps(ev)) < 300_000


def test_redaction(tmp_path):
    w = EventWriter(str(tmp_path), secrets=["supersecretvalue"])
    w.emit("e", nested={"k": ["a supersecretvalue b"]})
    assert "supersecretvalue" not in open(tmp_path / "events" / "00000001.json").read()


def test_tail_after_and_finished(tmp_path):
    w = EventWriter(str(tmp_path))
    for i in range(5):
        w.emit("message", content=str(i))
    evs, done = run_tail(tmp_path, after=2)
    assert [e["seq"] for e in evs] == [3, 4, 5]
    assert done == {"tail_done": True, "last_seq": 5, "finished": False}
    w.emit("status", state="completed")
    evs, done = run_tail(tmp_path, after=5)
    assert [e["seq"] for e in evs] == [6] and done["finished"] is True and done["last_seq"] == 6
    evs, done = run_tail(tmp_path, after=6)
    assert evs == [] and done == {"tail_done": True, "last_seq": 6, "finished": True}


def test_tail_is_bounded_and_resumable(tmp_path):
    w = EventWriter(str(tmp_path))
    for i in range(20):
        w.emit("message", content="y" * 100)
    w.emit("status", state="failed")
    after, seen, finished, rounds = 0, [], False, 0
    while not finished and rounds < 100:
        evs, done = run_tail(tmp_path, after=after, max_bytes=500)
        assert sum(len(json.dumps(e, separators=(",", ":"))) + 1 for e in evs) <= 500
        assert evs, "must make progress"
        seen += [e["seq"] for e in evs]
        after, finished = done["last_seq"], done["finished"]
        rounds += 1
    assert seen == list(range(1, 22)) and rounds > 3


def test_tail_not_finished_when_bounded_before_terminal(tmp_path):
    w = EventWriter(str(tmp_path))
    w.emit("message", content="y" * 100)
    w.emit("status", state="completed")
    evs, done = run_tail(tmp_path, max_bytes=200)
    assert [e["seq"] for e in evs] == [1] and done["finished"] is False


def test_tail_oversize_first_event_becomes_stub(tmp_path):
    w = EventWriter(str(tmp_path))
    w.emit("message", content="z" * 5000)
    w.emit("status", state="completed")
    evs, done = run_tail(tmp_path, max_bytes=300)
    assert evs[0]["type"] == "truncated" and evs[0]["seq"] == 1
    assert done["last_seq"] >= 1


def test_tail_ignores_tmp_and_foreign_files(tmp_path):
    w = EventWriter(str(tmp_path))
    w.emit("a")
    (tmp_path / "events" / ".00000002.tmp").write_text("{partial")
    (tmp_path / "events" / "notes.txt").write_text("hi")
    evs, done = run_tail(tmp_path)
    assert [e["seq"] for e in evs] == [1] and done["last_seq"] == 1


def test_tail_cli_entrypoint(tmp_path, capsys):
    from shellhouse_agent.cli import main

    EventWriter(str(tmp_path)).emit("a")
    assert main(["tail", "--dir", str(tmp_path), "--after", "0", "--max-bytes", "1000"]) == 0
    out = capsys.readouterr().out.splitlines()
    assert json.loads(out[-1])["tail_done"] is True and len(out) == 2


def test_delta_coalescer_interval():
    t = [0.0]
    out = []
    c = DeltaCoalescer(out.append, interval=0.1, clock=lambda: t[0])
    c.add("a"); t[0] = 0.05; c.add("b")
    assert out == []
    t[0] = 0.11; c.add("c")
    assert out == ["abc"]
    c.add("d"); c.flush()
    assert out == ["abc", "d"]
