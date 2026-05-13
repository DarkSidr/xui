#!/usr/bin/env bash
set -Eeuo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-vps-hardening.conf"

red=$'\033[0;31m'
green=$'\033[0;32m'
yellow=$'\033[0;33m'
plain=$'\033[0m'

log() {
  echo -e "${green}==>${plain} $*"
}

warn() {
  echo -e "${yellow}WARN:${plain} $*" >&2
}

die() {
  echo -e "${red}ERROR:${plain} $*" >&2
  exit 1
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

write_sysctl_config() {
  log "Writing persistent sysctl config to ${SYSCTL_FILE}"
  cat >"${SYSCTL_FILE}" <<'EOF'
# Managed by vps-hardening.sh
# Ignore IPv4 ICMP echo requests so the VPS does not answer ping.
net.ipv4.icmp_echo_ignore_all = 1

# Disable IPv6 for all current and future interfaces.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
}

apply_runtime_sysctl() {
  log "Applying runtime sysctl values"
  sysctl -w net.ipv4.icmp_echo_ignore_all=1 >/dev/null || warn "Could not set net.ipv4.icmp_echo_ignore_all"
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null || warn "Could not set net.ipv6.conf.all.disable_ipv6"
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null || warn "Could not set net.ipv6.conf.default.disable_ipv6"
  sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null || warn "Could not set net.ipv6.conf.lo.disable_ipv6"

  if command -v sysctl >/dev/null 2>&1; then
    sysctl --system >/dev/null || warn "sysctl --system returned a warning"
  fi
}

drop_ping_with_firewall() {
  if command -v iptables >/dev/null 2>&1; then
    log "Adding IPv4 firewall rule to drop ICMP echo requests"
    if ! iptables -C INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null; then
      iptables -I INPUT -p icmp --icmp-type echo-request -j DROP
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
      netfilter-persistent save >/dev/null || warn "Could not save firewall rules with netfilter-persistent"
    elif command -v iptables-save >/dev/null 2>&1 && [[ -d /etc/iptables ]]; then
      iptables-save >/etc/iptables/rules.v4 || warn "Could not save firewall rules to /etc/iptables/rules.v4"
    else
      warn "iptables rule is active now, but no known persistent firewall saver was found"
    fi
  else
    warn "iptables not found; ping blocking relies on sysctl only"
  fi
}

show_status() {
  echo
  echo -e "${green}Hardening complete${plain}"
  echo "IPv4 ping replies: disabled"
  echo "IPv6: disabled"
  echo "Persistent config: ${SYSCTL_FILE}"
}

main() {
  need_root
  write_sysctl_config
  apply_runtime_sysctl
  drop_ping_with_firewall
  show_status
}

main "$@"
