"""End-to-end proxy tests over real loopback sockets with an injected
resolver/connector, so no real network or DNS is used."""
import asyncio
import json

from egress_proxy.server import AdminApi, Config, EgressProxy

PUBLIC = "93.184.216.34"


def make_cfg(tmp_path, **kw):
    allow = tmp_path / "allow.txt"
    if not allow.exists():
        allow.write_text("allowed.com\n*.ok.org\n")
    base = dict(allowlist_file=str(allow), log_file=str(tmp_path / "log.jsonl"),
                pending_file=str(tmp_path / "pending.json"), admin_token="tok",
                header_timeout=0.5, idle_timeout=0.5, total_timeout=3,
                connect_timeout=1)
    base.update(kw)
    return Config(**base)


class World:
    """Proxy + fake upstream (echo/HTTP) served through injected hooks."""

    def __init__(self, tmp_path, resolver_ips=(PUBLIC,), **kw):
        self.cfg = make_cfg(tmp_path, **kw)
        self.upstream_requests = []
        self.connects = []

        async def resolver(host, port):
            return list(resolver_ips)

        async def connector(ip, port, timeout):
            self.connects.append((ip, port))
            return await asyncio.open_connection("127.0.0.1", self.up_port)

        self.proxy = EgressProxy(self.cfg, resolver=resolver, connector=connector)

    async def __aenter__(self):
        async def up(r, w):
            data = b""
            try:
                data = await asyncio.wait_for(r.readuntil(b"\r\n\r\n"), 1)
                rest = b""
                for l in data.split(b"\r\n"):
                    if l.lower().startswith(b"content-length:"):
                        rest = await r.readexactly(int(l.split(b":")[1]))
                self.upstream_requests.append(data + rest)
                w.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi")
            except Exception:
                pass
            await w.drain(); w.close()

        self.up = await asyncio.start_server(up, "127.0.0.1", 0)
        self.up_port = self.up.sockets[0].getsockname()[1]
        self.srv = await asyncio.start_server(self.proxy.handle_client, "127.0.0.1", 0,
                                              limit=self.cfg.max_header_bytes)
        self.port = self.srv.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, *a):
        self.srv.close(); self.up.close()

    async def raw(self, payload: bytes, read=65536, wait=True):
        r, w = await asyncio.open_connection("127.0.0.1", self.port)
        w.write(payload); await w.drain()
        try:
            out = await asyncio.wait_for(r.read(read), 2) if wait else b""
        except asyncio.TimeoutError:
            out = b""
        w.close()
        return out

    def log(self):
        return [json.loads(l) for l in open(self.cfg.log_file)]


def run(coro):
    return asyncio.run(coro)


def test_default_deny_records_pending(tmp_path):
    async def go():
        async with World(tmp_path) as w:
            out = await w.raw(b"CONNECT evil.com:443 HTTP/1.1\r\nHost: evil.com:443\r\n\r\n")
            assert out.startswith(b"HTTP/1.1 403")
            assert b"not_allowlisted" in out
            assert "evil.com" in w.proxy.pending.snapshot()["pending"]
            assert w.connects == []
            e = w.log()[-1]
            assert (e["host"], e["port"], e["verdict"], e["reason"]) == ("evil.com", 443, "deny", "not_allowlisted")
    run(go())


def test_connect_allowed_tunnels_bytes(tmp_path):
    async def go():
        async with World(tmp_path) as w:
            r, wr = await asyncio.open_connection("127.0.0.1", w.port)
            wr.write(b"CONNECT sub.ok.org:443 HTTP/1.1\r\n\r\n"); await wr.drain()
            assert (await asyncio.wait_for(r.readuntil(b"\r\n\r\n"), 2)).startswith(b"HTTP/1.1 200")
            wr.write(b"GET / HTTP/1.1\r\n\r\n"); await wr.drain()
            assert (await asyncio.wait_for(r.read(100), 2)).startswith(b"HTTP/1.1 200 OK")
            assert w.connects == [(PUBLIC, 443)]    # dialled the validated IP, not the name
            wr.close()
    run(go())


def test_port_not_allowed(tmp_path):
    async def go():
        async with World(tmp_path) as w:
            for p in (22, 8080, 25):
                out = await w.raw(f"CONNECT allowed.com:{p} HTTP/1.1\r\n\r\n".encode())
                assert b"port_not_allowed" in out
            assert w.connects == []
            assert w.proxy.pending.snapshot()["pending"] == {}   # not an approvable thing
    run(go())


