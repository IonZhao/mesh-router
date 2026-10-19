# Stability research: why the client keeps dropping (2026-10-16)

English summary of the full report (Chinese, Claude Doc):
https://claude.ai/code/artifact/af0ce6eb-a7e7-44d8-9633-e5bd5dfe7460

The implementation plan derived from this document is
`docs/superpowers/plans/2026-10-16-stability-fixes.md`.

## What is actually deployed (differs from README assumptions)

| Component | README assumption | Reality |
|---|---|---|
| VPS | Tokyo or US-West CN2 GIA | Los Angeles, AS2914 NTT America (Huawei Cloud ECS); path from China Telecom is 163 backbone (202.97.x) → NTT (129.250.x), no CN2 |
| VPS IPv6 | not stated | no IPv6 route; sing-box still dials IPv6 addresses |
| Mac mini exit | deployed, `mac-auto` prefers it | never joined the tailnet; `MAC_TAILSCALE_IP` is still the placeholder; `trusted-exit` always falls to `direct` (deferred by decision) |
| Client | rendered from the current template | Clash Verge 2.5.8 (mihomo v1.19.32) on the Windows box, running the profile rendered on 2026-06-12: `url-test` group, built-in geosite rules only; the uncommitted template changes were never imported |
| Cloudflare fallback | optional, dark | configured (`<CDN_DOMAIN>:2053`) and auto-selected by url-test |

## Evidence

