#!/usr/bin/env bash
# Check whether sites can serve as the Reality handshake target (REALITY_HANDSHAKE).
# Run it ON THE VPS: what matters is what the target's servers send to the VPS, and CDN-fronted
# sites send different certificate chains to different places.
#
#   scripts/check-reality-target.sh dl.google.com www.apple.com www.microsoft.com
#
# A target passes when, connecting with an X25519 key share the way Reality clients do, it
#   - negotiates TLS 1.3 with an X25519 key exchange and ALPN h2, with a certificate that verifies;
#   - sends every handshake record within REALITY's buffer: 5-byte header + length <= 8192
#     (sing-box/Xray's REALITY server closes the connection, logging "processed invalid
#     connection", when a record is larger);
#   - keeps the whole server flight (ServerHello .. Finished) within 8192 bytes, so REALITY's
#     buffer cannot overflow between two socket reads.
#
# Exit 0 = every target passed. CHECK_REALITY_INPUT=<file> parses saved `openssl s_client -msg`
# output instead of connecting (used by scripts/test-configs.sh).
set -uo pipefail

LIMIT=8192
[[ $# -gt 0 ]] || { echo "usage: $0 <host> [host...]" >&2; exit 2; }

# Print one verdict line for openssl -msg output read on stdin. Portable awk (mawk/gawk/busybox).
judge() {
  awk -v host="$1" -v limit="$LIMIT" '
    function hex(s,   i, v) {
      s = tolower(s); v = 0
      for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
      return v
    }
    { sub(/\r$/, "") }
    want_len {                      # the line after an incoming RecordHeader: "17 03 03 0d 1e"
      want_len = 0
      if (!done) {
        len = hex($4 $5); flight += len + 5
        if (len > maxrec) maxrec = len
      }
      next
    }
    /^<<< .*RecordHeader/       { want_len = 1; next }
    /^Verify return code:/      { if (!done) cert = ($4 == "0"); done = 1 }   # handshake finished
    /^(Server|Peer) Temp Key:/  { tk = $4; sub(/,$/, "", tk) }               # OpenSSL 1.1 - 3.4
    /^Negotiated TLS1\.3 group:/ { tk = $4 }                                  # OpenSSL 3.5+
    /TLSv1\.3/                  { tls13 = 1 }
    /^ALPN protocol: h2$/       { h2 = 1 }
    END {
      why = ""
      if (!done)                why = why " no-handshake"
      if (!tls13)               why = why " no TLS1.3"
      if (tk != "X25519")       why = why " key-exchange " (tk == "" ? "none" : tk)
      if (!h2)                  why = why " no h2"
      if (done && !cert)        why = why " certificate does not verify"
      if (maxrec + 5 > limit)   why = why " record " maxrec " bytes (+5 > " limit ")"
      if (flight > limit)       why = why " flight " flight " bytes (> " limit ")"
      printf "%-28s max_record=%-5d flight=%-5d %s\n", host, maxrec, flight, (why == "" ? "PASS" : "FAIL:" why)
      exit (why == "" ? 0 : 1)
    }'
}

rc=0
for host in "$@"; do
  if [[ -n "${CHECK_REALITY_INPUT:-}" ]]; then
    judge "$host" <"$CHECK_REALITY_INPUT" || rc=1
  else
    timeout 15 openssl s_client -connect "$host:443" -servername "$host" \
        -tls1_3 -groups X25519 -alpn h2 -msg </dev/null 2>/dev/null \
      | judge "$host" || rc=1
  fi
done
# A FAIL on every host can also mean this OpenSSL prints its handshake summary differently.
[[ $rc -ne 0 && -z "${CHECK_REALITY_INPUT:-}" ]] && echo "(checked with $(openssl version 2>/dev/null))"
exit $rc
