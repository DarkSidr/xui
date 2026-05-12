#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

APP_DIR="/opt/3x-ui-selfsteal"
WWW_DIR="/var/www/3x-ui-selfsteal"
STATE_FILE="${APP_DIR}/install-result.env"

DOMAIN="${DOMAIN:-}"
PANEL_PATH="${PANEL_PATH:-}"
PANEL_PORT="${PANEL_PORT:-2053}"
CADDY_STEAL_PORT="${CADDY_STEAL_PORT:-4123}"
REALITY_PORT="${REALITY_PORT:-443}"
SSH_PORT="${SSH_PORT:-22}"
INSTALL_FIREWALL="${INSTALL_FIREWALL:-true}"
ENABLE_BBR="${ENABLE_BBR:-true}"
BLOCK_ICMP_PING="${BLOCK_ICMP_PING:-}"
DISABLE_IPV6="${DISABLE_IPV6:-}"

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

ask_yes_no() {
  local prompt default answer
  prompt="$1"
  default="$2"
  while true; do
    read -rp "${prompt} [Y/n]: " answer
    answer="${answer:-${default}}"
    case "${answer,,}" in
      y | yes) return 0 ;;
      n | no) return 1 ;;
      *) echo "Please enter y or n." ;;
    esac
  done
}

normalize_bool() {
  local value
  value="${1,,}"
  case "${value}" in
    true | yes | y | 1) echo "true" ;;
    false | no | n | 0) echo "false" ;;
    *) die "Invalid boolean value: ${1}. Use y/n or true/false." ;;
  esac
}

prompt_inputs() {
  if [[ -z "${DOMAIN}" ]]; then
    read -rp "Enter domain for camouflage site and panel, e.g. example.com: " DOMAIN
  fi
  DOMAIN="${DOMAIN,,}"
  DOMAIN="${DOMAIN#http://}"
  DOMAIN="${DOMAIN#https://}"
  DOMAIN="${DOMAIN%%/*}"
  [[ "${DOMAIN}" =~ ^([a-z0-9](-*[a-z0-9])*\.)+[a-z]{2,}$ ]] || die "Invalid DOMAIN: ${DOMAIN}"

  if [[ -z "${PANEL_PATH}" ]]; then
    read -rp "Enter secret panel path without slash [random]: " PANEL_PATH
  fi
  if [[ -z "${PANEL_PATH}" ]]; then
    PANEL_PATH="$(openssl rand -hex 12)"
  fi
  PANEL_PATH="${PANEL_PATH#/}"
  PANEL_PATH="${PANEL_PATH%/}"
  [[ "${#PANEL_PATH}" -ge 8 ]] || die "PANEL_PATH must be at least 8 characters."
  [[ "${PANEL_PATH}" =~ ^[A-Za-z0-9._~-]+$ ]] || die "PANEL_PATH may contain only A-Z, a-z, 0-9, dot, underscore, tilde and dash."
}

prompt_security_options() {
  if [[ -z "${BLOCK_ICMP_PING}" ]]; then
    if ask_yes_no "Block ICMP ping to this server?" "y"; then
      BLOCK_ICMP_PING="true"
    else
      BLOCK_ICMP_PING="false"
    fi
  else
    BLOCK_ICMP_PING="$(normalize_bool "${BLOCK_ICMP_PING}")"
  fi

  if [[ -z "${DISABLE_IPV6}" ]]; then
    if ask_yes_no "Disable IPv6 on this server?" "y"; then
      DISABLE_IPV6="true"
    else
      DISABLE_IPV6="false"
    fi
  else
    DISABLE_IPV6="$(normalize_bool "${DISABLE_IPV6}")"
  fi
}

public_ipv4() {
  local ip
  ip="$(curl -4fsS --max-time 5 https://api.ipify.org || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I | awk '{print $1}')"
  fi
  echo "${ip}"
}

