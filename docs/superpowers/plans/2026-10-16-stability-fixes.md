# mesh-router Stability Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the China-side client from flapping between dead nodes by fixing the two server-side faults that kill Reality and random outbound connections, then replacing url-test with an ordered fallback group backed by real rule sets.

**Architecture:** Three layers, fixed in order. (1) VPS sing-box: resolve and dial IPv4 only (the host has no IPv6 route) and move the Reality handshake target off www.microsoft.com, whose TLS records can exceed REALITY's 8192-byte limit. (2) Client template: `fallback` group with hy2 first, `.mrs` rule sets from meta-rules-dat, sniffer, inline overrides. (3) Optional hardening: hy2 obfuscation and port hopping, Cloudflare path tuning, Mac-exit semantics.

**Tech Stack:** sing-box v1.11.14 (Docker, host network, rendered with envsubst by `vps/bootstrap.sh`), mihomo v1.19.32 inside Clash Verge 2.5.8 (template rendered with sed by `client/render-client-config.sh`), bash, ufw.

**Spec:** `docs/2026-10-16-stability-research.md` (English summary) and the full Chinese report it links to.

## Global Constraints

- sing-box config schema stays 1.11.x; `SINGBOX_VERSION=v1.11.14` in `.env` is not bumped by this plan.
- No secrets in git: `secrets/*` stays gitignored; templates reference `${VAR}` only; rendered files and `client/rules/*.mrs` are gitignored.
- Every VPS change ships through `git pull && vps/bootstrap.sh` run by the user over SSH; the implementer prepares the commit and the verification command, the user pastes the output back. Public ports stay exactly 443/tcp, 8443/udp, 80/tcp (+2053/tcp from Cloudflare ranges only).
- Every client change ships through `client/render-client-config.sh`, then the user imports `client/clash-meta.yaml` into Clash Verge as a new local profile and deletes the old `vps` / `vps2` profiles.
- Work on branch `stability-fixes` in `D:\Code\work\mesh-router` (always `cd` there explicitly; the Claude session's cwd is a different repo). One commit per task. Commit messages end with the attribution line the harness provides.
- Mac mini is out of scope (user decision 2026-10-16); do not touch `mac-mini/`.

## Review Focus

1. Rule-set download fails on first start → CN domains must still go DIRECT through `GEOSITE,cn` (Task 4 step 6).
2. hy2 outage while reality and cdn are also dead → the fallback group must return hy2 (first) rather than reality (Task 4 step 5 asserts the order; behaviour is mihomo's `findAliveProxy()`).
3. The new Reality target later serves a record larger than 8192 bytes → the measurement command is kept in `README.md` and the target is chosen from the VPS vantage, not from the laptop (Task 3 steps 1–2).
4. `ufw reload` with a malformed `before.rules` locks the firewall → Task 6 keeps the SSH session open, checks `ufw status` before and after, and documents the rollback line.
5. Verge re-applies `ipv6: true` over the profile → the README client checklist tells the user to turn IPv6 off in the Verge UI; the template still sets `ipv6: false` so other clients are correct (Task 4 step 7).

---

### Task 1: Validation harness

**Files:**
- Create: `scripts/validate-configs.sh`
- Create: `client/probe-node.sh`
- Modify: `.gitignore` (add `client/rules/`, `client/.probe/`)

**Interfaces:**
- Produces: `scripts/validate-configs.sh [--vps] [--client]` — renders both templates with throwaway values into a temp dir, runs `sing-box check` (Docker image `ghcr.io/sagernet/sing-box:${SINGBOX_VERSION}` from `.env`; skipped with a warning when `docker` is not available) and `mihomo -t` (`$MIHOMO_BIN`, default `D:/Program/Software/Clash Verge/verge-mihomo.exe` on Windows, `mihomo` on PATH elsewhere). Exit 0 only when every available check passes. Later tasks call it as their test.
- Produces: `client/probe-node.sh <node-name> [count]` — starts an isolated mihomo on 127.0.0.1:17890 from the rendered `client/clash-meta.yaml` with a `select` group pinned to `<node-name>`, requests `https://www.gstatic.com/generate_204` `count` times (default 3), prints `http=<code>` per try and the distinct mihomo error lines, then stops. Exit 0 when every try returns 204.

- [ ] **Step 1: Write `scripts/validate-configs.sh`.** Throwaway values: UUIDs via `python -c "import uuid;print(uuid.uuid4())"` or `uuidgen`; `REALITY_PRIVATE_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=')`; `REALITY_SHORT_ID=0123456789abcdef`; `MAC_TAILSCALE_IP=100.64.0.1`; a self-signed `cdn-selfsigned.crt/key` generated into the temp `acme/` dir (same openssl line as `vps/bootstrap.sh`). Render the VPS template with `envsubst "$VARS"` using the same `VARS` list as bootstrap; render the client template by sourcing the same sed pipeline as `client/render-client-config.sh` (factor the sed into a function both scripts can call if that is simpler).
- [ ] **Step 2: Run it against the current, unchanged templates.** Run: `cd /d/Code/work/mesh-router && bash scripts/validate-configs.sh`. Expected: client check prints `configuration file ... test is successful` (mihomo's wording); VPS check prints either sing-box's silent exit 0 or `WARN: docker not available, VPS check skipped`. Exit code 0.
- [ ] **Step 3: Write `client/probe-node.sh`** (a scratch version was used during the research session; generalise it: one node, no fingerprint variants, config derived from the rendered `client/clash-meta.yaml` instead of the Verge profile, work dir `client/.probe/`).
- [ ] **Step 4: Run it against hy2.** Run: `bash client/probe-node.sh hy2-vps`. Expected: three lines `http=204`, exit 0. Run: `bash client/probe-node.sh reality-vps`. Expected today: `http=000` ×3 and the error line `connect error: EOF`, exit 1 (this is the failing test that Task 3 turns green).
- [ ] **Step 5: Commit.**

```bash
cd /d/Code/work/mesh-router && git checkout -b stability-fixes && git add scripts/validate-configs.sh client/probe-node.sh .gitignore && git commit -m "scripts: config validation harness and single-node probe"
```

### Task 2: VPS resolves and dials IPv4 only

**Files:**
- Modify: `vps/sing-box/config.json.template` (`dns` block, `direct` outbound, Reality `handshake`, `log.level`)
- Modify: `README.md` (Prerequisites: state that the VPS needs no IPv6 and that sing-box is pinned to IPv4)

**Interfaces:**
- Consumes: `scripts/validate-configs.sh --vps` from Task 1.

- [ ] **Step 1: Edit the template.** `dns.servers` becomes two DoH servers (`doh-remote` 1.1.1.1 and `doh-google` 8.8.8.8, both `"detour": "direct"`), `dns.final` stays `doh-remote`, `dns.strategy` becomes `"ipv4_only"`. Add `"domain_strategy": "ipv4_only"` to the `direct` outbound object and inside `inbounds[0].tls.reality.handshake`. Set `log.level` to `"debug"` with a comment-free note in the commit message that it goes back to `info` after Task 3 is verified.
- [ ] **Step 2: Validate.** Run: `bash scripts/validate-configs.sh --vps`. Expected: exit 0 (or the documented Docker skip). If Docker is down, note in the commit message that `bootstrap.sh` step 6 performs the same `sing-box check` on the VPS.
- [ ] **Step 3: Assert the three settings are present** (guards against partial edits): `grep -c '"ipv4_only"' vps/sing-box/config.json.template` → `3`.
- [ ] **Step 4: Commit.**

```bash
cd /d/Code/work/mesh-router && git add vps/sing-box/config.json.template README.md && git commit -m "vps: resolve and dial IPv4 only; host has no IPv6 route"
```

- [ ] **Step 5: Deploy (user, on the VPS).** `cd ~/mesh-router && git fetch && git checkout stability-fixes && git pull && cd vps && ./bootstrap.sh`. Expected: `[bootstrap] Validating sing-box config...` passes, stack restarts.
- [ ] **Step 6: Verify after 30 minutes (user pastes output).** `docker logs sing-box --since 30m 2>&1 | grep -c 'network is unreachable'`. Expected: `0`. Also `docker logs sing-box --since 30m 2>&1 | grep -c 'failed to dial dest'`. Expected: `0`.

### Task 3: Replace the Reality handshake target

**Files:**
- Modify: `secrets/vps.env.example` (`REALITY_HANDSHAKE` comment: how to pick a target, the 8192-byte record rule, the measurement command)
- Modify: `README.md` (Prerequisites paragraph on Reality: replace the "borrows a real site's TLS handshake" sentence with the selection rule and the measurement command)
- Modify: `docs/deploy-guide.html` only where it names `www.microsoft.com` as the value to enter (search first; leave the rest alone)
- Not in git: `secrets/vps.env` on the VPS and locally (`REALITY_HANDSHAKE=<chosen>`)

**Interfaces:**
- Consumes: `client/probe-node.sh reality-vps` (Task 1) as the acceptance test.
- Produces: `REALITY_HANDSHAKE` value shared by `vps/bootstrap.sh` (server `server_name` + `handshake.server`) and `client/render-client-config.sh` (client `servername`); they must stay identical.

- [ ] **Step 1: Measure candidates from the VPS (user runs, pastes output).**

```bash
for h in www.microsoft.com dl.google.com www.apple.com; do echo "== $h"; openssl s_client -connect $h:443 -servername $h -tls1_3 -alpn h2 -msg </dev/null 2>/dev/null | awk '/RecordHeader/{getline; printf "%s%s ", $4, $5} END{print ""}'; done
```

Each number is a TLS record length in hex. Expected: www.microsoft.com shows a record at or above `2000` (8192) at least intermittently; dl.google.com and www.apple.com stay around `1000`. Pick the candidate whose records are all below `2000`; if both qualify prefer dl.google.com (XTLS README's own example: handshake messages after ServerHello are encrypted).

- [ ] **Step 2: Set the value on both sides.** On the VPS and locally edit `secrets/vps.env`: `REALITY_HANDSHAKE=<chosen>`. Locally run `client/render-client-config.sh`; confirm `grep -c '<chosen>' client/clash-meta.yaml` → `1`.
- [ ] **Step 3: Deploy (user, on the VPS).** `cd ~/mesh-router/vps && ./bootstrap.sh`.
- [ ] **Step 4: Acceptance test (local).** Run: `bash client/probe-node.sh reality-vps 5`. Expected: five lines `http=204`, exit 0. On the VPS, `docker logs sing-box --since 5m 2>&1 | grep -c 'processed invalid connection'` should no longer grow while the probe runs (scanner noise from foreign IPs may still appear; filter on this machine's IP if needed).
- [ ] **Step 5: If Step 4 still fails**, run the key sanity check on the VPS and compare with the client profile: `source secrets/vps.env && docker run --rm ghcr.io/xtls/xray-core:latest x25519 -i "$REALITY_PRIVATE_KEY"` — the printed public key must equal `public-key` in `client/clash-meta.yaml`. Mismatch → re-render the client from the VPS values. Match → test the vless share link in the sing-box desktop app or v2rayN and read the debug log for the Reality rejection reason. Stop and report; do not change the target again blindly.
- [ ] **Step 6: Docs and commit.** Update the three doc locations; set `log.level` back to `"info"` in the VPS template.

```bash
cd /d/Code/work/mesh-router && git add secrets/vps.env.example README.md docs/deploy-guide.html vps/sing-box/config.json.template && git commit -m "reality: pick a handshake target whose TLS records fit REALITY's 8192-byte limit"
```

### Task 4: Client template: fallback group, rule sets, sniffer

**Files:**
- Modify: `client/clash-meta.yaml.template` (replace `dns`, `proxy-groups`, `rule-providers`, `rules`; add `sniffer`; rewrite the header comments)
- Delete: `client/direct-extra.list`
- Modify: `client/render-client-config.sh` (drop the two `direct-extra.list` echo lines; add: download the three `.mrs` files into `client/rules/` if missing and print the instruction to copy `rules/` next to the imported profile)
- Modify: `README.md` (Repository layout row for the client template; Quickstart step 4; new "Client host checklist" subsection: import new profile, delete `vps` / `vps2`, Verge Settings → IPv6 off, TUN stack `mixed`, where `rules/` must live)

**Interfaces:**
- Consumes: `scripts/validate-configs.sh --client`, `client/probe-node.sh`.
- Produces: proxy group `PROXY` of type `fallback`, order `hy2-vps, reality-vps, cdn-fallback`; rule providers `direct-extra` (inline), `cn-domain`, `cn-ip`, `ads` (mrs, jsDelivr `@meta` / adrules.top, `path: ./rules/<name>.mrs`, `interval: 86400`, `proxy: DIRECT`).

- [ ] **Step 1: Write the new sections exactly as in the Chinese report §6.3** (dns with `default-nameserver: [223.5.5.5, 119.29.29.29]`, nameservers `https://dns.alidns.com/dns-query` and `https://doh.pub/dns-query`, `fake-ip-filter` with `geosite:cn`, `rule-set:cn-domain`, `rule-set:direct-extra`; `sniffer` TLS 443/8443, HTTP 80, QUIC 443; group `fallback`, `expected-status: 204`, `interval: 60`, `lazy: false`, no `tolerance`, no `timeout`, no `max-failed-times`; rules in this order: `GEOIP,private,DIRECT,no-resolve`, `RULE-SET,direct-extra,DIRECT`, `RULE-SET,ads,REJECT`, `RULE-SET,cn-domain,DIRECT`, `GEOSITE,cn,DIRECT`, `RULE-SET,cn-ip,DIRECT,no-resolve`, `MATCH,PROXY`). Keep `proxies` untouched. If Task 3 is not yet verified when this task runs, put `reality-vps` last and leave a comment saying when to move it up.
- [ ] **Step 2: Remove `client/direct-extra.list` and its mentions**; add the rule-file pre-seed to `render-client-config.sh` (curl the three URLs into `client/rules/`, skip when present, never fail the render if the download fails — print a warning instead).
- [ ] **Step 3: Validate.** Run: `bash scripts/validate-configs.sh --client`. Expected: `test is successful`, exit 0. If mihomo tries to fetch providers during `-t`, run Step 2's pre-seed first and point the validator's temp dir at `client/rules/`.
- [ ] **Step 4: Probe through the group.** Run: `bash client/probe-node.sh PROXY`. Expected: `http=204` ×3.
- [ ] **Step 5: Assert the order.** `awk '/^proxy-groups:/,/^rule-providers:/' client/clash-meta.yaml.template | grep -A4 'proxies:' | grep -E '^\s+- ' | head -1` → `      - hy2-vps`.
- [ ] **Step 6: Offline safety net test.** Copy the rendered config to a temp dir with an empty `rules/` directory and the three provider URLs replaced by `http://127.0.0.1:9/x`; start mihomo on 17890 with `log-level: info`; `curl -x http://127.0.0.1:17890 http://www.baidu.com -o /dev/null`; the log must contain `match GeoSite(cn) using DIRECT` for `www.baidu.com`. Expected: the line is present, i.e. CN traffic stays direct when every rule set is empty.
- [ ] **Step 7: README updates** (layout row, Quickstart, client host checklist).
- [ ] **Step 8: Commit.**

```bash
cd /d/Code/work/mesh-router && git add client/clash-meta.yaml.template client/render-client-config.sh README.md && git rm client/direct-extra.list && git commit -m "client: fallback group, meta-rules-dat rule sets, sniffer; drop file-based overrides"
```

- [ ] **Step 9: Hand-over (user).** Import `client/clash-meta.yaml` into Clash Verge as a new local profile, copy `client/rules/` into Verge's config directory, select the new profile, delete `vps` and `vps2`, turn IPv6 off and set the TUN stack to `mixed` in Verge Settings. Observe for 24 h: in Verge's log view count `activate health check` lines (target: fewer than 5 per day) and confirm `using PROXY[hy2-vps]` dominates.

### Task 5: Observation gate before hardening

- [ ] **Step 1:** After 24 h of Task 4, record in `docs/2026-10-16-stability-research.md` (new "Results" section): count of `activate health check`, distribution of `using PROXY[...]`, any `connect error` lines, and the VPS `network is unreachable` count. Commit as `docs: 24h results after P0`.
- [ ] **Step 2:** Decide with the user which of Tasks 6–8 to run. Task 6 only if hy2 showed probe failures or stalls during peak hours; Task 7 only if cdn-fallback was actually used; Task 8 only after the peak-hour line test.

### Task 6 (P2, gated): Hysteria2 obfuscation and port hopping

**Files:**
- Modify: `vps/sing-box/config.json.template` (hy2 inbound: `"ignore_client_bandwidth": true`, `"obfs": {"type": "salamander", "password": "${HY2_OBFS_PASSWORD}"}`)
- Modify: `vps/bootstrap.sh` (`REQUIRED` and `VARS` gain `HY2_OBFS_PASSWORD`)
- Modify: `scripts/gen-secrets.sh` (generate `HY2_OBFS_PASSWORD`), `secrets/vps.env.example`
- Modify: `scripts/firewall.sh` (install the `*nat` REDIRECT block into `/etc/ufw/before.rules` idempotently; do NOT add a `ufw allow` for the range)
- Modify: `client/clash-meta.yaml.template` (`ports: 20000-20999`, `hop-interval: 30`, `obfs: salamander`, `obfs-password: ${HY2_OBFS_PASSWORD}`) and `client/render-client-config.sh`, `client/render-share-links.sh` (add `obfs=salamander&obfs-password=` to the hy2 URI)

- [ ] **Step 1:** Edit templates and scripts; `bash scripts/validate-configs.sh`. Expected: exit 0.
- [ ] **Step 2:** `before.rules` block (interface from `ip route get 1.1.1.1`):

```
*nat
:PREROUTING ACCEPT [0:0]
-A PREROUTING -i eth0 -p udp --dport 20000:20999 -j REDIRECT --to-ports 8443
COMMIT
```

`firewall.sh` inserts it before the first `*filter` line only if the marker comment `# mesh-router hy2 port hopping` is absent. Rollback line in the script header: delete the block and `ufw reload`.
- [ ] **Step 3: Deploy (user):** `scripts/gen-secrets.sh` is NOT re-run (it would rotate every secret); instead add `HY2_OBFS_PASSWORD=$(openssl rand -hex 16)` to `secrets/vps.env` on both sides, `./bootstrap.sh`, `sudo ../scripts/firewall.sh`, keep the SSH session open, `sudo ufw status | head -5` before and after, `sudo iptables -t nat -L PREROUTING -n | grep 8443`.
- [ ] **Step 4: Verify:** re-render the client, `bash client/probe-node.sh hy2-vps 5` → `http=204` ×5; `scripts/check-tailscale-direct.sh` on the VPS still prints `OK: direct connection`.
- [ ] **Step 5: Commit** `hy2: salamander obfs, narrow port hopping range via ufw nat, pin BBR`.

### Task 7 (P2, gated): Cloudflare fallback tuning

**Files:**
- Modify: `vps/sing-box/config.json.template` (ws transport: `"max_early_data": 2048`, `"early_data_header_name": "Sec-WebSocket-Protocol"`)
- Modify: `client/clash-meta.yaml.template` (`ws-opts.max-early-data: 2048`, `early-data-header-name: Sec-WebSocket-Protocol`; keep cdn-fallback last in the group)
- Modify: `docs/cloudflare-fallback.md` (CloudflareSpeedTest procedure `cfst -tp 2053 -tl 200 -dn 10`, Origin Rule to serve 443, note that Cloudflare closes idle WebSockets so SSH must not use this path)

- [ ] **Step 1:** Edit, `bash scripts/validate-configs.sh` → exit 0.
- [ ] **Step 2: Deploy (user)** `./bootstrap.sh`; re-render client.
- [ ] **Step 3: Verify:** `bash client/probe-node.sh cdn-fallback 5` → `http=204` ×5 both before and after enabling early data (the change must not break the path).
- [ ] **Step 4: Commit** `cdn: ws early data on both ends; document preferred-IP selection`.

### Task 8 (P3): Line test runbook and VPS leftovers

**Files:**
- Modify: `README.md` (Runbook D: peak-hour line test — TUN off, 20:00–23:00, `ping -n 100`, `tracert -d`, thresholds 5 % loss / 300 ms, what the 202.97.x → 129.250.x hops mean)
- Modify: `vps/sing-box/config.json.template` (`mac-auto.tolerance` 100 → 1000; a comment next to `sniff` noting it is deprecated in 1.12 and becomes `route.rules` `action: sniff` before any image bump)

- [ ] **Step 1:** Edit, `bash scripts/validate-configs.sh --vps` → exit 0.
- [ ] **Step 2: Commit** `docs: peak-hour line test runbook; vps: prefer-mac tolerance, sniff deprecation note`.
- [ ] **Step 3:** No deploy needed until the Mac exists; the user runs the line test and records results in the research doc.
