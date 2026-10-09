#!/bin/sh
# TLS is strongly recommended: requests are signed (so they can't be forged or
# replayed) but message TEXT is not encrypted on the wire without it. Put a
# certificate at /certs/fullchain.pem + /certs/privkey.pem (see README) and it
# is used automatically. Without them the relay refuses to start unless
# RELAY_ALLOW_PLAINTEXT=1 is set (only sensible behind your own TLS proxy or
# bound to loopback).
set -e
if [ -f /certs/fullchain.pem ] && [ -f /certs/privkey.pem ]; then
  exec uvicorn main:app --host 0.0.0.0 --port 8443 \
    --ssl-certfile /certs/fullchain.pem --ssl-keyfile /certs/privkey.pem \
    --no-server-header --limit-concurrency 200 --timeout-keep-alive 15
fi
if [ "${RELAY_ALLOW_PLAINTEXT:-0}" = "1" ]; then
  echo "WARNING: starting WITHOUT TLS (RELAY_ALLOW_PLAINTEXT=1)" >&2
  exec uvicorn main:app --host 0.0.0.0 --port 8443 --no-server-header --limit-concurrency 200 --timeout-keep-alive 15
fi
echo "No TLS certificate in /certs and RELAY_ALLOW_PLAINTEXT is not set; refusing to start." >&2
exit 1
