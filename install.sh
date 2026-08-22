#!/bin/bash
# =============================================================================
#  Rathole Reverse Tunnel — v9 (WebSocket Reverse Proxy via Caddy on Port 80)
#  
#  Changes in v9:
#  - WebSocket now runs behind Caddy reverse proxy on port 80 (no domain needed)
#  - Rathole binds to 127.0.0.1 instead of 0.0.0.0 when WebSocket is selected
#  - Noise and TCP protocols remain completely untouched
#  - Auto-installs Caddy if missing when WebSocket is chosen
# =============================================================================

set -u

TUNNEL_PORT="8443"
TOKEN="e8c94f6a4e5ef135d7061fe365a686c070c1d1cd7337d8f6"
NOISE_PRIV="8bytOyfav+CIn6pEY+gCUSn6PpHJh7ADeHT55wmrTsE="
NOISE_PUB="gHmg3PHFH9+CouNJfGV28I4JwS3Hm28F8Vl2vGraU3g="
DEFAULT_PORTS="1080,443,23902,2053,8090"

RATHOLE_VERSION="v0.5.0"
RATHOLE_VERSION_MUSL="v0.4.8"
BIN="/usr/local/bin/rathole"
CONF_DIR="/etc/rathole"
ROLE_FILE="$CONF_DIR/role"
PROTO_FILE="$CONF_DIR/proto"
PORT_FILE="$CONF_DIR/tunnel_port"
FW_SVC="/etc/systemd/system/rathole-fw.service"
CADDY_WS_PORT="18443" # Internal port rathole listens on when using Caddy

if [ -f "$PORT_FILE" ]; then
  saved_port="$(cat "$PORT_FILE" 2>/dev/null || echo "")"
  if [[ "$saved_port" =~ ^[0-9]+$ ]] && [ "$saved_port" -ge 1 ] && [ "$saved_port" -le 65535 ]; then
    TUNNEL_PORT="$saved_port"
  fi
