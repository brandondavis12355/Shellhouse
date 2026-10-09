# egress-proxy

Stdlib-only allowlist egress proxy for sandboxes. See `../docs/EGRESS.md`.

    python -m egress_proxy          # configured by EGRESS_* env vars
    python -m pytest tests          # 175 tests, no network or Docker needed