| Source | Finding |
|---|---|
| mihomo core logs 2026-09-25 03:52–04:56 (one hour) | 2943 × `<VPS_HOST>:443 connect error: EOF` and 106 timeouts while reality-vps was selected, 0 successful reality connections; hy2 1255 ok / 0 failures; cdn 211 ok / 1 failure; 612 × `because PROXY failed multiple times, activate health check`; EOF bursts at 04:20–04:25 and 04:52–04:54 |
| mihomo source `adapter/outboundgroup/urltest.go` `fast()` | the group starts from `proxies[0]` (reality-vps) and only an *alive* proxy can replace it, so when hy2 and cdn probes both fail, traffic goes to reality even though it is dead. `fallback.go` `findAliveProxy()` has the same "first proxy when none alive" rule |
| VPS `docker logs sing-box` 2026-10-15 18:03–18:15 UTC | every Reality connection from the client machine's public IP (one per ~120 s = the url-test probe) ends in `REALITY: processed invalid connection`; six `REALITY: failed to dial dest: dial tcp [2600:1406:…]:443: network is unreachable`; 60+ `connection: open outbound connection: dial tcp [2a06:98c1… / 2606:4700… / 2001:4860… / 2607:6bc0…]:443: network is unreachable` for ordinary traffic (Cloudflare, Google, Akamai) |
| VPS Clash API `/proxies` | `mac-out` never alive; `mac-auto` and `trusted-exit` on `direct`; `direct` probe to gstatic 725 ms (LA → Google should be single-digit ms) |
| Local reproduction (isolated mihomo v1.19.32 forced to reality-vps, 2026-10-16 02:49–02:51 CST) | chrome / firefox / safari / random fingerprints and `support-x25519mlkem768: true` all fail with immediate EOF (22–25 per 20 s); local secrets match the profile's public-key / short-id / uuid / servername |
| SagerNet/reality `tls.go` (sing-box's REALITY server) | `size = 8192`; `Server()` dials the handshake target *before* reading the ClientHello and closes the client on dial failure; for an authenticated client it parses the target's ServerHello/Certificate records and closes the connection if any record exceeds `size`, logging `processed invalid connection` either way |
| openssl from this machine | www.microsoft.com Certificate record 5919 bytes (varies by Akamai edge; a 2025 community report measured 8273 bytes with exactly this symptom); dl.google.com max 3695; www.apple.com max 3370 |
| Direct path, TUN off, 02:10 CST | ping 186 ms, 0 % loss; TLS to the VPS with SNI www.microsoft.com relays Microsoft's 200 (non-Reality connections are forwarded normally) |

## Root causes (ranked)

1. **VPS resolves to IPv6-only address lists and the host has no IPv6 route.** Breaks the Reality handshake-target dial (client sees EOF) and a share of ordinary outbound connections on every path. Fix: `dns.strategy: ipv4_only` plus `domain_strategy: ipv4_only` on the `direct` outbound and the Reality `handshake`.
2. **Reality handshake target www.microsoft.com serves TLS records larger than REALITY's 8192-byte limit** (from the VPS vantage), so authenticated handshakes are closed and logged as invalid. Fix: measure candidates from the VPS with `openssl s_client -msg`, switch `REALITY_HANDSHAKE` to a site whose records are all below 0x2000 (dl.google.com or www.apple.com measured small; self-steal with Caddy is the long-term option). Confirmation command is in the plan (Task 3).
3. **Client PROXY group is `url-test`**, which falls back to the first listed proxy when nothing is alive and flaps between heterogeneous paths. Fix: `fallback` with hy2 first, `expected-status: 204`, default `timeout` / `max-failed-times`.
4. **Client runs a stale profile**; nothing in the repo reaches Clash Verge until it is re-rendered and imported.
5. **Routing relies only on built-in `geosite:cn`**; `GEOIP,CN,no-resolve` never matches domain traffic under fake-ip; no external rule sets. Fix: meta-rules-dat `.mrs` sets + AdRules, inline overrides, sniffer; keep `no-resolve` (privacy contract in the template header).
6. hy2 has minute-scale UDP outages; no port hopping or obfuscation (P2, contingent).
7. cdn-fallback: no preferred Cloudflare IP, port 2053, no WS early data, idle close (P2).
8. Line quality (163 → NTT) unverified at peak hours (P3).
9. `mac-auto` urltest tolerance 100 can never prefer the Mac (P3, Mac deferred).
10. Minor: uncommitted `GEOSITE,geolocation-cn` rule is a no-op (v2fly `cn` already includes it); Verge forces `ipv6: true`; gvisor stack; occasional DoH failures.

## Decisions taken (independent review 2026-10-16 folded in)

- Keep `RULE-SET,cn-ip,DIRECT,no-resolve`; do not resolve foreign domains locally.
- Keep mihomo defaults `timeout: 5000`, `max-failed-times: 5`; a 3 s timeout with 2 failures would move all new dials off hy2 on one missed probe.
- `GEOSITE,cn` stays as a safety net under `RULE-SET,cn-domain` so a failed rule-set download does not send CN traffic abroad.
- Do not open 20000–50000/udp in ufw; a REDIRECT in PREROUTING only needs the existing 8443/udp allow. Narrow range 20000–20999, rule lives in `/etc/ufw/before.rules` `*nat`.
- Server sets `ignore_client_bandwidth: true` to pin BBR.
- Reality target replacement is P0; self-steal / neighbour scanning is P2 hardening, scanned locally, never from the VPS.
- Mac mini stays out of scope until it is deployed.

## Rule-set sources verified live on 2026-10-16

MetaCubeX/meta-rules-dat `meta` branch (`geo/geosite/cn.mrs`, `geo/geoip/cn.mrs`, `geo/geosite/geolocation-!cn.mrs`, daily 06:30 Beijing; jsDelivr `@meta` mirror serves identical bytes), Cats-Team/AdRules `adrules-mihomo.mrs` (every 6 h; adrules.top mirror), privacy-protection-tools/anti-AD, Loyalsoldier/clash-rules, blackmatrix7/ios_rule_script, DustinWin/ruleset_geodata (details and caveats in the Chinese report §3.4).

## Open questions

- Record sizes of www.microsoft.com as seen *from the VPS* (one openssl command, plan Task 3 step 1).
- Whether the VPS copy of `secrets/vps.env` matches the local one (`xray x25519 -i` check, plan Task 3).
- Peak-hour loss on the 163 → NTT path (plan Task 8).

## Implementation record (branch `stability-fixes`, 2026-10-16)

Executed inline against `docs/superpowers/plans/2026-10-16-stability-fixes.md`; Tasks 1–4 and 8 done, Tasks 5–7 gated on the 24 h observation. Offline suite `scripts/test-configs.sh`: 29 passed. A fresh whole-branch review returned "with fixes"; all Critical/Important findings were fixed test-first, including scrubbing deployment identifiers from this file's first version (the branch history was rewritten before any push).

Additional evidence gathered while implementing:

- api.anthropic.com's IPv6 address is one of the targets in the VPS's `network is unreachable` lines; through hy2 it currently fails while google.com and github.com work. The IPv4-only change is the fix.
- From the client machine, www.microsoft.com measured max record 5919 / flight 6470 bytes (PASS), so the oversized-record hypothesis is unconfirmed from China; the VPS run of `scripts/check-reality-target.sh` decides.
- With no cached rule file and unreachable mirrors, mihomo v1.19.32 holds all connections for ~1–6 s at start (502 at 1 s, routed at 6 s). Pre-downloading `client/rules/` avoids it.
- With the real rule sets: bilibili / jd / baidu → `RuleSet(cn-domain)` DIRECT, the override list → DIRECT, doubleclick → `RuleSet(ads)` REJECT, google / github / anthropic → `PROXY[hy2-vps]`. `update.hwdns.net` still goes to PROXY (candidate for `direct-extra`).

Decisions that deviate from the plan (each: what — why — cost if wrong):

- No second DNS server — sing-box 1.11 never queries a server that neither `final` nor a rule references — none; if debug logs show A-query failures, they need a real resolver fix.
- Log level is `${SINGBOX_LOG_LEVEL}` (default `info`) instead of a committed `debug` — Docker's json log is not rotated — the variable must be passed when diagnosing.
- Fallback order fixed at hy2 → reality → cdn — a dead reality is never "alive" with `expected-status: 204`, and this avoids a second re-import — if reality's probe passes while dials fail, hy2 outages briefly route to it.
- The plan's inline openssl measurement became `scripts/check-reality-target.sh` with fixture tests, adding TLS 1.3 / X25519 / h2 / certificate checks and a whole-flight limit — may reject a target REALITY would usually accept (conservative).
- Example and deploy-guide default `REALITY_HANDSHAKE` is `dl.google.com`; local and VPS secrets are unchanged until the VPS measurement — none; one-line change.
- `GEOIP,CN,DIRECT,no-resolve` added after `cn-ip` (review finding) — a CN IP with no rule-set file would otherwise go abroad — none.
- Sing-box deprecation notes live in README "Version pinning" (the template is strict JSON) — none.
- Stale "url-test" wording also corrected in `docs/cloudflare-fallback.md` and `docs/deploy-guide.html` — none.

Deferred minor findings: no test asserts which node the group picks when every node is dead; `client/probe-node.sh` should be run with the client's TUN off and its fixed 120 s timeout cuts very long runs; the template comment credits jsDelivr for the ads list (it is adrules.top); the suite header says "no network" although the client runtime cases dial baidu/tuna (they pass offline via dial-error lines); the checker does not verify the ChangeCipherSpec record. Pre-existing and out of scope: README says "2 inbounds" (there are 3); `cache_file.path` is not under the compose volume, so the `trusted-exit` selection resets on restart; Docker log rotation.

Pending user steps: deploy the branch on the VPS (`./bootstrap.sh`), confirm `network is unreachable` → 0; run `scripts/check-reality-target.sh dl.google.com www.apple.com www.microsoft.com` on the VPS and set `REALITY_HANDSHAKE` to a PASS target on both sides; `client/probe-node.sh reality-vps 5` → 5/5; import the new client profile (README "Client host checklist"); observe 24 h (Task 5); peak-hour line test (README Runbook D).

## sing-box 1.14 upgrade (branch `singbox-1.14`, 2026-10-19)

Measurements after PR #1 was deployed on 2026-10-16 (the owner ran `bootstrap.sh`; the assistant then worked on the VPS over SSH with a dedicated key):

- `network is unreachable`: 0 in the sing-box log after the IPv4-only change. hy2 3/3 and the CDN path work from the client with the new profile (fallback group, rule sets).
- The Reality handshake-target hypothesis is **refuted**: from the VPS, `scripts/check-reality-target.sh` reports PASS for all three README candidates, dl.google.com (max record 3695), www.apple.com (3266) and www.microsoft.com (5919, flight 6470), including the configured target. `REALITY_HANDSHAKE` is unchanged on both sides.
- Reality still failed: every client connection ended as `REALITY: processed invalid connection`, the client saw `connect error: EOF`. Ruled out in order: secrets differ between the two machines (sha256 of uuid, short id, public key, handshake target and private key match; an earlier apparent mismatch was a trailing newline in the comparison command), public key not the pair of the private key (derived offline: it is), running config differs from secrets (same hashes), client fingerprint (chrome, firefox, safari, ios, random all fail), path or client (a sing-box 1.11.14 client on the VPS itself against 127.0.0.1:443 fails the same way), key material (a throwaway server with a freshly generated pair fails too).
- The blocker is the server version. In throwaway containers with the production keys and target: a v1.14.3 server passes the self-test 3/3 with a 1.14.3 client and 3/3 with a 1.11.14 client; the Windows client's real profile (mihomo v1.19.32, pointed at the throwaway over Tailscale) gets 5/5; a 1.11.14 server rejects even a 1.14.3 client. v1.13.21 refuses the current config at start (legacy DNS servers need `ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true`), v1.14.3 refuses it outright, so the upgrade is a config migration, not a version bump.

What the branch changes (the suite asserts each item, so a later deprecation fails loudly):

- `.env`: `SINGBOX_VERSION=v1.14.3`. `vps/bootstrap.sh` now reads the pin from `.env` and validates with exactly that image (it used to hard-code v1.11.14 in its `check` step, which would have rejected the migrated config).
- `vps/sing-box/config.json.template` in the 1.12+ schema: typed DNS server (`"type": "https"`, no `detour`), `route.default_domain_resolver` with `ipv4_only` replacing the Dial Field `domain_strategy` on the direct outbound and the Reality handshake, the inbound `sniff` fields replaced by a first `route.rules` entry `{"action": "sniff"}`, the Hysteria2 certificate from an ACME `certificate_providers` entry instead of inline `tls.acme` (same data directory; the dry run below found the existing certificate without re-issuing).
- `scripts/validate-configs.sh` also starts the rendered config for a moment on loopback high ports and waits for `sing-box started`. Reason: the first migrated template passed `check` and died at start with `start dns/https[doh-remote]: detour to an empty direct outbound makes no sense`; `check` only decodes. The suite has a regression case for exactly that config.
- README "Version pinning" and "Validating locally" updated; the `.tools/` convention is unchanged (the suite looks for `sing-box-1.14.3-<platform>/`).

Dry run on the VPS before any deploy (v1.14.3 container, the migrated config rendered from the real secrets, all listeners on 127.0.0.1 with shifted ports, a copy of the ACME state, sing-box clients on the same host): `check` ok, `sing-box started (0.60s)`, Reality 3/3, Hysteria2 3/3 with certificate verification against the real domain, CDN inbound 3/3, Clash API answering `sing-box 1.14.3`, no errors; the ACME provider reported background maintenance only. Production kept running v1.11.14 throughout.

Deploy plan (owner's go needed): merge, then on the VPS `git pull && cd vps && ./bootstrap.sh` (pulls v1.14.3, checks, `up -d`, restarts sing-box; hy2 is down for about a minute; the `trusted-exit` selection resets because the cache file lives inside the container, not under the compose volume, so there is no cache-format concern either). Verify: `docker logs sing-box --since 5m` shows `sing-box started` and no FATAL; `docker logs sing-box --since 10m | grep -c 'network is unreachable'` stays 0 (the original symptom); from the client `client/probe-node.sh reality-vps 5` → 5/5 and `hy2-vps 3` → 3/3; the Verge fallback group should then sit on hy2-vps with reality-vps alive. The first certificate renewal (about 30 days before expiry) is the first time the new provider's issuance path runs on the VPS; the provider obtains asynchronously, so a failure (challenge flags, key type) shows only in `docker logs sing-box | grep -i acme`, worth a look at that time. Rollback: set `SINGBOX_VERSION=v1.11.14` and check out the previous template, `./bootstrap.sh` again; that restores the status quo ante (hy2 and CDN up, Reality still broken). The old image stays on the host only until an image prune.

Deployed 2026-10-19 02:20 UTC (PR #3 merged as c06aae9; `git pull && ./bootstrap.sh` on the VPS, about one minute of hy2 downtime). Outcome: v1.14.3 running, `sing-box started (0.80s)`, 0 FATAL, 0 `network is unreachable`, 0 `invalid connection`; Reality self-test from the VPS 3/3; from the Windows client the real profile gets 5/5 over Tailscale, and the client's own 60-second Reality health checks complete on the public path (the VPS log shows them reaching the test URL); hy2 carried the owner's traffic throughout (hundreds of inbound connections per 5 minutes). Two notes: (1) v1.14 logs `connection download closed: stream N canceled by remote with error code 0` at ERROR level for ordinary hy2 stream cancellations; `scripts/singbox-log-alert.sh` counts ERROR lines only as information, not as an alert condition, so nothing fires, but the count is now noisy. (2) `client/probe-node.sh` must not be run with `PROBE_IGNORE_TUN=1` against the public address: the client's TUN captures the probe, its sniffer overrides the destination with the Reality SNI, and the probe reports `REALITY authentication failed` for a server that is fine; the override is only valid for tailnet targets, which bypass TUN.

Client-side finding during verification: the local `secrets/vps.env` still had the placeholder `CDN_DOMAIN`, so the profile rendered on 2026-10-16 carried a dead `cdn-fallback` node (the June profile had the real domain). The value was synced from the VPS secrets (hash-compared, never displayed), the profile re-rendered, validated with mihomo and written to Verge again; it takes effect when the profile is re-activated. The render script accepts a placeholder silently (`cdn.invalid` default); it should warn or drop the node. Open item.
