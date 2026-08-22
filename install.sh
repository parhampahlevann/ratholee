#!/bin/bash
# =============================================================================
#  Rathole Reverse Tunnel — v8
#  - WebSocket local compatibility test
#  - Fixed WebSocket config generation
#  - Default forward ports: 1080,443,23902,2053,8090
#  - Aggressive watchdog: every 5 seconds
#  - Separate TCP Optimizer menu option
# =============================================================================

set -u

# ---------- Fixed settings ----------
TUNNEL_PORT="8443"
TOKEN="e8c94f6a4e5ef135d7061fe365a686c070c1d1cd7337d8f6"

# Fixed valid base64 X25519 Noise keypair
NOISE_PRIV="8bytOyfav+CIn6pEY+gCUSn6PpHJh7ADeHT55wmrTsE="
NOISE_PUB="gHmg3PHFH9+CouNJfGV28I4JwS3Hm28F8Vl2vGraU3g="

# Default forward ports if user just presses Enter
DEFAULT_PORTS="1080,443,23902,2053,8090"

RATHOLE_VERSION="v0.5.0"
RATHOLE_VERSION_MUSL="v0.4.8"
BIN="/usr/local/bin/rathole"
CONF_DIR="/etc/rathole"
ROLE_FILE="$CONF_DIR/role"
PROTO_FILE="$CONF_DIR/proto"
PORT_FILE="$CONF_DIR/tunnel_port"
FW_SVC="/etc/systemd/system/rathole-fw.service"

# Load saved tunnel port if exists
if [ -f "$PORT_FILE" ]; then
  saved_port="$(cat "$PORT_FILE" 2>/dev/null || echo "")"
  if [[ "$saved_port" =~ ^[0-9]+$ ]] && [ "$saved_port" -ge 1 ] && [ "$saved_port" -le 65535 ]; then
    TUNNEL_PORT="$saved_port"
  fi
fi

# ---------- Colors ----------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

