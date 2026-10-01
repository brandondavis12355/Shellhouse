#!/bin/sh
# Generates a self-signed certificate for the relay into ./certs/ (fullchain.pem,
# privkey.pem). Usage: ./gen-cert.sh <host-or-ip> [more hosts/IPs...]
# (every name/address friends might use goes in the certificate)
# Friends' apps must trust/pin this certificate (phase 2 pins its fingerprint).
set -e
HOST="${1:?usage: gen-cert.sh <hostname-or-ip> [more...]}"
mkdir -p certs
SAN=""
for name in "$@"; do
  case "$name" in
    *[!0-9.]*) entry="DNS:$name" ;;
    *)         entry="IP:$name" ;;
  esac
  SAN="${SAN:+$SAN,}$entry"
done
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 \
  -keyout certs/privkey.pem -out certs/fullchain.pem \
  -subj "/CN=$HOST" -addext "subjectAltName=$SAN"
echo "SHA-256 fingerprint (give this to friends to verify):"
openssl x509 -in certs/fullchain.pem -noout -fingerprint -sha256
# The relay runs as uid 10001 inside its container and must be able to read the
# private key. Hand ownership of the key to that uid (mode 600), instead of
# making it world-readable on the host. Uses Docker since chown needs root.
docker run --rm -v "$PWD/certs:/certs" --entrypoint sh python:3.11-slim -c \
  'chown 10001:10001 /certs/privkey.pem /certs/fullchain.pem && chmod 600 /certs/privkey.pem && chmod 644 /certs/fullchain.pem'
echo "certs/privkey.pem is now owned by the relay user (readable only by it)."