check_dns() {
  local server_ip resolved
  server_ip="$(public_ipv4)"
  resolved="$(getent ahostsv4 "${DOMAIN}" | awk '{print $1; exit}' || true)"
  if [[ -z "${resolved}" ]]; then
    warn "No A record found for ${DOMAIN}. Let's Encrypt and Caddy will fail until DNS is fixed."
    return
  fi
  if [[ "${resolved}" != "${server_ip}" ]]; then
    warn "${DOMAIN} resolves to ${resolved}, but this server looks like ${server_ip}."
    read -rp "Continue anyway? [y/N]: " answer
    [[ "${answer,,}" == "y" ]] || die "Stopped by user."
  else
    log "DNS OK: ${DOMAIN} -> ${resolved}"
  fi
}

install_packages() {
  log "Installing base packages"
  apt-get update
  apt-get install -y ca-certificates curl wget tar gzip openssl jq iptables iptables-persistent systemd procps dnsutils gnupg debian-keyring debian-archive-keyring apt-transport-https

  if ! command -v caddy >/dev/null 2>&1; then
    log "Installing Caddy"
    if ! apt-get install -y caddy; then
      warn "Caddy package was not available in current apt sources; adding official Caddy repository."
      curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt" >/etc/apt/sources.list.d/caddy-stable.list
      apt-get update
      apt-get install -y caddy
    fi
  fi
}

arch_name() {
  case "$(uname -m)" in
    x86_64 | x64 | amd64) echo "amd64" ;;
    i*86 | x86) echo "386" ;;
    armv8* | armv8 | arm64 | aarch64) echo "arm64" ;;
    armv7* | armv7 | arm) echo "armv7" ;;
    armv6* | armv6) echo "armv6" ;;
    armv5* | armv5) echo "armv5" ;;
    s390x) echo "s390x" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

install_3xui() {
  local arch tmp
  arch="$(arch_name)"
  tmp="$(mktemp -d)"
  log "Installing latest 3x-ui release for ${arch}"
  wget -qO "${tmp}/x-ui.tar.gz" "https://github.com/MHSanaei/3x-ui/releases/latest/download/x-ui-linux-${arch}.tar.gz"

  systemctl stop x-ui 2>/dev/null || true
  rm -rf /usr/local/x-ui /usr/bin/x-ui "${tmp}/x-ui"
  tar zxf "${tmp}/x-ui.tar.gz" -C "${tmp}"
  chmod +x "${tmp}/x-ui/x-ui" "${tmp}/x-ui/x-ui.sh"
  chmod +x "${tmp}"/x-ui/bin/xray-linux-* 2>/dev/null || true
  cp "${tmp}/x-ui/x-ui.sh" /usr/bin/x-ui
  cp -f "${tmp}/x-ui/x-ui.service" /etc/systemd/system/x-ui.service
  mv "${tmp}/x-ui" /usr/local/x-ui
  systemctl daemon-reload
  systemctl enable x-ui
  systemctl restart x-ui
}

configure_panel() {
  XUI_USER="${XUI_USER:-admin_$(openssl rand -hex 4)}"
  XUI_PASSWORD="${XUI_PASSWORD:-$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 18)}"
  log "Configuring 3x-ui panel on 127.0.0.1:${PANEL_PORT}/${PANEL_PATH}"
  /usr/local/x-ui/x-ui setting -username "${XUI_USER}" -password "${XUI_PASSWORD}" -port "${PANEL_PORT}" -webBasePath "${PANEL_PATH}" -listenIP "127.0.0.1" >/dev/null
  /usr/local/x-ui/x-ui cert -webCert "" -webCertKey "" >/dev/null 2>&1 || true
  systemctl restart x-ui
}