fi

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
ok()   { echo -e "${G}[✔]${N} $1"; }
err()  { echo -e "${R}[✘]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
info() { echo -e "${C}[*]${N} $1"; }

banner() {
  clear
  echo -e "${C}=============================================================${N}"
  echo -e "${G}   Rathole v9 — WS Reverse Proxy (Caddy:80) + Noise/TCP${N}"
  echo -e "${C}      IRAN (Server)  <<==  ${TUNNEL_PORT}  ==>>  KHAREJ (Client)${N}"
  echo -e "${C}=============================================================${N}"
  echo ""
}

need_root() { [ "$(id -u)" -ne 0 ] && { err "Root required."; exit 1; }; }

install_deps() {
  local need=()
  command -v curl     >/dev/null 2>&1 || need+=(curl)
  command -v unzip    >/dev/null 2>&1 || need+=(unzip)
  command -v ss       >/dev/null 2>&1 || need+=(iproute2)
  command -v iptables >/dev/null 2>&1 || need+=(iptables)
  command -v tc       >/dev/null 2>&1 || need+=(iproute2)
  if command -v apt-get >/dev/null 2>&1; then
    [ ${#need[@]} -gt 0 ] && { info "Installing: ${need[*]}"; apt-get update -y >/dev/null 2>&1; apt-get install -y "${need[@]}" >/dev/null 2>&1; }
  elif command -v dnf >/dev/null 2>&1; then
    [ ${#need[@]} -gt 0 ] && { info "Installing: ${need[*]}"; dnf install -y "${need[@]}" >/dev/null 2>&1; }
  elif command -v yum >/dev/null 2>&1; then
    [ ${#need[@]} -gt 0 ] && { info "Installing: ${need[*]}"; yum install -y "${need[@]}" >/dev/null 2>&1; }
  fi
  ok "Prerequisites ready."
}

purge_watchdog() {
  local removed=0 u
  for u in rathole-watchdog.service rathole-watchdog.timer watchdog.service watchdog.timer rathole-guard.service rathole-guard.timer; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${u}" && { systemctl disable --now "$u" >/dev/null 2>&1; rm -f "/etc/systemd/system/${u}"; removed=1; }
  done
  rm -f /usr/local/bin/rathole-guard.sh /usr/local/bin/rathole-watchdog.sh 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  [ "$removed" = "1" ] && ok "Legacy watchdogs purged."
}

detect_asset() {
  case "$(uname -m)" in
    x86_64|amd64) ASSET="rathole-x86_64-unknown-linux-gnu.zip"; ASSET_VERSION="$RATHOLE_VERSION" ;;
    aarch64|arm64) ASSET="rathole-aarch64-unknown-linux-gnu.zip"; ASSET_VERSION="$RATHOLE_VERSION" ;;
    *) err "Unsupported arch: $(uname -m)"; return 1 ;;
  esac
}

download_asset() {
  local tmp="$1" u
  info "Downloading rathole ${ASSET_VERSION}..."
  for u in \
    "https://github.com/rathole-org/rathole/releases/download/${ASSET_VERSION}/${ASSET}" \
    "https://ghproxy.net/https://github.com/rathole-org/rathole/releases/download/${ASSET_VERSION}/${ASSET}" \
    "https://ghfast.top/https://github.com/rathole-org/rathole/releases/download/${ASSET_VERSION}/${ASSET}"; do
    curl -fL --connect-timeout 12 --max-time 240 -o "$tmp/rathole.zip" "$u" 2>/dev/null && \
      [ "$(stat -c%s "$tmp/rathole.zip" 2>/dev/null || echo 0)" -gt 100000 ] && return 0
  done
  return 1
}

extract_install_zip() {
  local tmp="$1" binfile
  unzip -o "$tmp/rathole.zip" -d "$tmp" >/dev/null 2>&1 || return 1
  binfile="$(find "$tmp" -type f -name rathole | head -n1)"
  [ -z "$binfile" ] && return 1
  install -m 0755 "$binfile" "$BIN" || return 1
}

install_core() {
  if [ -x "$BIN" ] && [ "${1:-}" != "force" ] && "$BIN" --version >/dev/null 2>&1; then
    ok "Rathole installed: $("$BIN" --version 2>/dev/null | head -n1)"; return 0
  fi
  detect_asset || return 1
  local tmp; tmp=$(mktemp -d)
  if ! download_asset "$tmp"; then
    if [ "$(uname -m)" = "aarch64" ] && [ "$ASSET_VERSION" = "$RATHOLE_VERSION" ]; then
      warn "Trying older ARM musl build..."; ASSET="rathole-aarch64-unknown-linux-musl.zip"; ASSET_VERSION="$RATHOLE_VERSION_MUSL"
      download_asset "$tmp" || { err "Download failed."; rm -rf "$tmp"; return 1; }
    else err "Download failed."; rm -rf "$tmp"; return 1; fi
  fi
  extract_install_zip "$tmp" || { err "Extract failed."; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"; mkdir -p "$CONF_DIR"
  if ! "$BIN" --version >/dev/null 2>&1; then
    warn "Binary cannot run. Trying static musl..."; rm -f "$BIN"
    [ "$(uname -m)" = "x86_64" ] && ASSET="rathole-x86_64-unknown-linux-musl.zip" || ASSET="rathole-aarch64-unknown-linux-musl.zip"
    ASSET_VERSION="$RATHOLE_VERSION_MUSL"; local t2; t2=$(mktemp -d)
    download_asset "$t2" && extract_install_zip "$t2"; rm -rf "$t2"
  fi
  "$BIN" --version >/dev/null 2>&1 || { err "Cannot run rathole."; return 1; }
  ok "Rathole installed: $("$BIN" --version 2>/dev/null | head -n1)"
}

parse_ports() {
  local raw="$1" out="" p
  raw="${raw//،/,}"; raw="${raw// /,}"; raw="${raw//;/,}"
  IFS=',' read -ra arr <<< "$raw"
  for p in "${arr[@]}"; do
    p="${p// /}"; [[ "$p" =~ ^[0-9]+$ ]] || continue
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || continue; [ "$p" = "$TUNNEL_PORT" ] && continue
    case " $out " in *" $p "*) continue ;; esac; out="$out $p"
  done; echo "${out# }"
}

port_in_use() { ss -tln 2>/dev/null | grep -q ":${1} "; }
find_free_port() { local p="$1"; while port_in_use "$p"; do p=$((p+1)); [ "$p" -gt 65535 ] && p=1024; done; echo "$p"; }

check_tunnel_port_free() {
  if port_in_use "$TUNNEL_PORT"; then
    warn "Port ${TUNNEL_PORT} in use."; read -rp "Free it and press Enter (or Ctrl+C)..."
    port_in_use "$TUNNEL_PORT" && { err "Still in use."; return 1; }
  fi
}

check_forward_ports_free() {
  local ports="$1" bad="" p
  for p in $ports; do
    ss -tln 2>/dev/null | grep -q ":${p} " && ! ss -tlnp 2>/dev/null | grep -E ":${p} " | grep -q rathole && bad="$bad $p"
  done
  [ -n "$bad" ] && { err "Ports in use:${bad}"; return 1; }; return 0
}

# ---------- Caddy Install & Config (Only for WebSocket) ----------
install_caddy() {
  if command -v caddy >/dev/null 2>&1; then ok "Caddy already installed."; return 0; fi
  info "Installing Caddy web server..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null 2>&1
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt-get update -y >/dev/null 2>&1 && apt-get install -y caddy >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y 'dnf-command(copr)' >/dev/null 2>&1
    dnf copr enable -y @caddy/caddy >/dev/null 2>&1
    dnf install -y caddy >/dev/null 2>&1
  else
    err "Cannot auto-install Caddy on this distro. Install manually."; return 1
  fi
  command -v caddy >/dev/null 2>&1 || { err "Caddy installation failed."; return 1; }
  ok "Caddy installed successfully."
}

configure_caddy_ws() {
  local internal_port="$1"
  cat > /etc/caddy/Caddyfile <<EOF
:80 {
    reverse_proxy 127.0.0.1:${internal_port}
}
EOF
  systemctl restart caddy >/dev/null 2>&1
  systemctl enable caddy >/dev/null 2>&1
  sleep 1
  if systemctl is-active --quiet caddy; then
    ok "Caddy configured: :80 -> 127.0.0.1:${internal_port}"
  else
    err "Caddy failed to start:"; journalctl -u caddy -n 10 --no-pager; return 1
  fi
}

# ---------- Protocol Selection ----------
choose_proto() {
  echo ""; echo -e "${Y}Choose transport protocol:${N}"
  echo "  1) Noise     (Recommended - encrypted, stable)"
  echo "  2) TCP       (Plain, less CPU)"
  echo "  3) WebSocket (Reverse via Caddy on port 80 - no domain needed)"
  echo ""
  read -rp "Choice [1]: " pc
  case "${pc:-1}" in
    2) PROTO="tcp" ;;
    3) PROTO="websocket" ;;
    *) PROTO="noise" ;;
  esac
  ok "Selected: $PROTO"

  if [ "$PROTO" = "websocket" ]; then
    warn "WebSocket will run behind Caddy reverse proxy on port 80 (plain HTTP, no TLS)."
    warn "Rathole will bind to 127.0.0.1:${CADDY_WS_PORT} (not publicly exposed)."
    TUNNEL_PORT=80
    ok "Tunnel port set to 80 (Caddy public), rathole internal: ${CADDY_WS_PORT}"
    install_caddy || return 1
  fi
}

# ---------- Config Blocks ----------
transport_server_block() {
  local bind_addr="0.0.0.0:${TUNNEL_PORT}"
  [ "$PROTO" = "websocket" ] && bind_addr="127.0.0.1:${CADDY_WS_PORT}"

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
  [ "$PROTO" = "noise" ] && cat <<EOF

[server.transport.noise]
pattern = "Noise_NK_25519_ChaChaPoly_BLAKE2s"
local_private_key = "${NOISE_PRIV}"
EOF
  [ "$PROTO" = "websocket" ] && cat <<EOF

[server.transport.websocket]
tls = false
EOF
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
  [ "$PROTO" = "noise" ] && cat <<EOF

[client.transport.noise]
pattern = "Noise_NK_25519_ChaChaPoly_BLAKE2s"
remote_public_key = "${NOISE_PUB}"
EOF
  [ "$PROTO" = "websocket" ] && cat <<EOF

[client.transport.websocket]
tls = false
EOF
}

make_unit() {
  local name="$1" conf="$2" desc="$3" port="${4:-}"
  systemctl stop "${name}.service" >/dev/null 2>&1; systemctl reset-failed "${name}.service" >/dev/null 2>&1
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
  systemctl daemon-reload; systemctl enable --now "${name}.service" >/dev/null 2>&1
  sleep 2
  systemctl is-active --quiet "${name}.service" || { err "${name} failed:"; journalctl -u "${name}" -n 15 --no-pager; return 1; }
  journalctl -u "${name}" -n 20 --no-pager 2>/dev/null | grep -qiE "panicked|core-dump" && { err "${name} crash-looping."; return 1; }
  [ -n "$port" ] && ! port_in_use "$port" && { err "${name} active but port ${port} not bound."; return 1; }
  ok "${name} active and stable."
}

open_ports() {
  local ports="$1" p IPT; IPT="$(command -v iptables 2>/dev/null || true)"
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
    local prev=""; [ -f "$CONF_DIR/ports.prev" ] && prev="$(tr '\n' ' ' < "$CONF_DIR/ports.prev")"
    for p in $prev; do case " $ports " in *" $p "*) continue ;; esac; "$IPT" -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; done
    "$IPT" -C INPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT 2>/dev/null || "$IPT" -I INPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT
    for p in $ports; do "$IPT" -C INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null || "$IPT" -I INPUT -p tcp --dport "${p}" -j ACCEPT; done
    { echo "[Unit]"; echo "Description=Rathole FW"; echo "After=network-online.target"; echo "[Service]"; echo "Type=oneshot"
      echo "ExecStart=/bin/sh -c '$IPT -C INPUT -p tcp --dport ${TUNNEL_PORT} -j ACCEPT 2>/dev/null || $IPT -A INPUT -p tcp --dport ${TUNNEL_PORT} -j ACCEPT'"
      for p in $ports; do echo "ExecStart=/bin/sh -c '$IPT -C INPUT -p tcp --dport ${p} -j ACCEPT 2>/dev/null || $IPT -A INPUT -p tcp --dport ${p} -j ACCEPT'"; done
      echo "RemainAfterExit=yes"; echo "[Install]"; echo "WantedBy=multi-user.target"
    } > "$FW_SVC"
    systemctl daemon-reload; systemctl enable --now rathole-fw.service >/dev/null 2>&1
    ok "Firewall rules applied."
  fi
}

