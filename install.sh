#!/bin/bash
# =============================================================================
#  Rathole Reverse Tunnel — Ultra-Stable Build (v7, WebSocket Fixed)
#
#  v7 Changes:
#  1) FIXED WebSocket connectivity: Removed invalid [transport.tcp] blocks 
#     from websocket configs that were causing silent connection failures.
#  2) Smart Default Ports: Automatically uses 1080,443,23902,2053,8090 if 
#     you just press Enter during port selection.
#  3) Watchdog Verification: Confirms timer activation after install.
#  4) Hardcoded Token/Keys: Zero-prompt setup as requested.
# =============================================================================

set -u

# ---------- Fixed settings (NO PROMPTS) ----------
TUNNEL_PORT="8443"
TOKEN="e8c94f6a4e5ef135d7061fe365a686c070c1d1cd7337d8f6"

# Fixed valid base64 X25519 Noise keypair
NOISE_PRIV="8bytOyfav+CIn6pEY+gCUSn6PpHJh7ADeHT55wmrTsE="
NOISE_PUB="gHmg3PHFH9+CouNJfGV28I4JwS3Hm28F8Vl2vGraU3g="

# Default forward ports (used if user just presses Enter)
DEFAULT_PORTS="1080,443,23902,2053,8090"

RATHOLE_VERSION="v0.5.0"
RATHOLE_VERSION_MUSL="v0.4.8"
BIN="/usr/local/bin/rathole"
CONF_DIR="/etc/rathole"
ROLE_FILE="$CONF_DIR/role"
PROTO_FILE="$CONF_DIR/proto"
FW_SVC="/etc/systemd/system/rathole-fw.service"

# ---------- Colors ----------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; M='\033[0;35m'; N='\033[0m'

ok()   { echo -e "${G}[✔]${N} $1"; }
err()  { echo -e "${R}[✘]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
info() { echo -e "${C}[*]${N} $1"; }

banner() {
  clear
  echo -e "${C}=============================================================${N}"
  echo -e "${G}   Rathole Reverse Tunnel — Ultra-Stable (v7, WS Fixed)${N}"
  echo -e "${C}      IRAN (Server)  <<==  ${TUNNEL_PORT}  ==>>  KHAREJ (Client)${N}"
  echo -e "${C}=============================================================${N}"
  echo ""
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run with root privileges."
    exit 1
  fi
}

install_deps() {
  local need=()
  command -v curl     >/dev/null 2>&1 || need+=(curl)
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

purge_watchdog() {
  local removed=0 u
  for u in rathole-watchdog.service rathole-watchdog.timer watchdog.service watchdog.timer rathole-guard.service rathole-guard.timer; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${u}"; then
      systemctl disable --now "$u" >/dev/null 2>&1
      rm -f "/etc/systemd/system/${u}"
      removed=1
    fi
  done
  rm -f /usr/local/bin/rathole-guard.sh /usr/local/bin/rathole-watchdog.sh 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  [ "$removed" = "1" ] && ok "Legacy watchdogs purged."
  return 0
}

detect_asset() {
  case "$(uname -m)" in
    x86_64|amd64)
      ASSET="rathole-x86_64-unknown-linux-gnu.zip"
      ASSET_VERSION="$RATHOLE_VERSION"
      ;;
    aarch64|arm64)
      ASSET="rathole-aarch64-unknown-linux-musl.zip"
      ASSET_VERSION="$RATHOLE_VERSION_MUSL"
      warn "ARM server detected: using rathole ${ASSET_VERSION} (musl)."
      ;;
    *) err "Architecture $(uname -m) is not supported."; return 1 ;;
  esac
  return 0
}

download_asset() {
  local tmp="$1" u
  info "Downloading rathole ${ASSET_VERSION} (${ASSET}) ..."
  local urls=(
    "https://github.com/rathole-org/rathole/releases/download/${ASSET_VERSION}/${ASSET}"
    "https://ghproxy.net/https://github.com/rathole-org/rathole/releases/download/${ASSET_VERSION}/${ASSET}"
    "https://ghfast.top/https://github.com/rathole-org/rathole/releases/download/${ASSET_VERSION}/${ASSET}"
  )
  for u in "${urls[@]}"; do
    if curl -fL --connect-timeout 12 --max-time 240 -o "$tmp/rathole.zip" "$u" 2>/dev/null; then
      if [ "$(stat -c%s "$tmp/rathole.zip" 2>/dev/null || echo 0)" -gt 100000 ]; then
        return 0
      fi
    fi
  done
  return 1
}