write_site() {
  log "Writing camouflage site"
  mkdir -p "${APP_DIR}" "${WWW_DIR}"
  if [[ -f "./templates/confluence.html" ]]; then
    cp ./templates/confluence.html "${WWW_DIR}/index.html"
  else
    cat >"${WWW_DIR}/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Team Knowledge Base</title>
  <style>
    body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif;background:#f7f8fa;color:#172b4d}
    header{height:56px;display:flex;align-items:center;gap:22px;padding:0 28px;border-bottom:1px solid #dfe1e6;background:#fff}
    .brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:15px}.mark{width:28px;height:28px;border-radius:6px;background:linear-gradient(135deg,#0c66e4,#0747a6)}
    nav{display:flex;gap:18px;color:#5e6c84;font-size:14px}main{max-width:1120px;margin:0 auto;padding:42px 24px 60px}
    .hero{display:grid;grid-template-columns:minmax(0,1.35fr) minmax(280px,.65fr);gap:28px;margin-bottom:28px}.panel{background:#fff;border:1px solid #dfe1e6;border-radius:8px;padding:28px}
    h1{margin:0 0 12px;font-size:34px;line-height:1.16;letter-spacing:0}h2{margin:0 0 16px;font-size:18px;letter-spacing:0}p{margin:0;color:#5e6c84;line-height:1.55;font-size:15px}
    .search{margin-top:28px;height:44px;display:flex;align-items:center;padding:0 14px;border:1px solid #dfe1e6;border-radius:6px;color:#5e6c84;background:#fafbfc;font-size:14px}
    .item{display:flex;justify-content:space-between;gap:16px;padding:13px 0;border-top:1px solid #dfe1e6;font-size:14px}.item:first-of-type{border-top:0}.ok{color:#1f845a;font-weight:600}
    .grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:18px}.grid .panel{min-height:168px}.grid p{font-size:14px}
    @media(max-width:760px){header{padding:0 18px}nav{display:none}main{padding:26px 16px 42px}.hero,.grid{grid-template-columns:1fr}.panel{padding:22px}h1{font-size:28px}}
  </style>
</head>
<body>
  <header><div class="brand"><span class="mark"></span><span>Confluence</span></div><nav><span>Home</span><span>Spaces</span><span>People</span><span>Apps</span></nav></header>
  <main>
    <section class="hero">
      <div class="panel"><h1>Team Knowledge Base</h1><p>Find operational notes, onboarding materials, incident reviews, and project documentation maintained by the internal platform team.</p><div class="search">Search pages, spaces, and attachments</div></div>
      <aside class="panel"><h2>System Status</h2><div class="item"><span>Documentation</span><span class="ok">Operational</span></div><div class="item"><span>Search index</span><span class="ok">Operational</span></div><div class="item"><span>Attachments</span><span class="ok">Operational</span></div><div class="item"><span>SSO</span><span class="ok">Operational</span></div></aside>
    </section>
    <section class="grid"><article class="panel"><h2>Recently Updated</h2><p>Release checklists, service ownership notes, and escalation runbooks were refreshed this week.</p></article><article class="panel"><h2>Popular Spaces</h2><p>Engineering, Infrastructure, Product Operations, Security, and Customer Enablement.</p></article><article class="panel"><h2>Quick Links</h2><p>Deployment calendar, change policy, API catalog, incident templates, and access requests.</p></article></section>
  </main>
</body>
</html>
HTML
  fi
  chown -R caddy:caddy "${WWW_DIR}" 2>/dev/null || true
}

write_caddyfile() {
  log "Configuring Caddy"
  cat >/etc/caddy/Caddyfile <<EOF
{
    https_port ${CADDY_STEAL_PORT}
    auto_https disable_redirects

    servers 127.0.0.1:${CADDY_STEAL_PORT} {
        protocols h1 h2
        listener_wrappers {
            proxy_protocol {
                allow 127.0.0.1/32
            }
            tls
        }
    }
}

http://${DOMAIN} {
    bind 0.0.0.0
    redir https://${DOMAIN}{uri} permanent
}

https://${DOMAIN} {
    bind 127.0.0.1
    root * ${WWW_DIR}
    encode gzip zstd

    handle /${PANEL_PATH}* {
        reverse_proxy 127.0.0.1:${PANEL_PORT} {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto https
        }
    }

    handle {
        file_server
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}
EOF
  caddy validate --config /etc/caddy/Caddyfile
  systemctl enable caddy
  systemctl restart caddy
}

api_base_candidates() {
  printf 'http://127.0.0.1:%s/%s\n' "${PANEL_PORT}" "${PANEL_PATH}"
  printf 'http://127.0.0.1:%s\n' "${PANEL_PORT}"
}

login_panel() {
  local base http_code
  COOKIE_FILE="$(mktemp)"
  for base in $(api_base_candidates); do
    http_code="$(curl -sS -o /tmp/xui-login.json -w "%{http_code}" \
      -c "${COOKIE_FILE}" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"${XUI_USER}\",\"password\":\"${XUI_PASSWORD}\"}" \
      "${base}/login" || true)"
    if [[ "${http_code}" == "200" ]] && jq -e '.success == true' /tmp/xui-login.json >/dev/null 2>&1; then
      XUI_API_BASE="${base}"
      return 0
    fi
  done
  cat /tmp/xui-login.json >&2 || true
  die "Could not login to 3x-ui API."
}

generate_reality_keys() {
  local xray_bin output
  xray_bin="$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray-linux-*' | head -n 1)"
  [[ -x "${xray_bin}" ]] || die "xray binary not found under /usr/local/x-ui/bin"
  output="$("${xray_bin}" x25519)"
  REALITY_PRIVATE_KEY="$(awk '/Private key:/ {print $3}' <<<"${output}")"
  REALITY_PUBLIC_KEY="$(awk '/Public key:/ {print $3}' <<<"${output}")"
  [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]] || die "Could not generate Reality keys."
  CLIENT_UUID="$("${xray_bin}" uuid)"
  SHORT_ID="$(openssl rand -hex 8)"
}

configure_reality_inbound() {
  log "Creating 3x-ui VLESS REALITY self-steal inbound"
  login_panel
  generate_reality_keys

  local settings stream sniffing http_code
  settings="$(jq -cn --arg uuid "${CLIENT_UUID}" '{
    clients: [{
      id: $uuid,
      flow: "xtls-rprx-vision",
      email: "default",
      limitIp: 0,
      totalGB: 0,
      expiryTime: 0,
      enable: true,
      tgId: "",
      subId: ""
    }],
    decryption: "none",
    fallbacks: []
  }')"
  stream="$(jq -cn \
    --arg domain "${DOMAIN}" \
    --arg dest "127.0.0.1:${CADDY_STEAL_PORT}" \
    --arg privateKey "${REALITY_PRIVATE_KEY}" \
    --arg shortId "${SHORT_ID}" \
    '{
      network: "tcp",
      security: "reality",
      tcpSettings: {
        acceptProxyProtocol: false,
        header: {type: "none"}
      },
      realitySettings: {
        show: false,
        xver: 1,
        dest: $dest,
        serverNames: [$domain],
        privateKey: $privateKey,
        minClientVer: "",
        maxClientVer: "",
        maxTimeDiff: 0,
        shortIds: [$shortId],
        settings: {
          publicKey: "",
          fingerprint: "chrome",
          serverName: "",
          spiderX: "/"
        }
      }
    }')"
  sniffing="$(jq -cn '{enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false, routeOnly: false}')"

  http_code="$(curl -sS -o /tmp/xui-add-inbound.json -w "%{http_code}" \
    -b "${COOKIE_FILE}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "up=0" \
    --data-urlencode "down=0" \
    --data-urlencode "total=0" \
    --data-urlencode "remark=VLESS REALITY self-steal ${DOMAIN}" \
    --data-urlencode "enable=true" \
    --data-urlencode "expiryTime=0" \
    --data-urlencode "listen=" \
    --data-urlencode "port=${REALITY_PORT}" \
    --data-urlencode "protocol=vless" \
    --data-urlencode "settings=${settings}" \
    --data-urlencode "streamSettings=${stream}" \
    --data-urlencode "sniffing=${sniffing}" \
    "${XUI_API_BASE}/panel/api/inbounds/add" || true)"

  if [[ "${http_code}" != "200" ]] || ! jq -e '.success == true' /tmp/xui-add-inbound.json >/dev/null 2>&1; then
    cat /tmp/xui-add-inbound.json >&2 || true
    die "Could not create Reality inbound through 3x-ui API."
  fi

  systemctl restart x-ui
}

