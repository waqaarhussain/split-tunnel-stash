#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
STASH_SOURCE="${STASH_SOURCE:-https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main}"
STASH_TMP="$(mktemp -d)"
trap 'rm -rf -- "$STASH_TMP"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 "$STASH_SOURCE/proxy-setup.sh" -o "$STASH_TMP/proxy-setup.sh"
echo 'da68e57db7e2635048e5adb7f0acd803fd41822403b169c3688bd83c90519e74  '"$STASH_TMP/proxy-setup.sh" | sha256sum -c -
STASH_SOURCE="$STASH_SOURCE" bash "$STASH_TMP/proxy-setup.sh" "$@"