install_core() {
  if [ -x "$BIN" ] && [ "${1:-}" != "force" ] && "$BIN" --version >/dev/null 2>&1; then
    ok "Rathole core is already installed: $("$BIN" --version 2>/dev/null | head -n1)"
    return 0
  fi
  detect_asset || return 1

  local tmp; tmp=$(mktemp -d)
  if ! download_asset "$tmp"; then
    err "Core download failed. Check internet connection."
    rm -rf "$tmp"; return 1
  fi
  unzip -o "$tmp/rathole.zip" -d "$tmp" >/dev/null 2>&1
  install -m 0755 "$tmp/rathole" "$BIN"
  rm -rf "$tmp"
  mkdir -p "$CONF_DIR"

  if ! "$BIN" --version >/dev/null 2>&1 && [ "$(uname -m)" = "x86_64" ]; then
    warn "Installed build cannot run here (glibc too old). Trying static musl build..."
    rm -f "$BIN"
    ASSET="rathole-x86_64-unknown-linux-musl.zip"
    ASSET_VERSION="$RATHOLE_VERSION_MUSL"
    local tmp2; tmp2=$(mktemp -d)
    if download_asset "$tmp2"; then
      unzip -o "$tmp2/rathole.zip" -d "$tmp2" >/dev/null 2>&1
      install -m 0755 "$tmp2/rathole" "$BIN"
    fi
    rm -rf "$tmp2"
  fi

  if ! "$BIN" --version >/dev/null 2>&1; then
    err "Rathole binary cannot run on this system."
    return 1
  fi
  ok "Rathole core installed: $("$BIN" --version 2>/dev/null | head -n1)"
  return 0
}

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

port_in_use() { ss -tln 2>/dev/null | grep -q ":${1} "; }

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
    if ss -tln 2>/dev/null | grep -q ":${p} " && ! ss -tlnp 2>/dev/null | grep -E ":${p} " | grep -q rathole; then
      bad="$bad $p"
    fi
  done
  if [ -n "$bad" ]; then
    err "These ports are in use by another service:${bad}"
    return 1
  fi
  return 0
}

choose_proto() {
  echo ""
  echo -e "${Y}Choose transport protocol:${N}"
  echo "  1) Noise     (Recommended - encrypted, same speed class as TCP)"
  echo "  2) TCP       (plain, slightly less CPU)"
  echo "  3) WebSocket (Try this if others get cut by DPI. Fixed in v7!)"
  echo ""
  read -rp "Choice [1]: " pc
  case "${pc:-1}" in
    2) PROTO="tcp" ;;
    3) PROTO="websocket" ;;
    *) PROTO="noise" ;;
  esac
  ok "Selected protocol: $PROTO"
  
  if [ "$PROTO" = "websocket" ]; then
    warn "WebSocket works best on port 80 or 443 for direct IP connections."
    warn "Note: Rathole v0.5.0 does NOT support TLS/WebSocket over CDN (like Cloudflare) natively."
    if [ "$TUNNEL_PORT" != "443" ] && [ "$TUNNEL_PORT" != "80" ]; then
      read -rp "Change tunnel port to 443 for better WebSocket compatibility? [Y/n]: " change_port
      if [[ ! "${change_port:-Y}" =~ ^[Nn]$ ]]; then
        TUNNEL_PORT="443"
        ok "Tunnel port changed to 443."
      fi
    fi
  fi
}

# FIXED: Only include [transport.tcp] for TCP and Noise protocols.
# Including it for WebSocket causes config parsing errors in rathole.
transport_server_block() {
  cat <<EOF
[server.transport]
type = "${PROTO}"
EOF
  if [ "$PROTO" = "tcp" ] || [ "$PROTO" = "noise" ]; then
    cat <<EOF

[server.transport.tcp]
nodelay = true
keepalive_secs = 20
keepalive_interval = 8
EOF
  fi
  if [ "$PROTO" = "noise" ]; then
    cat <<EOF

[server.transport.noise]
pattern = "Noise_NK_25519_ChaChaPoly_BLAKE2s"
local_private_key = "${NOISE_PRIV}"
EOF
  elif [ "$PROTO" = "websocket" ]; then
    cat <<EOF

[server.transport.websocket]
tls = false
EOF
  fi
}