apply_sysctl_tuning() {
  log "Applying kernel network tuning"
  : >/etc/sysctl.d/99-3x-ui-selfsteal.conf

  if [[ "${ENABLE_BBR}" == "true" ]]; then
    modprobe tcp_bbr 2>/dev/null || true
    cat >>/etc/sysctl.d/99-3x-ui-selfsteal.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  fi

  if [[ "${BLOCK_ICMP_PING}" == "true" ]]; then
    cat >>/etc/sysctl.d/99-3x-ui-selfsteal.conf <<'EOF'
net.ipv4.icmp_echo_ignore_all = 1
EOF
  else
    cat >>/etc/sysctl.d/99-3x-ui-selfsteal.conf <<'EOF'
net.ipv4.icmp_echo_ignore_all = 0
EOF
  fi

  if [[ "${DISABLE_IPV6}" == "true" ]]; then
    cat >>/etc/sysctl.d/99-3x-ui-selfsteal.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  else
    cat >>/etc/sysctl.d/99-3x-ui-selfsteal.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
  fi

  sysctl --system >/dev/null || true
}

configure_firewall() {
  [[ "${INSTALL_FIREWALL}" == "true" ]] || return 0
  log "Configuring iptables firewall"
  iptables -F
  iptables -X
  iptables -Z
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT
  iptables -A INPUT -p tcp --dport 80 -j ACCEPT
  iptables -A INPUT -p tcp --dport "${REALITY_PORT}" -j ACCEPT
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT
  mkdir -p /etc/iptables
  iptables-save >/etc/iptables/rules.v4
}

