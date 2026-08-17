#!/bin/bash
# =============================================================================
#  Rathole Reverse Tunnel Manager (IRAN <-> KHAREJ)
#  Reverse architecture: Iran server = rathole server | Kharej (abroad) server = rathole client
#  Tunnel port: 8085 | Fixed token | Auto watchdog | Up to 3 Iran servers
#  Stability patch: unlimited auto-restart, tolerant heartbeat, faster watchdog,
#                    kernel keepalive/idle tuning applied automatically at install.
# =============================================================================

# ---------- Fixed settings ----------
TUNNEL_PORT="8085"
TOKEN="sdfert54fg564y6trgby675ytrgftryrg"
BIN="/usr/local/bin/rathole"
CONF_DIR="/etc/rathole"
WATCHDOG="/usr/local/bin/rathole-watchdog.sh"
CRON_FILE="/etc/cron.d/rathole-watchdog"
LOG_FILE="/var/log/rathole-watchdog.log"
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
  echo -e "${G}      Rathole Reverse Tunnel${N}"
  echo -e "${C}      IRAN (Server)  <<==  8085  ==>>  KHAREJ (Client)${N}"
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
  command -v curl  >/dev/null 2>&1 || need+=(curl)
  command -v wget  >/dev/null 2>&1 || need+=(wget)
  command -v unzip >/dev/null 2>&1 || need+=(unzip)
  command -v ss    >/dev/null 2>&1 || need+=(iproute2)
  if command -v apt-get >/dev/null 2>&1; then
    command -v crontab >/dev/null 2>&1 || need+=(cron)
    [ ${#need[@]} -gt 0 ] && { info "Installing prerequisites: ${need[*]}"; apt-get update -y >/dev/null 2>&1; apt-get install -y "${need[@]}" >/dev/null 2>&1; }
  elif command -v dnf >/dev/null 2>&1; then
    command -v crontab >/dev/null 2>&1 || need+=(cronie)
    [ ${#need[@]} -gt 0 ] && { info "Installing prerequisites: ${need[*]}"; dnf install -y "${need[@]}" >/dev/null 2>&1; }
  elif command -v yum >/dev/null 2>&1; then
    command -v crontab >/dev/null 2>&1 || need+=(cronie)
    [ ${#need[@]} -gt 0 ] && { info "Installing prerequisites: ${need[*]}"; yum install -y "${need[@]}" >/dev/null 2>&1; }
  fi
  # Start cron
  systemctl enable --now cron  >/dev/null 2>&1
  systemctl enable --now crond >/dev/null 2>&1
  ok "Prerequisites are ready."
}

# ---------- Detect architecture ----------
detect_asset() {
  case "$(uname -m)" in
    x86_64|amd64)  ASSET="rathole-x86_64-unknown-linux-gnu.zip" ;;
    aarch64|arm64) ASSET="rathole-aarch64-unknown-linux-musl.zip" ;;
    *) err "Architecture $(uname -m) is not supported."; return 1 ;;
  esac
  return 0
}

# ---------- Get latest core release ----------
latest_tag() {
  local tag=""
  tag=$(curl -fsSL --connect-timeout 10 "https://api.github.com/repos/rathole-org/rathole/releases/latest" 2>/dev/null | grep -m1 '"tag_name"' | cut -d'"' -f4)
  [ -z "$tag" ] && tag=$(curl -fsSL --connect-timeout 10 "https://api.github.com/repos/rapiz1/rathole/releases/latest" 2>/dev/null | grep -m1 '"tag_name"' | cut -d'"' -f4)
  [ -z "$tag" ] && tag="v0.5.0"
  echo "$tag"
}

# ---------- Install/update rathole core ----------
install_core() {
  if [ -x "$BIN" ] && [ "$1" != "force" ]; then
    ok "Rathole core is already installed: $($BIN --version 2>/dev/null | head -n1)"
    return 0
  fi
  detect_asset || return 1
  local tag; tag=$(latest_tag)
  info "Downloading latest rathole core release ($tag) ..."
  local urls=(
    "https://github.com/rathole-org/rathole/releases/download/${tag}/${ASSET}"
    "https://github.com/rapiz1/rathole/releases/download/${tag}/${ASSET}"
    "https://ghproxy.net/https://github.com/rathole-org/rathole/releases/download/${tag}/${ASSET}"
    "https://ghfast.top/https://github.com/rathole-org/rathole/releases/download/${tag}/${ASSET}"
    "https://mirror.ghproxy.com/https://github.com/rathole-org/rathole/releases/download/${tag}/${ASSET}"
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
# Output: list of valid, unique ports separated by spaces
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

# ---------- Choose protocol ----------
# Output in global variable PROTO : tcp | websocket | noise
choose_proto() {
  echo ""
  echo -e "${Y}Choose the tunnel transport protocol:${N}"
  echo "  1) TCP        (default and recommended - fast and stable)"
  echo "  2) WebSocket  (better bypass of some filters)"
  echo "  3) Noise      (TCP + strong encryption - requires a key)"
  echo ""
  read -rp "Choice [1]: " pc
  case "${pc:-1}" in
    2) PROTO="websocket" ;;
    3) PROTO="noise" ;;
    *) PROTO="tcp" ;;
  esac
  ok "Selected protocol: $PROTO"
}

# ---------- Generate transport block for server ----------
# NOTE (stability patch): keepalive_secs/keepalive_interval tightened (10/3)
# so a dead peer is detected and NAT mappings on Iranian ISPs stay refreshed.
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
# NOTE (stability patch): StartLimitIntervalSec=0 removes systemd's default
# "5 restarts / 10s then give up" rule. Without this, a burst of rapid drops
# (common on filtered Iranian links) trips the limit and the unit goes to a
# permanently 'failed' state until someone restarts it by hand.
make_unit() {
  local name="$1" conf="$2" desc="$3"
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
#  Stability tuning (kernel + BBR) — silent version, called automatically
#  from setup_iran / setup_kharej so every fresh install gets it.
# =============================================================================
apply_net_tuning() {
  cat > /etc/sysctl.d/99-rathole-tune.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 87380 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 5
net.ipv4.tcp_keepalive_probes = 5
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_retries2 = 8
EOF
  sysctl --system >/dev/null 2>&1
}

# =============================================================================
#  Iran server setup (rathole SERVER - reverse side)
# =============================================================================
setup_iran() {
  banner
  echo -e "${M}>>> Setting up the Iran server (Server - reverse side)${N}"
  echo ""
  install_deps
  install_core || { read -rp "Press Enter to go back..."; return; }

  # --- Forward ports ---
  echo ""
  echo -e "${Y}Enter the ports you want to forward${N}"
  echo -e "${C}(comma-separated - example: 22,80,443,2086,2053)${N}"
  local ports=""
  while [ -z "$ports" ]; do
    read -rp "Ports: " raw_ports
    ports=$(parse_ports "$raw_ports")
    [ -z "$ports" ] && err "No valid port was entered."
  done
  ok "Forward ports: $(echo $ports | tr ' ' ',')"

  # --- Port conflict warning ---
  for p in $ports; do
    if ss -tln 2>/dev/null | grep -q ":${p} "; then
      warn "Port ${p} is currently in use on this server (e.g. by another service)."
    fi
  done

  # --- Protocol ---
  choose_proto

  # --- Noise: key generation ---
  NOISE_PRIV=""; NOISE_PUB=""
  if [ "$PROTO" = "noise" ]; then
    info "Generating Noise key ..."
    local keyout; keyout=$("$BIN" --genkey 2>/dev/null)
    NOISE_PRIV=$(echo "$keyout" | awk '/Private Key:/{getline; print}' | tr -d ' \r\n')
    NOISE_PUB=$(echo "$keyout"  | awk '/Public Key:/{getline; print}'  | tr -d ' \r\n')
    if [ -z "$NOISE_PRIV" ] || [ -z "$NOISE_PUB" ]; then
      err "Noise key generation failed."; read -rp "Press Enter to go back..."; return
    fi
  fi

  # --- Build server.toml ---
  # NOTE (stability patch): heartbeat_interval lowered 30 -> 15s so pings go
  # out more often, keeping NAT/firewall session state alive on both sides.
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

  # --- Watchdog ---
  install_watchdog

  # --- Kernel/network stability tuning (automatic) ---
  apply_net_tuning
  ok "Kernel network tuning applied (BBR + keepalive + idle-recovery)."

  # --- Firewall ---
  open_ports "$ports"

  echo "iran" > "$ROLE_FILE"
  echo "PROTO=$PROTO" > "$CONF_DIR/iran.env"
  echo "PORTS=$ports" >> "$CONF_DIR/iran.env"

  # --- Final test ---
  sleep 3
  echo ""
  if systemctl is-active --quiet rathole-iran; then
    ok "The tunnel on the Iran server started successfully and is listening on port ${TUNNEL_PORT}."
  else
    err "The service failed to start! Log: journalctl -u rathole-iran -n 30"
  fi
  if ss -tln | grep -q ":${TUNNEL_PORT} "; then
    ok "Tunnel port ${TUNNEL_PORT} is in LISTEN state."
  fi

  # --- Info for the kharej (abroad) side ---
  echo ""
  echo -e "${C}================ Info needed for the Kharej server side ================${N}"
  echo -e "  This server's IP (Iran):  ${G}$(curl -4 -fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || echo 'Iran server IP')${N}"
  echo -e "  Tunnel port:               ${G}${TUNNEL_PORT}${N}"
  echo -e "  Protocol:                  ${G}${PROTO}${N}"
  echo -e "  Forward ports:             ${G}$(echo $ports | tr ' ' ',')${N}"
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

    echo -e "${C}Forward ports for this server (comma-separated - example: 22,80,443,2086):${N}"
    ports=""
    while [ -z "$ports" ]; do
      read -rp "Ports: " raw_ports
      ports=$(parse_ports "$raw_ports")
      [ -z "$ports" ] && err "No valid port was entered."
    done

    read -rp "Traffic destination on the Kharej server [127.0.0.1]: " dest
    dest="${dest:-127.0.0.1}"

    # --- Build client.toml ---
    # NOTE (stability patch): heartbeat_timeout raised 40 -> 90s so normal
    # network jitter doesn't get misread as a dead server and trigger a
    # reconnect storm. retry_interval stays at 1s for a fast real reconnect.
    local conf="$CONF_DIR/kharej-client-${i}.toml"
    [ -f "$conf" ] && cp -f "$conf" "${conf}.bak.$(date +%s)"
    {
      echo "[client]"
      echo "remote_addr = \"${ip}:${TUNNEL_PORT}\""
      echo "default_token = \"${TOKEN}\""
      echo "retry_interval = 1"
      echo "heartbeat_timeout = 90"
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

  # --- Watchdog ---
  install_watchdog

  # --- Kernel/network stability tuning (automatic) ---
  apply_net_tuning
  ok "Kernel network tuning applied (BBR + keepalive + idle-recovery)."

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
      echo -e "    Check: 1) the script has been run on the Iran server 2) port ${TUNNEL_PORT} is open in the Iran server's firewall/datacenter 3) the protocol and key match on both sides."
      echo -e "    Log: journalctl -u rathole-kharej-${i} -n 30 --no-pager"
    fi
  done
  echo -e "${C}=========================================================${N}"
  echo -e "$summary"
  echo ""
  echo -e "${Y}Important reminder:${N} run this same script on each Iran server, choose option \"1\", and"
  echo -e "  enter the ${G}same ports and same protocol (${PROTO})${N} so both sides of the tunnel match."
  echo ""
  read -rp "Press Enter to return to the menu..."
}

# =============================================================================
#  Automatic watchdog (every 30 seconds - on both servers)
# =============================================================================
# NOTE (stability patch): watchdog now runs twice a minute (via two cron
# lines, one offset by sleep 30) instead of once, and calls
# 'systemctl reset-failed' before every restart so a unit that previously
# hit systemd's restart-rate limit and got stuck in 'failed' is guaranteed
# to be recovered instead of sitting dead until a human restarts it.
install_watchdog() {
  cat > "$WATCHDOG" <<'WDEOF'
#!/bin/bash
# Rathole Watchdog - checks service health and tunnel connection
LOG=/var/log/rathole-watchdog.log
TS="$(date '+%Y-%m-%d %H:%M:%S')"

# 1) Any rathole service that is enabled but not running -> restart
for unit in $(systemctl list-unit-files 2>/dev/null | grep -E '^rathole-(iran|kharej)-?[0-9]*\.service' | awk '{print $1}'); do
  systemctl is-enabled --quiet "$unit" 2>/dev/null || continue
  if ! systemctl is-active --quiet "$unit"; then
    echo "$TS $unit was stopped; restarted" >> "$LOG"
    systemctl reset-failed "$unit" 2>/dev/null
    systemctl restart "$unit"
  fi
done

# 2) Kharej side: check whether the TCP connection to each Iran server is up
for f in /etc/rathole/kharej-client-*.toml; do
  [ -e "$f" ] || continue
  n=$(basename "$f" .toml | grep -o '[0-9]*$')
  ip=$(grep remote_addr "$f" | head -n1 | cut -d'"' -f2 | cut -d: -f1)
  pt=$(grep remote_addr "$f" | head -n1 | cut -d'"' -f2 | cut -d: -f2)
  [ -z "$ip" ] && continue
  if ! ss -tn state established 2>/dev/null | grep -q "${ip}:${pt}"; then
    echo "$TS Connection to ${ip}:${pt} was down; restarting rathole-kharej-${n}" >> "$LOG"
    systemctl reset-failed "rathole-kharej-${n}.service" 2>/dev/null
    systemctl restart "rathole-kharej-${n}.service"
  fi
done

# 3) Prevent the log from growing too large (keep last 500 lines)
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
  tail -n 500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
WDEOF
  chmod +x "$WATCHDOG"
  {
    echo "* * * * * root ${WATCHDOG} >/dev/null 2>&1"
    echo "* * * * * root sleep 30 && ${WATCHDOG} >/dev/null 2>&1"
  } > "$CRON_FILE"
  chmod 644 "$CRON_FILE"
  systemctl restart cron  >/dev/null 2>&1
  systemctl restart crond >/dev/null 2>&1
  ok "Watchdog installed (automatic check every 30 seconds, self-heals failed units)."
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
  ss -tln 2>/dev/null | grep -E ":(${TUNNEL_PORT})\b" || true
  echo ""
  if [ -f "$LOG_FILE" ]; then
    echo -e "${C}--- Latest watchdog events ---${N}"
    tail -n 10 "$LOG_FILE"
  fi
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
#  Network optimization (BBR + sysctl) — manual menu entry point
# =============================================================================
optimize_net() {
  banner
  info "Applying BBR and network optimization ..."
  apply_net_tuning
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    ok "BBR enabled."
  else
    warn "BBR could not be enabled on this kernel (kernel too old?)."
  fi
  ok "Network optimization applied."
  read -rp "Press Enter to return to the menu..."
}

# =============================================================================
#  Edit ports (quickly rebuild config with the previous protocol)
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
    PROTO=$(grep -oP '(?<=^PROTO=).*' "$CONF_DIR/iran.env" 2>/dev/null); PROTO="${PROTO:-tcp}"
    local conf="$CONF_DIR/iran-server.toml"
    cp -f "$conf" "${conf}.bak.$(date +%s)" 2>/dev/null
    {
      echo "[server]"
      echo "bind_addr = \"0.0.0.0:${TUNNEL_PORT}\""
      echo "default_token = \"${TOKEN}\""
      echo "heartbeat_interval = 15"
      echo ""
      grep -A6 '^\[server.transport\]' "${conf}.bak."* 2>/dev/null | head -n 20 | sed '/^--$/d' || transport_server_block
      echo ""
      for p in $ports; do
        echo "[server.services.p${p}]"
        echo "bind_addr = \"0.0.0.0:${p}\""
        echo ""
      done
    } > "$conf"
    echo "PORTS=$ports" >> "$CONF_DIR/iran.env"
    systemctl restart rathole-iran && ok "Config updated and service restarted."
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
#  Full removal
# =============================================================================
uninstall_all() {
  banner
  read -rp "Are you sure you want to fully remove the tunnel? (y/N): " c
  [[ "$c" =~ ^[yY]$ ]] || return
  local u
  for u in $(systemctl list-unit-files 2>/dev/null | grep -E '^rathole-(iran|kharej)' | awk '{print $1}'); do
    systemctl disable --now "$u" >/dev/null 2>&1
    rm -f "/etc/systemd/system/${u}"
  done
  systemctl daemon-reload
  rm -f "$WATCHDOG" "$CRON_FILE" "$ROLE_FILE"
  rm -rf "$CONF_DIR"
  rm -f "$BIN"
  rm -f /etc/sysctl.d/99-rathole-tune.conf
  sysctl --system >/dev/null 2>&1
  ok "The rathole tunnel has been fully removed."
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
    echo "  5) Network optimization (BBR)"
    echo "  6) Edit ports"
    echo "  7) Update rathole core to the latest version"
    echo "  8) Fully remove tunnel"
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
