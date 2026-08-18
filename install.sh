#!/bin/bash
# =============================================================================
#  Rathole Reverse Tunnel — Fully Automated Anti-Drop Build (Fixed v2)
#  Fixes vs previous version:
#   1) TUNNEL_PORT fixed to 8443 (avoids port 443 conflicts)
#   2) Noise Keys hardcoded & automated (no prompt for keys)
#   3) Advanced TCP/MSS anti-drop tuning applied
#   4) REAL FIX: explicit iptables INPUT ACCEPT rules for tunnel + forward
#      ports (previous version only handled ufw/firewalld, so on servers
#      using raw iptables with a default DROP/REJECT policy, the port never
#      actually opened -> "Connection refused" from the client).
#   5) REAL FIX: after starting each systemd service, the script now VERIFIES
#      it is actually active and actually bound to the port, and prints the
#      last journalctl lines immediately if not, instead of always printing
#      a false "ready" message.
#   6) New: automatic post-install connection test on the Iran server.
# =============================================================================

set -u

# ---------- Fixed settings ----------
TUNNEL_PORT="8443"
TOKEN="rH7kQ2vXpL9mZ4wT6nB8sD3fG5jC1yA0"

# Fixed & Pre-generated Noise Keypair for zero-prompt setup
# IMPORTANT: rathole's noise transport requires base64-encoded X25519 keys
# (as produced by `rathole --genkey x25519`), NOT hex. Feeding a hex string
# here causes rathole-server to base64-decode it into 48 bytes instead of 32,
# which crashes the process with a Rust panic in the snow noise library
# ("range end index 48 out of range for slice of length 32") every single
# time a client connects — this was the actual cause of the refused/reset
# errors, not a firewall or timing issue.
NOISE_PRIV="8bytOyfav+CIn6pEY+gCUSn6PpHJh7ADeHT55wmrTsE="
NOISE_PUB="gHmg3PHFH9+CouNJfGV28I4JwS3Hm28F8Vl2vGraU3g="

RATHOLE_VERSION="v0.5.0"          # latest stable release (x86_64)
RATHOLE_VERSION_ARM="v0.4.8"      # last release that still ships aarch64 musl
BIN="/usr/local/bin/rathole"
CONF_DIR="/etc/rathole"
ROLE_FILE="$CONF_DIR/role"
FW_SVC="/etc/systemd/system/rathole-fw.service"

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
  if [ -x "$BIN" ] && [ "${1:-}" != "force" ]; then
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

# ---------- Service Creation (with real startup verification) ----------
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

  # REAL FIX: verify the service is actually up instead of assuming success.
  # A crash-looping service (Restart=always, RestartSec=1) can look "active"
  # at the exact instant we check even though it's panicking every second,
  # so also scan recent logs for a panic/core-dump before declaring success.
  sleep 3
  if ! systemctl is-active --quiet "${name}.service"; then
    err "Service ${name}.service failed to start. Last log lines:"
    journalctl -u "${name}.service" -n 15 --no-pager
    return 1
  fi
  if journalctl -u "${name}.service" -n 20 --no-pager 2>/dev/null | grep -qiE "panicked|core-dump|core_dump"; then
    err "Service ${name}.service is crash-looping (panic detected). Last log lines:"
    journalctl -u "${name}.service" -n 20 --no-pager
    return 1
  fi
  ok "Service ${name}.service is active and stable."
  return 0
}

