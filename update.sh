#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
STASH_SOURCE="${STASH_SOURCE:-https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main}"
STASH_TMP="$(mktemp -d)"
trap 'rm -rf -- "$STASH_TMP"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 "$STASH_SOURCE/proxy-setup.sh" -o "$STASH_TMP/proxy-setup.sh"
echo 'a7d5104e7eaecad57479a634bc1ceede0d40465faceb286b2d524208cfb87cbd  '"$STASH_TMP/proxy-setup.sh" | sha256sum -c -
STASH_SOURCE="$STASH_SOURCE" bash "$STASH_TMP/proxy-setup.sh" "$@"
