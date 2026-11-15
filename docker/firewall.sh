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
section_enabled=1
while IFS= read -r domain || [[ -n "$domain" ]]; do
  domain="${domain%$'\r'}"
  [[ -n "$domain" && "$domain" != \#* ]] || continue
  if [[ "$domain" =~ ^\[([A-Z_,]+)\]$ ]]; then
    section_enabled=0
    IFS=, read -r -a section_tools <<< "${BASH_REMATCH[1]}"
    for tool in "${section_tools[@]}"; do
      case ",${CODEXSHELL_ENABLED_TOOLS:-}," in *",$tool,"*) section_enabled=1 ;; esac
    done
    continue
  fi
  [[ "$section_enabled" == 1 ]] || continue
  [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { printf 'Firewall: invalid domain row.\n' >&2; exit 1; }
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

if [[ "${CODEXSHELL_XCODE:-0}" == 1 ]]; then
  bridge_host=${CODEXSHELL_XCODE_HOST:-}
  bridge_port=${CODEXSHELL_XCODE_PORT:-}
  [[ "$bridge_host" == host.docker.internal && "$bridge_port" =~ ^[1-9][0-9]{0,4}$ ]] || { printf 'Firewall: invalid Xcode endpoint.\n' >&2; exit 1; }
  ((bridge_port<=65535)) || { printf 'Firewall: invalid Xcode port.\n' >&2; exit 1; }
  bridge_ips=$(getent ahostsv4 "$bridge_host" | awk '$2 == "STREAM" {print $1}' | sort -u) || { printf 'Firewall: Xcode host resolution failed.\n' >&2; exit 1; }
  [[ -n "$bridge_ips" ]] || { printf 'Firewall: Xcode host has no IPv4 address.\n' >&2; exit 1; }
  while IFS= read -r bridge_ip; do
    [[ "$bridge_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { printf 'Firewall: invalid Xcode IPv4.\n' >&2; exit 1; }
    IFS=. read -r -a octets <<< "$bridge_ip"
    for octet in "${octets[@]}"; do
      ((10#$octet<=255)) || { printf 'Firewall: invalid Xcode IPv4.\n' >&2; exit 1; }
    done
    iptables -A CODEXSHELL_OUT -p tcp -d "$bridge_ip" --dport "$bridge_port" -j ACCEPT
  done <<< "$bridge_ips"
fi
iptables -A CODEXSHELL_OUT -j REJECT
iptables -I OUTPUT 1 -j CODEXSHELL_OUT
ip6tables -P OUTPUT DROP
printf 'Firewall enabled: %d IPv4 allow rules, %d unresolved domains skipped.\n' "$rule_count" "$skipped_count"
