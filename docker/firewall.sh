#!/usr/bin/env bash
set -euo pipefail

allowlist_file="${CODEXSHELL_ALLOWLIST_FILE:-/etc/codexshell/allowed-domains.txt}"
[[ -r "$allowlist_file" ]] || { printf 'Firewall allowlist is missing: %s\n' "$allowlist_file" >&2; exit 1; }

iptables -N CODEXSHELL_OUT
iptables -A CODEXSHELL_OUT -o lo -j ACCEPT
iptables -A CODEXSHELL_OUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A CODEXSHELL_OUT -p udp --dport 53 -j ACCEPT
iptables -A CODEXSHELL_OUT -p tcp --dport 53 -j ACCEPT

rule_count=0
skipped_count=0
while IFS= read -r domain || [[ -n "$domain" ]]; do
  domain="${domain%$'\r'}"
  [[ -n "$domain" ]] || continue
  addresses="$(getent ahostsv4 "$domain" 2>/dev/null | awk '$2 == "STREAM" {print $1}' | sort -u || true)"
  if [[ -z "$addresses" ]]; then
    printf 'Firewall warning: %s has no resolvable IPv4 address; skipping.\n' "$domain" >&2
    skipped_count=$((skipped_count + 1))
    continue
  fi
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    iptables -A CODEXSHELL_OUT -p tcp -d "$ip" -m multiport --dports 80,443 -j ACCEPT
    rule_count=$((rule_count + 1))
  done <<< "$addresses"
done < "$allowlist_file"

if ((rule_count == 0)); then
  printf 'Firewall error: no allowed IPv4 addresses could be resolved. Refusing to start Codex.\n' >&2
  exit 1
fi

iptables -A CODEXSHELL_OUT -j REJECT
iptables -I OUTPUT 1 -j CODEXSHELL_OUT
ip6tables -P OUTPUT DROP
printf 'Firewall enabled: %d IPv4 allow rules, %d unresolved domains skipped.\n' "$rule_count" "$skipped_count"
