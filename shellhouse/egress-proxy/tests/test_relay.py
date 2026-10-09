import asyncio

import pytest

from egress_proxy.relay import (ConnLimiter, ModelRelay, RelayConfigError, client_allowed,
                                resolve_target_once, split_hostport, start_relay,
                                validate_target_ip)


@pytest.mark.parametrize("ip", ["172.17.0.1", "10.0.0.5", "192.168.1.2"])
def test_target_private_ok(ip):
    assert validate_target_ip(ip) == ip


@pytest.mark.parametrize("ip", ["8.8.8.8", "127.0.0.1", "169.254.169.254", "0.0.0.0", "224.0.0.1",
                                "100.64.0.1", "::1", "fd00::1", "nope", "", "93.184.216.34"])
def test_target_rejected(ip):
    with pytest.raises(RelayConfigError):
        validate_target_ip(ip)


def test_resolve_once_and_hostport():
    assert resolve_target_once("172.17.0.1:11434") == ("172.17.0.1", 11434)
    fake = lambda h, p, **k: [(2, 1, 6, "", ("10.1.2.3", p))]
    assert resolve_target_once("gw.local:80", resolver=fake) == ("10.1.2.3", 80)
    bad = lambda h, p, **k: [(2, 1, 6, "", ("8.8.8.8", p))]
    with pytest.raises(RelayConfigError):
        resolve_target_once("evil.example:80", resolver=bad)
    for spec in ("nohost", ":80", "h:0", "h:99999", "h:x"):
        with pytest.raises(RelayConfigError):
            split_hostport(spec, "x")


def test_disabled_unless_both_set_and_never_raises():
    async def go():
        assert await start_relay("", "172.17.0.1:1") is None
        assert await start_relay("127.0.0.1:0", "") is None
        assert await start_relay("127.0.0.1:0", "8.8.8.8:80") is None      # public target: disabled
        assert await start_relay("bad", "172.17.0.1:80") is None
    asyncio.run(go())


def test_client_allowed_rules():
    sub = "172.18.0.0/16"
    assert client_allowed("172.20.0.5", (), sub)           # a sandbox net
    assert not client_allowed("172.18.0.9", (), sub)       # compose network
    assert not client_allowed("8.8.8.8", (), sub)
    assert not client_allowed("127.0.0.1", (), sub)
    assert not client_allowed("junk", (), sub)
    import ipaddress
    assert client_allowed("203.0.113.5", (ipaddress.ip_network("203.0.113.0/24"),), sub)
    assert not client_allowed("172.20.0.5", (ipaddress.ip_network("203.0.113.0/24"),), sub)


def test_limiter_fair_share():
    l = ConnLimiter(8, 8)
    for _ in range(5):
        l.acquire("noisy")
    l.acquire("quiet")                       # total 6 = 75%
    assert l.check("noisy") == "fair_share_limit"
    assert l.check("quiet") is None
    for _ in range(2):
        l.acquire("x")
    assert l.check("quiet") == "connection_limit"
    l.release("x"); l.release("x")
    assert l.check("quiet") is None
    assert ConnLimiter(8, 2).check("a") is None


class Fake:
    """Upstream that echoes, plus a relay wired to it via an injected opener."""
    def __init__(self, **kw):
        self.kw = kw

    async def __aenter__(self):
        async def echo(r, w):
            try:
                while True:
                    d = await r.read(65536)
                    if not d:
                        break
                    w.write(d); await w.drain()
            except Exception:
                pass
            w.close()
        self.up = await asyncio.start_server(echo, "127.0.0.1", 0)
        up_port = self.up.sockets[0].getsockname()[1]
        self.opened = []

        async def opener(host, port):
            self.opened.append((host, port))
            return await asyncio.open_connection("127.0.0.1", up_port)
        kw = dict(allow_cidrs=["127.0.0.0/8"], opener=opener)
        kw.update(self.kw)
        self.relay = ModelRelay("172.17.0.1", 11434, **kw)
        self.srv = await asyncio.start_server(self.relay.handle, "127.0.0.1", 0)
        self.port = self.srv.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, *a):
        self.srv.close(); self.up.close()


