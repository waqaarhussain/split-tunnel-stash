#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
STASH_STATE=/var/lib/stash-split-tunnel
STASH_LIB=/usr/local/lib/stash-split-tunnel
STASH_BACKUP="$STASH_STATE/manager-before-https-proxy.py"
[[ -f "$STASH_STATE/settings.json" && -f "$STASH_LIB/manager.py" ]] || {
    echo 'Install this repository install.sh first on a new VPS.' >&2; exit 1;
}
rollback_proxy() {
    systemctl disable --now stash-proxy.service 2>/dev/null || true
    [[ ! -x "$STASH_LIB/proxy-firewall" ]] || "$STASH_LIB/proxy-firewall" down
    if [[ -f "$STASH_BACKUP" ]]; then
        install -m 755 "$STASH_BACKUP" "$STASH_LIB/manager.py"
    fi
    python3 - "$STASH_LIB/manager.py" <<'PY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location('manager',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with m.locked():
    settings=m.load('settings.json')
    settings.pop('stash_proxy_enabled',None);settings.pop('stash_proxy_port',None)
    m.save('settings.json',settings)
PY
    systemctl restart stash-subscriptions
}
if [[ "${1:-}" == rollback ]]; then
    [[ -f "$STASH_BACKUP" ]] || { echo 'No HTTPS proxy backup exists.' >&2; exit 1; }
    rollback_proxy
    echo 'HTTPS proxy stopped and prior manager restored. Reconnect the saved Clash profile.'
    exit 0
