#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
STASH_STATE=/var/lib/stash-split-tunnel
STASH_MANAGER=/usr/local/lib/stash-split-tunnel/manager.py
STASH_BACKUP="$STASH_STATE/manager-before-stash-test.py"
[[ -f "$STASH_STATE/settings.json" && -f "$STASH_MANAGER" ]] || {
    echo 'No existing installation found. Use this repository install.sh on a new VPS.' >&2
    exit 1
}
if [[ "${1:-}" == rollback ]]; then
    [[ -f "$STASH_BACKUP" ]] || { echo 'No Stash test backup found.' >&2; exit 1; }
    install -m 755 "$STASH_BACKUP" "$STASH_MANAGER"
    systemctl restart stash-subscriptions
    echo 'Original manager restored. Disconnect Stash and reconnect the saved Clash profile.'
    exit 0
fi
[[ $# -eq 0 ]] || { echo 'Usage: bash update.sh [rollback]' >&2; exit 1; }
STASH_TMP="$(mktemp -d)"
trap 'rm -rf -- "$STASH_TMP"' EXIT
STASH_SOURCE='https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main'
curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 "$STASH_SOURCE/manager.py" -o "$STASH_TMP/manager.py"
echo '533813f1379d3bbac7ae7c860a7fed62d18771317cf0b4e81cbe0b79fe92250e  '"$STASH_TMP/manager.py" | sha256sum -c -
python3 -m py_compile "$STASH_TMP/manager.py"
if ! python3 - "$STASH_STATE/settings.json" <<'PY'
import json,sys
sys.exit(0 if json.load(open(sys.argv[1])).get('mihomo_doh') else 1)
PY
then
    echo 'Paste the existing Control D DoH URL. It is saved only in private VPS settings.'
    python3 "$STASH_TMP/manager.py" dns
fi
# Validate generated configs without printing private keys, URLs or DNS IDs.
# Compare the currently working Clash output before touching the installed file.
python3 - "$STASH_MANAGER" "$STASH_TMP/manager.py" <<'PY'
import importlib.util,sys

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    result=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

old,new=module('old_manager',sys.argv[1]),module('new_manager',sys.argv[2])
settings,clients=new.load('settings.json'),new.load('clients.json')
for client in clients.values():
    new.make_config(settings,client)
    if old.make_mihomo_config(settings,client) != new.make_mihomo_config(settings,client):
        raise SystemExit('Clash profile output changed. Update aborted before installation.')
print('Fixed-DNS Stash config validated; existing Clash profile output unchanged.')
PY
if [[ ! -e "$STASH_BACKUP" ]]; then
    install -m 600 "$STASH_MANAGER" "$STASH_BACKUP"
fi
install -m 600 "$STASH_MANAGER" "$STASH_TMP/previous.py"
install -m 755 "$STASH_TMP/manager.py" "$STASH_MANAGER"
if ! systemctl restart stash-subscriptions || ! curl --noproxy '*' -fsS --retry 5 --retry-connrefused --retry-delay 1 --max-time 3 http://127.0.0.1:8765/health >/dev/null; then
    install -m 755 "$STASH_TMP/previous.py" "$STASH_MANAGER"
    systemctl restart stash-subscriptions || true
    echo 'Subscription restart/check failed; previous manager restored.' >&2
    exit 1
fi
echo 'Stash test ready. Run: stash url'
echo 'Import the Stash TEST URL ending in /config.yaml. Disconnect Clash before connecting Stash.'
echo 'Keep the saved Clash profile. Check Control D resolver ID, YouTube playback and DIRECT browsing.'
echo 'Rollback if needed: bash /tmp/stash-test-update.sh rollback'
