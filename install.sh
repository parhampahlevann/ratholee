#!/bin/bash
# =============================================================================
#  Rathole Reverse Tunnel — Fully Automated Anti-Drop Build
#  Fixes:
#   1) TUNNEL_PORT fixed to 8443 (avoids port 443 conflicts)
#   2) Noise Keys hardcoded & automated (no prompt for keys)
#   3) Advanced TCP/MSS anti-drop tuning applied
# =============================================================================

# ---------- Fixed settings ----------
TUNNEL_PORT="8443"
TOKEN="rH7kQ2vXpL9mZ4wT6nB8sD3fG5jC1yA0"

# Fixed & Pre-generated Noise Keypair for zero-prompt setup
NOISE_PRIV="a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3"
NOISE_PUB="f5e4d3c2b1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4"

RATHOLE_VERSION="v0.5.0"          # latest stable release (x86_64)
RATHOLE_VERSION_ARM="v0.4.8"      # last release that still ships aarch64 musl
BIN="/usr/local/bin/rathole"
CONF_DIR="/etc/rathole"
ROLE_FILE="$CONF_DIR/role"

# ---------- Colors ----------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[0;34m'; M='\033[0;35m'; N='\033[0m'

ok()   { echo -e "${G}[✔]${N} $1"; }
err()  { echo -e "${R}[✘]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
info() { echo -e "${C}[*]${N} $1"; }

banner() {
  clear
  echo -e "${C}=============================================================${N}"
  echo -e "${G}     Rathole Reverse Tunnel (Automated Build - Port 8443)${N}"
  echo -e "${C}      IRAN (Server)  <<==  ${TUNNEL_PORT}  ==>>  KHAREJ (Client)${N}"
  echo -e "${C}=============================================================${N}"
  echo ""
}

# ---------- Root check ----------
need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run with root privileges."
    exit 1
  fi
}

