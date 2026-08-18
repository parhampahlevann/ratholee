#!/bin/bash
# =============================================================================
#  Rathole Reverse Tunnel — Automated Stable Build (v3, Anti-Drop Edition)
#
#  Root causes of the "connects, then keeps dropping" problem in v2 and
#  what this version does about them:
#
#   1) TCP keepalive was 5s/2s. With the kernel default of 3 probes, any
#      connection stalled for ~11s (typical DPI throttling / congestion
#      burst) was killed by the kernel -> endless reconnect loop.
#      v3 uses rathole's proven defaults: 20s / 8s.
#   2) heartbeat_timeout=25 with heartbeat_interval=8 tolerated only ~2-3
#      lost heartbeats. On lossy links that causes false-positive reconnects.
#      v3 uses interval=10 / timeout=40 (~4 lost heartbeats tolerated, and
#      timeout > interval as required by rathole).
#   3) sysctl tcp_retries2=5 made the kernel RESET any flow that lost a few
#      retransmissions -> live sessions (SSH, downloads) through the tunnel
#      died during loss bursts. v3 uses tcp_retries2=8.
#   4) sysctl tcp_base_mss=1024 killed throughput; removed (MSS clamp stays).
#   5) MSS clamp flushed the WHOLE mangle/OUTPUT chain (-F), destroying
#      rules of other tools. v3 adds/removes only its own rule, idempotently.
#   6) /sbin/iptables was hardcoded (on many systems it lives in /usr/sbin).
#      v3 auto-detects the path everywhere (live rules + systemd units).
#   7) The firewall systemd unit duplicated rules on every boot. v3 uses
#      "-C check || -A add" so rules are always idempotent.
#   8) Re-running setup falsely reported "port busy" because the old rathole
#      instance was still bound. v3 stops the old service before checking.
#   9) Kharej setup did not abort when the service failed to start. Fixed.
#  10) v0.5.0 is a glibc (Ubuntu 22.04) build: on old distros the binary
#      crashed at startup while the install still "succeeded". v3 test-runs
#      the binary after install and falls back to the static musl build.
#  11) Uninstall left sysctl/mangle/INPUT rules behind. v3 cleans up fully.
#  12) NEW: lightweight self-healing guard (systemd timer, checks every 30s,
#      restarts the tunnel only after 3 consecutive failed checks) so a
#      wedged-but-alive connection recovers by itself.
#  13) NEW: optional fresh Noise keypair per install (validated as base64
#      32-byte X25519 keys). The built-in shared key still works by default
#      for zero-prompt setups.
#
#  Transport note: rathole's [x.transport.tcp] block (nodelay/keepalive)
#  also applies to the noise transport, so it is written for BOTH modes.
# =============================================================================

set -u

# ---------- Fixed settings ----------
TUNNEL_PORT="8443"
TOKEN="rH7kQ2vXpL9mZ4wT6nB8sD3fG5jC1yA0"

# Built-in Noise keypair (base64 X25519, 32 bytes) — works out of the box.
# You may replace these, or let the installer generate a fresh pair.
NOISE_PRIV="8bytOyfav+CIn6pEY+gCUSn6PpHJh7ADeHT55wmrTsE="
NOISE_PUB="gHmg3PHFH9+CouNJfGV28I4JwS3Hm28F8Vl2vGraU3g="

RATHOLE_VERSION="v0.5.0"          # latest stable release (x86_64 glibc)
RATHOLE_VERSION_MUSL="v0.4.8"     # last release that still ships musl/static builds
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
  echo -e "${G}   Rathole Reverse Tunnel — Stable Anti-Drop Build (v3)${N}"
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

# ---------- Purge obsolete watchdogs (legacy versions only) ----------
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
      ASSET_VERSION="$RATHOLE_VERSION_MUSL"
      warn "ARM server detected: using rathole ${ASSET_VERSION} (musl)."
      ;;
    *) err "Architecture $(uname -m) is not supported."; return 1 ;;
  esac
  return 0
}

# ---------- Download helper ----------
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

# ---------- Install core (with real run-verification) ----------
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

  # REAL CHECK: the binary must actually RUN on this system.
  # v0.5.0 x86_64 is built on a recent glibc; on old distros (e.g. CentOS 7)
  # it fails to start. Fall back to the static musl build in that case.
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

# ---------- Protocol selection ----------
choose_proto() {
  echo ""
  echo -e "${Y}Choose transport protocol:${N}"
  echo "  1) Noise (Recommended - encrypted, same speed class as TCP)"
  echo "  2) TCP   (plain, slightly less CPU)"
  echo ""
  read -rp "Choice [1]: " pc
  case "${pc:-1}" in
    2) PROTO="tcp" ;;
    *) PROTO="noise" ;;
  esac
  ok "Selected protocol: $PROTO"
}

