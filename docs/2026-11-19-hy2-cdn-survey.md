# Hysteria2 and CDN fallback survey (2026-11-19)

**Outcome: both paths work and neither needs a change now.** Nothing was changed on the VPS or
the client. One VPS housekeeping item is worth folding into the next deploy (Docker log rotation),
and one date needs a look (the first certificate renewal under the new ACME provider).

Companion to `2026-11-19-reality-target-survey.md`. Same setup: VPS in Los Angeles (AS2914),
sing-box v1.14.3 at `c06aae9`, client in mainland China on Clash Verge, TUN off.

## What is configured

| | Hysteria2 (`hy2-vps`) | CDN fallback (`cdn-fallback`) |
|---|---|---|
| Transport | QUIC over UDP 8443 | VLESS + WebSocket + TLS over TCP 2053, through Cloudflare |
| Certificate | Let's Encrypt for `STATIC_DOMAIN`, ACME provider in sing-box | Cloudflare's at the edge; self-signed at the origin (SSL mode Full) |
| Congestion control | BBR on both sides — no `up`/`down` on the client, no `up_mbps`/`down_mbps` on the server, so Brutal is never negotiated | TCP (kernel BBR on the VPS) |
| Obfuscation / masquerade / port hopping | none | n/a |
| Firewall | 8443/udp open to all | 2053/tcp open to Cloudflare ranges only |

The TCP paths are Reality (443) and the CDN fallback (2053). Hysteria2 is the only UDP path.

## What was measured

1. **VPS state** — ufw rules, UDP buffer sysctls, certificate dates, Docker log size.
2. **24 hours of sing-box log** — inbound connections per path and per client network, error shapes.
3. **Four weeks of sing-box log** — per day, minutes in which a main client network had more than
   three Reality (or CDN) connections, i.e. the fallback group had left hy2.
4. **Throughput per path** — an isolated mihomo on the client with one local port bound to each
   node (the running Verge core untouched), 40 MB download from `speed.cloudflare.com` twice,
   8 MB upload once, ten requests to `generate_204`. Thursday 17:25 CST, not peak hours.

## Results

Throughput (client → VPS → Cloudflare speed test):

| Path | download, 2 runs | upload | `generate_204` ×10 |
|---|---|---|---|
| hy2-vps | 30.5 / 56.6 Mbit/s | 22.7 Mbit/s | 10/10, typically 0.35 s |
| reality-vps | 75.1 / 45.8 Mbit/s | 20.5 Mbit/s | 10/10, typically 0.8 s |
| cdn-fallback | 16.6 / 17.9 Mbit/s | 13.9 Mbit/s | 10/10, 1.9–4.3 s |

Stability of hy2: on days with a full day of activity (2026-11-13 to 11-18) the main client
networks had hy2 connections in every active minute, and traffic spilled to Reality in 0–20
minutes per day, to CDN in 0–22. Over the four weeks the usual figure is under 15 minutes a day.
(2026-11-19 is inflated by this survey's own tests.)

VPS state:

- UDP buffers are already raised (`rmem_max` / `wmem_max` 32 MiB), kernel congestion control is
  BBR with `fq`. No buffer warnings in the sing-box log.
- hy2 certificate expires 2027-01-08. Renewal has not run yet under the `certificate_providers`
  entry introduced with v1.14.3.
- **Docker json log of sing-box: 720 MB after 8 days** (about 90 MB a day). Root disk 20 GB, 8.4 GB
  free. No rotation is configured.
- ufw has 15 Cloudflare rules; Cloudflare publishes 14 IPv4 ranges today — one stale rule.
- 24 h error lines: 3921, of which 1873 are ordinary hy2 stream cancellations logged at ERROR by
  v1.14, 1064 are `REALITY: processed invalid connection` from scanners (cloud-provider ranges),
  and the rest are upstream DNS failures for individual hostnames. Nothing points at hy2 or the
  CDN inbound failing.

Client side:

- The running Verge profile carries a live `cdn-fallback`: the CDN inbound logged about 930
  connections from the main client network in 24 h (its 60-second health checks). This closes the
  October open item about the placeholder `CDN_DOMAIN`.
- A second client network sends almost everything through Reality (about 12.9k connections in
  24 h against about 250 on hy2). It is on a profile that does not put hy2 first.

## Findings

- **No bandwidth setting is needed for hy2.** With no `up`/`down` declared, Hysteria2 uses BBR and
  finds the rate itself. Declaring them switches to Brutal, which sends at the declared rate
  whatever the loss; it helps only on a lossy line and only if the numbers are at or below the real
  capacity. hy2 and Reality measured in the same range off-peak, so there is no evidence of loss
  that Brutal would fix. Worth revisiting only if a peak-hour test (README Runbook D) shows hy2
  far below Reality.
- **Port hopping and obfuscation are not needed now.** They were listed as contingent in October
  for "minute-scale UDP outages"; the four-week log shows hy2 carrying nearly every active minute.
- **hy2 has no `masquerade`.** An HTTP/3 probe of 8443 does not get a real-looking site. Cheap to
  add at the next deploy; not urgent.
- **CDN fallback does its job.** About a third of hy2's speed and 2 s per new request — acceptable
  for a path that only matters when the VPS IP is blocked. The October tuning ideas (preferred
  Cloudflare IP, port 443 through an Origin Rule, WebSocket early data) would speed up a path that
  is almost never used.

## Open items

1. **Log rotation for the sing-box container** (`logging: {driver: json-file, options: {max-size,
   max-file}}` in `vps/docker-compose.yml`). At 90 MB a day the free space lasts about three
   months; a full disk takes every path down. Needs the container recreated, so do it with the
   next deploy. Already noted as out of scope in October.
2. **Check the certificate after about 2026-12-09.** `notAfter` should move past 2027-01-08. If it
   has not by late December, read `docker logs sing-box | grep -i acme`; hy2 stops when the
   certificate expires.
3. Re-run `scripts/firewall-cdn.sh` on the VPS to drop the stale Cloudflare range (no downtime).
4. `client/render-client-config.sh` still accepts a placeholder `CDN_DOMAIN` silently (October item).
5. Optional: `masquerade` on the hy2 inbound; re-import the current profile on the second client
   network so it uses hy2 first.