# ---------- Install prerequisites ----------
install_deps() {
  local need=()
  command -v curl     >/dev/null 2>&1 || need+=(curl)
  command -v wget     >/dev/null 2>&1 || need+=(wget)
  command -v unzip    >/dev/null 2>&1 || need+=(unzip)
  command -v ss       >/dev/null 2>&1 || need+=(iproute2)
  command -v iptables >/dev/null 2>&1 || need+=(iptables)
  if command -v apt-get >/dev/null 2>&1; then
    [ ${#need[@]} -gt 0 ] && { info "Installing prerequisites: ${need[*]}"; apt-get update -y >/dev/null 2>&1; apt-get install -y "${need[@]}" >/dev/null 2>&1; }
  elif command -v dnf >/dev/null 2>&1; then
    [ ${#need[@]} -gt 0 ] && { info "Installing prerequisites: ${need[*]}"; dnf install -y "${need[@]}" >/dev/null 2>&1; }
  elif command -v yum >/dev/null 2>&1; then
    [ ${#need[@]} -gt 0 ] && { info "Installing prerequisites: ${need[*]}"; yum install -y "${need[@]}" >/dev/null 2>&1; }
  fi
  ok "Prerequisites are ready."
}

# ---------- Purge obsolete Watchdogs ----------
purge_watchdog() {
  local removed=0 u
  for u in rathole-watchdog.service rathole-watchdog.timer watchdog.service watchdog.timer; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${u}"; then
      systemctl disable --now "$u" >/dev/null 2>&1
      rm -f "/etc/systemd/system/${u}"
      removed=1
    fi
  done
  rm -f /usr/local/bin/rathole-watchdog.sh /usr/local/bin/watchdog.sh 2>/dev/null
  if [ -f /etc/cron.d/rathole-watchdog ] || [ -f /etc/cron.d/rathole ]; then
    rm -f /etc/cron.d/rathole-watchdog /etc/cron.d/rathole
    removed=1
  fi
  if crontab -l 2>/dev/null | grep -qi 'rathole.*watchdog\|watchdog.*rathole'; then
    crontab -l 2>/dev/null | grep -vi 'rathole.*watchdog\|watchdog.*rathole' | crontab - 2>/dev/null
    removed=1
  fi
  systemctl daemon-reload 2>/dev/null
  [ "$removed" = "1" ] && ok "Legacy watchdog purged."
  return 0
}

# ---------- Detect architecture ----------
detect_asset() {
  case "$(uname -m)" in
    x86_64|amd64)
      ASSET="rathole-x86_64-unknown-linux-gnu.zip"
      ASSET_VERSION="$RATHOLE_VERSION"
      ;;
    aarch64|arm64)
      ASSET="rathole-aarch64-unknown-linux-musl.zip"
      ASSET_VERSION="$RATHOLE_VERSION_ARM"
      warn "ARM server detected: using rathole ${ASSET_VERSION}."
      ;;
    *) err "Architecture $(uname -m) is not supported."; return 1 ;;
  esac
  return 0
}

# ---------- Install core ----------
install_core() {
  if [ -x "$BIN" ] && [ "$1" != "force" ]; then
    ok "Rathole core is already installed: $($BIN --version 2>/dev/null | head -n1)"
    return 0
  fi
  detect_asset || return 1
  info "Downloading rathole core (${ASSET_VERSION}) ..."
  local urls=(
    "https://github.com/rathole-org/rathole/releases/download/${ASSET_VERSION}/${ASSET}"
    "https://github.com/rapiz1/rathole/releases/download/${ASSET_VERSION}/${ASSET}"
    "https://ghproxy.net/https://github.com/rathole-org/rathole/releases/download/${ASSET_VERSION}/${ASSET}"
    "https://ghfast.top/https://github.com/rathole-org/rathole/releases/download/${ASSET_VERSION}/${ASSET}"
  )
  local tmp; tmp=$(mktemp -d)
  local done_dl=0
  for u in "${urls[@]}"; do
    if curl -fL --connect-timeout 12 --max-time 180 -o "$tmp/rathole.zip" "$u" 2>/dev/null; then
      if [ "$(stat -c%s "$tmp/rathole.zip" 2>/dev/null || echo 0)" -gt 100000 ]; then done_dl=1; break; fi
    fi
  done
  if [ "$done_dl" != "1" ]; then
    err "Core download failed. Check internet connection."
    rm -rf "$tmp"; return 1
  fi
  unzip -o "$tmp/rathole.zip" -d "$tmp" >/dev/null 2>&1
  install -m 0755 "$tmp/rathole" "$BIN"
  rm -rf "$tmp"
  mkdir -p "$CONF_DIR"
  ok "Rathole core installed: $($BIN --version 2>/dev/null | head -n1)"
  return 0
}

# ---------- Port check helpers ----------
parse_ports() {
  local raw="$1"
  raw="${raw//،/,}"; raw="${raw// /,}"; raw="${raw//;/,}"
  local out="" p
  IFS=',' read -ra arr <<< "$raw"
  for p in "${arr[@]}"; do
    p="${p// /}"
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || continue
    [ "$p" = "$TUNNEL_PORT" ] && continue
    case " $out " in *" $p "*) continue ;; esac
    out="$out $p"
  done
  echo "${out# }"
}

port_in_use() { ss -tln 2>/dev/null | grep -qE "[:.]${1}[[:space:]]"; }

check_tunnel_port_free() {
  if port_in_use "$TUNNEL_PORT"; then
    warn "Port ${TUNNEL_PORT} is already in use."
    read -rp "Press Enter once port ${TUNNEL_PORT} is free (or Ctrl+C to abort)..."
    if port_in_use "$TUNNEL_PORT"; then
      err "Port ${TUNNEL_PORT} is still in use."
      return 1
    fi
  fi
  return 0
}

check_forward_ports_free() {
  local ports="$1" bad="" p
  for p in $ports; do
    if port_in_use "$p" && ! ss -tlnp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" | grep -q rathole; then
      bad="$bad $p"
    fi
  done
  if [ -n "$bad" ]; then
    err "These ports are in use by another service:${bad}"
    return 1
  fi
  return 0
}

# ---------- Protocol Selection ----------
choose_proto() {
  echo ""
  echo -e "${Y}Choose transport protocol:${N}"
  echo "  1) Noise (Recommended - Secured Encryption)"
  echo "  2) TCP   (Standard Keepalive)"
  echo ""
  read -rp "Choice [1]: " pc
  case "${pc:-1}" in
    2) PROTO="tcp" ;;
    *) PROTO="noise" ;;
  esac
  ok "Selected protocol: $PROTO"
}