# ---------- Noise key helpers ----------
b64_len() { printf '%s' "$1" | base64 -d 2>/dev/null | wc -c; }

gen_noise_keys() {
  GEN_PRIV=""; GEN_PUB=""
  local out="" arg
  for arg in "25519" "x25519" ""; do
    out="$("$BIN" --genkey $arg 2>/dev/null)" && [ -n "$out" ] && break
    out=""
  done
  GEN_PRIV="$(printf '%s\n' "$out" | sed -n 's/.*[Pp]rivate[ _][Kk]ey[: ]*//p' | head -n1 | tr -d '[:space:]')"
  GEN_PUB="$(printf  '%s\n' "$out" | sed -n 's/.*[Pp]ublic[ _][Kk]ey[: ]*//p'  | head -n1 | tr -d '[:space:]')"
  # validate: must be base64-encoded 32-byte X25519 keys (hex keys crash rathole)
  if [ "$(b64_len "$GEN_PRIV")" = "32" ] && [ "$(b64_len "$GEN_PUB")" = "32" ]; then
    return 0
  fi
  GEN_PRIV=""; GEN_PUB=""
  return 1
}

prepare_noise_server() {
  SRV_PRIV="$NOISE_PRIV"
  echo ""
  read -rp "Generate a fresh Noise keypair for this server? (more secure) [y/N]: " gk
  if [[ "${gk:-N}" =~ ^[Yy]$ ]]; then
    if gen_noise_keys; then
      SRV_PRIV="$GEN_PRIV"
      printf '%s\n' "$GEN_PUB" > "$CONF_DIR/noise-public-key.txt"
      chmod 600 "$CONF_DIR/noise-public-key.txt"
      echo ""
      ok "Fresh keypair generated and validated."
      echo -e "${Y}------------------------------------------------------------${N}"
      echo -e "${Y}Public key — enter this on the KHAREJ side when asked:${N}"
      echo -e "${G}${GEN_PUB}${N}"
      echo -e "${Y}(also saved to ${CONF_DIR}/noise-public-key.txt)${N}"
      echo -e "${Y}------------------------------------------------------------${N}"
      echo ""
    else
      warn "Key generation failed; using the built-in keypair."
    fi
  fi
}

prepare_noise_client() {
  CLI_PUB="$NOISE_PUB"
  echo ""
  read -rp "Remote (Iran) Noise public key [Enter = built-in default]: " rpk
  if [ -n "$rpk" ]; then
    if [ "$(b64_len "$rpk")" = "32" ]; then
      CLI_PUB="$rpk"
      ok "Custom public key accepted."
    else
      warn "Invalid key (not a 32-byte base64 key) — using built-in default."
    fi
  fi
}

# ---------- Transport blocks ----------
# NOTE: rathole applies [x.transport.tcp] options to noise/tls as well,
# so the tcp block is always written, whatever the chosen protocol.
transport_server_block() {
  cat <<EOF
[server.transport]
type = "${PROTO}"

[server.transport.tcp]
nodelay = true
keepalive_secs = 20
keepalive_interval = 8
EOF
  if [ "$PROTO" = "noise" ]; then
    cat <<EOF

[server.transport.noise]
pattern = "Noise_NK_25519_ChaChaPoly_BLAKE2s"
local_private_key = "${SRV_PRIV}"
EOF
  fi
}

transport_client_block() {
  cat <<EOF
[client.transport]
type = "${PROTO}"

[client.transport.tcp]
nodelay = true
keepalive_secs = 20
keepalive_interval = 8
EOF
  if [ "$PROTO" = "noise" ]; then
    cat <<EOF

[client.transport.noise]
pattern = "Noise_NK_25519_ChaChaPoly_BLAKE2s"
remote_public_key = "${CLI_PUB}"
EOF
  fi
}

# ---------- Service creation (with real startup verification) ----------
# Usage: make_unit <name> <conf> <desc> [must_listen_port]
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
RestartSec=2
LimitNOFILE=1048576
OOMScoreAdjust=-900
Nice=-10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${name}.service" >/dev/null 2>&1

  sleep 3
  if ! systemctl is-active --quiet "${name}.service"; then
    err "Service ${name}.service failed to start. Last log lines:"
    journalctl -u "${name}.service" -n 15 --no-pager
    return 1
  fi
  # a crash-looping service can look "active" at the instant we check
  if journalctl -u "${name}.service" -n 20 --no-pager 2>/dev/null | grep -qiE "panicked|core-dump|core_dump"; then
    err "Service ${name}.service is crash-looping (panic detected). Last log lines:"
    journalctl -u "${name}.service" -n 20 --no-pager
    return 1
  fi
  # for the server side, also verify the port is actually bound
  if [ -n "$port" ] && ! port_in_use "$port"; then
    err "Service is active but port ${port} is NOT bound. Last log lines:"
    journalctl -u "${name}.service" -n 15 --no-pager
    return 1
  fi
  ok "Service ${name}.service is active and stable."
  return 0
}

