#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
STASH_STATE=/var/lib/stash-split-tunnel
STASH_MANAGER=/usr/local/lib/stash-split-tunnel/manager.py
[[ -f "$STASH_STATE/settings.json" && -f "$STASH_MANAGER" ]] || {
    echo 'Existing Stash HTTPS setup required.' >&2; exit 1;
}
STASH_TMP="$(mktemp -d)"
trap 'rm -rf -- "$STASH_TMP"' EXIT
STASH_SOURCE="${STASH_SOURCE:-https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main}"
curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 "$STASH_SOURCE/manager.py" -o "$STASH_TMP/manager.py"
echo '338880104084a0692d10b6c3c1be6ee7176cd70bb993d34a50dea73c8fe11ac6  '"$STASH_TMP/manager.py" | sha256sum -c -
python3 -m py_compile "$STASH_TMP/manager.py"
python3 - "$STASH_MANAGER" "$STASH_TMP/manager.py" <<'PY'
import importlib.util,sys

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
old,new=module('old',sys.argv[1]),module('new',sys.argv[2])
settings,clients=new.load('settings.json'),new.load('clients.json')
if not settings.get('stash_proxy_enabled'):
    raise SystemExit('HTTPS proxy is not enabled. No changes made.')
for client in clients.values():
    for method in ('make_config','make_mihomo_config'):
        if getattr(old,method)(settings,client) != getattr(new,method)(settings,client):
            raise SystemExit('A working profile would change. Update aborted.')
    new.make_device_dns_config(settings,client)
print('Working fixed-DNS Stash and Clash profiles unchanged. Separate test URL validated.')
PY
STASH_BACKUP="$STASH_STATE/manager-before-device-dns-test.py"
[[ -e "$STASH_BACKUP" ]] || install -m 600 "$STASH_MANAGER" "$STASH_BACKUP"
install -m 600 "$STASH_MANAGER" "$STASH_TMP/previous.py"
install -m 755 "$STASH_TMP/manager.py" "$STASH_MANAGER"
if ! systemctl restart stash-subscriptions || ! curl --noproxy '*' -fsS --retry 5 --retry-connrefused --retry-delay 1 --max-time 3 http://127.0.0.1:8765/health >/dev/null; then
    install -m 755 "$STASH_TMP/previous.py" "$STASH_MANAGER"
    systemctl restart stash-subscriptions || true
    echo 'Subscription check failed. Previous manager restored.' >&2
    exit 1
fi
echo 'Device-DNS experiment ready. Run stash url for its /device-dns.yaml URL.'
echo 'Keep the working /config.yaml profile. Only connect one profile at a time.'
echo 'The proxy still uses the saved Control D DoH for hostname resolution on the VPS.'