ok()   { echo -e "${G}[✔]${N} $1"; }
err()  { echo -e "${R}[✘]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
info() { echo -e "${C}[*]${N} $1"; }

banner() {
  clear
  echo -e "${C}=============================================================${N}"
  echo -e "${G}   Rathole Reverse Tunnel — v8 (WebSocket Fix + Optimizer)${N}"
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

# ---------- Install prerequisites ----------
install_deps() {
  local need=()
  command -v curl     >/dev/null 2>&1 || need+=(curl)
  command -v unzip    >/dev/null 2>&1 || need+=(unzip)
  command -v ss       >/dev/null 2>&1 || need+=(iproute2)
  command -v iptables >/dev/null 2>&1 || need+=(iptables)
  command -v tc       >/dev/null 2>&1 || need+=(iproute2)

  if command -v apt-get >/dev/null 2>&1; then
    [ ${#need[@]} -gt 0 ] && { info "Installing prerequisites: ${need[*]}"; apt-get update -y >/dev/null 2>&1; apt-get install -y "${need[@]}" >/dev/null 2>&1; }
  elif command -v dnf >/dev/null 2>&1; then
    [ ${#need[@]} -gt 0 ] && { info "Installing prerequisites: ${need[*]}"; dnf install -y "${need[@]}" >/dev/null 2>&1; }
  elif command -v yum >/dev/null 2>&1; then
    [ ${#need[@]} -gt 0 ] && { info "Installing prerequisites: ${need[*]}"; yum install -y "${need[@]}" >/dev/null 2>&1; }
  fi
  ok "Prerequisites are ready."
}

# ---------- Purge old watchdogs ----------
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

# ---------- Download/install helpers ----------
detect_asset() {
  case "$(uname -m)" in
    x86_64|amd64)
      ASSET="rathole-x86_64-unknown-linux-gnu.zip"
      ASSET_VERSION="$RATHOLE_VERSION"
      ;;
    aarch64|arm64)
      # Try v0.5.0 GNU first; fallback handled in install_core if unavailable
      ASSET="rathole-aarch64-unknown-linux-gnu.zip"
      ASSET_VERSION="$RATHOLE_VERSION"
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

extract_install_zip() {
  local tmp="$1" binfile
  unzip -o "$tmp/rathole.zip" -d "$tmp" >/dev/null 2>&1 || return 1
  binfile="$(find "$tmp" -type f -name rathole | head -n1)"
  [ -z "$binfile" ] && return 1
  install -m 0755 "$binfile" "$BIN" || return 1
  return 0
}

install_core() {
  if [ -x "$BIN" ] && [ "${1:-}" != "force" ] && "$BIN" --version >/dev/null 2>&1; then
    ok "Rathole core is already installed: $("$BIN" --version 2>/dev/null | head -n1)"
    return 0
  fi

  detect_asset || return 1
  local tmp; tmp=$(mktemp -d)

  if ! download_asset "$tmp"; then
    if [ "$(uname -m)" = "aarch64" ] && [ "$ASSET_VERSION" = "$RATHOLE_VERSION" ]; then
      warn "Primary ARM asset unavailable. Trying older musl build..."
      ASSET="rathole-aarch64-unknown-linux-musl.zip"
      ASSET_VERSION="$RATHOLE_VERSION_MUSL"
      if ! download_asset "$tmp"; then
        err "Core download failed."
        rm -rf "$tmp"
        return 1
      fi
    else
      err "Core download failed. Check internet connection."
      rm -rf "$tmp"
      return 1
    fi
  fi

  if ! extract_install_zip "$tmp"; then
    err "Failed to extract/install rathole binary."
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  mkdir -p "$CONF_DIR"

  # Fallback to static musl if the installed binary cannot run here
  if ! "$BIN" --version >/dev/null 2>&1; then
    warn "Installed build cannot run here. Trying static musl build..."
    rm -f "$BIN"
    if [ "$(uname -m)" = "x86_64" ]; then
      ASSET="rathole-x86_64-unknown-linux-musl.zip"
    else
      ASSET="rathole-aarch64-unknown-linux-musl.zip"
    fi
    ASSET_VERSION="$RATHOLE_VERSION_MUSL"

    local tmp2; tmp2=$(mktemp -d)
    if download_asset "$tmp2" && extract_install_zip "$tmp2"; then
      :
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

# ---------- Port helpers ----------
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

find_free_port() {
  local p="$1"
  while port_in_use "$p"; do
    p=$((p + 1))
    [ "$p" -gt 65535 ] && p=1024
  done
  echo "$p"
}

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

# ---------- WebSocket support test ----------
ensure_websocket_binary() {
  if [ ! -x "$BIN" ]; then
    install_core || return 1
  fi

  if "$BIN" --version 2>/dev/null | grep -qE "v0\.4"; then
    warn "Current rathole 0.4.x does not support WebSocket. Trying v0.5.0..."
    install_core force || return 1
  fi
  return 0
}

websocket_local_selftest() {
  info "Running local WebSocket compatibility test..."
  if [ ! -x "$BIN" ]; then
    err "Rathole binary not found."
    return 1
  fi

  local tmp sp cp sport fport oport pass unsupported
  tmp=$(mktemp -d)
  sport=$(find_free_port 39000)
  fport=$(find_free_port 39100)
  oport=$(find_free_port 39300)

  cat > "$tmp/ws-server.toml" <<EOF
[server]
bind_addr = "127.0.0.1:${sport}"
default_token = "${TOKEN}"
heartbeat_interval = 10

[server.transport]
type = "websocket"

[server.transport.websocket]
tls = false

[server.services.wstest]
type = "tcp"
bind_addr = "127.0.0.1:${fport}"
nodelay = true
EOF

  cat > "$tmp/ws-client.toml" <<EOF
[client]
remote_addr = "127.0.0.1:${sport}"
default_token = "${TOKEN}"
retry_interval = 1
heartbeat_timeout = 40

[client.transport]
type = "websocket"

[client.transport.websocket]
tls = false

[client.services.wstest]
type = "tcp"
local_addr = "127.0.0.1:${oport}"
nodelay = true
EOF

  "$BIN" "$tmp/ws-server.toml" > "$tmp/s.log" 2>&1 &
  sp=$!
  sleep 1

  "$BIN" "$tmp/ws-client.toml" > "$tmp/c.log" 2>&1 &
  cp=$!
  sleep 3

  pass=0
  unsupported=0

  if grep -qiE "unknown variant|unsupported transport|not compiled|invalid transport|unrecognized transport" "$tmp/s.log" "$tmp/c.log" 2>/dev/null; then
    unsupported=1
  fi

  if grep -qiE "Control channel established|connection established" "$tmp/c.log" 2>/dev/null; then
    pass=1
  fi

  kill "$sp" "$cp" >/dev/null 2>&1 || true
  wait "$sp" "$cp" 2>/dev/null || true

  if [ "$unsupported" = "1" ]; then
    err "This rathole binary does not support WebSocket."
    echo "--- server log ---"
    tail -n 10 "$tmp/s.log" 2>/dev/null
    echo "--- client log ---"
    tail -n 10 "$tmp/c.log" 2>/dev/null
    rm -rf "$tmp"
    return 1
  fi

  if [ "$pass" = "1" ]; then
    ok "Local WebSocket test passed."
    rm -rf "$tmp"
    return 0
  fi

  warn "Local WebSocket test could not confirm a control channel."
  echo "--- server log ---"
  tail -n 10 "$tmp/s.log" 2>/dev/null
  echo "--- client log ---"
  tail -n 10 "$tmp/c.log" 2>/dev/null
  rm -rf "$tmp"

  read -rp "Continue with WebSocket anyway? [y/N]: " cont
  [[ "$cont" =~ ^[Yy]$ ]] && return 0 || return 1
}

# ---------- Protocol selection ----------
choose_proto() {
  echo ""
  echo -e "${Y}Choose transport protocol:${N}"
  echo "  1) Noise     (Recommended - encrypted, stable)"
  echo "  2) TCP       (plain, slightly less CPU)"
  echo "  3) WebSocket (Use for DPI bypass; best on direct IP + port 80)"
  echo ""
  read -rp "Choice [1]: " pc
  case "${pc:-1}" in
    2) PROTO="tcp" ;;
    3) PROTO="websocket" ;;
    *) PROTO="noise" ;;
  esac
  ok "Selected protocol: $PROTO"

  if [ "$PROTO" = "websocket" ]; then
    local default_port="$TUNNEL_PORT"
    [ "$default_port" = "8443" ] && default_port=80

    echo ""
    warn "For direct WebSocket, port 80 usually works better than 443."
    warn "If you use Cloudflare/CDN, plain Rathole WebSocket may not work without a reverse proxy."
    read -rp "WebSocket tunnel port (must match both sides) [${default_port}]: " wsp
    wsp="${wsp:-$default_port}"

    if [[ "$wsp" =~ ^[0-9]+$ ]] && [ "$wsp" -ge 1 ] && [ "$wsp" -le 65535 ]; then
      TUNNEL_PORT="$wsp"
    else
      TUNNEL_PORT="$default_port"
    fi

    ok "WebSocket tunnel port set to: $TUNNEL_PORT"

    ensure_websocket_binary || return 1
    websocket_local_selftest || return 1
  fi

  return 0
}

# ---------- Config blocks ----------
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

# ---------- systemd unit ----------
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
    journalctl -u "${name}.service" -n 20 --no-pager
    return 1
  fi

  if [ -n "$port" ] && ! port_in_use "$port"; then
    err "Service is active but port ${port} is NOT bound."
    journalctl -u "${name}.service" -n 15 --no-pager
    return 1
  fi

  ok "Service ${name}.service is active and stable."
  return 0
}

# ---------- Firewall ----------
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
  else
    warn "iptables not found — check cloud firewall/security group manually."
  fi
}

# ---------- Network tuning ----------
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
  ok "Rathole network tuning applied."
}

# ---------- MSS clamp ----------
apply_mss_clamp() {
  local IPT; IPT="$(command -v iptables 2>/dev/null || true)"
  [ -z "$IPT" ] && return 0

  # Remove old fixed MSS rule from older versions
  "$IPT" -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true

  "$IPT" -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    "$IPT" -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

  "$IPT" -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    "$IPT" -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

  cat > /etc/systemd/system/rathole-mss-clamp.service <<EOF
[Unit]
Description=Rathole Anti-Drop MSS Clamp
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

  systemctl daemon-reload
  systemctl enable --now rathole-mss-clamp.service >/dev/null 2>&1
  ok "Smart MSS clamp (PMTU) applied."
}

# ---------- Watchdog ----------
install_guard() {
  cat > /usr/local/bin/rathole-guard.sh <<EOF
#!/bin/bash
PORT="${TUNNEL_PORT}"
ROLE="\$(cat /etc/rathole/role 2>/dev/null)"
UNIT=""
STATE=/run/rathole-guard.fails
fails="\$(cat "\$STATE" 2>/dev/null || echo 0)"

reset_fails() { echo 0 > "\$STATE"; exit 0; }

mark_fail() {
  fails=\$((fails + 1))
  echo "\$fails" > "\$STATE"
  if [ "\$fails" -ge 2 ]; then
    logger -t rathole-guard "Restarting \$1 after \$fails failed checks (port ${TUNNEL_PORT}, role \$ROLE)"
    systemctl restart "\$1"
    echo 0 > "\$STATE"
  fi
  exit 0
}

case "\$ROLE" in
  iran)   UNIT="rathole-iran.service" ;;
  kharej) UNIT="rathole-kharej-1.service" ;;
  *) exit 0 ;;
