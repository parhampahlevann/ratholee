#!/bin/bash
# =============================================================================
#  Rathole Reverse Tunnel — fixed build
#  Fixes vs previous version:
#   1) Watchdog fully purged (legacy service/timer/cron removed on install & uninstall)
#   2) Port-bind conflict now BLOCKS setup instead of crash-looping the tunnel
#      (this was the main "disconnects after a few seconds" bug)
#   3) aarch64: rathole dropped the musl ARM asset in v0.5.0 -> automatic
#      fallback to v0.4.8 core with a clear warning (no websocket on ARM)
#   4) edit_ports no longer mangles the transport block / loses the Noise key
#   5) Noise keys are persisted and reused across re-runs
#   6) Client heartbeat_timeout 90 -> 45 (dead tunnels detected 2x faster)
#   7) make_unit resets failed state before start
# =============================================================================

# ---------- Fixed settings ----------
TUNNEL_PORT="443"
TOKEN="rH7kQ2vXpL9mZ4wT6nB8sD3fG5jC1yA0"
RATHOLE_VERSION="v0.5.0"          # latest stable release (x86_64)
RATHOLE_VERSION_ARM="v0.4.8"      # last release that still ships aarch64 musl
BIN="/usr/local/bin/rathole"
CONF_DIR="/etc/rathole"
ROLE_FILE="$CONF_DIR/role"
MAX_IRAN=3

# ---------- Colors ----------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[0;34m'; M='\033[0;35m'; N='\033[0m'

ok()   { echo -e "${G}[✔]${N} $1"; }
err()  { echo -e "${R}[✘]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
info() { echo -e "${C}[*]${N} $1"; }

banner() {
  clear
  echo -e "${C}=============================================================${N}"
  echo -e "${G}      Rathole Reverse Tunnel (fixed build)${N}"
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

# =============================================================================
#  Watchdog purge — removes every trace of the old watchdog approach.
#  The tunnel self-heals via systemd (Restart=always + StartLimitIntervalSec=0),
#  so any external watchdog/timer/cron is obsolete and can fight with systemd.
# =============================================================================
purge_watchdog() {
  local removed=0 u
  # systemd units from any previous version
  for u in rathole-watchdog.service rathole-watchdog.timer watchdog.service watchdog.timer; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${u}"; then
      systemctl disable --now "$u" >/dev/null 2>&1
      rm -f "/etc/systemd/system/${u}"
      removed=1
    fi
  done
  # watchdog scripts / cron entries from older installers
  rm -f /usr/local/bin/rathole-watchdog.sh /usr/local/bin/watchdog.sh 2>/dev/null
  if [ -f /etc/cron.d/rathole-watchdog ] || [ -f /etc/cron.d/rathole ]; then
    rm -f /etc/cron.d/rathole-watchdog /etc/cron.d/rathole
    removed=1
  fi
  # clean user/root crontab lines pointing at rathole watchdog
  if crontab -l 2>/dev/null | grep -qi 'rathole.*watchdog\|watchdog.*rathole'; then
    crontab -l 2>/dev/null | grep -vi 'rathole.*watchdog\|watchdog.*rathole' | crontab - 2>/dev/null
    removed=1
  fi
  systemctl daemon-reload 2>/dev/null
  [ "$removed" = "1" ] && ok "Legacy watchdog found and fully removed."
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
      # rathole dropped the aarch64 musl asset in v0.5.0 — last ARM build is v0.4.8.
      # NOTE: v0.4.8 has NO websocket transport (websocket was added in v0.5.0).
      ASSET="rathole-aarch64-unknown-linux-musl.zip"
      ASSET_VERSION="$RATHOLE_VERSION_ARM"
      warn "ARM server detected: using rathole ${ASSET_VERSION} (last ARM build)."
      warn "WebSocket transport is NOT available on ARM — use TCP or Noise."
      ;;
    *) err "Architecture $(uname -m) is not supported."; return 1 ;;
  esac
  return 0
}

# ---------- Install/update rathole core ----------
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
    "https://mirror.ghproxy.com/https://github.com/rathole-org/rathole/releases/download/${ASSET_VERSION}/${ASSET}"
  )
  local tmp; tmp=$(mktemp -d)
  local done_dl=0
  for u in "${urls[@]}"; do
    info "Trying: $u"
    if curl -fL --connect-timeout 12 --max-time 180 -o "$tmp/rathole.zip" "$u" 2>/dev/null; then
      if [ "$(stat -c%s "$tmp/rathole.zip" 2>/dev/null || echo 0)" -gt 100000 ]; then done_dl=1; break; fi
    fi
    warn "This link failed, trying the next one..."
  done
  if [ "$done_dl" != "1" ]; then
    err "Core download failed. Check the server's internet connection."
    rm -rf "$tmp"; return 1
  fi
  unzip -o "$tmp/rathole.zip" -d "$tmp" >/dev/null 2>&1
  install -m 0755 "$tmp/rathole" "$BIN"
  rm -rf "$tmp"
  if ! "$BIN" --version >/dev/null 2>&1; then
    err "Failed to run the rathole binary (possible glibc incompatibility)."
    return 1
  fi
  ok "Rathole core installed: $($BIN --version 2>/dev/null | head -n1)"
  mkdir -p "$CONF_DIR"
  return 0
}

