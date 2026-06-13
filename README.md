# mesh-router

Personal two-layer cross-border network. **VPS = control plane** (sing-box, the single
routing brain). **US Mac mini = trusted residential exit** (sing-box, pure egress, zero routing).
Client = Clash Meta doing geo split only. Connected by Tailscale (application-layer chaining, not
L3 NAT). Fully reproducible from this repo.

> Design rationale and decision log: [`../docs/2026-06-10-mesh-routerwork-design.md`](../docs/2026-06-10-mesh-routerwork-design.md)
> **New to this? Use the click-by-click walkthrough:** [`docs/deploy-guide.html`](docs/deploy-guide.html) (open in a browser).

```
Client (China, Clash Meta)        geo split: CN -> direct, else -> VPS
   │  VLESS+Reality :443 (primary) / Hysteria2 :8443 (backup)
   ▼
VPS (any region, sing-box)        trust split: sensitive -> trusted-exit, else -> direct
   ├── direct  (datacenter egress)
   └── mac-out (VLESS over Tailscale)
          ▼
       Mac mini (US residential, sing-box)   inbound -> direct, ZERO rules
          ▼
       Residential ISP egress
```

## Prerequisites (read first)

- **A domain you own.** Required for Hysteria2's TLS cert (auto-issued via Let's Encrypt) and
  the dashboards. ~$10/yr. Point an A record (e.g. `static.yourdomain.com` — pick a boring,
  innocuous name; **avoid words like `proxy`/`vpn`**, since the hostname lands in public
  Certificate Transparency logs and the Hysteria2 TLS SNI) at the VPS IP. Reality
  (port 443) does *not* use your domain — it borrows a real site's TLS handshake.
- **A VPS — region is your call.** Tokyo gives the lowest everyday-browsing latency from China;
  a US-West box (CN2 GIA) shortens the hop to the US residential exit, better if AI traffic
  dominates. Either works — the configs are region-agnostic; just set `VPS_HOSTNAME` in `.env`.
  2 vCPU / 2–4 GB RAM / ≥2 TB traffic is plenty (a proxy hub is network-bound, not CPU-bound) —
  spend the budget on route quality, not cores. Debian/Ubuntu.
- **A Mac mini on a US residential connection**, powered on and online.
- **A Tailscale account** (free tier is fine) — used as the private link *and* the out-of-band
  rescue channel to the Mac.
- Docker Engine + compose plugin on the VPS; Homebrew on the Mac.
- Optional but recommended: `sops` + `age` for encrypted secrets in git.

## Repository layout

| Path | What |
|---|---|
| `vps/docker-compose.yml` | sing-box + tailscale + netdata + uptime-kuma + vnstat (all host-networked) |
| `vps/sing-box/config.json.template` | 2 inbounds (Reality, Hysteria2), the `trusted-exit` selector, route rules |
| `vps/rulesets/` | `sensitive-domains.json` (→ residential), `api-domains.json` (→ direct) |
| `vps/bootstrap.sh` | fresh VPS → running stack |
| `mac-mini/setup.sh` | fresh macOS → running exit node (brew + launchd, no Docker) |
| `mac-mini/sing-box/config.json.template` | single Tailscale-only inbound → direct |
| `client/clash-meta.yaml.template` | fake-ip, CN-direct, Reality/Hysteria2 url-test group (Clash.Meta clients) |
| `client/render-share-links.sh` | share-link URIs + base64 subscription for non-Clash clients (Shadowrocket, v2rayN, sing-box…) |
| `scripts/gen-secrets.sh` | generate UUIDs, Reality keypair, passwords |
| `scripts/firewall.sh` | ufw: only proxy ports public; admin via Tailscale only |
| `scripts/firewall-cdn.sh` | open the CDN fallback port (2053) to Cloudflare IPs only (optional) |
| `scripts/check-tailscale-direct.sh` | alert if the VPS↔Mac link drops to a DERP relay |
| `docs/cloudflare-fallback.md` | optional emergency path that survives the VPS IP being blocked |
| `secrets/*.env.example` | secret templates (real secrets live OUTSIDE this repo — see "Code delivery & disaster recovery") |

## Quickstart

