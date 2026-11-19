# Reality handshake target survey (2026-11-19)

**Decision: keep `REALITY_HANDSHAKE=www.microsoft.com`.** Nothing was changed on the VPS or the
client. If the target ever has to change, use `www.intel.com`, not `dl.google.com`.

The question was whether to move the target from `www.microsoft.com` to `dl.google.com` (the
repo's example default), because Microsoft's handshake records are the largest of the candidates
and REALITY closes the connection when a record exceeds 8192 bytes.

## Setup at the time

- VPS: Los Angeles, AS2914 (NTT America). sing-box v1.14.3, repo at `c06aae9`.
- Client network: mainland China, Clash Verge running with TUN off (system proxy only), so
  `curl --noproxy '*'` leaves on the direct path.

## What was measured

1. **Record sizes from the VPS** — `scripts/check-reality-target.sh`, 23 hosts, two runs, same
   result both times. Everything passed except `swcdn.apple.com` (no TLS 1.3).
2. **Where each name resolves and connects from inside China** — `curl -4 --noproxy '*'
   https://<host>/` on the client, then the owner of the answering IP (Team Cymru origin lookup).
3. **Whether the GFW lets the name through to the VPS** — from the client, no proxy:
   `curl -k --noproxy '*' --resolve <host>:443:<VPS public IP> https://<host>/`, three tries each.
   The VPS forwards a non-Reality connection to the configured target, so any HTTP status means
   the ClientHello with that SNI crossed the border and a ServerHello came back.
4. **A real Reality handshake against each target** — throwaway v1.14.3 server and client
   containers on the VPS loopback with a fresh key pair (ports 24443 / 21080, removed afterwards),
   five requests to `https://www.gstatic.com/generate_204` each, plus a non-Reality request to
   confirm the fallback serves the real site with a certificate that verifies.

## Results

| Target | max record | flight | resolves from China to | SNI to VPS | Reality | fallback |
|---|---|---|---|---|---|---|
| `www.intel.com` | 3339 | 3890 | Akamai, outside China (AS16625) | pass 3/3 | 5/5 | 301, cert ok |
| `www.tesla.com` | 2834 | 3385 | Akamai, outside China (AS16625) | pass 3/3 | 5/5 | 403, cert ok |
| `www.microsoft.com` (current) | 5919 | 6470 | Akamai, outside China (AS16625) | pass 3/3 | 5/5 | 200, cert ok |
| `dl.google.com` | 3723 | 3861 | **a mainland IP** (AS23724) | pass 3/3 | 5/5 | 302, cert ok |
| `www.apple.com` | 3263 | 3814 | **a mainland IP** (AS4134) | pass 3/3 | not run | not run |

Also passing the size check and the SNI test, not taken further: `addons.mozilla.org` (4125,
Fastly), `www.speedtest.net` (2659, Cloudflare), `www.nvidia.com` (5066, Akamai). Size check only:
`gateway.icloud.com` (3232, but 300 ms TLS from the VPS — too slow), `www.icloud.com`,
`itunes.apple.com`, `www.amazon.com`, `aws.amazon.com` (did not connect from the client network),
`www.amd.com` (timed out from the client network), `www.samsung.com`, `www.sony.com`,
`www.oracle.com`, `www.cisco.com`, `www.ntt.com`, `www.bing.com`, `learn.microsoft.com`,
`www.yahoo.com`.

TLS handshake time from the VPS to the shortlisted targets is 45–70 ms.

## Findings

- **`dl.google.com` works but is a worse disguise than Microsoft.** Inside China it resolves to a
  mainland server, so a Chinese client sending that name to a Los Angeles IP is not what a normal
  visitor does. `www.apple.com` has the same problem. Microsoft, Intel and Tesla resolve to
  Akamai nodes abroad, so going abroad for them is normal.
- **No candidate fixes the name-vs-network mismatch.** The VPS is in AS2914; every candidate is
  served from a CDN's own network (`www.ntt.com` too — it is on Akamai). Only a same-network
  neighbour or a self-hosted site behind the same IP would.
- **`www.intel.com` is the best of the set**: half of Microsoft's flight size, resolves abroad from
  China, a plain 301 for non-Reality visitors, and it is not the tutorial default. The gain over
  Microsoft is margin, not a fix; Microsoft passes with 1722 bytes of flight headroom.
- **Why it was not switched.** A switch means a redeploy (about one minute with every path down,
  Hysteria2 included) and a re-import on every client. The VPS log showed a second client network
  actively using Reality; it would lose Reality until its profile is updated.

## Side effect to avoid next time

As a positive control, step 3 was also run with `www.google.com`. The first try was reset, and
after that **every TCP connection from the client network to the VPS on port 443 timed out for
about five minutes**, whatever the SNI — the GFW's residual block on the (client, server, port)
triple. Reality from that network was dead for that window; Hysteria2 (UDP 8443) was not affected.
In the same minute the VPS log shows eight single connections to 443 from addresses not seen
before or after; cause unknown.

Do not send a blocked SNI to the production IP and port. If a control is needed, point it at a
throwaway port or a different host.

## Open items

- The example default (`secrets/vps.env.example`, README, `docs/deploy-guide.html`) is still
  `dl.google.com`. For a client in mainland China `www.intel.com` or `www.microsoft.com` is the
  better default; the README should also say to check where the name resolves from the client side.
- `scripts/check-reality-target.sh` checks the VPS side only. The client-side checks (steps 2 and
  3) and the loopback handshake test (step 4) are not scripted.
- Microsoft's record size varies by Akamai edge. Re-run the checker on the VPS if Reality starts
  failing with `processed invalid connection`.
