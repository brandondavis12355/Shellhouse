#!/bin/bash
# Plant decoy credentials ("canaries") that look like the things an attacker
# or a hijacked agent goes looking for. They are FAKE and unusable; each embeds
# a unique honeytoken `SHELLHOUSE-CANARY-<random>`.
#
# Detection (defense in depth, none of it perfect):
#   - the Mac-side policy engine treats these four paths as tripwires;
#   - the egress proxy flags/blocks plain-HTTP requests containing the token
#     (it cannot see inside TLS/CONNECT tunnels).
#
# Idempotent: an existing canary file is left untouched so its token stays
# stable; any OTHER existing file is never touched (a warning is printed).
# CANARY_DRY_RUN=1 prints what would be created and changes nothing. Safe to run as `box` (normal) or root (files are chowned to box).
set -u
umask 077

BOX_HOME="${CANARY_HOME:-/home/box}"
WS="${CANARY_WORKSPACE:-/workspace}"
OWNER="${CANARY_OWNER:-box}"

tok() { printf 'SHELLHOUSE-CANARY-%s' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }

DRY="${CANARY_DRY_RUN:-0}"     # 1 = print what would happen, change nothing

warn() { echo "seed-canaries: WARNING: $*" >&2; }

# plant <path> <content-with-%TOKEN%>
# Never overwrites a file that is not already one of our canaries, never
# follows symlinks (target or parent directory), and creates atomically with
# noclobber so a racing file/symlink is not clobbered.
plant() {
  local path="$1" body="$2" t dir
  dir="$(dirname "$path")"
  if [ -L "$path" ]; then warn "$path is a symlink; skipped"; return 0; fi
  if [ -L "$dir" ]; then warn "$dir is a symlink; skipped $path"; return 0; fi
  if [ -e "$path" ]; then
    if grep -q 'SHELLHOUSE-CANARY-' "$path" 2>/dev/null; then return 0; fi
    warn "$path exists and is not a canary; left untouched"
    return 0
  fi
  if [ "$DRY" = "1" ]; then echo "seed-canaries: would create $path"; return 0; fi
  mkdir -p "$dir" || return 0
  if [ -L "$dir" ]; then warn "$dir is a symlink; skipped $path"; return 0; fi
  t="$(tok)"
  if ! ( set -C; printf '%s\n' "${body//%TOKEN%/$t}" > "$path" ) 2>/dev/null; then
    warn "could not create $path (appeared concurrently?); skipped"
    return 0
  fi
  chmod 600 "$path"
  if [ "$(id -u)" = "0" ]; then chown -h "$OWNER:$OWNER" "$path" "$dir" 2>/dev/null || true; fi
}

plant "$BOX_HOME/.aws/credentials" '[default]
aws_access_key_id = %TOKEN%
aws_secret_access_key = %TOKEN%
region = us-east-1'

plant "$BOX_HOME/.ssh/id_ed25519" '-----BEGIN OPENSSH PRIVATE KEY-----
%TOKEN%
-----END OPENSSH PRIVATE KEY-----'

plant "$BOX_HOME/.config/gcloud/application_default_credentials.json" '{
  "type": "authorized_user",
  "client_id": "%TOKEN%.apps.example.invalid",
  "client_secret": "%TOKEN%",
  "refresh_token": "%TOKEN%"
}'

plant "$WS/.env.production" '# production settings (decoy)
DATABASE_URL=postgres://app:%TOKEN%@db.example.invalid:5432/app
API_SECRET_KEY=%TOKEN%'

# Tighten directories we created holding canaries (never via symlinks).
if [ "$DRY" != "1" ]; then
  for d in "$BOX_HOME/.aws" "$BOX_HOME/.ssh" "$BOX_HOME/.config/gcloud"; do
    [ -d "$d" ] && [ ! -L "$d" ] && chmod 700 "$d" 2>/dev/null
  done
fi
exit 0