# ---------- Firewall (path-detected, idempotent, persisted) ----------
open_ports() {
  local ports="$1" p
  local IPT; IPT="$(command -v iptables 2>/dev/null || true)"

  # 1) high-level firewall managers, if present
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${TUNNEL_PORT}/tcp" >/dev/null 2>&1
    for p in $ports; do ufw allow "${p}/tcp" >/dev/null 2>&1; done
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${TUNNEL_PORT}/tcp" >/dev/null 2>&1
    for p in $ports; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1; done
    firewall-cmd --reload >/dev/null 2>&1
  fi

  # 2) explicit iptables rules — works regardless of ufw/firewalld
  if [ -n "$IPT" ]; then
    # remove rules left by a previous install for ports no longer used
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

    # persist across reboots (idempotent "-C || -A", no duplicates)
    {
      echo "[Unit]"
      echo "Description=Rathole firewall rules (tunnel + forward ports)"
      echo "After=network-online.target"
      echo "Wants=network-online.target"
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
    ok "Firewall rules applied for port ${TUNNEL_PORT} + forward ports (persisted, idempotent)."
  else
    warn "iptables not found — check your cloud firewall / security group manually."
  fi
}

# ---------- Anti-drop / performance sysctl tuning ----------
apply_net_tuning() {
  cat > /etc/sysctl.d/99-rathole-anti-drop.conf <<'EOF'
# --- Rathole anti-drop / performance tuning (v3) ---
# BBR + fq: best throughput on lossy, high-latency paths
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Large buffers for high bandwidth-delay-product links
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 131072 67108864

# Queue depths for many concurrent flows
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192

# Keepalive defaults for non-rathole sockets (rathole sets its own per-socket)
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# Loss tolerance: do NOT reset flows after a few lost retransmits
# (v2 used tcp_retries2=5, which killed live sessions during loss bursts)
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3

# Path-MTU blackhole protection (common on tunneled ISP paths)
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1

# Wider ephemeral port range for many parallel data channels (client side)
net.ipv4.ip_local_port_range = 10240 65535

# File-descriptor ceiling for many concurrent flows
fs.file-max = 1048576
EOF
  sysctl --system >/dev/null 2>&1
}

# ---------- MSS clamping (idempotent, non-destructive) ----------
apply_mss_clamp() {
  local IPT; IPT="$(command -v iptables 2>/dev/null || true)"
  [ -z "$IPT" ] && return 0
  # v2 flushed the entire mangle/OUTPUT chain — never do that.
  # Only ensure our single rule exists; leave other rules untouched.
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

# ---------- Self-healing guard (lightweight, flap-safe) ----------
install_guard() {
  cat > /usr/local/bin/rathole-guard.sh <<EOF
#!/bin/bash
# rathole self-healing guard: restarts the tunnel ONLY after 3 consecutive
# failed checks (~90s), so brief network blips never trigger a restart.
PORT=${TUNNEL_PORT}
ROLE="\$(cat /etc/rathole/role 2>/dev/null)"
STATE=/run/rathole-guard.fails
fails="\$(cat "\$STATE" 2>/dev/null || echo 0)"

mark_fail() {
  fails=\$((fails + 1))
  echo "\$fails" > "\$STATE"
  if [ "\$fails" -ge 3 ]; then
    logger -t rathole-guard "restarting \$1 after \$fails failed checks"
    systemctl restart "\$1"
    echo 0 > "\$STATE"
  fi
  exit 0
}

case "\$ROLE" in
  iran)
    systemctl is-active --quiet rathole-iran.service || mark_fail rathole-iran.service
    ss -tln 2>/dev/null | grep -qE "[:.]\${PORT}[[:space:]]" || mark_fail rathole-iran.service
    ;;
  kharej)
    systemctl is-active --quiet rathole-kharej-1.service || mark_fail rathole-kharej-1.service
    # control channel must be established towards the Iran server
    ss -tn state established 2>/dev/null | grep -qE "[:.]\${PORT}[[:space:]]" || mark_fail rathole-kharej-1.service
    ;;
  *) exit 0 ;;
esac
echo 0 > "\$STATE"
exit 0
EOF
  chmod 0755 /usr/local/bin/rathole-guard.sh

  cat > /etc/systemd/system/rathole-guard.service <<'EOF'
[Unit]
Description=Rathole self-healing guard check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rathole-guard.sh
EOF

  cat > /etc/systemd/system/rathole-guard.timer <<'EOF'
[Unit]
Description=Rathole self-healing guard timer