# ---------- Normalize port input ----------
parse_ports() {
  local raw="$1"
  raw="${raw//،/,}"; raw="${raw// /,}"; raw="${raw//;/,}"
  local out="" p
  IFS=',' read -ra arr <<< "$raw"
  for p in "${arr[@]}"; do
    p="${p// /}"
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || continue
    [ "$p" = "$TUNNEL_PORT" ] && { warn "Port $TUNNEL_PORT is reserved for the tunnel itself and was rejected."; continue; }
    case " $out " in *" $p "*) continue ;; esac
    out="$out $p"
  done
  echo "${out# }"
}

# ---------- Port check helpers ----------
port_in_use() { ss -tln 2>/dev/null | grep -qE "[:.]${1}[[:space:]]"; }

check_tunnel_port_free() {
  if port_in_use "$TUNNEL_PORT"; then
    warn "Port ${TUNNEL_PORT} is already in use on this server (likely a web server)."
    echo -e "${Y}rathole needs this port exclusively. Stop whatever is using it, e.g.:${N}"
    echo "    systemctl stop nginx    # or apache2, caddy, etc."
    read -rp "Press Enter once port ${TUNNEL_PORT} is free (or Ctrl+C to abort)..."
    if port_in_use "$TUNNEL_PORT"; then
      err "Port ${TUNNEL_PORT} is still in use. Aborting to avoid a crash-loop."
      return 1
    fi
  fi
  return 0
}

# =============================================================================
#  FIX #2 — hard block on forward-port conflicts (Iran side).
#  Previously this only warned; rathole then failed to bind the busy port,
#  the server process exited, systemd restarted it, and the tunnel appeared
#  to "connect for a few seconds then disconnect" forever.
# =============================================================================
check_forward_ports_free() {
  local ports="$1" bad="" p
  for p in $ports; do
    # ignore ports bound by our own rathole server from a previous run
    if port_in_use "$p" && ! ss -tlnp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" | grep -q rathole; then
      bad="$bad $p"
    fi
  done
  if [ -n "$bad" ]; then
    err "These ports are already in use by another service:${bad}"
    echo -e "${Y}If rathole binds a busy port, the server crashes and restarts in a loop${N}"
    echo -e "${Y}(tunnel connects for a few seconds, then drops). Free them or pick others.${N}"
    return 1
  fi
  return 0
}

# ---------- Choose protocol ----------
choose_proto() {
  echo ""
  echo -e "${Y}Choose the tunnel transport protocol:${N}"
  echo "  1) TCP        (default and recommended - fast and stable)"
  echo "  2) WebSocket  (better bypass of some filters; x86_64 only)"
  echo "  3) Noise      (TCP + strong encryption - requires a key)"
  echo ""
  read -rp "Choice [1]: " pc
  case "${pc:-1}" in
    2)
      if [ "$(uname -m)" != "x86_64" ]; then
        err "WebSocket is not available on ARM (rathole ${RATHOLE_VERSION_ARM} has no websocket transport). Falling back to TCP."
        PROTO="tcp"
      else
        PROTO="websocket"
      fi
      ;;
    3) PROTO="noise" ;;
    *) PROTO="tcp" ;;
  esac
  ok "Selected protocol: $PROTO"
}

