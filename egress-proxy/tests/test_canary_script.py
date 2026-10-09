import os
import subprocess

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "..", "sandbox", "bin", "seed-canaries.sh")
PATHS = [".aws/credentials", ".ssh/id_ed25519", ".config/gcloud/application_default_credentials.json"]


def run(tmp_path, **env):
    e = dict(os.environ, CANARY_HOME=str(tmp_path / "h"), CANARY_WORKSPACE=str(tmp_path / "w"), **env)
    (tmp_path / "w").mkdir(exist_ok=True)
    return subprocess.run(["bash", SCRIPT], env=e, capture_output=True, text=True)


def test_creates_all_600_with_tokens_and_is_idempotent(tmp_path):
    r = run(tmp_path)
    assert r.returncode == 0
    files = [tmp_path / "h" / p for p in PATHS] + [tmp_path / "w" / ".env.production"]
    first = {}
    for f in files:
        assert f.exists() and (f.stat().st_mode & 0o777) == 0o600
        assert "SHELLHOUSE-CANARY-" in f.read_text()
        first[f] = f.read_text()
    run(tmp_path)
    assert all(f.read_text() == first[f] for f in files)
    import re
    assert len({t for v in first.values() for t in re.findall(r"SHELLHOUSE-CANARY-[0-9a-f]+", v)}) == 4   # unique per file


def test_never_overwrites_real_file(tmp_path):
    f = tmp_path / "h" / ".aws" / "credentials"
    f.parent.mkdir(parents=True)
    f.write_text("[default]\nreal=secret\n")
    r = run(tmp_path)
    assert f.read_text() == "[default]\nreal=secret\n"
    assert "WARNING" in r.stderr and "not a canary" in r.stderr
    assert (tmp_path / "h" / ".ssh" / "id_ed25519").exists()      # others still planted


def test_symlink_target_and_parent_not_followed(tmp_path):
    victim = tmp_path / "victim.txt"
    victim.write_text("precious")
    (tmp_path / "h" / ".aws").mkdir(parents=True)
    os.symlink(victim, tmp_path / "h" / ".aws" / "credentials")
    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(outside, tmp_path / "h" / ".ssh")
    r = run(tmp_path)
    assert victim.read_text() == "precious"
    assert list(outside.iterdir()) == []
    assert r.stderr.count("symlink") >= 2


def test_dry_run_changes_nothing(tmp_path):
    r = run(tmp_path, CANARY_DRY_RUN="1")
    assert "would create" in r.stdout
    assert not (tmp_path / "h").exists()
    assert not (tmp_path / "w" / ".env.production").exists()
