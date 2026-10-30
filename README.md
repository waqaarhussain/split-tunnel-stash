# Split Tunnel Stash

YouTube domain rules through this VPS's authenticated HTTPS proxy, fixed Control D DNS-over-HTTPS, and DIRECT routing for other destinations. Import a private Stash profile URL; the domain rules refresh centrally. The existing Clash WireGuard profile stays available as a fallback.

**Current status:** the earlier Stash WireGuard trial failed despite working main Control D DNS. Packet captures confirmed separate YouTube DNS lookups to 1.0.0.1 and 8.8.4.4 inside WireGuard. This version changes Stash's transport to an HTTP CONNECT proxy over verified TLS. The user reports that YouTube and fixed Control D DNS now work on iPhone with this HTTPS transport. Apple TV acceptance and long-term reliability remain unverified.

## Optional device-DNS experiment

Keep the working fixed-DNS `/config.yaml` profile. A separate `/device-dns.yaml` profile removes the explicit Control D URL and bootstrap IP from the Stash document and requests `system` DNS for all resolver fields. The HTTPS node, authentication, domain catalog and default DIRECT rule are unchanged. This does not guarantee that Stash inherits an installed Apple encrypted DNS profile; the earlier system trial did not preserve it.

On the existing HTTPS installation:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main/dns-test-update.sh -o /tmp/stash-dns-test-update.sh && bash /tmp/stash-dns-test-update.sh
```

Run `stash url` and import the optional `/device-dns.yaml` URL as a second profile. Connect only one profile at a time. Verify the intended device resolver with Control D's configuration check and then test YouTube. If it fails either test, select the saved `/config.yaml` profile again; no server rollback or DNS-setting change is required.

**Scope:** this changes Stash's main DNS choice only. The VPS HTTPS proxy still resolves hostnames through the saved Control D DoH endpoint. A domain-forwarding HTTP proxy cannot inherit the phone's DNS settings. If Stash sends an already resolved IP, that connection needs no proxy-side DNS lookup. Do not describe this experiment as all resolution using device DNS or as removing Control D from the server.

The updater validates both working profile documents against the installed manager before replacement, backs up the manager and restarts only the subscription service. It does not change the HTTPS proxy, its certificate, firewall, client keys, passwords or private DNS settings. The new test URL has the same authentication and revocation checks as the other URLs.

## Existing VPS: enable the HTTPS transport

No reset or new client is needed. Run as root:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main/proxy-setup.sh -o /tmp/stash-proxy-setup.sh && bash /tmp/stash-proxy-setup.sh
```

The setup reuses your saved Control D DoH URL and client credentials. If the DNS URL is missing, it prompts for it. The personal resolver ID remains in private VPS settings, not GitHub. Keep YouTube redirect disabled in that Control D profile.

Allow inbound **TCP 9443** in any provider firewall. Setup manages a labelled host iptables rule for that port only. Existing Nginx SNI on TCP 443, subscription HTTPS on TCP 8443, wg0 and the Clash WireGuard interface remain intact. This is an update to the installed subscription manager plus a separate stash-proxy service, not a reinstall.

Before switching the profile, setup checks file digests, validates the Python/shell code, checks the trusted TLS certificate, performs a real Control D DoH lookup, and compares actual per-client Clash documents against the installed manager. If an existing client is present, it also makes an authenticated CONNECT request to YouTube with full outer and inner TLS verification. Setup failure after changes triggers rollback to the manager saved before the HTTPS experiment.

After success:

```bash
stash url
```

Select the existing device and copy the **Stash TEST URL ending in `/config.yaml`**. Disconnect Clash. Remove the older Stash profile and import the same URL afresh using Configuration > Download from URL. Use Rule mode. In the new source, the This VPS proxy must be `type: http`, `tls: true`, port **9443**. If it still says wireguard, the app is using an older profile.

No secrets need manual entry in Stash. Each client's private subscription already contains its unique proxy password. Do not run the same client concurrently from multiple apps or devices.

## How traffic and DNS work

Stash matches DOMAIN, DOMAIN-SUFFIX and DOMAIN-KEYWORD rules from the private rule provider. Matching service destinations use This VPS, and the final rule is MATCH,DIRECT. This is domain selection inside the app, not periodically resolved real-IP routing and not Control D DNS redirection.

Main Stash DNS explicitly uses your chosen Control D DoH URL with `follow-rule: false`. Its bootstrap lookup uses Control D's published 76.76.2.22 resolver. This selects a fixed provider; it does not inherit arbitrary Apple encrypted DNS profiles automatically.

The proxy carries TCP HTTPS connections to destination port 443. Stash documents blocking proxied QUIC by default so apps can fall back to TCP. Direct traffic is not subjected to a global UDP block. Apps that require UDP or plain HTTP through this proxy are outside this trial's supported transport.

When the proxy receives a hostname, it resolves A records over **your same saved Control D DoH URL**. It connects directly to Control D's published 76.76.2.22 address while verifying the dns.controld.com TLS hostname; it does not use the VPS's system resolver or an alternate DNS provider. If the app sends an already-resolved public IPv4 address, the proxy connects to that IP. DNS failure does not fall back to system DNS.

The TLS proxy is on the VPS itself. Traffic exits that VPS's own public network. Its endpoint is detected at installation, not hardcoded to a particular VPS IP. YouTube sees the VPS exit for successfully proxied requests.

## Authentication, TLS and access limits

