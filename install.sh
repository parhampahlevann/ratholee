#!/usr/bin/env bash
set -euo pipefail

VERSION="v0.5.0"
BIN="/usr/local/bin/rathole"
CONF_DIR="/etc/rathole"
TOKEN="${TOKEN:-change_me_please}"

log(){ echo -e "\033[1;32m[+] $*\033[0m"; }
err(){ echo -e "\033[1;31m[!] $*\033[0m" >&2; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || err "با sudo اجرا کن."; }

detect_arch(){
  case "$(uname -m)" in
    x86_64|amd64)  echo "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
    armv7l)        echo "armv7-unknown-linux-musleabihf" ;;
    *) err "معماری پشتیبانی نمی‌شود: $(uname -m)" ;;
  esac
}

install_bin(){
  need_root
  command -v curl >/dev/null || err "curl نصب نیست"
  command -v unzip >/dev/null || { log "نصب unzip"; apt-get install -y unzip || yum install -y unzip; }
  local arch file url
  arch=$(detect_arch)
  file="rathole-${arch}.zip"
  url="https://github.com/rathole-org/rathole/releases/download/${VERSION}/${file}"
  log "دانلود $url"
  curl -fL --progress-bar -o "/tmp/${file}" "$url"
  rm -rf /tmp/rathole_bin && mkdir -p /tmp/rathole_bin
  unzip -o -q "/tmp/${file}" -d /tmp/rathole_bin
  install -m 755 /tmp/rathole_bin/rathole "$BIN"
  rm -rf "/tmp/${file}" /tmp/rathole_bin
  "$BIN" --version
}

tune_network(){
  need_root
  log "اعمال BBR + بافر"
  cat > /etc/sysctl.d/99-rathole.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
EOF
  sysctl -p /etc/sysctl.d/99-rathole.conf >/dev/null || true
}

# ====== سؤال یا دریافت پورت‌ها ======
read_ports(){
  if [ -z "${PORTS:-}" ]; then
    read -rp "پورت‌های فوروارد را با کاما بده (مثل 1080,443,23902,2053): " PORTS
  fi
  [ -n "$PORTS" ] || err "حداقل یک پورت وارد کن"
}

gen_server_conf(){
  read_ports
  local bind="${BIND_PORT:-2333}"
  mkdir -p "$CONF_DIR"
  {
    echo "[server]"
    echo "bind_addr = \"0.0.0.0:${bind}\""
    echo ""
    local p
    IFS=',' read -ra arr <<< "$PORTS"
    for p in "${arr[@]}"; do
      p=$(echo "$p" | tr -d '[:space:]')
      echo "[server.services.p${p}]"
      echo "type = \"tcp\""
      echo "token = \"${TOKEN}\""
      echo "bind_addr = \"0.0.0.0:${p}\""
      echo ""
    done
  } > "$CONF_DIR/server.toml"
}

gen_client_conf(){
  read_ports
  local remote="${REMOTE_ADDR:?مقدار REMOTE_ADDR مثل IP:2333 را بده}"
  mkdir -p "$CONF_DIR"
  {
    echo "[client]"
    echo "remote_addr = \"${remote}\""
    echo ""
    local p
    IFS=',' read -ra arr <<< "$PORTS"
    for p in "${arr[@]}"; do
      p=$(echo "$p" | tr -d '[:space:]')
      echo "[client.services.p${p}]"
      echo "type = \"tcp\""
      echo "token = \"${TOKEN}\""
      echo "local_addr = \"127.0.0.1:${p}\""
      echo ""
    done
  } > "$CONF_DIR/client.toml"
}

service_unit(){
  local role="$1"
  cat > "/etc/systemd/system/rathole-${role}.service" <<EOF
[Unit]
Description=Rathole ${role} tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} --config ${CONF_DIR}/${role}.toml
Restart=always
RestartSec=2
LimitNOFILE=1048576
Nice=-10
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "rathole-${role}"
}

cmd_server(){
  need_root; install_bin; tune_network; gen_server_conf; service_unit server
  log "سرور فعال. پورت کنترل: ${BIND_PORT:-2333} | فورواردها: ${PORTS}"
}
cmd_client(){
  need_root; install_bin; gen_client_conf; service_unit client
  log "کلاینت فعال. فورواردها: ${PORTS}"
}
cmd_status(){
  for s in server client; do
    if systemctl list-unit-files "rathole-${s}.service" >/dev/null 2>&1; then
      echo "──────── rathole-${s} ────────"
      systemctl is-active "rathole-${s}" || true
      systemctl status "rathole-${s}" --no-pager -l | head -n 12 || true
    fi
  done
  echo "──────── پورت‌های شنونده ────────"
  ss -tlnp 2>/dev/null | grep rathole || true
}
cmd_logs(){ journalctl -u rathole-client -u rathole-server -f; }
cmd_uninstall(){
  need_root
  for s in server client; do
    systemctl disable --now "rathole-${s}" 2>/dev/null || true
    rm -f "/etc/systemd/system/rathole-${s}.service"
  done
  systemctl daemon-reload
  rm -f "$BIN" /etc/sysctl.d/99-rathole.conf
  rm -rf "$CONF_DIR"
  log "Rathole حذف شد."
}

case "${1:-}" in
  install)   install_bin ;;
  server)    cmd_server ;;
  client)    cmd_client ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  uninstall) cmd_uninstall ;;
  *) echo "Usage: $0 {install|server|client|status|logs|uninstall}"; exit 1 ;;
esac