apply_net_tuning() {
  cat > /etc/sysctl.d/99-rathole-anti-drop.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 1048576
EOF
  sysctl --system >/dev/null 2>&1; ok "Network tuning applied."
}

apply_mss_clamp() {
  local IPT; IPT="$(command -v iptables 2>/dev/null || true)"; [ -z "$IPT" ] && return 0
  "$IPT" -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
  "$IPT" -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    "$IPT" -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  "$IPT" -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    "$IPT" -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  cat > /etc/systemd/system/rathole-mss-clamp.service <<EOF
[Unit]
Description=MSS Clamp
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c '$IPT -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true'
ExecStart=/bin/sh -c '$IPT -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || $IPT -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
ExecStart=/bin/sh -c '$IPT -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || $IPT -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable --now rathole-mss-clamp.service >/dev/null 2>&1; ok "MSS clamp applied."
}

install_guard() {
  cat > /usr/local/bin/rathole-guard.sh <<EOF
#!/bin/bash
PORT="${TUNNEL_PORT}"
ROLE="\$(cat /etc/rathole/role 2>/dev/null)"
STATE=/run/rathole-guard.fails
fails="\$(cat "\$STATE" 2>/dev/null || echo 0)"
reset_fails() { echo 0 > "\$STATE"; exit 0; }
mark_fail() {
  fails=\$((fails+1)); echo "\$fails" > "\$STATE"
  if [ "\$fails" -ge 2 ]; then
    logger -t rathole-guard "Restarting \$1 after \$fails fails (port ${TUNNEL_PORT})"
    systemctl restart "\$1"; echo 0 > "\$STATE"
  fi; exit 0
}
case "\$ROLE" in
  iran)   UNIT="rathole-iran.service" ;;
  kharej) UNIT="rathole-kharej-1.service" ;;
  *) exit 0 ;;
