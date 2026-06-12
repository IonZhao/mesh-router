# Cloudflare CDN fallback (optional emergency path)

A last-resort tunnel that **survives the VPS IP being GFW-blocked**. The China client only ever
connects to Cloudflare's edge IPs (which the GFW generally doesn't block); Cloudflare then reaches
your origin VPS from outside the GFW, so a China-side block of your VPS IP doesn't affect it. It's
slower than Reality/Hysteria2, so the client's url-test only falls to it when the direct paths die.

```
China client ──TLS──▶ Cloudflare edge (cdn.yourdomain:2053) ──TLS(Full)──▶ VPS origin :2053
                       (orange cloud)                                       VLESS+WS, self-signed cert
```

The VPS side is **already deployed** by `bootstrap.sh` (a VLESS+WS inbound on `2053/tcp` with a
self-signed cert). It sits dark behind the firewall until you do the steps below. ~10 minutes,
mostly Cloudflare dashboard clicks.

## Prerequisites

- Your domain's DNS is managed by Cloudflare (nameservers point to Cloudflare).
- The base system is deployed and working.

## Steps

### 1. DNS record (proxied)
Cloudflare dashboard → your domain → **DNS → Records → Add record**:

| Type | Name | Content | Proxy status |
|---|---|---|---|
| A | `cdn` | your VPS public IP | **Proxied** (orange cloud) ✅ |

This is the opposite of the `static.` record (which must be grey/DNS-only). `cdn.` MUST be orange.

### 2. SSL/TLS mode = Full (not Flexible, not Full-strict)
This is a **separate section from DNS** — you won't see it while adding the record. In the left
sidebar go to **SSL/TLS → Overview** (the mode lives here, not on the DNS record).

- If the page shows **"Automatic SSL/TLS"** selected (the new default), click **Configure
  SSL/TLS** / switch to **Custom SSL/TLS**, then pick **Full**. (Automatic probes the origin on
  standard ports and may not handle our self-signed listener on 2053 correctly — set it explicitly.)
- Our origin presents a **self-signed** cert on 2053, which is why the mode must be **Full**:
  Full encrypts CF↔origin but does not validate the cert. **Full (strict)** would reject self-signed;
  **Flexible** would talk plain HTTP and break the TLS listener.

This setting is **zone-wide**. **If you also host a website** on this domain and want Full (strict)
for it, leave the zone strict and scope an override instead: **Rules → Configuration Rules** →
"When hostname equals `cdn.yourdomain.com`" → **SSL = Full**.

> Never use **Flexible** — plain HTTP to the origin mismatches our TLS listener and weakens the
> whole zone's security.

### 3. Set the domain in secrets and re-render the client
In `secrets/vps.env` set `CDN_DOMAIN=cdn.yourdomain.com`, then on your laptop:

```bash
cd client && ./render-client-config.sh   # the cdn-fallback proxy now points at your real CDN domain
```

Re-import the updated `clash-meta.yaml`. (The VPS doesn't need `CDN_DOMAIN` — its inbound only cares
about the WS path + cert, both already in place. No VPS redeploy needed unless you rotated secrets.)

### 4. Open the firewall to Cloudflare only
On the VPS:

```bash
sudo scripts/firewall-cdn.sh   # allows 2053/tcp from Cloudflare edge ranges only
```

### 5. Verify
In the dashboard (`http://<vps-ts-ip>:9090/ui`) the `cdn-fallback` proxy should now show a latency
(alive). To prove the end-to-end path, select `cdn-fallback` directly in the PROXY group and load a
site, or temporarily stop sing-box's Reality/Hy2 reachability and confirm traffic still flows.

## How it survives an IP block

The GFW blocks **China ↔ your-VPS-IP**. With the CDN path, the China client connects to a
**Cloudflare edge IP**, not your VPS. Cloudflare's data centers (outside the GFW) connect to your
VPS origin normally. So even with your VPS IP fully blocked from China, the fallback keeps working —
which is exactly why it's the IP-replacement insurance referenced in the design doc §4.1.

## Notes & tuning

- **Port choice:** 2053 is used because Cloudflare proxies it as HTTPS on all plans, and your origin's
  443 (Reality) and 8443 (Hysteria2) are already taken. Cloudflare forwards edge:2053 → origin:2053.
- **Want the client to use 443 instead of 2053?** Add a Cloudflare **Origin Rule** ("Override origin
  port" → 2053) scoped to `cdn.yourdomain.com`, then change the client `cdn-fallback` port to 443.
  443 is the most reliable port through restrictive networks.
- **Caching:** Cloudflare disables caching on 2053 automatically — correct for a WebSocket tunnel.
- **Security:** the payload is VLESS-encrypted end-to-end, so the self-signed CF↔origin hop never
  exposes traffic; `firewall-cdn.sh` also restricts 2053 to Cloudflare IPs.
