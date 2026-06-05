#!/usr/bin/env bash
# Gateway entrypoint. Runs as root (needs iptables). Starts the three services
# and watches the allowlist for live reloads (no container restart).
#
# Enforcement model (fail-closed): the kind node sits on a docker `--internal`
# network with no egress of its own, and its default route points here. This
# gateway does NOT forward — only connections terminating at the proxy/DNS
# listeners below reach the internet, re-originated by those processes. So a
# pod that ignores the proxy simply can't get out.
set -uo pipefail

GW_INTERNAL_IP="${GW_INTERNAL_IP:-172.30.0.2}"
UPSTREAM_DNS="${UPSTREAM_DNS:-1.1.1.1}"
ALLOWLIST="${ALLOWLIST:-/etc/gateway/allowlist}"
FILTER=/etc/gateway/tinyproxy.filter
DNSLIVE=/etc/gateway/dnsmasq.live

# Seed the allowlist from the baked default if no host file is bind-mounted.
[ -f "$ALLOWLIST" ] || cp /etc/gateway/allowlist.default "$ALLOWLIST"

# --- no transit: belt-and-suspenders to the --internal network + --sysctl ----
sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || echo "WARN: could not set ip_forward=0 (run with --sysctl net.ipv4.ip_forward=0)"
if iptables -P FORWARD DROP 2>/dev/null; then
  iptables -F FORWARD 2>/dev/null || true
else
  echo "WARN: could not set FORWARD DROP (run with --cap-add=NET_ADMIN) — relying on --internal network + ip_forward=0"
fi

# --- regenerate tinyproxy filter + dnsmasq servers from the allowlist ---------
# tinyproxy:  allowlist regex (FilterDefaultDeny) — anchored so evil-foo.com
#             can't match foo.com, but sub.foo.com can.
# dnsmasq:    forward allowlisted domains upstream; sinkhole all else to 0.0.0.0
#             (kills DNS tunnelling). SIGHUP doesn't reread server= lines, so we
#             restart dnsmasq on change.
regen() {
  : > "$FILTER"
  cp /etc/gateway/dnsmasq.conf "$DNSLIVE"
  echo "listen-address=${GW_INTERNAL_IP},127.0.0.1" >> "$DNSLIVE"
  while IFS= read -r line || [ -n "$line" ]; do
    d="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "$d" ] && continue
    case "$d" in \#*) continue ;; esac
    esc="$(printf '%s' "$d" | sed 's/\./\\./g')"
    printf '(^|\\.)%s$\n' "$esc" >> "$FILTER"
    echo "server=/${d}/${UPSTREAM_DNS}" >> "$DNSLIVE"
  done < "$ALLOWLIST"
  echo "address=/#/0.0.0.0" >> "$DNSLIVE"   # sinkhole everything not listed
}
regen

# --- start services -----------------------------------------------------------
start_dnsmasq() { dnsmasq -C "$DNSLIVE" -k & DNSMASQ_PID=$!; }
start_dnsmasq
tinyproxy -d -c /etc/gateway/tinyproxy.conf & TINY_PID=$!
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile & CADDY_PID=$!

echo "==> gateway up: tinyproxy:8888 dnsmasq:53 caddy(ingress 4444/7681, git 8088, anthropic 8443) ip=${GW_INTERNAL_IP}"

cleanup() { kill "$DNSMASQ_PID" "$TINY_PID" "$CADDY_PID" 2>/dev/null || true; }
trap cleanup TERM INT

# --- watch the allowlist; live-reload on change (no restart) ------------------
lastsum="$(md5sum "$ALLOWLIST" 2>/dev/null | awk '{print $1}')"
while sleep 10; do
  # if any service died, exit so docker restart-policy recycles us
  kill -0 "$TINY_PID" 2>/dev/null && kill -0 "$CADDY_PID" 2>/dev/null && kill -0 "$DNSMASQ_PID" 2>/dev/null || {
    echo "ERROR: a gateway service exited — recycling"; cleanup; exit 1; }
  newsum="$(md5sum "$ALLOWLIST" 2>/dev/null | awk '{print $1}')"
  if [ "$newsum" != "$lastsum" ]; then
    echo "==> allowlist changed — reloading"
    regen
    kill -HUP "$TINY_PID" 2>/dev/null || true   # tinyproxy rereads conf + filter
    kill "$DNSMASQ_PID" 2>/dev/null || true     # dnsmasq must restart for server= lines
    start_dnsmasq
    lastsum="$newsum"
  fi
done