def test_userinfo_and_ip_literal_tricks(tmp_path):
    async def go():
        async with World(tmp_path) as w:
            for t in ("allowed.com@evil.com:443", "allowed.com:443@evil.com:443",
                      "127.0.0.1:443", "169.254.169.254:80", "[::1]:443", "2130706433:80"):
                out = await w.raw(f"CONNECT {t} HTTP/1.1\r\n\r\n".encode())
                assert out.startswith(b"HTTP/1.1 403"), t
            out = await w.raw(b"GET http://allowed.com@evil.com/ HTTP/1.1\r\nHost: allowed.com\r\n\r\n")
            assert b"userinfo" in out
            assert w.connects == []
    run(go())


def test_dns_rebinding_private_answer_denied(tmp_path):
    async def go():
        for ips in (["127.0.0.1"], [PUBLIC, "10.0.0.7"], ["169.254.169.254"], ["::ffff:192.168.0.1"], ["fd00::1"]):
            async with World(tmp_path, resolver_ips=ips) as w:
                out = await w.raw(b"CONNECT allowed.com:443 HTTP/1.1\r\n\r\n")
                assert b"resolved_private_address" in out, ips
                assert w.connects == []
    run(go())


def test_plain_http_forward_strips_hop_headers(tmp_path):
    async def go():
        async with World(tmp_path) as w:
            out = await w.raw(
                b"POST http://allowed.com/p?q=1 HTTP/1.1\r\nHost: evil.com\r\n"
                b"Proxy-Authorization: Basic xxx\r\nConnection: keep-alive\r\n"
                b"Content-Length: 3\r\nX-A: b\r\n\r\nabc")
            assert out.endswith(b"hi") and out.startswith(b"HTTP/1.1 200")
            up = w.upstream_requests[0]
            assert up.startswith(b"POST /p?q=1 HTTP/1.1\r\nHost: allowed.com\r\n")
            assert b"evil.com" not in up and b"Proxy-Authorization" not in up
            assert b"Connection: close" in up and up.endswith(b"abc")
    run(go())


def test_origin_form_and_https_absolute_rejected(tmp_path):
    async def go():
        async with World(tmp_path) as w:
            assert (await w.raw(b"GET /admin HTTP/1.1\r\nHost: x\r\n\r\n")).startswith(b"HTTP/1.1 400")
            assert (await w.raw(b"GET https://allowed.com/ HTTP/1.1\r\n\r\n")).startswith(b"HTTP/1.1 400")
    run(go())


def test_canary_in_plain_http_denied_and_flagged(tmp_path):
    async def go():
        async with World(tmp_path) as w:
            for req in (b"GET http://allowed.com/?k=SHELLHOUSE-CANARY-abc123 HTTP/1.1\r\n\r\n",
                        b"GET http://allowed.com/?k=shellhouse%2Dcanary%2Dabc HTTP/1.1\r\n\r\n",
                        b"GET http://allowed.com/ HTTP/1.1\r\nX-Key: SHELLHOUSE-CANARY-zz\r\n\r\n",
                        b"POST http://allowed.com/ HTTP/1.1\r\nContent-Length: 26\r\n\r\nkey=SHELLHOUSE-CANARY-zz99"):
                out = await w.raw(req)
                assert b"canary_token_in_request" in out, req
            assert w.upstream_requests == []
            hits = [e for e in w.log() if e["canary"]]
            assert len(hits) == 4
            # the token itself is never written to the log
            assert "SHELLHOUSE-CANARY" not in open(w.cfg.log_file).read().upper().replace("CANARY_TOKEN_IN_REQUEST", "")
    run(go())


def test_canary_flag_mode_allows_but_flags(tmp_path):
    async def go():
        async with World(tmp_path, canary_action="flag") as w:
            out = await w.raw(b"GET http://allowed.com/?k=SHELLHOUSE-CANARY-q HTTP/1.1\r\n\r\n")
            assert out.startswith(b"HTTP/1.1 200")
            assert w.log()[-1]["canary"] is True and w.log()[-1]["verdict"] == "allow"
    run(go())


def test_canary_in_connect_hostname(tmp_path):
    async def go():
        async with World(tmp_path) as w:
            await w.raw(b"CONNECT shellhouse-canary-abc.evil.com:443 HTTP/1.1\r\n\r\n")
            assert w.log()[-1]["canary"] is True
    run(go())


def test_header_limits_and_malformed(tmp_path):
    async def go():
        async with World(tmp_path, max_header_bytes=1024) as w:
            big = b"GET http://allowed.com/ HTTP/1.1\r\nX: " + b"a" * 4000 + b"\r\n\r\n"
            assert (await w.raw(big)).startswith(b"HTTP/1.1 431")
            many = b"GET http://allowed.com/ HTTP/1.1\r\n" + b"".join(b"H%d: v\r\n" % i for i in range(120)) + b"\r\n"
            many_cfg = w.cfg.max_headers
            assert many_cfg == 100
            assert (await w.raw(many)).startswith(b"HTTP/1.1 431")
            assert (await w.raw(b"garbage\r\n\r\n")).startswith(b"HTTP/1.1 400")
            assert (await w.raw(b"GET http://allowed.com/ HTTP/1.1\r\n folded\r\n\r\n")).startswith(b"HTTP/1.1 400")
    run(go())