esac
systemctl is-active --quiet "\$UNIT" || { systemctl restart "\$UNIT"; echo 0 > "\$STATE"; exit 0; }
if [ "\$ROLE" = "kharej" ]; then
  ss -tn state established 2>/dev/null | grep -q ":\${PORT} " && reset_fails || mark_fail "\$UNIT"
else
  ss -tln 2>/dev/null | grep -q ":\${PORT} " && reset_fails || mark_fail "\$UNIT"
fi
EOF
  chmod 0755 /usr/local/bin/rathole-guard.sh
  cat > /etc/systemd/system/rathole-guard.service <<'EOF'
[Unit]
Description=Rathole Guard Check
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rathole-guard.sh
EOF
  cat > /etc/systemd/system/rathole-guard.timer <<'EOF'
[Unit]
Description=Rathole Guard Timer
[Timer]
OnBootSec=5
OnUnitActiveSec=5
AccuracySec=1
Unit=rathole-guard.service
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload; systemctl enable --now rathole-guard.timer >/dev/null 2>&1
  ok "Watchdog active (5s interval)."
  systemctl list-timers rathole-guard.timer --no-pager 2>/dev/null | grep rathole-guard || warn "Timer not detected!"
}

# ---------- Setup Functions ----------
setup_iran() {
  banner; info "Setting up Iran Server..."
  install_deps; purge_watchdog; install_core || { read -rp "Enter..."; return; }
  systemctl stop rathole-iran.service >/dev/null 2>&1
  choose_proto || { read -rp "Enter..."; return; }
  check_tunnel_port_free || { read -rp "Enter..."; return; }
  local ports="" raw_ports
  echo -e "${Y}Forward ports (comma-separated). Default: ${DEFAULT_PORTS}${N}"
  read -rp "Ports [Enter=default]: " raw_ports; raw_ports="${raw_ports:-$DEFAULT_PORTS}"
  ports=$(parse_ports "$raw_ports")
  while [ -z "$ports" ]; do warn "No valid ports."; read -rp "Ports [Enter=default]: " raw_ports; raw_ports="${raw_ports:-$DEFAULT_PORTS}"; ports=$(parse_ports "$raw_ports"); done
  check_forward_ports_free "$ports" || { read -rp "Enter..."; return; }
  [ -f "$CONF_DIR/ports" ] && cp "$CONF_DIR/ports" "$CONF_DIR/ports.prev"
  printf '%s\n' $ports > "$CONF_DIR/ports"

  local bind_display="0.0.0.0:${TUNNEL_PORT}"
  [ "$PROTO" = "websocket" ] && bind_display="127.0.0.1:${CADDY_WS_PORT} (Caddy proxies :80)"

  local conf="$CONF_DIR/iran-server.toml"
  { echo "[server]"; echo "bind_addr = \"${bind_display%% (*}\""
    echo "default_token = \"${TOKEN}\""; echo "heartbeat_interval = 10"; echo ""
    transport_server_block; echo ""
    for p in $ports; do echo "[server.services.p${p}]"; echo "type = \"tcp\""; echo "bind_addr = \"0.0.0.0:${p}\""; echo "nodelay = true"; echo ""; done
  } > "$conf"; chmod 600 "$conf"

  # For websocket, rathole binds internally; check that internal port instead
  local check_port="$TUNNEL_PORT"
  [ "$PROTO" = "websocket" ] && check_port="$CADDY_WS_PORT"

  make_unit "rathole-iran" "$conf" "Rathole Iran Server" "$check_port" || { read -rp "Enter..."; return; }

  [ "$PROTO" = "websocket" ] && configure_caddy_ws "$CADDY_WS_PORT"

  apply_net_tuning; apply_mss_clamp; open_ports "$ports"
  echo "iran" > "$ROLE_FILE"; echo "$PROTO" > "$PROTO_FILE"; echo "$TUNNEL_PORT" > "$PORT_FILE"
  install_guard
  echo ""; ok "Iran ready. Public: :${TUNNEL_PORT} | Protocol: ${PROTO}"
  [ "$PROTO" = "websocket" ] && ok "Caddy reverse proxy active on port 80 -> rathole 127.0.0.1:${CADDY_WS_PORT}"
  ok "Token: ${TOKEN}"
  warn "Kharej MUST use same protocol and port ${TUNNEL_PORT}"
  read -rp "Enter..."
}