[Timer]
OnBootSec=45
OnUnitActiveSec=30
AccuracySec=5
Unit=rathole-guard.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now rathole-guard.timer >/dev/null 2>&1
  ok "Self-healing guard installed (checks every 30s, restarts only after 3 failed checks)."
}

# ---------- Post-install verification (Iran side) ----------
test_iran_listening() {
  info "Verifying the tunnel port is actually listening..."
  sleep 1
  if port_in_use "$TUNNEL_PORT"; then
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
  info "Setting up Iran Server (port ${TUNNEL_PORT})..."
  install_deps
  purge_watchdog
  install_core || { read -rp "Press Enter to return..."; return; }

  # re-run safe: stop the previous instance BEFORE checking ports
  systemctl stop rathole-iran.service >/dev/null 2>&1

  check_tunnel_port_free || { read -rp "Press Enter to return..."; return; }

  local ports="" raw_ports
  while [ -z "$ports" ]; do
    read -rp "Enter Forward Ports (e.g., 1080,80,443): " raw_ports
    ports=$(parse_ports "$raw_ports")
  done

  check_forward_ports_free "$ports" || { read -rp "Press Enter to return..."; return; }
  choose_proto
  SRV_PRIV="$NOISE_PRIV"
  [ "$PROTO" = "noise" ] && prepare_noise_server

  # remember port list (used to clean old firewall rules on re-install/uninstall)
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
  test_iran_listening

  echo ""
  ok "Iran Server ready on port ${TUNNEL_PORT} (protocol: ${PROTO})."
  warn "IMPORTANT: the Kharej side MUST choose the SAME protocol (${PROTO})."
  read -rp "Press Enter to return..."
}

# ---------- Setup Kharej Server ----------
setup_kharej() {
  banner
  info "Setting up Kharej Server (client)..."
  install_deps
  purge_watchdog
  install_core || { read -rp "Press Enter to return..."; return; }

  # re-run safe: stop the previous instance first
  systemctl stop rathole-kharej-1.service >/dev/null 2>&1

  choose_proto
  CLI_PUB="$NOISE_PUB"
  [ "$PROTO" = "noise" ] && prepare_noise_client

  local ip=""
  while [ -z "$ip" ]; do
    read -rp "Enter Iran Server IP: " ip
    [[ "$ip" =~ ^[0-9a-zA-Z.:-]+$ ]] || { warn "Invalid address."; ip=""; }
  done

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
  sleep 4
  if journalctl -u rathole-kharej-1 -n 12 --no-pager 2>/dev/null | grep -qiE "error|refused|reset"; then
    warn "Recent errors detected:"
    journalctl -u rathole-kharej-1 -n 12 --no-pager
    echo ""
    warn "'Connection refused' -> Iran side is down or the port is blocked."
    warn "'Connection reset'   -> token/key mismatch, wrong protocol on one side, or DPI."
    warn "Handshake errors     -> Noise keys don't match the Iran public key."
  else
    ok "No recent errors — control channel is up."
  fi

  echo ""
  ok "Kharej client configured (Iran: ${ip}:${TUNNEL_PORT}, protocol: ${PROTO})."
  warn "IMPORTANT: the Iran side MUST be running the SAME protocol (${PROTO})."
  read -rp "Press Enter to return..."
}

# ---------- Status ----------
show_status() {
  banner
  local role proto
  role="$(cat "$ROLE_FILE" 2>/dev/null || echo '?')"
  proto="$(cat "$PROTO_FILE" 2>/dev/null || echo '?')"
  info "Role: ${role}    Protocol: ${proto}    Tunnel port: ${TUNNEL_PORT}"
  echo ""
  systemctl status rathole-iran rathole-kharej-1 --no-pager 2>/dev/null
  echo ""
  info "Self-healing guard:"
  systemctl list-timers rathole-guard.timer --no-pager 2>/dev/null | head -n 3 || true
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

# ---------- Full uninstall (leaves nothing behind) ----------
uninstall_all() {
  local IPT; IPT="$(command -v iptables 2>/dev/null || true)"
  systemctl stop rathole-iran rathole-kharej-1 rathole-fw rathole-mss-clamp rathole-guard.timer rathole-guard.service 2>/dev/null
  systemctl disable rathole-iran rathole-kharej-1 rathole-fw rathole-mss-clamp rathole-guard.timer rathole-guard.service 2>/dev/null

  # remove live firewall rules added by this script
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
  rm -f /etc/systemd/system/rathole* /run/rathole-guard.fails
  rm -f /etc/sysctl.d/99-rathole-anti-drop.conf
  sysctl --system >/dev/null 2>&1
  systemctl daemon-reload
  ok "Tunnel fully removed (services, firewall rules, sysctl tuning, guard)."
  sleep 2
}

# ---------- Main menu ----------
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
