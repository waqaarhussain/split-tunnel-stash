# Split Tunnel Stash

Stash trial using a fixed Control D DNS-over-HTTPS resolver, YouTube domain routing through this VPS's WireGuard exit, and DIRECT routing for other destinations. Import a private URL once; the server's rule catalog refreshes on the hour and half hour, with a client fetch interval of 1800 seconds.

**Device testing required.** The earlier Stash system-DNS profile failed: captures showed the WireGuard adapter making separate remote DNS lookups. This version tests explicit Control D DoH in Stash's main DNS configuration. It does not claim that setting main DNS also disables the adapter's own resolver. Remote DNS firewall guards remain in place. If YouTube fails or those guard counters increase, the separate adapter DNS issue remains unresolved. Do not treat Control D verification alone as proof that playback DNS is correct.

## Test on the existing Clash VPS

No VPS reset, new client or fresh installation is needed. Keep the saved working Clash profile. Run as root:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main/update.sh -o /tmp/stash-test-update.sh && bash /tmp/stash-test-update.sh
```

The updater reuses the Control D DoH URL already saved by `stash dns`. If absent, it prompts for the URL. Personal resolver IDs are saved only in private VPS state, never GitHub. Keep YouTube redirect disabled in that Control D profile.

The updater downloads and checksum-checks the manager, compiles it, validates generated Stash configs and compares the existing Clash output before replacing the installed manager. It saves a root-only manager backup and restarts only stash-subscriptions. A failed service restart or backend health check restores the previously installed manager. It does not change peer keys, client tokens, WireGuard, firewall, HTTPS or Nginx configuration.

Then run:

```bash
stash url
```

Choose the existing device. Import the **Stash TEST subscription URL ending in `/config.yaml`** into Stash using Configuration > Download from URL. Use Rule mode. This is a different URL suffix from Clash's `/mihomo.yaml`. Disconnect Clash before connecting Stash with the same peer. Do not run both simultaneously.

If an earlier Stash profile exists, remove it and import this URL afresh. Check that its `dns.nameserver` and `dns.proxy-server-nameserver` contain the intended Control D HTTPS URL, not `system`. The DNS bootstrap uses Control D's documented `76.76.2.22` address; ordinary destination lookups have no fallback provider. `follow-rule: false` requests direct DNS connections. The existing main-DNS real-answer mode is retained for this isolated test. No undocumented Mihomo-only fields are added to the Stash adapter.

## Device acceptance

1. Confirm Control D reports the expected resolver ID while Stash is connected.
2. Fully close and reopen YouTube; test thumbnails, sign-in and actual video playback.
3. Check Stash connections: matching service hostnames should use This VPS. Unrelated browsing should use DIRECT.
4. Compare `stash status` DNS rejection counters before and after playback. A handshake alone does not establish success.
5. If playback fails, capture only DNS traffic with `timeout 20 tcpdump -nn -i wg-stash -c 8 'port 53 or port 853'` while opening YouTube. Do not publish complete configs or private keys.

The domain catalog is community maintained, not Control D's own service catalog. Unknown hostnames can go direct; shared hostnames match regardless of which app requests them. Complete YouTube coverage and Apple TV behavior still need device tests.

## Return to Clash

Disconnect Stash and reconnect the saved Clash profile. Its endpoint and generated profile output are retained. To restore the original subscription manager too:

```bash
bash /tmp/stash-test-update.sh rollback
```

The first original backup is `/var/lib/stash-split-tunnel/manager-before-stash-test.py`. Repeated test updates do not overwrite it. Existing client URLs and keys remain valid.

## Fresh VPS installation

On a new Debian/Ubuntu VPS only:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/split-tunnel-stash/main/install.sh -o /tmp/stash-install.sh && bash /tmp/stash-install.sh
```

Then run `stash dns`, paste the fixed Control D DoH URL, and run `new`. Import the `/config.yaml` URL into Stash. Public TCP 80/8443 and UDP 51821 must be reachable, including provider firewall rules. `curl`, root and systemd are required. The installer detects this VPS's public IPv4; no exit IP is hardcoded.

Existing Nginx SNI on TCP 443 and wg0 on UDP 51820 are preserved. The project uses wg-stash, 10.88.0.0/24, UDP 51821 and separate trusted HTTPS on TCP 8443. Nginx gets a backed-up, syntax-checked HTTP ACME route and a graceful reload. Certificates require TCP 80 for renewal; certificate verification is never bypassed. Preserve `/var/lib/stash-https`.

The dedicated firewall blocks tunnel access to the VPS itself, private destinations and forwarded DNS on ports 53/853. NAT only applies to this project's subnet. No firewall block is removed for this DNS test. The health timer recovers missing project services, not idle peers; it never periodically reboots the VPN to flush client caches.

## Management

| Command | Action |
| --- | --- |
| `new` | Create a named client and print Stash and Clash URLs |
| `stash url` | Show existing URLs |
| `stash dns` | Set fixed Control D DoH for both profile formats |
| `stash list` | List clients |
| `stash remove` | Confirm removal and revoke peer and URL |
| `stash rules` | Refresh the upstream domain catalog |
| `stash service youtube` | Use YouTube catalog |
| `stash service netflix` | Select Netflix catalog for a separate experiment |
| `stash service custom` | Use only domains.txt |
| `stash status` | Services, DNS mode, rule age, handshakes and DNS guards |

`stash dns system` removes the explicit DNS override. The Stash fixed-DNS endpoint then refuses to generate a profile until a fixed resolver is set again; Clash retains its earlier system-DNS trial behavior.

Private settings, clients and extra suffixes are under `/var/lib/stash-split-tunnel`. These legacy paths and systemd names are deliberately retained for compatibility. Do not install multiple repository copies on the same VPS. Subscription URLs grant access to client private keys; keep them private. Removing a client revokes its peer and both profile URLs.

## Related repositories and validation

[Clash baseline](https://github.com/waqaarhussain/split-tunnel-clash) remains separate and unchanged by this test. [Shadowrocket copy](https://github.com/waqaarhussain/split-tunnel-shadowrocket) is separate future work. [Original WireGuard baseline](https://github.com/waqaarhussain/wireguard-server) is unchanged.

Run `python3 -m unittest -q` and `bash -n install.sh firewall update.sh`. Tests cover DNS fields, missing fixed resolver, retained Clash fields, keys and peers, authenticated URLs, revocation, domain rules, rollback and simulated firewall/Nginx behavior. The updater additionally compares actual per-client Clash documents on the target VPS before installation. Neither local tests nor source inspection replace Stash playback and DNS tests on the device.