setup_kharej() {
  banner; info "Setting up Kharej Client..."
  install_deps; purge_watchdog; install_core || { read -rp "Enter..."; return; }
  systemctl stop rathole-kharej-1.service >/dev/null 2>&1
  choose_proto || { read -rp "Enter..."; return; }
  local ip=""
  while [ -z "$ip" ]; do read -rp "Iran Server IP: " ip; [[ "$ip" =~ ^[0-9a-zA-Z.:-]+$ ]] || { warn "Invalid."; ip=""; }; done
  local ports="" raw_ports
  echo -e "${Y}Forward ports MUST match Iran. Default: ${DEFAULT_PORTS}${N}"
  read -rp "Ports [Enter=default]: " raw_ports; raw_ports="${raw_ports:-$DEFAULT_PORTS}"
  ports=$(parse_ports "$raw_ports")
  while [ -z "$ports" ]; do warn "No valid ports."; read -rp "Ports [Enter=default]: " raw_ports; raw_ports="${raw_ports:-$DEFAULT_PORTS}"; ports=$(parse_ports "$raw_ports"); done

  local conf="$CONF_DIR/kharej-client-1.toml"
  { echo "[client]"; echo "remote_addr = \"${ip}:${TUNNEL_PORT}\""
    echo "default_token = \"${TOKEN}\""; echo "retry_interval = 1"; echo "heartbeat_timeout = 40"; echo ""
    transport_client_block; echo ""
    for p in $ports; do echo "[client.services.p${p}]"; echo "type = \"tcp\""; echo "local_addr = \"127.0.0.1:${p}\""; echo "nodelay = true"; echo ""; done
  } > "$conf"; chmod 600 "$conf"

  make_unit "rathole-kharej-1" "$conf" "Rathole Kharej Client" || { read -rp "Enter..."; return; }
  apply_net_tuning; apply_mss_clamp
  echo "kharej" > "$ROLE_FILE"; echo "$PROTO" > "$PROTO_FILE"; echo "$TUNNEL_PORT" > "$PORT_FILE"
  install_guard

  info "Checking connection..."; sleep 3
  if ss -tn state established 2>/dev/null | grep -q ":${TUNNEL_PORT} "; then
    ok "Control channel established."
  else
    warn "No established connection yet."; journalctl -u rathole-kharej-1 -n 15 --no-pager
    warn "Check: matching protocol/port, firewall, Caddy running on Iran side"
  fi
  echo ""; ok "Kharej configured (Iran: ${ip}:${TUNNEL_PORT}, ${PROTO})"
  ok "Token: ${TOKEN}"; read -rp "Enter..."
}

