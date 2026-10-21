"""Resource checks and the parallel-boot limit of the Firecracker backend (no KVM needed: the VM steps are faked)."""
import asyncio

import pytest
from providers import firecracker_backend as fc

GIB = 1 << 30


def _check(**kw):
    args = dict(new_disk=True, state_dir="/var/lib/agent-vm/instances", base_image="/nonexistent", mem_mib=2048,
                free_disk=lambda _p: 100 * GIB, available_mem=lambda: 16000)
    args.update(kw)
    fc.check_resources(**args)


def test_enough_room_passes():
    _check()


def test_low_disk_names_the_numbers():
    with pytest.raises(RuntimeError) as e:
        _check(free_disk=lambda _p: GIB // 2)
    msg = str(e.value)
    assert "Not enough free disk space" in msg and "0.5 GiB is free" in msg and "/var/lib/agent-vm/instances" in msg


def test_disk_is_not_checked_when_the_vm_reuses_its_disk():
    _check(new_disk=False, free_disk=lambda _p: 0)


def test_base_image_size_counts(tmp_path):
    image = tmp_path / "rootfs.ext4"
    image.write_bytes(b"\0" * (8 * 1024 * 1024))
    need = image.stat().st_blocks * 512 + fc.DISK_HEADROOM_BYTES
    _check(base_image=str(image), free_disk=lambda _p: need)            # exactly enough
    with pytest.raises(RuntimeError):
        _check(base_image=str(image), free_disk=lambda _p: need - 1)    # one byte short


def test_low_memory_names_the_numbers():
    with pytest.raises(RuntimeError) as e:
        _check(available_mem=lambda: 1000)
    msg = str(e.value)
    assert "Not enough free memory" in msg and "2048 MiB" in msg and "1000 MiB is available" in msg


def test_memory_that_cannot_be_read_does_not_block():
    _check(available_mem=lambda: None)


def test_boots_are_limited_to_the_configured_parallelism(monkeypatch, tmp_path):
    for name in ("rootfs.ext4", "vmlinux"):
        (tmp_path / name).write_bytes(b"")
    monkeypatch.setattr(fc, "FC_ROOTFS", str(tmp_path / "rootfs.ext4"))
    monkeypatch.setattr(fc, "FC_KERNEL", str(tmp_path / "vmlinux"))
    for attr in ("FC_STATE_DIR", "FC_RUN_DIR", "FC_LOG_DIR"):
        monkeypatch.setattr(fc, attr, str(tmp_path / attr))
    monkeypatch.setattr(fc, "check_resources", lambda **_: None)

    async def scenario():
        b = fc.FirecrackerBackend()
        b._boot_slots = asyncio.Semaphore(2)
        running = peak = 0

        async def nop(*_a, **_k):
            return None

        async def slow_boot_step(*_a, **_k):
            nonlocal running, peak
            running += 1
            peak = max(peak, running)
            await asyncio.sleep(0.05)
            running -= 1

        for name in ("_setup_tap", "_prepare_disk", "_spawn_firecracker", "_configure_vm", "_api",
                     "_start_ssh_master", "_start_forwarder", "_import_docker_workspace", "_teardown"):
            monkeypatch.setattr(b, name, nop)
        monkeypatch.setattr(b, "_wait_for_ssh", slow_boot_step)
        handles = await asyncio.gather(*[b.create(f"bot-{i}", persistent=False) for i in range(6)])
        return peak, len(handles)

    peak, made = asyncio.run(scenario())
    assert made == 6, "every VM still gets made; the extra ones just wait their turn"
    assert peak == 2


def test_a_failed_resource_check_cleans_up_and_explains(monkeypatch, tmp_path):
    for name in ("rootfs.ext4", "vmlinux"):
        (tmp_path / name).write_bytes(b"")
    monkeypatch.setattr(fc, "FC_ROOTFS", str(tmp_path / "rootfs.ext4"))
    monkeypatch.setattr(fc, "FC_KERNEL", str(tmp_path / "vmlinux"))
    for attr in ("FC_STATE_DIR", "FC_RUN_DIR", "FC_LOG_DIR"):
        monkeypatch.setattr(fc, attr, str(tmp_path / attr))

    def refuse(**_):
        raise RuntimeError("Not enough free memory for another VM")

    monkeypatch.setattr(fc, "check_resources", refuse)

    async def scenario():
        b = fc.FirecrackerBackend()
        torn = []

        async def teardown(slot, delete_disk):
            torn.append(slot.vm_id)

        monkeypatch.setattr(b, "_teardown", teardown)
        with pytest.raises(RuntimeError, match="Not enough free memory"):
            await b.create("bot-x", persistent=True)
        return torn, b._used_indexes

    torn, used = asyncio.run(scenario())
    assert len(torn) == 1, "the half-made VM is torn down"


# --- ssh that exits before it takes its input (a VM still booting) must not crash the manager's event loop (uvloop) ---

@pytest.mark.parametrize("stdin", [b"", b"export A=1\necho hi\n"])
def test_ssh_that_exits_early_returns_its_exit_code_under_uvloop(stdin):
    uvloop = pytest.importorskip("uvloop")

    async def run():
        backend = fc.FirecrackerBackend()
        backend._ssh_base = lambda slot: ["sh", "-c", "exit 255"]
        real = asyncio.create_subprocess_exec

        async def exited_first(*a, **k):        # make the race deterministic: the process is gone before the write
            proc = await real(*a, **k)
            await proc.wait()
            return proc

        asyncio.create_subprocess_exec = exited_first
        try:
            return await backend._ssh_raw(None, "true", stdin=stdin, timeout=5)
        finally:
            asyncio.create_subprocess_exec = real

    assert uvloop.run(run())[0] == 255


# --- short names inside VMs: the search domain reaches every command as LOCALDOMAIN ---

def _run_exec(monkeypatch, search, env=None):
    monkeypatch.setattr(fc, "FC_SEARCH", search)
    seen = {}

    async def scenario():
        b = fc.FirecrackerBackend()

        async def running(_id):
            return object()

        async def raw(_slot, _remote, stdin=b"", timeout=0):
            seen["stdin"] = stdin.decode()
            return 0, b"", b""

        monkeypatch.setattr(b, "_running", running)
        monkeypatch.setattr(b, "_ssh_raw", raw)
        await b.exec("vm", "getent hosts intranet-host", env=env)

    asyncio.run(scenario())
    return seen["stdin"].splitlines()


def test_exec_sets_the_search_domain_first_when_configured(monkeypatch):
    lines = _run_exec(monkeypatch, "example.com corp.example.com")
    assert lines[0] == "export LOCALDOMAIN='example.com corp.example.com'"
    assert lines[-1] == "getent hosts intranet-host"


def test_exec_adds_nothing_when_no_search_domain_is_set(monkeypatch):
    assert _run_exec(monkeypatch, "") == ["getent hosts intranet-host"]


def test_a_secret_env_does_not_lose_the_search_domain(monkeypatch):
    lines = _run_exec(monkeypatch, "example.com", env={"TOKEN": "x"})
    assert lines[0].startswith("export LOCALDOMAIN=") and "export TOKEN=x" in lines


def test_search_domains_from_the_environment_are_checked():
    import importlib, os
    old = os.environ.get("FIRECRACKER_SEARCH")
    os.environ["FIRECRACKER_SEARCH"] = "ok.example.com bad;rm -rf x $(id) -lead a..b"
    try:
        mod = importlib.reload(fc)
        assert mod.FC_SEARCH == "ok.example.com x"
    finally:
        os.environ.pop("FIRECRACKER_SEARCH", None) if old is None else os.environ.__setitem__("FIRECRACKER_SEARCH", old)
        importlib.reload(fc)
