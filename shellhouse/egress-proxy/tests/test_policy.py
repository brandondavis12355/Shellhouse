import os
import time

import pytest

from egress_proxy.policy import (Allowlist, AllowlistFile, is_blocked_ip,
                                 normalize_host, parse_authority)


def al(text):
    return Allowlist.parse(text)


# ---- matching ---------------------------------------------------------
def test_exact_and_wildcard():
    a = al("example.com\n*.pypi.org\n")
    assert a.matches("example.com")
    assert not a.matches("www.example.com")      # exact is exact
    assert a.matches("files.pypi.org")
    assert a.matches("a.b.pypi.org")             # any depth
    assert not a.matches("pypi.org")             # wildcard excludes apex


def test_suffix_confusion():
    a = al("*.example.com\nexample.com")
    assert not a.matches("evilexample.com")
    assert not a.matches("example.com.evil.com")
    assert not a.matches("notexample.com")
    assert a.matches("x.example.com")


def test_comments_blank_invalid_ignored():
    a = al("# c\n\n  good.com  # trailing\n*.com\n10.0.0.1\n[::1]\nbad host\n")
    assert a.matches("good.com")
    assert not a.suffixes                         # *.com refused
    assert a.exact == frozenset({"good.com"})


@pytest.mark.parametrize("raw,expected", [
    ("Example.COM", "example.com"),
    ("example.com.", "example.com"),
    ("bücher.example", "xn--bcher-kva.example"),
    ("XN--BCHER-KVA.example", "xn--bcher-kva.example"),
])
def test_normalize_ok(raw, expected):
    assert normalize_host(raw) == (expected, "")


def test_idn_homograph_does_not_match_ascii():
    a = al("apple.com")
    h, _ = normalize_host("аpple.com")   # Cyrillic a
    assert h is not None and h.startswith("xn--")
    assert not a.matches(h)


@pytest.mark.parametrize("raw", [
    "", ".", "..", "a..b", ".example.com", "example.com..", "allowed.com@evil.com",
    "evil.com/x", "a b.com", "a\x00.com", "ex%41mple.com", "[::1]", "::1",
    "127.0.0.1", "10.1.2.3", "169.254.169.254", "2130706433", "0x7f.0.0.1",
    "127.1", "0177.0.0.1", "1.2.3.4", "localhost:80", "-bad.com", "a" * 64 + ".com",
])
def test_normalize_rejects(raw):
    host, why = normalize_host(raw)
    assert host is None and why


def test_normalize_does_not_strip_multiple_trailing_dots():
    assert normalize_host("example.com..")[0] is None


# ---- authority / userinfo / port tricks ------------------------------
@pytest.mark.parametrize("auth", [
    "allowed.com@evil.com:443", "allowed.com:80@evil.com", "user:pw@allowed.com",
    "allowed.com:443:80", "allowed.com:", "allowed.com:80a", "allowed.com:99999",
    "allowed.com:0", "[::1]:443", "allowed.com:４43",
])
def test_authority_rejects(auth):
    assert parse_authority(auth, 80)[0] is None


def test_authority_ok_and_defaults():
    assert parse_authority("Example.com:8443", 80)[:2] == ("example.com", 8443)
    assert parse_authority("example.com", 80)[:2] == ("example.com", 80)
    assert parse_authority("example.com", None)[0] is None     # CONNECT needs a port


# ---- IP blocking ------------------------------------------------------
@pytest.mark.parametrize("ip", [
    "127.0.0.1", "127.255.255.254", "10.0.0.5", "172.16.0.1", "172.31.255.255",
    "192.168.1.1", "169.254.169.254", "169.254.0.1", "0.0.0.0", "100.64.0.1",
    "224.0.0.1", "::1", "::", "fc00::1", "fd12:3456::1", "fe80::1",
    "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:169.254.169.254",
    "64:ff9b::7f00:1", "2002:7f00:1::1", "not-an-ip", "::7f00:1", "::808:808", "64:ff9b:1::1",
])
def test_blocked_ips(ip):
    assert is_blocked_ip(ip)


@pytest.mark.parametrize("ip", ["93.184.216.34", "8.8.8.8", "2606:4700:4700::1111", "172.32.0.1"])
def test_public_ips_pass(ip):
    assert not is_blocked_ip(ip)


# ---- file / hot reload -----------------------------------------------
def test_hot_reload_and_missing_file(tmp_path):
    p = tmp_path / "allow.txt"
    f = AllowlistFile(str(p))
    assert not f.current().matches("a.com")      # missing -> deny all
    p.write_text("a.com\n")
    assert f.current().matches("a.com")
    p.write_text("b.com\n")
    os.utime(p, ns=(time.time_ns() + 10**9, time.time_ns() + 10**9))
    assert not f.current().matches("a.com") and f.current().matches("b.com")
    p.unlink()
    assert not f.current().matches("b.com")


def test_add_validates_and_dedupes(tmp_path):
    p = tmp_path / "allow.txt"
    f = AllowlistFile(str(p))
    assert f.add("Example.COM.") == "example.com"
    assert f.add("example.com") == "example.com"
    assert f.add("*.Foo.org") == "*.foo.org"
    for bad in ("*.com", "1.2.3.4", "a@b.com", "", "x y"):
        with pytest.raises(ValueError):
            f.add(bad)
    assert p.read_text().splitlines() == ["example.com", "*.foo.org"]
    assert f.current().matches("x.foo.org")


def test_netinfo_default_iface():
    from egress_proxy.netinfo import default_iface
    text = ("Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n"
            "eth1\t0010A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\n"
            "eth0\t00000000\t0100A8C0\t0003\t0\t0\t0\t00000000\n")
    assert default_iface(text) == "eth0"
    assert default_iface("Iface\n") is None