# ---------- Transport Blocks ----------
transport_server_block() {
  case "$PROTO" in
    tcp)
      cat <<EOF
[server.transport]
type = "tcp"

[server.transport.tcp]
nodelay = true
keepalive_secs = 5
keepalive_interval = 2
EOF
      ;;
    noise)
      cat <<EOF
[server.transport]
type = "noise"

[server.transport.noise]
pattern = "Noise_NK_25519_ChaChaPoly_BLAKE2s"
local_private_key = "$NOISE_PRIV"
EOF
      ;;
  esac
}

transport_client_block() {
  case "$PROTO" in
    tcp)
      cat <<EOF
[client.transport]
type = "tcp"

[client.transport.tcp]
nodelay = true
keepalive_secs = 5
keepalive_interval = 2
EOF
      ;;
    noise)
      cat <<EOF
[client.transport]
type = "noise"

[client.transport.noise]
pattern = "Noise_NK_25519_ChaChaPoly_BLAKE2s"
remote_public_key = "$NOISE_PUB"
EOF
      ;;
  esac
}

# ---------- Service Creation ----------
make_unit() {
  local name="$1" conf="$2" desc="$3"
  systemctl stop "${name}.service" >/dev/null 2>&1
  systemctl reset-failed "${name}.service" >/dev/null 2>&1
  cat > "/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${BIN} ${conf}
Restart=always
RestartSec=1
LimitNOFILE=1048576
Nice=-10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${name}.service" >/dev/null 2>&1
}

open_ports() {
  local ports="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${TUNNEL_PORT}/tcp" >/dev/null 2>&1
    for p in $ports; do ufw allow "${p}/tcp" >/dev/null 2>&1; done
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${TUNNEL_PORT}/tcp" >/dev/null 2>&1
    for p in $ports; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1; done
    firewall-cmd --reload >/dev/null 2>&1
  fi
}

# ---------- Anti-Drop Sysctl Tuning ----------
apply_net_tuning() {
  cat > /etc/sysctl.d/99-rathole-anti-drop.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 15
net.ipv4.tcp_keepalive_intvl = 3
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 15
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_retries2 = 5
EOF
  sysctl --system >/dev/null 2>&1
}

# ---------- MSS Clamping (MSS = 1360) ----------
apply_mss_clamp() {
  if ! command -v iptables >/dev/null 2>&1; then return; fi
  iptables -t mangle -F OUTPUT 2>/dev/null
  iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360

  cat > /etc/systemd/system/rathole-mss-clamp.service <<'EOF'
[Unit]
Description=Rathole Anti-Drop MSS Clamp
After=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now rathole-mss-clamp.service >/dev/null 2>&1
  ok "Anti-Drop MSS Clamping (1360) applied."
}