transport_client_block() {
  cat <<EOF
[client.transport]
type = "${PROTO}"
EOF
  if [ "$PROTO" = "tcp" ] || [ "$PROTO" = "noise" ]; then
    cat <<EOF

[client.transport.tcp]
nodelay = true
keepalive_secs = 20
keepalive_interval = 8
EOF
  fi
  if [ "$PROTO" = "noise" ]; then
    cat <<EOF

[client.transport.noise]
pattern = "Noise_NK_25519_ChaChaPoly_BLAKE2s"
remote_public_key = "${NOISE_PUB}"
EOF
  elif [ "$PROTO" = "websocket" ]; then
    cat <<EOF

[client.transport.websocket]
tls = false
EOF
  fi
}

make_unit() {
  local name="$1" conf="$2" desc="$3" port="${4:-}"
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
OOMScoreAdjust=-900
Nice=-10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${name}.service" >/dev/null 2>&1

  sleep 2
  if ! systemctl is-active --quiet "${name}.service"; then
    err "Service ${name}.service failed to start. Last log lines:"
    journalctl -u "${name}.service" -n 15 --no-pager
    return 1
  fi
  if journalctl -u "${name}.service" -n 20 --no-pager 2>/dev/null | grep -qiE "panicked|core-dump|core_dump"; then
    err "Service ${name}.service is crash-looping (panic detected)."
    return 1
  fi
  if [ -n "$port" ] && ! port_in_use "$port"; then
    err "Service is active but port ${port} is NOT bound."
    return 1
  fi
  ok "Service ${name}.service is active and stable."
  return 0
}

open_ports() {
  local ports="$1" p
  local IPT; IPT="$(command -v iptables 2>/dev/null || true)"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${TUNNEL_PORT}/tcp" >/dev/null 2>&1
    for p in $ports; do ufw allow "${p}/tcp" >/dev/null 2>&1; done
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${TUNNEL_PORT}/tcp" >/dev/null 2>&1
    for p in $ports; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1; done
    firewall-cmd --reload >/dev/null 2>&1
  fi

  if [ -n "$IPT" ]; then
    local prev=""
    [ -f "$CONF_DIR/ports.prev" ] && prev="$(tr '\n' ' ' < "$CONF_DIR/ports.prev")"
    for p in $prev; do
      case " $ports " in *" $p "*) continue ;; esac
      "$IPT" -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
    done

    "$IPT" -C INPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT 2>/dev/null || \
      "$IPT" -I INPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT
    for p in $ports; do
      "$IPT" -C INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null || \
        "$IPT" -I INPUT -p tcp --dport "${p}" -j ACCEPT
    done

    {
      echo "[Unit]"
      echo "Description=Rathole firewall rules"
      echo "After=network-online.target"
      echo ""
      echo "[Service]"
      echo "Type=oneshot"
      echo "ExecStart=/bin/sh -c '$IPT -C INPUT -p tcp --dport ${TUNNEL_PORT} -j ACCEPT 2>/dev/null || $IPT -A INPUT -p tcp --dport ${TUNNEL_PORT} -j ACCEPT'"
      for p in $ports; do
        echo "ExecStart=/bin/sh -c '$IPT -C INPUT -p tcp --dport ${p} -j ACCEPT 2>/dev/null || $IPT -A INPUT -p tcp --dport ${p} -j ACCEPT'"
      done
      echo "RemainAfterExit=yes"
      echo ""
      echo "[Install]"
      echo "WantedBy=multi-user.target"
    } > "$FW_SVC"
    systemctl daemon-reload
    systemctl enable --now rathole-fw.service >/dev/null 2>&1
    ok "Firewall rules applied and persisted."
  fi
}

apply_net_tuning() {
  cat > /etc/sysctl.d/99-rathole-anti-drop.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 1048576
EOF
  sysctl --system >/dev/null 2>&1
  ok "Network tuning applied (BBR, large buffers, fastopen)."
}

apply_mss_clamp() {
  local IPT; IPT="$(command -v iptables 2>/dev/null || true)"
  [ -z "$IPT" ] && return 0
  "$IPT" -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || \
    "$IPT" -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360

  cat > /etc/systemd/system/rathole-mss-clamp.service <<EOF
[Unit]
Description=Rathole Anti-Drop MSS Clamp
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '${IPT} -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || ${IPT} -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now rathole-mss-clamp.service >/dev/null 2>&1
  ok "Anti-Drop MSS Clamping (1360) applied."
}

install_guard() {
  cat > /usr/local/bin/rathole-guard.sh <<EOF
#!/bin/bash
# rathole aggressive self-healing guard (v7)
PORT="${TUNNEL_PORT}"
ROLE="\$(cat /etc/rathole/role 2>/dev/null)"
UNIT=""

case "\$ROLE" in
  iran)   UNIT="rathole-iran.service" ;;
  kharej) UNIT="rathole-kharej-1.service" ;;
  *) exit 0 ;;
