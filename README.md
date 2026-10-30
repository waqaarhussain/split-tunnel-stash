# Split Tunnel Stash

The working Stash setup: YouTube domain rules select an authenticated HTTPS proxy on this VPS, each device uses its own explicit Control D DNS-over-HTTPS URL, and other traffic uses DIRECT. Import the client's private `/config.yaml` URL once. Shared domain rules update separately.

YouTube playback with fixed Control D DNS has been confirmed on iPhone. Apple TV and continuous use over several days still need device testing. This repository is separate from the working [Clash baseline](https://github.com/waqaarhussain/split-tunnel-clash) and the [Shadowrocket copy](https://github.com/waqaarhussain/split-tunnel-shadowrocket); neither is changed by this release.

## Update the existing working VPS

Run as root. Do not reset the VPS or reinstall the base setup:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main/update.sh -o /tmp/stash-update.sh && bash /tmp/stash-update.sh
```

The update preserves client credentials, private URLs, the currently working DNS choice and Clash fallback documents. Existing clients are assigned their current resolver individually and get private YAML copies under `/home/stash/<client name>/config.yaml`. No reimport is needed for an unchanged existing profile. It briefly restarts the Stash proxy and subscription service to load the update. Nginx SNI, wg0, the Clash repository and Shadowrocket repository are left alone.

Setup verifies file digests, syntax, the trusted endpoint certificate and each distinct saved Control D resolver. It checks existing profile documents against the installed manager. With an existing client, it also tests an authenticated HTTPS CONNECT request to YouTube. If the update fails after replacement, it restores the immediately previous proxy code, manager, settings, client database and service configuration.

## Create a device

```bash
new
```

The helper asks for:

1. Client name, including spaces or apostrophes if wanted.
2. **That device's Control D DoH URL**, such as `https://dns.controld.com/YOUR_DEVICE_RESOLVER_ID`.

Each client gets its own credentials, DNS URL, private subscription URL and YAML:

```text
/home/stash/My iPhone/config.yaml
/home/stash/Living Room TV/config.yaml
```

Folders are administrator-only (0700), YAML files are 0600. Private DNS IDs and credentials are stored on the VPS, never in this repository. The subscription gateway renders from private state; it does not need access to the home folders. Exported YAML is a copy of the client's current profile, with the same private rule-provider URL.

Copy the printed **Stash subscription URL ending in `/config.yaml`** into Stash > Configuration > Download from URL, then select Rule mode. Disconnect Clash before connecting Stash with the same client. The profile includes all proxy authentication; no password needs manual entry. Use a separate client for each device.

Existing clients can be shown with `stash url`. To change one device's resolver:

```bash
stash client-dns
```

Select the device and enter its new Control D DoH URL. The saved YAML and private subscription update together in normal operation. Refresh that device's full profile and reconnect so its local DNS settings match the server. `stash export` regenerates all YAML copies. `stash remove` revokes the selected client's URLs/proxy password and removes its exported `config.yaml`; unrelated files in its folder are retained.

`stash dns` is retained for the legacy global/default resolver and Clash fallback. It does not overwrite DNS choices pinned to individual Stash clients. New clients always prompt for a device resolver. Keep YouTube redirection disabled in the selected Control D profile.

## Five-minute idle cleanup

There is no YouTube or WireGuard handshake in this Stash HTTPS transport. The relay tracks authenticated proxy connections separately for each client.

- A connection with no payload activity in either direction for five minutes is closed. Downstream video activity keeps it alive even when the device is not sending requests upstream.
- After a client has no active proxy connections for five minutes, its VPS DNS cache entries are discarded. Cleanup runs every ten seconds, so the idle threshold is applied within roughly ten seconds.
- DNS TTLs still expire normally, capped at five minutes. Cache entries are isolated by client, resolver and destination. One client's cleanup does not reset another client's cache or connections.
- The proxy is not restarted for inactivity. Systemd restarts it if the process fails. No old WireGuard handshake triggers a reboot.

The two timers are separate: a quiet but still open connection can take five minutes to close, followed by five minutes with no connections before client cache cleanup. This does not clear YouTube's or Stash's cache on the phone/TV, force the device to reconnect, or flush OS DNS. Stash can stay connected while the VPS does this housekeeping.

## Traffic and DNS

Stash matches DOMAIN, DOMAIN-SUFFIX and DOMAIN-KEYWORD rules from the private rule provider. Selected domains use **This VPS**, and the final rule is `MATCH,DIRECT`. This is domain selection inside Stash, rather than IP-range routing or Control D redirection. The VPS endpoint is detected at installation; each installation exits through its own network.

The main Stash DNS configuration explicitly uses the client's Control D DoH URL. When the HTTPS proxy receives a hostname, it uses **that same client's resolver**. If Stash sends an already resolved public IP, the proxy connects directly to that IP. A failed DNS request does not fall back to the VPS's system resolver or another public resolver.

The Control D hostname is bootstrapped using its published `76.76.2.22` address. Proxy-side DoH verifies the `dns.controld.com` TLS hostname. This is explicit fixed DNS per client, not inheritance of an Apple encrypted DNS profile. The earlier system-DNS experiment did not preserve the installed Control D profile; its optional `/device-dns.yaml` endpoint remains for compatibility but is not the supported import workflow.

The relay supports public IPv4 TCP destinations on port 443. Stash blocks proxied QUIC by default, allowing YouTube to fall back to TCP; DIRECT traffic has no global UDP block. Plain HTTP and apps requiring proxied UDP are outside this transport's scope. The community blackmatrix7 YouTube catalog is not Control D's private catalog or a guarantee of exhaustive coverage. Shared domains may also match other services, while unlisted destinations can go DIRECT.

## Rules and helpers

| Command | Action |
| --- | --- |
| `new` | Ask for client name and device Control D DoH URL; create credentials, YAML and private URL |
| `stash url` | Show the selected client's private Stash URL and retained Clash fallback URL |
| `stash client-dns` | Change a selected Stash client's resolver and regenerate its YAML |
| `stash export` | Migrate legacy resolver choices and regenerate private YAML copies |
| `stash list` | List clients |
| `stash remove` | Confirm removal, revoke access and remove its exported YAML |
| `stash dns` | Set the legacy global/default resolver, including Clash fallback DNS |
| `stash rules` | Refresh the domain catalog now |
| `stash service youtube` | Select YouTube catalog |
| `stash service netflix` | Select Netflix catalog for a separate service setup |
| `stash service custom` | Use only custom domain suffixes |
| `stash status` | Show transport, services, rule refresh and legacy WireGuard diagnostics |

Add custom suffixes to `/var/lib/stash-split-tunnel/domains.txt`. The VPS refreshes its catalog at :00 and :30 each hour in its own timezone. Stash's rule-provider interval is 1800 seconds, subject to app/OS scheduling. Changing domain rules does not require another full-profile import. Changes to DNS, server endpoint or proxy settings require refreshing the full profile; the private URL is reusable.

## New VPS

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main/install.sh -o /tmp/stash-install.sh && bash /tmp/stash-install.sh
```

Requires root, Debian/Ubuntu, systemd and curl. Allow inbound TCP **80, 8443 and 9443**, plus UDP 51821 for the retained Clash WireGuard fallback. After setup, run `new` and enter the device's DNS URL. On an existing initialized VPS use `update.sh`, not the base installer.

The base installer creates the separate wg-stash interface and subscription service. It extracts Caddy from the official signed APT package without starting a global Caddy service. A separate Nginx port-80 route handles trusted IP-certificate renewal, with backups, syntax checks and graceful reload; the existing TCP443 SNI stream and wg0 are preserved. The proxy uses TCP9443 and adds only its own labelled iptables rule. Provider firewall rules may need changing separately.

Keep TCP80 reachable for renewal. The proxy reuses the certificate maintained by stash-https and reloads renewed keys without dropping current sessions. Both outer proxy TLS and inner YouTube TLS are verified; the proxy does not intercept YouTube TLS.

## Access and recovery

Proxy authentication uses HTTP Basic inside verified TLS, username `stash`, and each client's private token as the password. Subscription URLs are bearer credentials. Removing a client blocks new access, and active proxy sessions check revocation every ten seconds. Private, loopback, link-local, multicast, reserved, IPv6 and the configured VPS endpoint are rejected as proxy destinations. DNS results are checked and pinned to their IP, without a second system lookup. Connections, request headers and authentication timeouts are bounded. Request targets and credentials are not logged.

Runtime state is in `/var/lib/stash-split-tunnel`; certificate state is in `/var/lib/stash-https`. Keep both, along with private exports, secure and backed up. Exports alone are not a full server backup. Services run as the restricted stash-split user; home-folder exports are written only by root management commands.

To use the retained Clash fallback, disconnect Stash and reconnect the saved Clash profile. Its WireGuard configuration and `/mihomo.yaml` output are preserved. The original explicit transport rollback remains available via `proxy-setup.sh rollback`; it stops the HTTPS proxy and restores the pre-HTTPS manager for Clash. This differs from an update failure's automatic restoration of the immediately previous working Stash setup.

## Validation

```bash
stash status
systemctl status stash-proxy --no-pager
journalctl -u stash-proxy -n 30 --no-pager
```

Check the intended Control D resolver ID, YouTube video playback and unrelated DIRECT browsing after importing. Test Apple TV independently; server tests and iPhone playback do not establish tvOS behavior.

Local suite: `python3 -m unittest -q` with PyYAML and dnspython installed. It exercises separate device resolvers and private YAMLs, legacy migration, unchanged Clash output, cache isolation and idle timing, shared activity tracking, authentication/revocation, forbidden destinations, DoH wire parsing, no system-DNS fallback, subscription access, firewall/Nginx checks, and an actual curl request through outer TLS CONNECT to an inner HTTPS server. Test certificates are trusted explicitly in the local fixture only; production never disables certificate verification.
