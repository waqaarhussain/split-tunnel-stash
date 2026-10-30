#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
STASH_SOURCE="${STASH_SOURCE:-https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main}"
STASH_TMP="$(mktemp -d)"
trap 'rm -rf -- "$STASH_TMP"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 "$STASH_SOURCE/proxy-setup.sh" -o "$STASH_TMP/proxy-setup.sh"
echo '25071b7a9f0bc3d84bddc767e93c6bf3c02b0ce3f9a08f67e7a74fb61623b6bb  '"$STASH_TMP/proxy-setup.sh" | sha256sum -c -
STASH_SOURCE="$STASH_SOURCE" bash "$STASH_TMP/proxy-setup.sh" "$@"
