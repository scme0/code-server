# Boundary gateway image. Built locally by up.sh (no registry/CI) — the single
# point all sandbox traffic flows through:
#   - Caddy:     ingress reverse-proxy (code-server/ttyd) + git/anthropic cred proxy
#   - tinyproxy: egress forward proxy with a domain allowlist
#   - dnsmasq:   resolves allowlisted domains, sinkholes everything else
#   - iptables:  ip_forward=0 / FORWARD DROP so nothing transits (fail-closed)
#   - socat:     opt-in, port-scoped raw-TCP relays to the Docker host (HOST_RELAY_PORTS)
# Based on the same Caddy image the old git-proxy used; add the rest via apk.
FROM caddy:2.10-alpine

RUN apk add --no-cache bash tinyproxy dnsmasq iptables socat

# Static config; the per-domain bits (tinyproxy filter, dnsmasq servers) are
# generated at runtime from the allowlist by entrypoint.sh.
COPY Caddyfile          /etc/caddy/Caddyfile
COPY tinyproxy.conf     /etc/gateway/tinyproxy.conf
COPY dnsmasq.conf       /etc/gateway/dnsmasq.conf
COPY allowlist.default  /etc/gateway/allowlist.default
COPY entrypoint.sh      /usr/local/bin/gateway-entrypoint.sh
RUN chmod +x /usr/local/bin/gateway-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/gateway-entrypoint.sh"]