show_status() {
  banner
  [ -f "$PORT_FILE" ] && { local sp; sp="$(cat "$PORT_FILE" 2>/dev/null)"; [[ "$sp" =~ ^[0-9]+$ ]] && TUNNEL_PORT="$sp"; }
  local role proto; role="$(cat "$ROLE_FILE" 2>/dev/null || echo '?')"; proto="$(cat "$PROTO_FILE" 2>/dev/null || echo '?')"
  info "Role: ${role} | Proto: ${proto} | Public Port: ${TUNNEL_PORT}"
  [ "$proto" = "websocket" ] && info "Caddy internal port: ${CADDY_WS_PORT}"
  echo ""; systemctl status rathole-iran rathole-kharej-1 --no-pager 2>/dev/null | head -n 25
  [ "$proto" = "websocket" ] && { echo ""; info "Caddy status:"; systemctl is-active caddy 2>/dev/null && ok "Caddy active" || err "Caddy NOT active"; }
  echo ""; info "Guard timer:"; systemctl list-timers rathole-guard.timer --no-pager 2>/dev/null | grep rathole-guard || echo "Inactive"
  echo ""; info "Established on :${TUNNEL_PORT}:"; ss -tn state established 2>/dev/null | grep ":${TUNNEL_PORT}" || echo "none"
  echo ""; read -rp "Enter..."
}