```bash
git clone <repo> && cd mesh-router

# 1. Generate secrets (needs Docker), then fill in the human fields it lists.
scripts/gen-secrets.sh
#    edit secrets/vps.env : STATIC_DOMAIN, ACME_EMAIL, REALITY_HANDSHAKE, TS_AUTHKEY, VPS_HOST
#    edit secrets/mac.env : TS_AUTHKEY (a second, separate auth key)

# 2. Mac mini first — it prints its Tailscale IP for the next step.
#    (on the Mac)
cd mac-mini && ./setup.sh
#    copy the printed MAC_TAILSCALE_IP into secrets/vps.env

# 3. VPS.
#    (on the VPS)
cd vps && ./bootstrap.sh
sudo ../scripts/firewall.sh

# 4. Client config.
cd client && ./render-client-config.sh   # produces clash-meta.yaml -> import into a Clash.Meta client
#    OR for non-Clash clients (Shadowrocket, v2rayN, sing-box apps):
#    ./render-share-links.sh              # produces share-links.txt + subscription.txt (local import)
```

Validate before/after: `docker compose run --rm sing-box check -c /etc/sing-box/config.json`.

## Code delivery & disaster recovery

Both machines get the code by **cloning this repo with git** — that's the whole reproducibility
story. Secrets are the one thing that must NOT live in a public repo, so they travel separately.

**Two-repo model (recommended if you open-source this):**

| Repo | Visibility | Contents | How it reaches a machine |
|---|---|---|---|
| `<this-repo>` | public OK | all code, templates, examples, docs — **no real secrets, no real domain/IP** | `git clone https://github.com/<you>/<repo>` |
| `<this-repo>-secrets` | **private** | your `secrets/vps.env.enc` + `secrets/mac.env.enc` (sops-encrypted) | `git clone git@github.com:<you>/<repo>-secrets secrets-private` then copy/symlink into `secrets/`, or clone directly into `secrets/` |

The real `STATIC_DOMAIN`, `VPS_HOST`, keys, and passwords exist **only** in the private secrets
(or your password manager). That's why the public repo is safe to publish as-is.

**Full recovery from scratch (e.g. rebuilding a wiped VPS):**

```bash
git clone https://github.com/<you>/<repo> && cd <repo>
git clone git@github.com:<you>/<repo>-secrets secrets   # or restore your sops .enc files into secrets/
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt     # the age private key from your password manager
cd vps && ./bootstrap.sh                                  # bootstrap auto-decrypts *.env.enc via sops
sudo ../scripts/firewall.sh
```

Same on the Mac: `git clone … && cd mac-mini && ./setup.sh`. With the age key in hand, **clone +
one command = a fully restored node** — no manual file copying, nothing to remember.

**Private-repo access on a server** (for `git clone`/`git pull` of a private repo): add a GitHub
**deploy key** (read-only SSH key per machine) or a fine-grained PAT. Don't reuse your personal key.

**Updating after you change configs:** commit & push, then on each machine
`git pull && ./bootstrap.sh` (VPS) or `git pull && ./setup.sh` (Mac). Both scripts are idempotent —
they re-render configs and recreate only what changed.

> Simpler alternative if you're *not* open-sourcing yet: keep one **private** mono-repo with the
> sops `.enc` files committed in `secrets/` (flip the `.gitignore` rule back to allow `*.enc`). Then
> `git clone` alone restores everything. Split out a sanitized public repo later when you're ready.

## Two exit modes (switch at runtime, no redeploy)

Sensitive traffic always routes to the **`trusted-exit` selector** outbound. Route rules never
change; you change which *member* is active:

| Member | Behaviour | Mode |
|---|---|---|
| `mac-auto` *(default)* | prefer Mac mini, **fail open to VPS direct** if it's down | A — residential |
| `mac-out` | pin to Mac mini, fail closed | A — strict |
| `direct` | VPS's own IP | B — VPS-direct |

**Switch:** open the dashboard (`http://<vps-tailscale-ip>:9090/ui`, secret = `CLASH_API_SECRET`),
pick the `trusted-exit` group, click a member. Takes effect immediately; the choice persists across
restarts (`cache_file`). For a permanent default, also change `"default"` in the template and re-run
bootstrap. In Mode B the Mac tunnel + monitoring stay up, just unused — flip back in one click.

This is also the failover policy: `mac-auto` means **availability over IP purity** — if the Mac is
unreachable, sensitive traffic degrades to the datacenter IP rather than breaking. Uptime Kuma alerts
you so the degradation is never silent.

## Observability (all Tailscale-only)