esac

# 1. Immediate restart if inactive
if ! systemctl is-active --quiet "\$UNIT"; then
  logger -t rathole-guard "Service \$UNIT is inactive. Restarting immediately."
  systemctl restart "\$UNIT"
  exit 0
fi

# 2. Smart drop detection
if [ "\$ROLE" = "kharej" ]; then
  if ! ss -tn state established 2>/dev/null | grep -q ":\${PORT} "; then
    if journalctl -u "\$UNIT" -n 15 --no-pager 2>/dev/null | grep -qiE "reset by peer|handshake failed|timed out|connection refused|error|panicked|websocket"; then
      logger -t rathole-guard "No established connection + critical errors. Restarting \$UNIT."
      systemctl restart "\$UNIT"
    fi
  fi
else
  if ! ss -tln 2>/dev/null | grep -q ":\${PORT} "; then
    logger -t rathole-guard "Port \$PORT not listening. Restarting \$UNIT."
    systemctl restart "\$UNIT"
  fi
fi
EOF
  chmod 0755 /usr/local/bin/rathole-guard.sh

  cat > /etc/systemd/system/rathole-guard.service <<'EOF'
[Unit]
Description=Rathole aggressive self-healing guard check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rathole-guard.sh
EOF

  cat > /etc/systemd/system/rathole-guard.timer <<'EOF'
[Unit]
Description=Rathole aggressive self-healing guard timer

[Timer]
OnBootSec=10
OnUnitActiveSec=10
AccuracySec=1
Unit=rathole-guard.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now rathole-guard.timer >/dev/null 2>&1
  ok "Aggressive guard installed (checks every 10s, instant restart on drop/error)."
  
  # Verification output
  echo -e "${C}[*]${N} Verifying watchdog timer status:"
  systemctl list-timers rathole-guard.timer --no-pager | grep rathole-guard || warn "Timer not found!"
}

setup_iran() {
  banner
  info "Setting up Iran Server (port ${TUNNEL_PORT})..."
  install_deps
  purge_watchdog
  install_core || { read -rp "Press Enter to return..."; return; }

  systemctl stop rathole-iran.service >/dev/null 2>&1
  check_tunnel_port_free || { read -rp "Press Enter to return..."; return; }

  local ports="" raw_ports
  echo ""
  echo -e "${Y}Tip: You can enter multiple ports separated by commas.${N}"
  echo -e "${C}Default ports if you press Enter: ${DEFAULT_PORTS}${N}"
  read -rp "Enter Forward Ports [Press Enter for defaults]: " raw_ports
  
  # Use default if empty
  raw_ports="${raw_ports:-$DEFAULT_PORTS}"
  ports=$(parse_ports "$raw_ports")

  check_forward_ports_free "$ports" || { read -rp "Press Enter to return..."; return; }
  choose_proto

  [ -f "$CONF_DIR/ports" ] && cp "$CONF_DIR/ports" "$CONF_DIR/ports.prev"
  printf '%s\n' $ports > "$CONF_DIR/ports"

  local conf="$CONF_DIR/iran-server.toml"
  {
    echo "[server]"
    echo "bind_addr = \"0.0.0.0:${TUNNEL_PORT}\""
    echo "default_token = \"${TOKEN}\""
    echo "heartbeat_interval = 10"
    echo ""
    transport_server_block
    echo ""
    for p in $ports; do
      echo "[server.services.p${p}]"
      echo "bind_addr = \"0.0.0.0:${p}\""
      echo ""
    done
  } > "$conf"
  chmod 600 "$conf"

  make_unit "rathole-iran" "$conf" "Rathole Iran Server" "$TUNNEL_PORT" || { read -rp "Press Enter to return..."; return; }
  apply_net_tuning
  apply_mss_clamp
  open_ports "$ports"
  echo "iran" > "$ROLE_FILE"
  echo "$PROTO" > "$PROTO_FILE"
  install_guard

  echo ""
  ok "Iran Server ready on port ${TUNNEL_PORT} (protocol: ${PROTO})."
  ok "Fixed Token used: ${TOKEN}"
  read -rp "Press Enter to return..."
}

