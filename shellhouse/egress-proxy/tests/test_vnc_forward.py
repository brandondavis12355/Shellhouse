import asyncio

import pytest

from egress_proxy.vnc_forward import make_handler, parse_range, peer_allowed, start_forwarders
import ipaddress


def test_range_and_peer():
    assert list(parse_range("6100-6102")) == [6100, 6101, 6102]
    for bad in ("80-90", "6100-9999", "x"):
        with pytest.raises(ValueError):
            parse_range(bad)
    nets = [ipaddress.ip_network("172.18.0.1/32")]
    assert peer_allowed("172.18.0.1", nets)
    assert not peer_allowed("172.19.0.5", nets) and not peer_allowed("junk", nets)


def test_refuses_without_cidrs():
    with pytest.raises(ValueError):
        asyncio.run(start_forwarders("6100-6101", ""))


def test_forwards_only_allowed_peers():
    async def go():
        async def echo(r, w):
            w.write(await r.read(10)); await w.drain(); w.close()
        up = await asyncio.start_server(echo, "127.0.0.1", 0)
        up_port = up.sockets[0].getsockname()[1]

        async def opener(host, port):
            assert host == "sbx-6100"
            return await asyncio.open_connection("127.0.0.1", up_port)

        for cidr, expect in (("127.0.0.1/32", b"hello"), ("10.9.9.9/32", b"")):
            h = make_handler(6100, [ipaddress.ip_network(cidr)], opener=opener)
            srv = await asyncio.start_server(h, "127.0.0.1", 0)
            r, w = await asyncio.open_connection("127.0.0.1", srv.sockets[0].getsockname()[1])
            w.write(b"hello"); await w.drain()
            try:
                got = await asyncio.wait_for(r.read(10), 2)
            except ConnectionResetError:
                got = b""
            assert got == expect
            srv.close()
    asyncio.run(go())
