#!/usr/bin/env bash
# Egress firewall: drop all outbound traffic except DNS, the Docker host
# (Postgres/Redis forwards), and the allowlisted domains Claude needs.
# Requires NET_ADMIN (run.sh adds it in --block-net mode).
set -euo pipefail

# Minimal set per https://code.claude.com/docs/en/network-config:
#   api.anthropic.com      - Claude API, feature flags
#   claude.ai              - claude.ai account auth
#   platform.claude.com    - OAuth token exchange/refresh (needed for injected creds)
#   claude.com             - sign-in redirect host
#   mcp-proxy.anthropic.com- claude.ai MCP connectors (Atlassian, Notion, ...)
# Plus GitHub, so the `gh` CLI and git-over-HTTPS work:
#   github.com, api.github.com, codeload.github.com, objects.githubusercontent.com
# Extend via ALLOWED_DOMAINS env, e.g. add registry.npmjs.org for npx MCP servers.
ALLOWED_DOMAINS="${ALLOWED_DOMAINS:-api.anthropic.com claude.ai platform.claude.com claude.com mcp-proxy.anthropic.com github.com api.github.com codeload.github.com objects.githubusercontent.com}"

iptables -F OUTPUT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Docker host gateway — keeps localhost:5432/6379 socat forwards working
host_ip="$(getent ahostsv4 host.docker.internal | awk '{print $1; exit}')"
[ -n "$host_ip" ] && iptables -A OUTPUT -d "$host_ip" -j ACCEPT

for domain in $ALLOWED_DOMAINS; do
  for ip in $(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'); do
    iptables -A OUTPUT -d "$ip" -j ACCEPT
  done
done

iptables -P OUTPUT DROP

# Block IPv6 egress entirely (except loopback/established/DNS) so allowlisted
# domains can't be bypassed over v6.
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -F OUTPUT 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
  ip6tables -P OUTPUT DROP 2>/dev/null || true
fi
echo "[claude-sandbox] egress firewall ACTIVE — allowed: $ALLOWED_DOMAINS + host DB/Redis + DNS"