# ---------- Generate transport block for server ----------
transport_server_block() {
  case "$PROTO" in
    tcp)
      cat <<EOF
[server.transport]
type = "tcp"

[server.transport.tcp]
nodelay = true
keepalive_secs = 10
keepalive_interval = 3
EOF
      ;;
    websocket)
      cat <<EOF
[server.transport]
type = "websocket"

[server.transport.websocket]
tls = false
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

# ---------- Generate transport block for client ----------
transport_client_block() {
  case "$PROTO" in
    tcp)
      cat <<EOF
[client.transport]
type = "tcp"

[client.transport.tcp]
nodelay = true
keepalive_secs = 10
keepalive_interval = 3
EOF
      ;;
    websocket)
      cat <<EOF
[client.transport]
type = "websocket"

[client.transport.websocket]
tls = false
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

# ---------- Create systemd service ----------
# StartLimitIntervalSec=0 removes systemd's "5 restarts / 10s then give up"
# rule, so rapid drops can never leave the unit stuck in 'failed' state.
# This (no external watchdog) is enough for self-healing.
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
RestartSec=2
LimitNOFILE=1048576
Nice=-10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${name}.service" >/dev/null 2>&1
}

# ---------- Open ports in firewall (if present) ----------
open_ports() {
  local ports="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${TUNNEL_PORT}/tcp" >/dev/null 2>&1
    for p in $ports; do ufw allow "${p}/tcp" >/dev/null 2>&1; done
    ok "Ports opened in ufw."
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${TUNNEL_PORT}/tcp" >/dev/null 2>&1
    for p in $ports; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1; done
    firewall-cmd --reload >/dev/null 2>&1
    ok "Ports opened in firewalld."
  fi
}

# =============================================================================
#  Stability tuning (kernel + BBR) — anti-bufferbloat version.
# =============================================================================
apply_net_tuning() {
  cat > /etc/sysctl.d/99-rathole-tune.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 5
net.ipv4.tcp_keepalive_probes = 5
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 1400
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_retries2 = 8
EOF
  sysctl --system >/dev/null 2>&1
}

# =============================================================================
#  MSS clamping — eliminates PMTU-blackhole packet drops.
# =============================================================================
apply_mss_clamp() {
  if ! command -v iptables >/dev/null 2>&1; then
    warn "iptables not found; skipping MSS clamp."
    return
  fi
  iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

  cat > /etc/systemd/system/rathole-mss-clamp.service <<'EOF'
[Unit]
Description=Rathole MSS clamp (prevents PMTU blackhole packet drops)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now rathole-mss-clamp.service >/dev/null 2>&1
  ok "MSS clamp applied (survives reboot)."
}

# ---------- Persisted env helpers (FIX #5: keys survive re-runs) ----------
save_iran_env() {
  {
    echo "PROTO=$PROTO"
    echo "PORTS=$1"
    [ -n "$NOISE_PRIV" ] && echo "NOISE_PRIV=$NOISE_PRIV"
    [ -n "$NOISE_PUB" ]  && echo "NOISE_PUB=$NOISE_PUB"
  } > "$CONF_DIR/iran.env"
}

load_iran_env() {
  [ -f "$CONF_DIR/iran.env" ] || return 1
  PROTO=$(grep -oP '(?<=^PROTO=).*' "$CONF_DIR/iran.env" | head -n1)
  NOISE_PRIV=$(grep -oP '(?<=^NOISE_PRIV=).*' "$CONF_DIR/iran.env" | head -n1)
  NOISE_PUB=$(grep -oP '(?<=^NOISE_PUB=).*' "$CONF_DIR/iran.env" | head -n1)
  PROTO="${PROTO:-tcp}"
  return 0
}