def test_body_limits_and_chunked(tmp_path):
    async def go():
        async with World(tmp_path, max_body_bytes=10) as w:
            out = await w.raw(b"POST http://allowed.com/ HTTP/1.1\r\nContent-Length: 11\r\n\r\n")
            assert out.startswith(b"HTTP/1.1 413")
            out = await w.raw(b"POST http://allowed.com/ HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
            assert out.startswith(b"HTTP/1.1 501")
            out = await w.raw(b"POST http://allowed.com/ HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab")
            assert out.startswith(b"HTTP/1.1 400")
            assert w.upstream_requests == []
    run(go())


def test_slowloris_header_timeout(tmp_path):
    async def go():
        async with World(tmp_path, header_timeout=0.2) as w:
            r, wr = await asyncio.open_connection("127.0.0.1", w.port)
            wr.write(b"GET http://allowed.com/ HT")      # never completes
            await wr.drain()
            out = await asyncio.wait_for(r.read(1000), 2)
            assert out.startswith(b"HTTP/1.1 408")
            wr.close()
    run(go())


def test_idle_tunnel_closed(tmp_path):
    async def go():
        async with World(tmp_path, idle_timeout=0.2) as w:
            r, wr = await asyncio.open_connection("127.0.0.1", w.port)
            wr.write(b"CONNECT allowed.com:443 HTTP/1.1\r\n\r\n"); await wr.drain()
            await r.readuntil(b"\r\n\r\n")
            # send nothing; proxy must hang up on its own
            assert await asyncio.wait_for(r.read(10), 2) == b""
    run(go())


def test_per_client_connection_limit(tmp_path):
    async def go():
        async with World(tmp_path, max_conn_per_client=2) as w:
            holders = []
            for _ in range(2):
                holders.append(await asyncio.open_connection("127.0.0.1", w.port))
            await asyncio.sleep(0.05)
            out = await w.raw(b"CONNECT allowed.com:443 HTTP/1.1\r\n\r\n")
            assert out.startswith(b"HTTP/1.1 429")
            for _, wr in holders:
                wr.close()
            await asyncio.sleep(0.7)     # header timeout frees the slots
            assert w.proxy._per_client == {}
    run(go())


def test_hot_reload_changes_decision(tmp_path):
    async def go():
        async with World(tmp_path) as w:
            assert b"not_allowlisted" in await w.raw(b"CONNECT new.example.net:443 HTTP/1.1\r\n\r\n")
            w.proxy.allow.add("new.example.net")
            r = await w.raw(b"CONNECT new.example.net:443 HTTP/1.1\r\n\r\n")
            assert r.startswith(b"HTTP/1.1 200")
    run(go())


# ---- admin -----------------------------------------------------------
def test_admin_routes(tmp_path):
    w = World(tmp_path)
    api = AdminApi(w.proxy)
    call = lambda m, t, body=b"", auth="Bearer tok", ip="10.0.0.2": api.route(m, t, auth, body, ip)
    assert call("GET", "/healthz", auth="")[0] == 200
    assert call("GET", "/v1/pending", auth="")[0] == 401
    assert call("GET", "/v1/pending", auth="Bearer wrong")[0] == 401
    w.proxy.pending.record("new.com", 443, "c")
    assert "new.com" in call("GET", "/v1/pending")[1]["pending"]
    assert call("POST", "/v1/allow", b'{"host":"*.new.com"}')[1]["entry"] == "*.new.com"
    assert "new.com" in call("GET", "/v1/pending")[1]["pending"]    # wildcard excludes apex
    assert w.proxy.allow.current().matches("a.new.com")
    assert call("POST", "/v1/allow", b'{"host":"1.2.3.4"}')[0] == 400
    assert call("POST", "/v1/allow", b'{"host":"a.com","x":1}')[0] == 400
    assert call("POST", "/v1/allow", b'nope')[0] == 400
    w.proxy.pending.record("bad.com", 443, "c")
    assert call("POST", "/v1/deny", b'{"host":"bad.com"}')[0] == 200
    assert w.proxy.pending.record("bad.com", 443, "c") == "muted"
    w.proxy.log.write(client="c", method="GET", host="h", port=80, verdict="deny", reason="r", canary=True)
    assert len(call("GET", "/v1/log?n=5&canary=1")[1]["entries"]) == 1
    assert call("GET", "/nope")[0] == 404


def test_admin_cidr_restriction(tmp_path):
    w = World(tmp_path, admin_allow_cidrs=("172.20.0.0/16",))
    api = AdminApi(w.proxy)
    assert api.route("GET", "/v1/pending", "Bearer tok", b"", "172.20.0.5")[0] == 200
    assert api.route("GET", "/v1/pending", "Bearer tok", b"", "172.30.0.5")[0] == 403
    assert api.route("GET", "/v1/pending", "Bearer tok", b"", "")[0] == 403


def test_admin_over_socket(tmp_path):
    async def go():
        w = World(tmp_path)
        api = AdminApi(w.proxy)
        srv = await asyncio.start_server(api.handle, "127.0.0.1", 0)
        port = srv.sockets[0].getsockname()[1]
        r, wr = await asyncio.open_connection("127.0.0.1", port)
        wr.write(b"GET /v1/pending HTTP/1.1\r\nAuthorization: Bearer tok\r\n\r\n"); await wr.drain()
        data = await asyncio.wait_for(r.read(10000), 2)
        assert data.startswith(b"HTTP/1.1 200") and b'"pending"' in data
        srv.close()
    run(go())


def test_expect_100_continue_gets_417(tmp_path):
    async def go():
        async with World(tmp_path) as w:
            out = await w.raw(b"POST http://allowed.com/ HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
            assert out.startswith(b"HTTP/1.1 417")
    run(go())


def test_rejected_authority_logs_only_after_at_sign(tmp_path):
    async def go():
        async with World(tmp_path) as w:
            await w.raw(b"CONNECT user:hunter2@evil.com:443 HTTP/1.1\r\n\r\n")
            await w.raw(b"GET http://user:hunter2@evil.com/ HTTP/1.1\r\n\r\n")
            text = open(w.cfg.log_file).read()
            assert "hunter2" not in text and "user:" not in text
    run(go())


def test_fair_share_and_caps(tmp_path):
    w = World(tmp_path, max_conn_total=8, max_conn_per_client=8)
    p = w.proxy
    assert p._admit_check("a") is None
    p._total, p._per_client = 6, {"noisy": 5, "quiet": 1}       # >= 75% full
    assert p._admit_check("noisy") == "fair_share_limit"
    assert p._admit_check("quiet") is None                      # quiet sandbox still served
    assert p._admit_check("new") is None
    p._total = 8
    assert p._admit_check("quiet") == "connection_limit"
    p._total, p._per_client = 2, {"a": 8}
    assert p._admit_check("a") == "connection_limit"


def test_admin_throttle_and_nonascii_token(tmp_path):
    w = World(tmp_path, admin_fail_limit=3)
    api = AdminApi(w.proxy)
    bad = lambda t, ip="9.9.9.9": api.route("GET", "/v1/pending", "Bearer " + t, b"", ip, now=t_now[0])
    t_now = [100.0]
    assert [bad("x\u00e9")[0] for _ in range(3)] == [401, 401, 401]     # no exception on non-ASCII
    assert api.route("GET", "/v1/pending", "Bearer tok", b"", "9.9.9.9", now=101.0)[0] == 429   # even correct token
    assert api.route("GET", "/v1/pending", "Bearer tok", b"", "8.8.8.8", now=101.0)[0] == 200   # other clients fine
    assert api.route("GET", "/v1/pending", "Bearer tok", b"", "9.9.9.9", now=200.0)[0] == 200    # window passed


def test_admin_connection_cap(tmp_path):
    async def go():
        w = World(tmp_path, admin_max_conn=1)
        api = AdminApi(w.proxy)
        srv = await asyncio.start_server(api.handle, "127.0.0.1", 0)
        port = srv.sockets[0].getsockname()[1]
        r1, w1 = await asyncio.open_connection("127.0.0.1", port)      # holds the only slot (no request sent)
        await asyncio.sleep(0.05)
        r2, w2 = await asyncio.open_connection("127.0.0.1", port)
        assert await asyncio.wait_for(r2.read(10), 2) == b""            # dropped immediately
        w1.close(); w2.close(); srv.close()
    run(go())


def test_vnc_forward_without_cidrs_logs_instead_of_crashing(tmp_path, monkeypatch):
    async def go():
        monkeypatch.setenv("EGRESS_VNC_FORWARD", "6100-6101")
        monkeypatch.delenv("EGRESS_VNC_ALLOW_CIDRS", raising=False)
        w = World(tmp_path, listen_host="127.0.0.1", listen_port=0, admin_token="")
        servers = await w.proxy.start()           # must not raise
        assert len(servers) == 1
        for s in servers:
            s.close()
    run(go())