write_result() {
  local vless_link
  vless_link="vless://${CLIENT_UUID}@${DOMAIN}:${REALITY_PORT}?type=tcp&security=reality&pbk=${REALITY_PUBLIC_KEY}&fp=chrome&sni=${DOMAIN}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#${DOMAIN}-selfsteal"
  cat >"${STATE_FILE}" <<EOF
DOMAIN=${DOMAIN}
PANEL_URL=https://${DOMAIN}/${PANEL_PATH}
PANEL_USER=${XUI_USER}
PANEL_PASSWORD=${XUI_PASSWORD}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
CLIENT_UUID=${CLIENT_UUID}
SHORT_ID=${SHORT_ID}
BLOCK_ICMP_PING=${BLOCK_ICMP_PING}
DISABLE_IPV6=${DISABLE_IPV6}
VLESS_LINK=${vless_link}
EOF
  chmod 600 "${STATE_FILE}"

  echo
  echo -e "${green}Installation complete${plain}"
  echo "Site:      https://${DOMAIN}/"
  echo "Panel:     https://${DOMAIN}/${PANEL_PATH}"
  echo "User:      ${XUI_USER}"
  echo "Password:  ${XUI_PASSWORD}"
  echo "VLESS:     ${vless_link}"
  echo
  echo "Saved to ${STATE_FILE}"
}

main() {
  need_root
  install_packages
  prompt_inputs
  prompt_security_options
  check_dns
  apply_sysctl_tuning
  install_3xui
  configure_panel
  write_site
  write_caddyfile
  configure_reality_inbound
  configure_firewall
  write_result
}

main "$@"