restart_all() { rm -f /run/rathole-guard.fails; systemctl restart rathole-iran rathole-kharej-1 2>/dev/null; ok "Restarted."; sleep 2; }

apply_tcp_optimizer() {
  banner; info "TCP Optimizer: BBR + FQ + low-latency buffers"
  read -rp "Apply? [Y/n]: " ans; [[ "${ans:-Y}" =~ ^[Nn]$ ]] && return
  modprobe tcp_bbr 2>/dev/null || true; mkdir -p /etc/modules-load.d; echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
  cat > /etc/sysctl.d/99-tcp-optimizer.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 2097152
EOF
  sysctl --system >/dev/null 2>&1
  sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr || warn "BBR not active: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  if command -v tc >/dev/null 2>&1; then
    cat > /usr/local/bin/tcp-optimizer-qdisc.sh <<'SCRIPT'
#!/bin/bash
command -v tc >/dev/null 2>&1 || exit 0
for d in /sys/class/net/*; do dev="$(basename "$d")"; [ "$dev" = "lo" ] && continue
  ip link show "$dev" 2>/dev/null | grep -q "state UP" && tc qdisc replace dev "$dev" root fq 2>/dev/null || true
done
SCRIPT
    chmod 0755 /usr/local/bin/tcp-optimizer-qdisc.sh; /usr/local/bin/tcp-optimizer-qdisc.sh
    cat > /etc/systemd/system/tcp-optimizer-qdisc.service <<'EOF'
[Unit]
Description=FQ Qdisc
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/tcp-optimizer-qdisc.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable --now tcp-optimizer-qdisc.service >/dev/null 2>&1
  fi
  ok "TCP Optimizer applied."; read -rp "Enter..."
}

uninstall_all() {
  local IPT; IPT="$(command -v iptables 2>/dev/null || true)"
  systemctl stop rathole-iran rathole-kharej-1 rathole-fw rathole-mss-clamp rathole-guard.timer rathole-guard.service tcp-optimizer-qdisc.service 2>/dev/null
  systemctl disable rathole-iran rathole-kharej-1 rathole-fw rathole-mss-clamp rathole-guard.timer rathole-guard.service tcp-optimizer-qdisc.service 2>/dev/null
  if [ -n "$IPT" ]; then
    local plist="$TUNNEL_PORT"; [ -f "$CONF_DIR/ports" ] && plist="$plist $(tr '\n' ' ' < "$CONF_DIR/ports")"
    [ -f "$CONF_DIR/ports.prev" ] && plist="$plist $(tr '\n' ' ' < "$CONF_DIR/ports.prev")"
    for p in $plist; do "$IPT" -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; done
    "$IPT" -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null
    "$IPT" -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    "$IPT" -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
  fi
  rm -rf "$CONF_DIR" "$BIN" /usr/local/bin/rathole-guard.sh /usr/local/bin/tcp-optimizer-qdisc.sh
  rm -f /etc/systemd/system/rathole* /etc/systemd/system/tcp-optimizer-qdisc.service
  rm -f /etc/sysctl.d/99-rathole-anti-drop.conf /etc/sysctl.d/99-tcp-optimizer.conf /etc/modules-load.d/bbr.conf /run/rathole-guard.fails
  sysctl --system >/dev/null 2>&1; systemctl daemon-reload
  ok "Fully removed (Caddy NOT removed — uninstall separately if needed)."; sleep 2
}

main_menu() {
  while true; do
    banner
    echo " 1) Install Iran Server"
    echo " 2) Install Kharej Client"
    echo " 3) Status & Connection Test"
    echo " 4) Restart Services"
    echo " 5) Fully Remove Tunnel"
    echo " 6) TCP Optimizer"
    echo " 0) Exit"
    echo ""
    read -rp "Choice: " ch
    case "$ch" in
      1) setup_iran ;; 2) setup_kharej ;; 3) show_status ;; 4) restart_all ;;
      5) uninstall_all ;; 6) apply_tcp_optimizer ;; 0) exit 0 ;; *) warn "Invalid."; sleep 1 ;;
    esac
  done
}

need_root; main_menu