# =============================================================================
#  Iran server setup (rathole SERVER - reverse side)
# =============================================================================
setup_iran() {
  banner
  echo -e "${M}>>> Setting up the Iran server (Server - reverse side)${N}"
  echo ""
  install_deps
  purge_watchdog
  install_core || { read -rp "Press Enter to go back..."; return; }

  # --- Make sure the tunnel port (443) isn't already taken ---
  check_tunnel_port_free || { read -rp "Press Enter to go back..."; return; }

  # --- Forward ports ---
  echo ""
  echo -e "${Y}Enter the ports you want to forward${N}"
  echo -e "${C}(comma-separated - example: 22,80,2086,2053)${N}"
  local ports="" raw_ports
  while [ -z "$ports" ]; do
    read -rp "Ports: " raw_ports
    ports=$(parse_ports "$raw_ports")
    [ -z "$ports" ] && err "No valid port was entered."
  done
  ok "Forward ports: $(echo $ports | tr ' ' ',')"

  # --- FIX #2: block on busy ports instead of crash-looping the tunnel ---
  if ! check_forward_ports_free "$ports"; then
    read -rp "Press Enter to go back and free those ports first..."
    return
  fi

  # --- Protocol ---
  choose_proto

  # --- Noise: reuse existing key, otherwise generate once and persist ---
  NOISE_PRIV=""; NOISE_PUB=""
  if [ "$PROTO" = "noise" ]; then
    local old_priv old_pub
    old_priv=$(grep -oP '(?<=^NOISE_PRIV=).*' "$CONF_DIR/iran.env" 2>/dev/null | head -n1)
    old_pub=$(grep -oP '(?<=^NOISE_PUB=).*'  "$CONF_DIR/iran.env" 2>/dev/null | head -n1)
    if [ -n "$old_priv" ] && [ -n "$old_pub" ]; then
      NOISE_PRIV="$old_priv"; NOISE_PUB="$old_pub"
      ok "Reusing the existing Noise key (Kharej side stays valid)."
    else
      info "Generating Noise key ..."
      local keyout; keyout=$("$BIN" --genkey 2>/dev/null)
      NOISE_PRIV=$(echo "$keyout" | awk '/Private Key:/{getline; print}' | tr -d ' \r\n')
      NOISE_PUB=$(echo "$keyout"  | awk '/Public Key:/{getline; print}'  | tr -d ' \r\n')
      if [ -z "$NOISE_PRIV" ] || [ -z "$NOISE_PUB" ]; then
        err "Noise key generation failed."; read -rp "Press Enter to go back..."; return
      fi
    fi
  fi

  # --- Build server.toml ---
  local conf="$CONF_DIR/iran-server.toml"
  [ -f "$conf" ] && cp -f "$conf" "${conf}.bak.$(date +%s)"
  {
    echo "[server]"
    echo "bind_addr = \"0.0.0.0:${TUNNEL_PORT}\""
    echo "default_token = \"${TOKEN}\""
    echo "heartbeat_interval = 15"
    echo ""
    transport_server_block
    echo ""
    for p in $ports; do
      echo "[server.services.p${p}]"
      echo "bind_addr = \"0.0.0.0:${p}\""
      echo ""
    done
  } > "$conf"
  ok "Server config created: $conf"

  # --- systemd service ---
  make_unit "rathole-iran" "$conf" "Rathole Iran Server (Reverse Tunnel)"
  ok "The rathole-iran service is enabled and running."

  # --- Kernel/network stability tuning (automatic) ---
  apply_net_tuning
  apply_mss_clamp
  ok "Kernel network tuning applied (BBR + anti-bufferbloat + MSS clamp)."

  # --- Firewall ---
  open_ports "$ports"

  echo "iran" > "$ROLE_FILE"
  save_iran_env "$ports"

  # --- Final test ---
  sleep 3
  echo ""
  if systemctl is-active --quiet rathole-iran; then
    ok "The tunnel on the Iran server started successfully and is listening on port ${TUNNEL_PORT}."
  else
    err "The service failed to start! Log: journalctl -u rathole-iran -n 30"
  fi
  if port_in_use "$TUNNEL_PORT"; then
    ok "Tunnel port ${TUNNEL_PORT} is in LISTEN state."
  fi

  # --- Info for the kharej (abroad) side ---
  echo ""
  echo -e "${C}================ Info needed for the Kharej server side ================${N}"
  echo -e "  This server's IP (Iran):  ${G}$(curl -4 -fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || echo 'Iran server IP')${N}"
  echo -e "  Tunnel port:               ${G}${TUNNEL_PORT}${N}  (fixed, same in both scripts)"
  echo -e "  Token:                     ${G}${TOKEN}${N}  (fixed, same in both scripts)"
  echo -e "  Protocol:                  ${G}${PROTO}${N}"
  echo -e "  Forward ports:             ${G}$(echo $ports | tr ' ' ',')${N}  ${Y}(must be identical on the Kharej side)${N}"
  if [ "$PROTO" = "noise" ]; then
    echo -e "  ${Y}Public Key (enter this on the Kharej side):${N}"
    echo -e "  ${G}${NOISE_PUB}${N}"
  fi
  echo -e "${C}=================================================================${N}"
  echo ""
  read -rp "Press Enter to return to the menu..."
}