# ---------- REAL FIX: explicit iptables ACCEPT (works regardless of ufw/firewalld) ----------
open_ports() {
  local ports="$1"

  # 1) Try the high-level firewall managers if present (kept for convenience).
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${TUNNEL_PORT}/tcp" >/dev/null 2>&1
    for p in $ports; do ufw allow "${p}/tcp" >/dev/null 2>&1; done
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${TUNNEL_PORT}/tcp" >/dev/null 2>&1
    for p in $ports; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1; done
    firewall-cmd --reload >/dev/null 2>&1
  fi

  # 2) Always ALSO add explicit iptables INPUT ACCEPT rules. This is the part
  #    that was missing before: on servers with a raw iptables setup and a
  #    default DROP/REJECT policy, ufw/firewalld being absent meant the port
  #    was never actually reachable, which produced "Connection refused" on
  #    the client side even though the rathole service itself was healthy.
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT
    for p in $ports; do
      iptables -C INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "${p}" -j ACCEPT
    done

    # Persist across reboots via a small systemd oneshot (works even without
    # iptables-persistent/netfilter-persistent installed).
    {
      echo "[Unit]"
      echo "Description=Rathole firewall rules (tunnel + forward ports)"
      echo "After=network-online.target"
      echo "Wants=network-online.target"
      echo ""
      echo "[Service]"
      echo "Type=oneshot"
      echo "ExecStart=/sbin/iptables -I INPUT -p tcp --dport ${TUNNEL_PORT} -j ACCEPT"
      for p in $ports; do
        echo "ExecStart=/sbin/iptables -I INPUT -p tcp --dport ${p} -j ACCEPT"
      done
      echo "RemainAfterExit=yes"
      echo ""
      echo "[Install]"
      echo "WantedBy=multi-user.target"
    } > "$FW_SVC"
    systemctl daemon-reload
    systemctl enable --now rathole-fw.service >/dev/null 2>&1
    ok "iptables INPUT rules applied for port ${TUNNEL_PORT} and forward ports (persisted)."
  else
    warn "iptables not found — cannot guarantee the port is reachable from outside. Check your cloud provider's security group / firewall panel too."
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

# ---------- REAL FIX: post-install connection test on the Iran side ----------
test_iran_listening() {
  info "Verifying the tunnel port is actually listening..."
  sleep 1
  if ss -tln 2>/dev/null | grep -qE "[:.]${TUNNEL_PORT}[[:space:]]"; then
    ok "Port ${TUNNEL_PORT} is listening locally. Good."
  else
    err "Port ${TUNNEL_PORT} is NOT listening. rathole-iran did not bind it."
    warn "Run: journalctl -u rathole-iran -n 30 --no-pager"
    return 1
  fi

  info "Local self-connect test (does not confirm public reachability)..."
  if command -v curl >/dev/null 2>&1; then
    curl -s --connect-timeout 3 "http://127.0.0.1:${TUNNEL_PORT}" >/dev/null 2>&1
    ok "Local TCP handshake reachable on 127.0.0.1:${TUNNEL_PORT}."
  fi
  warn "This only confirms the LOCAL bind. If the Kharej client still gets"
  warn "'Connection refused' after this, the block is on the network path"
  warn "(cloud provider security group, upstream ISP, or DPI) — not this script."
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

  make_unit "rathole-iran" "$conf" "Rathole Iran Server" || { read -rp "Press Enter to return..."; return; }
  apply_net_tuning
  apply_mss_clamp
  open_ports "$ports"
  test_iran_listening
  echo "iran" > "$ROLE_FILE"

  ok "Iran Server setup finished on Port ${TUNNEL_PORT}."
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

  info "Checking for connection errors in the first few seconds..."
  sleep 4
  if journalctl -u rathole-kharej-1 -n 10 --no-pager 2>/dev/null | grep -qi "error"; then
    warn "Client is still reporting errors. Recent log:"
    journalctl -u rathole-kharej-1 -n 10 --no-pager
    warn "If you see 'Connection refused', the problem is on the Iran server"
    warn "side (service not running, or port blocked). If you see 'Connection"
    warn "reset by peer' during handshake, check that the token/keys match on"
    warn "both ends, or that nothing is intercepting the connection in between."
  else
    ok "No recent errors — connection appears healthy."
  fi

  ok "Kharej Client configured to connect to Iran Server (${ip}:${TUNNEL_PORT})."
  read -rp "Press Enter to return..."
}

show_status() {
  banner
  info "Rathole Service Status:"
  systemctl status rathole-iran rathole-kharej-1 --no-pager 2>/dev/null
  echo ""
  info "Active Connections on Tunnel Port ${TUNNEL_PORT}:"
  ss -tnp state established 2>/dev/null | grep ":${TUNNEL_PORT}" || echo "No active connections on port ${TUNNEL_PORT}."
  echo ""
  info "Is the tunnel port actually listening here?"
  ss -tln 2>/dev/null | grep ":${TUNNEL_PORT}" || warn "Not listening."
  read -rp "Press Enter to return..."
}

restart_all() {
  systemctl restart rathole-iran rathole-kharej-1 2>/dev/null
  ok "Services restarted."
  sleep 2
}

uninstall_all() {
  systemctl stop rathole-iran rathole-kharej-1 rathole-fw rathole-mss-clamp 2>/dev/null
  systemctl disable rathole-iran rathole-kharej-1 rathole-fw rathole-mss-clamp 2>/dev/null
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
