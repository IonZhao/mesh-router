# cross-border-net

Personal two-layer cross-border network. **Tokyo VPS = control plane** (sing-box, the single
routing brain). **US Mac mini = trusted residential exit** (sing-box, pure egress, zero routing).
Client = Clash Meta doing geo split only. Connected by Tailscale (application-layer chaining, not
L3 NAT). Fully reproducible from this repo.

> Design rationale and decision log: [`../docs/2026-06-10-cross-border-network-design.md`](../docs/2026-06-10-cross-border-network-design.md)
> **New to this? Use the click-by-click walkthrough:** [`docs/deploy-guide.html`](docs/deploy-guide.html) (open in a browser).

```
Client (China, Clash Meta)        geo split: CN -> direct, else -> VPS
   │  VLESS+Reality :443 (primary) / Hysteria2 :8443 (backup)
   ▼
VPS (Tokyo, sing-box)             trust split: sensitive -> trusted-exit, else -> direct
   ├── direct  (datacenter egress)
   └── mac-out (VLESS over Tailscale)
          ▼
       Mac mini (US residential, sing-box)   inbound -> direct, ZERO rules
          ▼
       Residential ISP egress
```

## Prerequisites (read first)

- **A domain you own.** Required for Hysteria2's TLS cert (auto-issued via Let's Encrypt) and
  the dashboards. ~$10/yr. Point an A record (e.g. `proxy.yourdomain.com`) at the VPS IP. Reality
  (port 443) does *not* use your domain — it borrows a real site's TLS handshake.
- **A VPS in Tokyo.** 2 vCPU / 2–4 GB RAM / ≥2 TB traffic is plenty (a proxy hub is network-bound,
  not CPU-bound). Spend the budget on route quality (Softbank/IIJ peering or CN2 GIA), not cores.
  Debian/Ubuntu.
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
| `client/clash-meta.yaml.template` | fake-ip, CN-direct, Reality/Hysteria2 url-test group |
| `scripts/gen-secrets.sh` | generate UUIDs, Reality keypair, passwords |
| `scripts/firewall.sh` | ufw: only proxy ports public; admin via Tailscale only |
| `scripts/check-tailscale-direct.sh` | alert if the VPS↔Mac link drops to a DERP relay |
| `secrets/*.env.example` | secret templates (real secrets gitignored / sops-encrypted) |

## Quickstart

```bash
git clone <repo> && cd cross-border-net

# 1. Generate secrets (needs Docker), then fill in the human fields it lists.
scripts/gen-secrets.sh
#    edit secrets/vps.env : PROXY_DOMAIN, ACME_EMAIL, REALITY_HANDSHAKE, TS_AUTHKEY, VPS_HOST
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
cd client && ./render-client-config.sh   # produces clash-meta.yaml -> import into Clash Meta
```

Validate before/after: `docker compose run --rm sing-box check -c /etc/sing-box/config.json`.

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

| Tool | URL | Use |
|---|---|---|
| metacubexd (sing-box Clash API) | `http://<vps-ts-ip>:9090/ui` | **live per-connection outbound view** — verify the split; switch modes |
| Uptime Kuma | `http://<vps-ts-ip>:3001` | probe the Mac exit (TCP to `<mac-ts-ip>:18443`); alert on outage |
| Netdata | `http://<vps-ts-ip>:19999` | real-time host/container metrics |
| vnStat | `http://<vps-ts-ip>:8685` | long-term per-interface traffic (quota tracking) |

After first boot, add an Uptime Kuma monitor: **TCP Port**, host = Mac mini Tailscale IP, port `18443`,
interval 60s, plus a notification. Optionally cron `scripts/check-tailscale-direct.sh` for DERP alerts.

## Runbooks

### A. VPS IP blocked (most likely disaster — target < 30 min)
1. Provision a new VPS (or request an IP swap).
2. `git clone <repo> && cd cross-border-net/vps && ./bootstrap.sh` (secrets come from the sops file or your fill-in).
3. Update the DNS A record for `PROXY_DOMAIN` → new IP, and `VPS_HOST` in `secrets/vps.env`.
4. Re-render and re-import the client config (`client/render-client-config.sh`). Reality reconnects by IP.
- *Insurance:* the optional Cloudflare CDN path (see design doc §4.1) survives IP blocking entirely.

### B. Switch residential ↔ VPS-direct
See "Two exit modes" above — one click in the dashboard.

### C. Mac mini down / recovery
- The `mac-auto` selector already failed sensitive traffic over to the VPS; you're not offline.
- SSH in over Tailscale (out-of-band): `ssh you@mac-mini-exit` (works even when the data path is dead).
- Re-run `mac-mini/setup.sh` to rebuild. Check the daemon: `sudo launchctl print system/com.crossborder.singbox`.

## Security notes

- Only 443/tcp, 8443/udp, 80/tcp (ACME) are public. Everything else is Tailscale-gated by `firewall.sh`.
- Secrets never enter git in plaintext: `secrets/*.env` is gitignored; commit only the sops-encrypted
  `*.env.enc`. With `sops`+`age`, `git clone` + one private key = a complete rebuild.
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