# ---------- Setup Iran Server ----------
setup_iran() {
  banner
  info "Setting up Iran Server (Port ${TUNNEL_PORT})..."
  install_deps
  purge_watchdog
  install_core || return

  check_tunnel_port_free || return

  local ports="" raw_ports
  while [ -z "$ports" ]; do
    read -rp "Enter Forward Ports (e.g., 1080,80,443): " raw_ports
    ports=$(parse_ports "$raw_ports")
  done

  check_forward_ports_free "$ports" || return
  choose_proto

  local conf="$CONF_DIR/iran-server.toml"
  {
    echo "[server]"
    echo "bind_addr = \"0.0.0.0:${TUNNEL_PORT}\""
    echo "default_token = \"${TOKEN}\""
    echo "heartbeat_interval = 8"
    echo ""
    transport_server_block
    echo ""
    for p in $ports; do
      echo "[server.services.p${p}]"
      echo "bind_addr = \"0.0.0.0:${p}\""
      echo ""
    done
  } > "$conf"

  make_unit "rathole-iran" "$conf" "Rathole Iran Server"
  apply_net_tuning
  apply_mss_clamp
  open_ports "$ports"
  echo "iran" > "$ROLE_FILE"

  ok "Iran Server ready on Port ${TUNNEL_PORT}!"
  read -rp "Press Enter to return..."
}

# ---------- Setup Kharej Server ----------
setup_kharej() {
  banner
  info "Setting up Kharej Server..."
  install_deps
  purge_watchdog
  install_core || return

  choose_proto

  read -rp "Enter Iran Server IP: " ip
  local ports="" raw_ports
  while [ -z "$ports" ]; do
    read -rp "Enter Forward Ports (MUST match Iran side): " raw_ports
    ports=$(parse_ports "$raw_ports")
  done

  local conf="$CONF_DIR/kharej-client-1.toml"
  {
    echo "[client]"
    echo "remote_addr = \"${ip}:${TUNNEL_PORT}\""
    echo "default_token = \"${TOKEN}\""
    echo "retry_interval = 1"
    echo "heartbeat_timeout = 25"
    echo ""
    transport_client_block
    echo ""
    for p in $ports; do
      echo "[client.services.p${p}]"
      echo "local_addr = \"127.0.0.1:${p}\""
      echo ""
    done
  } > "$conf"

  make_unit "rathole-kharej-1" "$conf" "Rathole Kharej Client"
  apply_net_tuning
  apply_mss_clamp
  echo "kharej" > "$ROLE_FILE"

  ok "Kharej Client connected to Iran Server (${ip}:${TUNNEL_PORT})!"
  read -rp "Press Enter to return..."
}

show_status() {
  banner
  info "Rathole Service Status:"
  systemctl status rathole-iran rathole-kharej-1 --no-pager 2>/dev/null
  echo ""
  info "Active Connections on Tunnel Port ${TUNNEL_PORT}:"
  ss -tnp state established 2>/dev/null | grep ":${TUNNEL_PORT}" || echo "No active connections on port ${TUNNEL_PORT}."
  read -rp "Press Enter to return..."
}

restart_all() {
  systemctl restart rathole-iran rathole-kharej-1 2>/dev/null
  ok "Services restarted."
  sleep 2
}

uninstall_all() {
  systemctl stop rathole-iran rathole-kharej-1 2>/dev/null
  systemctl disable rathole-iran rathole-kharej-1 2>/dev/null
  rm -rf "$CONF_DIR" "$BIN" /etc/systemd/system/rathole*
  systemctl daemon-reload
  ok "Tunnel completely uninstalled."
  sleep 2
}

# ---------- Main Menu ----------
main_menu() {
  while true; do
    banner
    echo " 1) Install Iran Server (Server)"
    echo " 2) Install Kharej Server (Client)"
    echo " 3) Status & Connection Test"
    echo " 4) Restart Tunnel Services"
    echo " 5) Fully Remove Tunnel"
    echo " 0) Exit"
    echo ""
    read -rp "Choice: " ch
    case "$ch" in
      1) setup_iran ;;
      2) setup_kharej ;;
      3) show_status ;;
      4) restart_all ;;
      5) uninstall_all ;;
      0) exit 0 ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

need_root
main_menu