esac

if ! systemctl is-active --quiet "\$UNIT"; then
  logger -t rathole-guard "Service \$UNIT inactive, restarting now."
  systemctl restart "\$UNIT"
  echo 0 > "\$STATE"
  exit 0
fi

if [ "\$ROLE" = "kharej" ]; then
  if ss -tn state established 2>/dev/null | grep -q ":\${PORT} "; then
    reset_fails
  else
    mark_fail "\$UNIT"
  fi
else
  if ss -tln 2>/dev/null | grep -q ":\${PORT} "; then
    reset_fails
  else
    mark_fail "\$UNIT"
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
OnBootSec=5
OnUnitActiveSec=5
AccuracySec=1
Unit=rathole-guard.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now rathole-guard.timer >/dev/null 2>&1
  ok "Aggressive watchdog installed (checks every 5 seconds)."

  echo -e "${C}[*]${N} Verifying watchdog timer status:"
  if systemctl list-timers rathole-guard.timer --no-pager 2>/dev/null | grep -q rathole-guard; then
    ok "Watchdog timer is active."
    systemctl list-timers rathole-guard.timer --no-pager | grep rathole-guard || true
  else
    warn "Watchdog timer not detected!"
  fi
}

# ---------- TCP Optimizer ----------
apply_tcp_optimizer() {
  banner
  info "TCP Optimizer: BBR + FQ + low-latency buffers for all TCP traffic, including rathole."
  read -rp "Apply TCP optimizer now? [Y/n]: " ans
  if [[ "${ans:-Y}" =~ ^[Nn]$ ]]; then
    return
  fi

  modprobe tcp_bbr 2>/dev/null || true
  mkdir -p /etc/modules-load.d
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

  cat > /etc/sysctl.d/99-tcp-optimizer.conf <<'EOF'
# TCP Optimizer for rathole and general TCP traffic
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144

net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 1440000

net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384

net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_recovery = 1

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rfc1337 = 1

net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 2097152
EOF

  sysctl --system >/dev/null 2>&1

  if ! sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    warn "BBR is not active on this kernel. Current congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  fi

  if command -v tc >/dev/null 2>&1; then
    cat > /usr/local/bin/tcp-optimizer-qdisc.sh <<'EOF'
#!/bin/bash
command -v tc >/dev/null 2>&1 || exit 0
for dev_path in /sys/class/net/*; do
  dev="$(basename "$dev_path")"
  [ "$dev" = "lo" ] && continue
  ip link show "$dev" 2>/dev/null | grep -q "state UP" || continue
  tc qdisc replace dev "$dev" root fq 2>/dev/null || true
done
exit 0
EOF
    chmod 0755 /usr/local/bin/tcp-optimizer-qdisc.sh
    /usr/local/bin/tcp-optimizer-qdisc.sh

    cat > /etc/systemd/system/tcp-optimizer-qdisc.service <<'EOF'
[Unit]
Description=Apply fq qdisc to active interfaces
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tcp-optimizer-qdisc.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now tcp-optimizer-qdisc.service >/dev/null 2>&1
  fi

  ok "TCP Optimizer applied and persisted."
  info "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) | Default qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
  read -rp "Press Enter to return..."
}

# ---------- WebSocket repair menu ----------
run_websocket_repair() {
  banner
  info "WebSocket Repair / Local Test"
  install_deps
  ensure_websocket_binary || { read -rp "Press Enter to return..."; return; }

  if websocket_local_selftest; then
    ok "WebSocket local test result: OK"
  else
    err "WebSocket local test result: FAILED"
    warn "If local test fails, use Noise/TCP or install a rathole build with WebSocket support."
    warn "If local test passes but remote still fails, issue is network/firewall/CDN/path."
  fi

  read -rp "Press Enter to return..."
}

# ---------- Setup Iran ----------
setup_iran() {
  banner
  info "Setting up Iran Server..."
  install_deps
  purge_watchdog
  install_core || { read -rp "Press Enter to return..."; return; }

  systemctl stop rathole-iran.service >/dev/null 2>&1

  choose_proto || { read -rp "Press Enter to return..."; return; }
  check_tunnel_port_free || { read -rp "Press Enter to return..."; return; }

  local ports="" raw_ports
  echo ""
  echo -e "${Y}Tip: You can enter multiple ports separated by commas.${N}"
  echo -e "${C}Default ports if you press Enter: ${DEFAULT_PORTS}${N}"
  read -rp "Enter Forward Ports [Press Enter for defaults]: " raw_ports
  raw_ports="${raw_ports:-$DEFAULT_PORTS}"
  ports=$(parse_ports "$raw_ports")

  while [ -z "$ports" ]; do
    warn "No valid forward ports entered."
    read -rp "Enter Forward Ports [Press Enter for defaults]: " raw_ports
    raw_ports="${raw_ports:-$DEFAULT_PORTS}"
    ports=$(parse_ports "$raw_ports")
  done

  check_forward_ports_free "$ports" || { read -rp "Press Enter to return..."; return; }

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
      echo "type = \"tcp\""
      echo "bind_addr = \"0.0.0.0:${p}\""
      echo "nodelay = true"
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
  echo "$TUNNEL_PORT" > "$PORT_FILE"

  install_guard

  echo ""
  ok "Iran Server ready on port ${TUNNEL_PORT} (protocol: ${PROTO})."
  ok "Fixed Token used: ${TOKEN}"
  warn "Kharej side MUST use the same protocol and same tunnel port: ${TUNNEL_PORT}"
  read -rp "Press Enter to return..."
}

# ---------- Setup Kharej ----------
setup_kharej() {
  banner
  info "Setting up Kharej Server (client)..."
  install_deps
  purge_watchdog
  install_core || { read -rp "Press Enter to return..."; return; }

  systemctl stop rathole-kharej-1.service >/dev/null 2>&1

  choose_proto || { read -rp "Press Enter to return..."; return; }

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
  raw_ports="${raw_ports:-$DEFAULT_PORTS}"
  ports=$(parse_ports "$raw_ports")

  while [ -z "$ports" ]; do
    warn "No valid forward ports entered."
    read -rp "Enter Forward Ports [Press Enter for defaults]: " raw_ports
    raw_ports="${raw_ports:-$DEFAULT_PORTS}"
    ports=$(parse_ports "$raw_ports")
  done

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
      echo "type = \"tcp\""
      echo "local_addr = \"127.0.0.1:${p}\""
      echo "nodelay = true"
      echo ""
    done
  } > "$conf"
  chmod 600 "$conf"

  make_unit "rathole-kharej-1" "$conf" "Rathole Kharej Client" || { read -rp "Press Enter to return..."; return; }

  apply_net_tuning
  apply_mss_clamp

  echo "kharej" > "$ROLE_FILE"
  echo "$PROTO" > "$PROTO_FILE"
  echo "$TUNNEL_PORT" > "$PORT_FILE"

  install_guard

  info "Checking established control channel..."
  sleep 3
  if ss -tn state established 2>/dev/null | grep -q ":${TUNNEL_PORT} "; then
    ok "Control channel established."
  else
    warn "No established connection detected yet."
    journalctl -u rathole-kharej-1 -n 15 --no-pager
    echo ""
    warn "Possible causes:"
    warn "1) Iran/Kharej protocol or tunnel port mismatch"
    warn "2) Firewall/cloud security group blocking port ${TUNNEL_PORT}"
    warn "3) WebSocket blocked by DPI/CDN; try port 80 or use Noise/TCP"
  fi

  echo ""
  ok "Kharej client configured (Iran: ${ip}:${TUNNEL_PORT}, protocol: ${PROTO})."
  ok "Fixed Token used: ${TOKEN}"
  read -rp "Press Enter to return..."
}

# ---------- Status ----------
show_status() {
  banner
  local role proto
  role="$(cat "$ROLE_FILE" 2>/dev/null || echo '?')"
  proto="$(cat "$PROTO_FILE" 2>/dev/null || echo '?')"

  if [ -f "$PORT_FILE" ]; then
    local saved_port
    saved_port="$(cat "$PORT_FILE" 2>/dev/null || echo "")"
    [[ "$saved_port" =~ ^[0-9]+$ ]] && TUNNEL_PORT="$saved_port"
  fi

  info "Role: ${role}    Protocol: ${proto}    Tunnel port: ${TUNNEL_PORT}"
  echo ""
  systemctl status rathole-iran rathole-kharej-1 --no-pager 2>/dev/null | head -n 25
  echo ""

  info "Watchdog Timer Status:"
  systemctl list-timers rathole-guard.timer --no-pager 2>/dev/null | grep rathole-guard || echo "Not active"
  echo ""

  info "Guard fail counter: $(cat /run/rathole-guard.fails 2>/dev/null || echo 0)"
  echo ""

  info "Established tunnel connections on port ${TUNNEL_PORT}:"
  ss -tn state established 2>/dev/null | grep ":${TUNNEL_PORT}" || echo "none"
  echo ""

  info "Listening check on port ${TUNNEL_PORT}:"
  ss -tln 2>/dev/null | grep ":${TUNNEL_PORT}" || warn "Not listening here."
  echo ""

  read -rp "Press Enter to return..."
}

restart_all() {
  rm -f /run/rathole-guard.fails
  systemctl restart rathole-iran rathole-kharej-1 2>/dev/null
  ok "Services restarted."
  sleep 2
}

# ---------- Uninstall ----------
uninstall_all() {
  local IPT; IPT="$(command -v iptables 2>/dev/null || true)"

  systemctl stop rathole-iran rathole-kharej-1 rathole-fw rathole-mss-clamp rathole-guard.timer rathole-guard.service tcp-optimizer-qdisc.service 2>/dev/null
  systemctl disable rathole-iran rathole-kharej-1 rathole-fw rathole-mss-clamp rathole-guard.timer rathole-guard.service tcp-optimizer-qdisc.service 2>/dev/null

  if [ -n "$IPT" ]; then
    local plist="$TUNNEL_PORT"
    [ -f "$CONF_DIR/ports" ] && plist="$plist $(tr '\n' ' ' < "$CONF_DIR/ports")"
    [ -f "$CONF_DIR/ports.prev" ] && plist="$plist $(tr '\n' ' ' < "$CONF_DIR/ports.prev")"
    local p
    for p in $plist; do
      "$IPT" -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
    done

    "$IPT" -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null
    "$IPT" -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    "$IPT" -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
  fi

  rm -rf "$CONF_DIR" "$BIN" /usr/local/bin/rathole-guard.sh
  rm -f /etc/systemd/system/rathole*
  rm -f /etc/sysctl.d/99-rathole-anti-drop.conf
  rm -f /run/rathole-guard.fails

  # Remove TCP optimizer if installed by this script
  rm -f /etc/sysctl.d/99-tcp-optimizer.conf
  rm -f /etc/modules-load.d/bbr.conf
  rm -f /usr/local/bin/tcp-optimizer-qdisc.sh
  rm -f /etc/systemd/system/tcp-optimizer-qdisc.service

  sysctl --system >/dev/null 2>&1
  systemctl daemon-reload

  ok "Tunnel and related optimizer fully removed."
  sleep 2
}

# ---------- Menu ----------
main_menu() {
  while true; do
    banner
    echo " 1) Install Iran Server (Server)"
    echo " 2) Install Kharej Server (Client)"
    echo " 3) Status & Connection Test"
    echo " 4) Restart Tunnel Services"
    echo " 5) Fully Remove Tunnel"
    echo " 6) TCP Optimizer (Speed / Ping / Stability)"
    echo " 7) WebSocket Repair / Local Test"
    echo " 0) Exit"
    echo ""
    read -rp "Choice: " ch
    case "$ch" in
      1) setup_iran ;;
      2) setup_kharej ;;
      3) show_status ;;
      4) restart_all ;;
      5) uninstall_all ;;
      6) apply_tcp_optimizer ;;
      7) run_websocket_repair ;;
      0) exit 0 ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

need_root
main_menu