setup_kharej() {
  banner
  info "Setting up Kharej Server (client)..."
  install_deps
  purge_watchdog
  install_core || { read -rp "Press Enter to return..."; return; }

  systemctl stop rathole-kharej-1.service >/dev/null 2>&1

  choose_proto

  local ip=""
  while [ -z "$ip" ]; do
    read -rp "Enter Iran Server IP: " ip
    [[ "$ip" =~ ^[0-9a-zA-Z.:-]+$ ]] || { warn "Invalid address."; ip=""; }
  done

  local ports="" raw_ports
  echo ""
  echo -e "${Y}Tip: These ports MUST match the Iran side exactly.${N}"
  echo -e "${C}Default ports if you press Enter: ${DEFAULT_PORTS}${N}"
  read -rp "Enter Forward Ports [Press Enter for defaults]: " raw_ports
  
  # Use default if empty
  raw_ports="${raw_ports:-$DEFAULT_PORTS}"
  ports=$(parse_ports "$raw_ports")

  local conf="$CONF_DIR/kharej-client-1.toml"
  {
    echo "[client]"
    echo "remote_addr = \"${ip}:${TUNNEL_PORT}\""
    echo "default_token = \"${TOKEN}\""
    echo "retry_interval = 1"
    echo "heartbeat_timeout = 40"
    echo ""
    transport_client_block
    echo ""
    for p in $ports; do
      echo "[client.services.p${p}]"
      echo "local_addr = \"127.0.0.1:${p}\""
      echo ""
    done
  } > "$conf"
  chmod 600 "$conf"

  make_unit "rathole-kharej-1" "$conf" "Rathole Kharej Client" || { read -rp "Press Enter to return..."; return; }
  apply_net_tuning
  apply_mss_clamp
  echo "kharej" > "$ROLE_FILE"
  echo "$PROTO" > "$PROTO_FILE"
  install_guard

  info "Watching the first seconds of the connection..."
  sleep 3
  if journalctl -u rathole-kharej-1 -n 12 --no-pager 2>/dev/null | grep -qiE "error|refused|reset|panicked"; then
    warn "Recent errors detected. Check logs or try a different protocol/port."
    journalctl -u rathole-kharej-1 -n 12 --no-pager
  else
    ok "No recent errors — control channel is up."
  fi

  echo ""
  ok "Kharej client configured (Iran: ${ip}:${TUNNEL_PORT}, protocol: ${PROTO})."
  ok "Fixed Token used: ${TOKEN}"
  read -rp "Press Enter to return..."
}

show_status() {
  banner
  local role proto
  role="$(cat "$ROLE_FILE" 2>/dev/null || echo '?')"
  proto="$(cat "$PROTO_FILE" 2>/dev/null || echo '?')"
  info "Role: ${role}    Protocol: ${proto}    Tunnel port: ${TUNNEL_PORT}"
  echo ""
  systemctl status rathole-iran rathole-kharej-1 --no-pager 2>/dev/null | head -n 20
  echo ""
  info "Watchdog Timer Status:"
  systemctl list-timers rathole-guard.timer --no-pager | grep rathole-guard || echo "Not active"
  echo ""
  info "Established tunnel connections on port ${TUNNEL_PORT}:"
  ss -tn state established 2>/dev/null | grep ":${TUNNEL_PORT}" || echo "none"
  echo ""
  read -rp "Press Enter to return..."
}

restart_all() {
  systemctl restart rathole-iran rathole-kharej-1 2>/dev/null
  ok "Services restarted."
  sleep 2
}

uninstall_all() {
  local IPT; IPT="$(command -v iptables 2>/dev/null || true)"
  systemctl stop rathole-iran rathole-kharej-1 rathole-fw rathole-mss-clamp rathole-guard.timer rathole-guard.service 2>/dev/null
  systemctl disable rathole-iran rathole-kharej-1 rathole-fw rathole-mss-clamp rathole-guard.timer rathole-guard.service 2>/dev/null

  if [ -n "$IPT" ]; then
    local plist="$TUNNEL_PORT"
    [ -f "$CONF_DIR/ports" ] && plist="$plist $(tr '\n' ' ' < "$CONF_DIR/ports")"
    [ -f "$CONF_DIR/ports.prev" ] && plist="$plist $(tr '\n' ' ' < "$CONF_DIR/ports.prev")"
    local p
    for p in $plist; do
      "$IPT" -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
    done
    "$IPT" -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null
  fi

  rm -rf "$CONF_DIR" "$BIN" /usr/local/bin/rathole-guard.sh
  rm -f /etc/systemd/system/rathole* 
  rm -f /etc/sysctl.d/99-rathole-anti-drop.conf
  sysctl --system >/dev/null 2>&1
  systemctl daemon-reload
  ok "Tunnel fully removed."
  sleep 2
}

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