**Four dashboards, each a different lens.** None are exposed publicly — reach them over Tailscale
(the VPS's `100.x` address: `docker exec tailscale tailscale ip -4`). The firewall blocks these ports
on the public IP.

| Tool | URL | What it shows |
|---|---|---|
| **metacubexd** (sing-box Clash API) | `http://<vps-ts-ip>:9090/ui` | Live connections + **which outbound each took**, per-node latency, real-time up/down per connection, the `trusted-exit` selector (switch exit mode here) |
| **Netdata** | `http://<vps-ts-ip>:19999` | Real-time (per-second) **CPU** (total / per-core / per-container), **memory + swap**, **per-interface network** rates, disk I/O |
| **Uptime Kuma** | `http://<vps-ts-ip>:3001` | Up/down history + **alerting** for whatever monitors you add (e.g. the Mac exit) |
| **vnStat** | `http://<vps-ts-ip>:8685` | Cumulative **per-interface traffic**, daily/monthly totals (quota tracking) |

**Where do I find metric X?**

| I want to see… | Go to |
|---|---|
| CPU / RAM / load %, per-container resource use | **Netdata** (`:19999`) |
| Which exit a connection used; per-exit / live throughput; verify the split | **metacubexd** (`:9090/ui`) |
| Is the Mac exit (or a host) up; get alerted when it drops | **Uptime Kuma** (`:3001`) |
| Monthly traffic vs. provider quota | **vnStat** (`:8685`) or CLI `docker exec vnstat vnstat -m` |

> Note: per-container **network** attribution isn't available (all containers use host networking, so
> network is measured per-interface). Per-container **CPU/memory** work fine; for per-exit traffic use
> metacubexd.

After first boot, add an Uptime Kuma monitor: **TCP Port**, host = Mac mini Tailscale IP, port `18443`,
interval 60s, plus a notification. Optionally cron `scripts/check-tailscale-direct.sh` for DERP alerts.

**Netdata access note.** The new Netdata UI nudges you to sign in to Netdata Cloud — you don't need it;
the agent collects everything locally regardless. Use the **local, no-account** path: when prompted, run
`docker exec netdata cat /var/lib/netdata/netdata_random_session_id` and paste the token. Don't sign in
with Google — that ships your metrics to a third party (and links this box to your identity). Netdata
keeps metrics at three resolutions, automatically: **tier0** per-second (short retention), **tier1**
per-minute, **tier2** per-hour (longest) — so recent data is detailed and old data stays cheap.

## Runbooks

### A. VPS IP blocked (most likely disaster — target < 30 min)
1. Provision a new VPS (or request an IP swap).
2. `git clone <repo> && cd mesh-router/vps && ./bootstrap.sh` (secrets come from the sops file or your fill-in).
3. Update the DNS A record for `STATIC_DOMAIN` → new IP, and `VPS_HOST` in `secrets/vps.env`.
4. Re-render and re-import the client config (`client/render-client-config.sh`). Reality reconnects by IP.
- *Insurance:* enable the [Cloudflare CDN fallback](docs/cloudflare-fallback.md) ahead of time — it
  survives the VPS IP being blocked entirely (the client reaches Cloudflare's edge, not your VPS, and
  CF reaches the origin from outside the GFW). The VPS side ships ready; setup is ~10 min of CF clicks.

### B. Switch residential ↔ VPS-direct
See "Two exit modes" above — one click in the dashboard.

### C. Mac mini down / recovery
- The `mac-auto` selector already failed sensitive traffic over to the VPS; you're not offline.
- SSH in over Tailscale (out-of-band): `ssh you@mac-mini-exit` (works even when the data path is dead).
- Re-run `mac-mini/setup.sh` to rebuild. Check the daemon: `sudo launchctl print system/com.meshrouter.singbox`.

## Security notes

- Only 443/tcp, 8443/udp, 80/tcp (ACME) are public. Everything else is Tailscale-gated by `firewall.sh`.
- Secrets never enter this (public) repo at all: `secrets/` is fully gitignored except `*.example`.
  Real secrets live in a separate private repo / password manager (see "Code delivery & disaster
  recovery"). The real domain and IP exist only there, so this repo is safe to open-source as-is.
- Reality private key, Hysteria2 password, Tailscale auth keys, and the Clash API secret are all
  generated by `gen-secrets.sh` — never reuse the examples.
- Tighten SSH to Tailscale-only once you've confirmed Tailscale SSH works (see `firewall.sh`).

## Future: automation agents (OpenClaw / n8n)

Run agents on the VPS egressing **direct**, never through the residential exit by default — bot
traffic poisons a home IP's reputation. Only flows that must act *as you* (interactive sessions)
should opt into `trusted-exit`, per-domain. `api.anthropic.com` / `api.openai.com` already route
direct (datacenter IPs are normal for API traffic).

## Version pinning

`/.env` pins image tags. sing-box configs target the **1.11.x** schema. Bumping sing-box to 1.12+
may require config changes (the DNS server format changed). Always `sing-box check` after a bump.