# =============================================================================
#  Kharej (abroad) server setup (rathole CLIENT - up to 3 Iran servers)
# =============================================================================
setup_kharej() {
  banner
  echo -e "${M}>>> Setting up the Kharej server (Client)${N}"
  echo ""
  install_deps
  purge_watchdog
  install_core || { read -rp "Press Enter to go back..."; return; }

  # --- Number of Iran servers ---
  local count=1
  echo ""
  read -rp "How many Iran servers do you want to connect to this Kharej server? (1 to ${MAX_IRAN}) [1]: " count
  count="${count:-1}"
  if ! [[ "$count" =~ ^[1-3]$ ]]; then warn "Invalid value; set to 1."; count=1; fi

  # --- Protocol (shared across all) ---
  choose_proto
  NOISE_PUB=""
  if [ "$PROTO" = "noise" ]; then
    echo ""
    echo -e "${Y}Enter the Public Key generated on the Iran server${N} (must be the same across all Iran servers):"
    read -rp "Noise Public Key: " NOISE_PUB
    if [ -z "$NOISE_PUB" ]; then err "The key is empty."; read -rp "Press Enter..."; return; fi
  fi

  local i ip raw_ports ports dest summary=""
  for ((i=1; i<=count; i++)); do
    echo ""
    echo -e "${B}----- Iran server #${i} -----${N}"
    while true; do
      read -rp "Iran server ${i} IP: " ip
      [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
      err "Invalid IP address."
    done

    echo -e "${C}Forward ports for this server (comma-separated - example: 22,80,2086)${N}"
    echo -e "${Y}These must EXACTLY match the ports entered on Iran server #${i}, otherwise${N}"
    echo -e "${Y}the client retries forever and the tunnel looks 'connected but dead'.${N}"
    ports=""
    while [ -z "$ports" ]; do
      read -rp "Ports: " raw_ports
      ports=$(parse_ports "$raw_ports")
      [ -z "$ports" ] && err "No valid port was entered."
    done

    read -rp "Traffic destination on the Kharej server [127.0.0.1]: " dest
    dest="${dest:-127.0.0.1}"

    # --- Build client.toml ---
    # FIX #6: heartbeat_timeout 90 -> 45. rathole only reconnects after this
    # timeout fires, so 90s meant up to a minute and a half of dead tunnel
    # before recovery. Must stay greater than server heartbeat_interval (15).
    local conf="$CONF_DIR/kharej-client-${i}.toml"
    [ -f "$conf" ] && cp -f "$conf" "${conf}.bak.$(date +%s)"
    {
      echo "[client]"
      echo "remote_addr = \"${ip}:${TUNNEL_PORT}\""
      echo "default_token = \"${TOKEN}\""
      echo "retry_interval = 1"
      echo "heartbeat_timeout = 45"
      echo ""
      transport_client_block
      echo ""
      for p in $ports; do
        echo "[client.services.p${p}]"
        echo "local_addr = \"${dest}:${p}\""
        echo ""
      done
    } > "$conf"

    make_unit "rathole-kharej-${i}" "$conf" "Rathole Kharej Client -> Iran ${i} (${ip})"
    ok "The rathole-kharej-${i} service is running for Iran server ${ip}."
    summary="${summary}\n  Iran ${i}: ${G}${ip}${N} | Ports: ${G}$(echo $ports | tr ' ' ',')${N} -> destination ${G}${dest}${N}"
  done

  # --- Kernel/network stability tuning (automatic) ---
  apply_net_tuning
  apply_mss_clamp
  ok "Kernel network tuning applied (BBR + anti-bufferbloat + MSS clamp)."

  echo "kharej" > "$ROLE_FILE"
  {
    echo "PROTO=$PROTO"
    echo "COUNT=$count"
  } > "$CONF_DIR/kharej.env"

  # --- Final connection test ---
  sleep 4
  echo ""
  echo -e "${C}===================== Connection result =====================${N}"
  for ((i=1; i<=count; i++)); do
    local c="$CONF_DIR/kharej-client-${i}.toml"
    ip=$(grep remote_addr "$c" | cut -d'"' -f2 | cut -d: -f1)
    if ss -tn state established 2>/dev/null | grep -q "${ip}:${TUNNEL_PORT}"; then
      ok "Connection to Iran server ${i} (${ip}:${TUNNEL_PORT}) is established ✔"
    else
      warn "Connection to ${ip}:${TUNNEL_PORT} is not yet established."
      echo -e "    Check: 1) the script has been run on the Iran server 2) port ${TUNNEL_PORT} is open in the Iran server's firewall/datacenter 3) the protocol/key match on both sides."
      echo -e "    Log: journalctl -u rathole-kharej-${i} -n 30 --no-pager"
    fi
  done
  echo -e "${C}=========================================================${N}"
  echo -e "$summary"
  echo ""
  echo -e "${Y}Important reminder:${N} run this same script on each Iran server, choose option \"1\", and"
  echo -e "  make sure the ${G}same protocol (${PROTO})${N} and the ${G}same ports${N} are used so both sides match."
  echo ""
  read -rp "Press Enter to return to the menu..."
}

# =============================================================================
#  Status and connection test
# =============================================================================
show_status() {
  banner
  echo -e "${M}>>> Tunnel status${N}"
  echo ""
  local found=0 u
  for u in $(systemctl list-unit-files 2>/dev/null | grep -E '^rathole-(iran|kharej)' | awk '{print $1}'); do
    found=1
    if systemctl is-active --quiet "$u"; then
      ok "$u : ${G}active${N}"
    else
      err "$u : ${R}inactive${N}"
    fi
  done
  [ "$found" = "0" ] && warn "No rathole service is installed on this server."
  echo ""
  echo -e "${C}--- Established tunnel connections (port ${TUNNEL_PORT}) ---${N}"
  ss -tnp state established 2>/dev/null | grep ":${TUNNEL_PORT}" || echo "  (no active connection found)"
  echo ""
  echo -e "${C}--- Listening ports ---${N}"
  ss -tln 2>/dev/null | grep -E "[:.]${TUNNEL_PORT}[[:space:]]" || true
  echo ""
  read -rp "Press Enter to return to the menu..."
}

# =============================================================================
#  Restart tunnel
# =============================================================================
restart_all() {
  banner
  local u found=0
  for u in $(systemctl list-unit-files 2>/dev/null | grep -E '^rathole-(iran|kharej)' | awk '{print $1}'); do
    found=1
    systemctl reset-failed "$u" 2>/dev/null
    systemctl restart "$u" && ok "$u restarted."
  done
  [ "$found" = "0" ] && warn "No service found."
  sleep 2
  read -rp "Press Enter to return to the menu..."
}

# =============================================================================
#  Network optimization (BBR + sysctl + MSS clamp) — manual menu entry point
# =============================================================================
optimize_net() {
  banner
  info "Applying BBR, anti-bufferbloat tuning, and MSS clamp ..."
  apply_net_tuning
  apply_mss_clamp
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    ok "BBR enabled."
  else
    warn "BBR could not be enabled on this kernel (kernel too old?)."
  fi
  ok "Network optimization applied."
  read -rp "Press Enter to return to the menu..."
}

# =============================================================================
#  Edit ports — FIX #4: rebuild the transport block cleanly from the saved
#  env (protocol + persisted Noise keys) instead of grepping old .bak files,
#  which mixed multiple backups and destroyed the Noise private key.
# =============================================================================
edit_ports() {
  banner
  local role; role=$(cat "$ROLE_FILE" 2>/dev/null)
  if [ "$role" = "iran" ]; then
    info "This server's role: Iran - enter the new ports:"
    local ports="" raw_ports
    while [ -z "$ports" ]; do
      read -rp "Ports: " raw_ports
      ports=$(parse_ports "$raw_ports")
      [ -z "$ports" ] && err "No valid port was entered."
    done
    check_forward_ports_free "$ports" || { read -rp "Press Enter to go back..."; return; }

    load_iran_env || { err "Saved settings not found; run option 1 again."; read -rp "Press Enter..."; return; }

    local conf="$CONF_DIR/iran-server.toml"
    cp -f "$conf" "${conf}.bak.$(date +%s)" 2>/dev/null
    {
      echo "[server]"
      echo "bind_addr = \"0.0.0.0:${TUNNEL_PORT}\""
      echo "default_token = \"${TOKEN}\""
      echo "heartbeat_interval = 15"
      echo ""
      transport_server_block
      echo ""
      for p in $ports; do
        echo "[server.services.p${p}]"
        echo "bind_addr = \"0.0.0.0:${p}\""
        echo ""
      done
    } > "$conf"
    save_iran_env "$ports"
    systemctl reset-failed rathole-iran 2>/dev/null
    systemctl restart rathole-iran && ok "Config updated and service restarted (protocol: $PROTO)."
    open_ports "$ports"
  elif [ "$role" = "kharej" ]; then
    info "To edit the ports for each Iran server, run option 2 (install Kharej) again;"
    info "the configs will be rewritten with the new values."
  else
    warn "The tunnel must be installed first (option 1 or 2)."
  fi
  read -rp "Press Enter to return to the menu..."
}

# =============================================================================
#  Full removal — now also purges every watchdog trace (service, timer,
#  script, cron) and any rathole unit from older script versions.
# =============================================================================
uninstall_all() {
  banner
  read -rp "Are you sure you want to fully remove the tunnel? (y/N): " c
  [[ "$c" =~ ^[yY]$ ]] || return

  # watchdog first (service, timer, helper script, cron entries)
  purge_watchdog

  # all rathole units (current naming + any legacy names)
  local u
  for u in $(systemctl list-unit-files 2>/dev/null | grep -E '^rathole' | awk '{print $1}'); do
    systemctl disable --now "$u" >/dev/null 2>&1
    rm -f "/etc/systemd/system/${u}"
  done
  # legacy unit files that might not be registered anymore
  rm -f /etc/systemd/system/rathole.service \
        /etc/systemd/system/rathole-server.service \
        /etc/systemd/system/rathole-client.service 2>/dev/null

  systemctl daemon-reload

  # MSS clamp firewall rule
  iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

  # config, role, binary, tuning
  rm -rf "$CONF_DIR"
  rm -f "$BIN"
  rm -f /etc/sysctl.d/99-rathole-tune.conf
  sysctl --system >/dev/null 2>&1

  ok "The rathole tunnel (and all watchdog leftovers) have been fully removed."
  read -rp "Press Enter to return to the menu..."
}

# =============================================================================
#  Main menu
# =============================================================================
main_menu() {
  while true; do
    banner
    local role; role=$(cat "$ROLE_FILE" 2>/dev/null)
    [ -n "$role" ] && echo -e "  This server's role: ${G}${role}${N}   |   Tunnel port: ${G}${TUNNEL_PORT}${N}"
    echo ""
    echo "  1) Install Iran server  (Server - reverse side)"
    echo "  2) Install Kharej server   (Client - up to 3 Iran servers)"
    echo "  3) Status and connection test"
    echo "  4) Restart tunnel"
    echo "  5) Network optimization (BBR + MSS clamp)"
    echo "  6) Edit ports"
    echo "  7) Reinstall rathole core (pinned stable version)"
    echo "  8) Fully remove tunnel (incl. watchdog leftovers)"
    echo "  0) Exit"
    echo ""
    read -rp "Choice: " ch
    case "$ch" in
      1) setup_iran ;;
      2) setup_kharej ;;
      3) show_status ;;
      4) restart_all ;;
      5) optimize_net ;;
      6) edit_ports ;;
      7) install_core "force"; read -rp "Press Enter to go back..." ;;
      8) uninstall_all ;;
      0) exit 0 ;;
      *) warn "Invalid option."; sleep 1 ;;
    esac
  done
}

need_root
main_menu