def run(c):
    return asyncio.run(c)


def test_forwards_only_to_fixed_target():
    async def go():
        async with Fake() as f:
            r, w = await asyncio.open_connection("127.0.0.1", f.port)
            w.write(b"CONNECT evil.com:443 HTTP/1.1\r\n\r\n"); await w.drain()     # client input is just bytes
            assert await asyncio.wait_for(r.read(100), 2) == b"CONNECT evil.com:443 HTTP/1.1\r\n\r\n"
            assert f.opened == [("172.17.0.1", 11434)]
            w.close()
            await asyncio.sleep(0.1)
            assert f.relay.stats["accepted"] == 1 and f.relay.limiter.total == 0
    run(go())


def test_disallowed_client_refused():
    async def go():
        async with Fake(allow_cidrs=["10.9.0.0/16"]) as f:
            r, w = await asyncio.open_connection("127.0.0.1", f.port)
            w.write(b"hi")
            try:
                got = await asyncio.wait_for(r.read(10), 2)
            except ConnectionResetError:
                got = b""
            assert got == b"" and f.opened == [] and f.relay.stats["refused"] == 1
    run(go())


def test_connection_caps():
    async def go():
        async with Fake(max_conn_per_client=2) as f:
            hs = [await asyncio.open_connection("127.0.0.1", f.port) for _ in range(2)]
            await asyncio.sleep(0.1)
            r, w = await asyncio.open_connection("127.0.0.1", f.port)
            try:
                got = await asyncio.wait_for(r.read(10), 2)
            except ConnectionResetError:
                got = b""
            assert got == b"" and f.relay.stats["refused"] == 1
            for _, h in hs:
                h.close()
    run(go())


def test_idle_and_total_timeouts():
    async def go():
        async with Fake(idle_timeout=0.2) as f:
            r, w = await asyncio.open_connection("127.0.0.1", f.port)
            assert await asyncio.wait_for(r.read(10), 2) == b""        # closed by idle timeout
        async with Fake(total_timeout=0.3, idle_timeout=5) as f:
            r, w = await asyncio.open_connection("127.0.0.1", f.port)
            t = asyncio.get_event_loop().time()
            assert await asyncio.wait_for(r.read(10), 2) == b""
            assert asyncio.get_event_loop().time() - t < 1.5
    run(go())


def test_byte_caps_each_direction():
    async def go():
        async with Fake(max_request_bytes=10, max_response_bytes=1000) as f:
            r, w = await asyncio.open_connection("127.0.0.1", f.port)
            w.write(b"x" * 20); await w.drain()
            data = await asyncio.wait_for(r.read(100), 2)
            assert len(data) < 20                                       # request cap cut it off
            assert await asyncio.wait_for(r.read(100), 2) == b""
        async with Fake(max_request_bytes=1000, max_response_bytes=10) as f:
            r, w = await asyncio.open_connection("127.0.0.1", f.port)
            w.write(b"y" * 100); await w.drain()
            got = b""
            while True:
                chunk = await asyncio.wait_for(r.read(100), 2)
                if not chunk:
                    break
                got += chunk
            assert len(got) == 0 or len(got) <= 100 and got != b"y" * 100   # response cap hit
    run(go())


def test_upstream_unreachable_closes():
    async def go():
        async def opener(h, p):
            raise OSError("down")
        relay = ModelRelay("172.17.0.1", 1, allow_cidrs=["127.0.0.0/8"], opener=opener)
        srv = await asyncio.start_server(relay.handle, "127.0.0.1", 0)
        r, w = await asyncio.open_connection("127.0.0.1", srv.sockets[0].getsockname()[1])
        assert await asyncio.wait_for(r.read(10), 2) == b""
        assert relay.limiter.total == 0
        srv.close()
    run(go())