The proxy requires HTTP Basic authentication inside TLS, using username stash and the existing per-client private subscription token as its password. Unauthorized requests cannot open a tunnel. Removing a client revokes its password for new connections, and active connections check revocation periodically. The node does not skip certificate checks. The proxy does not decrypt the inner YouTube TLS session.

Only public IPv4 destinations on TCP 443 are allowed. Loopback, private, link-local, multicast, reserved destinations and the configured VPS endpoint are rejected. DNS answers are validated and connections are pinned to the returned IP, preventing a second system-DNS lookup. Header sizes, handshake/read timeouts, concurrent connections and per-client sessions are bounded. Credentials and request targets are not logged.

The proxy reuses the publicly trusted endpoint certificate already maintained by the separate stash-https Caddy service. It reloads renewed certificate/key files without dropping existing sessions. TCP 80 must remain reachable for certificate renewals. The proxy runs as the existing unprivileged stash-split service user; its firewall helper runs separately with the required privileges.

The WireGuard DNS firewall guards remain unchanged. Stash no longer uses WireGuard for this profile; Clash still does. Keep `/var/lib/stash-https` and `/var/lib/stash-split-tunnel` intact across reboots.

## Device acceptance

1. Confirm the imported node is HTTPS on port 9443, then connect Stash in Rule mode.
2. Check Control D reports the intended resolver ID.
3. Close and reopen YouTube; verify thumbnails and actual video playback.
4. In Stash connections, confirm YouTube matches This VPS and unrelated browsing is DIRECT.
5. Test Apple TV independently. Neither an iPhone test nor server curl proves tvOS acceptance.

The default catalog is the community-maintained blackmatrix7 YouTube list, not Control D's private service catalog. It is not guaranteed exhaustive. Shared hostnames are matched regardless of the requesting app, and unlisted or unclassified destinations can go direct.

## Return to Clash

Disconnect Stash and reconnect the saved Clash profile. Its `/mihomo.yaml` URL, WireGuard keys and output are retained. To stop the HTTPS proxy and restore the pre-proxy subscription manager:

```bash
bash /tmp/stash-proxy-setup.sh rollback
```

The root-only original manager backup is `/var/lib/stash-split-tunnel/manager-before-https-proxy.py`. Repeated setup runs do not replace this first backup. Rollback removes only the labelled proxy firewall rule and disables stash-proxy. It preserves clients, their tokens, the configured Control D URL and the existing VPN/SNI services.

## New VPS

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main/install.sh -o /tmp/stash-install.sh && bash /tmp/stash-install.sh
```

Requires root, Debian/Ubuntu, systemd, curl and inbound TCP 80/8443/9443 plus UDP 51821 for the retained Clash fallback. The base installer sets up the separate WireGuard interface and subscription HTTPS, then invokes the HTTPS proxy setup. It prompts for the Control D DoH URL if absent. Run `new` afterward to create the device's credentials and private URLs. Existing initialized installations must use proxy-setup.sh instead of reinstalling.

The installer extracts Caddy from the official signed APT package without starting a global Caddy service. It backs up and syntax-checks Nginx before adding a separate port-80 ACME route and graceful reload. Existing SNI stream configuration and wg0 are preserved and checked. The HTTPS proxy adds only its own service, Python file and labelled TCP 9443 firewall rule. The additional DNS wire-format library comes from the OS python3-dnspython package.

## Rules and helpers

| Command | Action |
| --- | --- |
| `new` | Create client credentials and private Stash/Clash URLs |
| `stash url` | Show existing URLs |
| `stash dns` | Set fixed Control D DoH for Stash, proxy resolution and Clash |
| `stash list` | List clients |
| `stash remove` | Confirm removal and revoke all access for the client |
| `stash rules` | Refresh upstream catalog now |
| `stash service youtube` | Select YouTube catalog |
| `stash service netflix` | Select Netflix catalog for a separate service experiment |
| `stash service custom` | Use only domains.txt |
| `stash status` | Current transport, DNS mode, services and counters |

Extra suffixes belong in `/var/lib/stash-split-tunnel/domains.txt`. The server refreshes the catalog every hour at :00 and :30 in the VPS timezone; client rule fetch interval is 1800 seconds subject to app/OS scheduling. No peer reboot is used to refresh rules. Existing sessions and caches can persist. The status helper retains legacy service names for compatibility.

Do not remove the fixed DNS setting during this experiment. A missing explicit URL makes Stash profile generation refuse and hostname resolution fail, rather than silently use another resolver.

## Diagnostics and tests

```bash
stash status
systemctl status stash-proxy --no-pager
journalctl -u stash-proxy -n 30 --no-pager
```

Subscription URLs contain bearer credentials and return private client material. Keep them private. No actual client tokens, server keys or personal DNS IDs belong in GitHub.

Local validation: `python3 -m unittest -q` with PyYAML and dnspython installed, and `bash -n install.sh update.sh proxy-setup.sh proxy-firewall firewall`. Tests include full curl traffic through a locally trusted outer TLS CONNECT relay and an inner HTTPS server, authentication, revocation, destination restrictions, explicit DoH wire parsing, no system-DNS fallback, retained Clash output, subscription access and earlier firewall/Nginx checks. The local integration fixture uses a generated test CA certificate only; production uses the existing publicly trusted certificate and never disables TLS checks.

[Clash baseline](https://github.com/waqaarhussain/split-tunnel-clash) and [Shadowrocket copy](https://github.com/waqaarhussain/split-tunnel-shadowrocket) remain separate. The original [wireguard-server](https://github.com/waqaarhussain/wireguard-server) is unchanged. Do not install repository copies alongside one another on the same VPS; use this updater on the existing shared infrastructure.