fi
[[ $# -eq 0 ]] || { echo 'Usage: bash proxy-setup.sh [rollback]' >&2; exit 1; }
if ss -H -lnt | awk '{print $4}' | grep -Eq ':9443$'; then
    systemctl is-active --quiet stash-proxy.service || {
        echo 'TCP 9443 is already occupied by another service. No changes made.' >&2; exit 1;
    }
fi
STASH_TMP="$(mktemp -d)"
trap 'rm -rf -- "$STASH_TMP"' EXIT
STASH_SOURCE="${STASH_SOURCE:-https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main}"
for STASH_FILE in manager.py https_proxy.py proxy-firewall; do
    curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 "$STASH_SOURCE/$STASH_FILE" -o "$STASH_TMP/$STASH_FILE"
done
# DIGESTS_BEGIN
echo '0b05f81b1dd60e953b472e9974648698f488f34d967054c3c5d466178b6170fc  '"$STASH_TMP/manager.py" | sha256sum -c -
echo '5c8f5423bff38e42e605081b665280c01eec6a9baa7f7c04c85986655f218980  '"$STASH_TMP/https_proxy.py" | sha256sum -c -
echo 'dbf1eb55814523858759dfeea5355a1d0c444e3e235b52d392efda3d67791bd5  '"$STASH_TMP/proxy-firewall" | sha256sum -c -
# DIGESTS_END
python3 -m py_compile "$STASH_TMP/manager.py" "$STASH_TMP/https_proxy.py"
bash -n "$STASH_TMP/proxy-firewall"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
if ! python3 -c 'import dns.message' 2>/dev/null; then
    apt-get update
    apt-get install -y python3-dnspython
fi
if ! python3 - "$STASH_STATE/settings.json" <<'PY'
import json,sys
sys.exit(0 if json.load(open(sys.argv[1])).get('mihomo_doh') else 1)
PY
then
    python3 "$STASH_TMP/manager.py" dns
fi
python3 - "$STASH_LIB/manager.py" "$STASH_TMP/manager.py" "$STASH_TMP/https_proxy.py" <<'PY'
import importlib.util,sys

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
old,new,proxy=[module('module'+str(i),path) for i,path in enumerate(sys.argv[1:])]
settings,clients=new.load('settings.json'),new.load('clients.json')
proxy.certificate_files(settings['endpoint'])
# Real DNS request over verified TLS before changing the running services.
proxy.doh_lookup('www.youtube.com',settings.get('mihomo_doh',''),settings['endpoint'])
for client in clients.values():
    if old.make_mihomo_config(settings,client) != new.make_mihomo_config(settings,client):
        raise SystemExit('Clash output changed. Setup aborted.')
print('Control D DoH answered. Trusted certificate found. Clash output unchanged.')
PY
[[ -e "$STASH_BACKUP" ]] || install -m 600 "$STASH_LIB/manager.py" "$STASH_BACKUP"
# Any subsequent setup failure restores the saved pre-proxy manager.
proxy_setup_error() {
    trap - ERR
    echo 'HTTPS proxy setup failed. Restoring the pre-proxy manager.' >&2
    rollback_proxy || true
    exit 1
}
trap proxy_setup_error ERR
install -m 755 "$STASH_TMP/manager.py" "$STASH_LIB/manager.py"
install -m 755 "$STASH_TMP/https_proxy.py" "$STASH_LIB/https_proxy.py"
install -m 755 "$STASH_TMP/proxy-firewall" "$STASH_LIB/proxy-firewall"
cat > /etc/systemd/system/stash-proxy.service <<'UNIT'
[Unit]
Description=Authenticated Stash HTTPS CONNECT proxy with explicit Control D DoH
Wants=network-online.target
After=network-online.target stash-https.service
[Service]
User=stash-split
Group=stash-split
ExecStartPre=+/usr/local/lib/stash-split-tunnel/proxy-firewall up
ExecStart=/usr/bin/python3 /usr/local/lib/stash-split-tunnel/https_proxy.py
ExecStopPost=+/usr/local/lib/stash-split-tunnel/proxy-firewall down
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
MemoryMax=256M
LimitNOFILE=512
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable stash-proxy.service
systemctl restart stash-proxy.service
STASH_IP="$(python3 -c 'import json;print(json.load(open("/var/lib/stash-split-tunnel/settings.json"))["endpoint"])')"
curl --noproxy '*' -fsS --retry 5 --retry-connrefused --retry-delay 1 --max-time 5 \
    --resolve "$STASH_IP:9443:127.0.0.1" "https://$STASH_IP:9443/health" >/dev/null
# Test an actual authenticated CONNECT and YouTube HTTPS request. Credentials
# stay in a root-only temporary curl config, never argv, logs or terminal output.
python3 - "$STASH_TMP/proxy-check.conf" <<'PY'
import json,os,sys
from pathlib import Path
settings=json.loads(Path('/var/lib/stash-split-tunnel/settings.json').read_text())
clients=json.loads(Path('/var/lib/stash-split-tunnel/clients.json').read_text())
if clients:
    token=next(iter(clients.values()))['token']
    options={'proxy':'https://'+settings['endpoint']+':9443','proxy-user':'stash:'+token,
             'resolve':settings['endpoint']+':9443:127.0.0.1','url':'https://www.youtube.com/generate_204',
             'noproxy':''}
    Path(sys.argv[1]).write_text(''.join(k+' = '+json.dumps(v)+'\n' for k,v in options.items()))
    os.chmod(sys.argv[1],0o600)
PY
if [[ -f "$STASH_TMP/proxy-check.conf" ]]; then
    curl -fsS --connect-timeout 10 --max-time 30 --config "$STASH_TMP/proxy-check.conf" -o /dev/null
    echo 'Authenticated HTTPS proxy and YouTube upstream test passed.'
fi
python3 - "$STASH_LIB/manager.py" <<'PY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location('manager',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with m.locked():
    settings=m.load('settings.json');settings.update(stash_proxy_enabled=True,stash_proxy_port=9443)
    for client in m.load('clients.json').values(): m.make_config(settings,client)
    m.save('settings.json',settings)
PY
systemctl restart stash-subscriptions
curl --noproxy '*' -fsS --retry 5 --retry-connrefused --retry-delay 1 --max-time 3 http://127.0.0.1:8765/health >/dev/null
trap - ERR
echo 'Stash HTTPS transport ready. Allow inbound TCP 9443 in any provider firewall.'
echo 'Run stash url. Reimport its /config.yaml URL into Stash; disconnect Clash first.'
echo 'Check Control D resolver ID, YouTube playback and DIRECT browsing.'
echo 'Rollback: bash /tmp/stash-proxy-setup.sh rollback'
