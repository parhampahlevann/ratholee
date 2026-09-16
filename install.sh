#!/bin/bash

# ============================================================
#  Rathole Tunnel Manager - v3 (customized for Parham)
#  Changes vs original:
#   - Downloads latest STABLE official release from GitHub
#     (musl build preferred for max compatibility), with
#     automatic architecture detection and safe fallback.
#   - Adds a Watchdog (systemd service) on BOTH Iran and Kharej
#     sides that detects disconnects / packet loss and forces
#     an instant restart to keep the tunnel stable.
#   - Kharej (client) side now asks how many Iran servers you
#     have and builds one client profile per Iran server, all
#     connecting simultaneously (multi-server / failover setup).
#   - Tunnel port defaults to 8090 and PSK token defaults to 123
#     (both still editable - press Enter to accept the default).
#   - TCP_NODELAY is now a simple y/n question.
#   - Added tuning profiles: gaming / stable / balanced / speed /
#     custom - each sets sane heartbeat / nodelay / retry values.
#   - Fixed bugs: RED/GREEN/... colors were referenced before
#     being defined (silent no-color bug on first run), SERVER_IP
#     was used without ever being set, a stray "done" token in a
#     colorize call, and the destroy flow now also removes the
#     matching watchdog service.
#   - No existing menu option / feature was removed.
# ============================================================

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   sleep 1
   exit 1
fi

# ---- Color codes (moved to the very top so they are defined
#      before any function that references them can run) ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\e[36m'
MAGENTA="\e[95m"
NC='\033[0m' # No Color

# just press key to continue
press_key(){
 read -p "Press any key to continue..."
}

# Define a function to colorize text
colorize() {
    local color="$1"
    local text="$2"
    local style="${3:-normal}"

    local black="\033[30m"
    local red="\033[31m"
    local green="\033[32m"
    local yellow="\033[33m"
    local blue="\033[34m"
    local magenta="\033[35m"
    local cyan="\033[36m"
    local white="\033[37m"
    local reset="\033[0m"

    local normal="\033[0m"
    local bold="\033[1m"
    local underline="\033[4m"

    local color_code
    case $color in
        black) color_code=$black ;;
        red) color_code=$red ;;
        green) color_code=$green ;;
        yellow) color_code=$yellow ;;
        blue) color_code=$blue ;;
        magenta) color_code=$magenta ;;
        cyan) color_code=$cyan ;;
        white) color_code=$white ;;
        *) color_code=$reset ;;
    esac

    local style_code
    case $style in
        bold) style_code=$bold ;;
        underline) style_code=$underline ;;
        normal | *) style_code=$normal ;;
    esac

    echo -e "${style_code}${color_code}${text}${reset}"
}

# ---- Global defaults (requested) ----
DEFAULT_TUNNEL_PORT=8090
DEFAULT_TOKEN=123

# Function to install unzip if not already installed
install_unzip() {
    if ! command -v unzip &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            echo -e "${RED}unzip is not installed. Installing...${NC}"
            sleep 1
            sudo apt-get update
            sudo apt-get install -y unzip
        else
            echo -e "${RED}Error: Unsupported package manager. Please install unzip manually.${NC}\n"
            press_key
            exit 1
        fi
    fi
}
install_unzip

# Function to install cron if not already installed
install_cron() {
    if ! command -v cron &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            echo -e "${RED}cron is not installed. Installing...${NC}"
            sleep 1
            sudo apt-get update
            sudo apt-get install -y cron
        else
            echo -e "${RED}Error: Unsupported package manager. Please install cron manually.${NC}\n"
            press_key
            exit 1
        fi
    fi
}
install_cron

# Function to install jq if not already installed
install_jq() {
    if ! command -v jq &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            echo -e "${RED}jq is not installed. Installing...${NC}"
            sleep 1
            sudo apt-get update
            sudo apt-get install -y jq
        else
            echo -e "${RED}Error: Unsupported package manager. Please install jq manually.${NC}\n"
            press_key
            exit 1
        fi
    fi
}
install_jq

# Make sure netcat/timeout basics for watchdog exist (bash's /dev/tcp is used, no extra pkg needed)

config_dir="/root/rathole-core"

# ---- Detect the correct official release asset for this CPU arch ----
# Prefers the musl build (statically linked -> works on any glibc version,
# which is the most "stable" choice across different Debian/Ubuntu bases).
get_rathole_asset_url() {
    local arch
    arch=$(uname -m)
    local patterns=()

    case "$arch" in
        x86_64|amd64)
            patterns=("x86_64-unknown-linux-musl" "x86_64-unknown-linux-gnu")
            ;;
        aarch64|arm64)
            patterns=("aarch64-unknown-linux-musl" "aarch64-unknown-linux-gnu")
            ;;
        armv7l)
            patterns=("armv7-unknown-linux-musleabihf" "arm-unknown-linux-gnueabihf")
            ;;
        *)
            patterns=()
            ;;
    esac

    if [[ ${#patterns[@]} -eq 0 ]]; then
        return 1
    fi

    local release_json
    release_json=$(curl -sSL --max-time 10 "https://api.github.com/repos/rapiz1/rathole/releases/latest")

    if [[ -z "$release_json" ]]; then
        return 1
    fi

    local url
    for p in "${patterns[@]}"; do
        url=$(echo "$release_json" | grep -o "https://[^\"]*${p}[^\"]*\.zip" | head -n 1)
        if [[ -n "$url" ]]; then
            echo "$url"
            return 0
        fi
    done

    return 1
}

# Function to download and extract Rathole Core
download_and_extract_rathole() {
    # check if core installed already
    if [[ -f "${config_dir}/rathole" ]]; then
        if [[ "$1" == "sleep" ]]; then
            echo
            colorize green "Rathole Core is already installed." bold
            sleep 1
        fi
        return 1
    fi

    mkdir -p "$config_dir"

    ENTRY="185.199.108.133 raw.githubusercontent.com"
    if ! grep -q "$ENTRY" /etc/hosts; then
        echo "Github Entry not found. Adding to /etc/hosts..."
        echo "$ENTRY" >> /etc/hosts
    else
        echo "Github entry already exists in /etc/hosts."
    fi

    if [[ $(uname) != "Linux" ]]; then
        echo -e "${RED}Unsupported operating system.${NC}"
        sleep 1
        exit 1
    fi

    colorize cyan "Fetching the latest STABLE official rathole release from GitHub..." bold

    DOWNLOAD_URL=$(get_rathole_asset_url)

    if [ -z "$DOWNLOAD_URL" ]; then
        colorize yellow "Could not resolve an official GitHub asset (rate-limited / no network to GitHub?). Falling back to mirrored build..."
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then
            DOWNLOAD_URL='https://github.com/Musixal/rathole-tunnel/raw/main/core/rathole.zip'
        fi
    fi

    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${RED}Failed to retrieve download URL for this architecture.${NC}"
        sleep 1
        exit 1
    fi

    DOWNLOAD_DIR=$(mktemp -d)
    echo -e "Downloading Rathole from $DOWNLOAD_URL...\n"
    sleep 1
    if ! curl -sSL -o "$DOWNLOAD_DIR/rathole.zip" "$DOWNLOAD_URL"; then
        colorize red "Download failed. Check your network/GitHub access." bold
        rm -rf "$DOWNLOAD_DIR"
        exit 1
    fi
    echo -e "Extracting Rathole...\n"
    sleep 1
    unzip -o -q "$DOWNLOAD_DIR/rathole.zip" -d "$config_dir"

    # The zip may contain the binary directly or inside a subfolder - normalize it
    if [[ ! -f "${config_dir}/rathole" ]]; then
        found_bin=$(find "$config_dir" -maxdepth 3 -type f -iname "rathole*" ! -iname "*.zip" | head -n 1)
        if [[ -n "$found_bin" ]]; then
            mv -f "$found_bin" "${config_dir}/rathole"
        fi
    fi

    echo -e "${GREEN}Rathole installation completed.${NC}\n"
    chmod u+x "${config_dir}/rathole"
    rm -rf "$DOWNLOAD_DIR"
}

# Download and extract the Rathole core
download_and_extract_rathole

# Get server public IP (was previously referenced but never set - fixed)
SERVER_IP=$(curl -s --max-time 3 -4 ifconfig.me 2>/dev/null)
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Fetch server country
SERVER_COUNTRY=$(curl --max-time 3 -sS "http://ipwhois.app/json/$SERVER_IP" | jq -r '.country' 2>/dev/null)

# Fetch server isp
SERVER_ISP=$(curl --max-time 3 -sS "http://ipwhois.app/json/$SERVER_IP" | jq -r '.isp' 2>/dev/null)

# Function to display ASCII logo
display_logo() {
    echo -e "${CYAN}"
    cat << "EOF"
               __  .__           .__          
____________ _/  |_|  |__   ____ |  |   ____  
\_  __ \__  \\   __|  |  \ /  _ \|  | _/ __ \ 
 |  | \// __ \|  | |   Y  (  <_> |  |_\  ___/ 
 |__|  (____  |__| |___|  /\____/|____/\___  >
            \/          \/                 \/ 	
EOF
    echo -e "${NC}${GREEN}"
    echo -e "Version: ${YELLOW}v3.0 (custom)${GREEN}"
    echo -e "Github: ${YELLOW}github.com/Musixal/Rathole-Tunnel${GREEN}"
    echo -e "Telegram Channel: ${YELLOW}@Gozar_Xray${NC}"
}

# Function to display server location and IP
display_server_info() {
    echo -e "\e[93m═════════════════════════════════════════════\e[0m"
    echo -e "${CYAN}Location:${NC} $SERVER_COUNTRY "
    echo -e "${CYAN}Datacenter:${NC} $SERVER_ISP"
}

# Function to display Rathole Core installation status
display_rathole_core_status() {
    if [[ -f "${config_dir}/rathole" ]]; then
        echo -e "${CYAN}Rathole Core:${NC} ${GREEN}Installed${NC}"
    else
        echo -e "${CYAN}Rathole Core:${NC} ${RED}Not installed${NC}"
    fi
    echo -e "\e[93m═════════════════════════════════════════════\e[0m"
}

# Function to check if a given string is a valid IPv6 address
check_ipv6() {
    local ip=$1
    ipv6_pattern="^([0-9a-fA-F]{1,4}:){7}([0-9a-fA-F]{1,4}|:)$|^(([0-9a-fA-F]{1,4}:){1,7}|:):((:[0-9a-fA-F]{1,4}){1,7}|:)$"
    ip="${ip#[}"
    ip="${ip%]}"

    if [[ $ip =~ $ipv6_pattern ]]; then
        return 0
    else
        return 1
    fi
}

check_port() {
    local PORT=$1
    local TRANSPORT=$2

    if [ -z "$PORT" ]; then
        echo "Usage: check_port <port> <transport>"
        return 1
    fi

    if [[ "$TRANSPORT" == "tcp" ]]; then
        if ss -tlnp "sport = :$PORT" | grep "$PORT" > /dev/null; then
            return 0
        else
            return 1
        fi
    elif [[ "$TRANSPORT" == "udp" ]]; then
        if ss -ulnp "sport = :$PORT" | grep "$PORT" > /dev/null; then
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
}

# ============================================================
#  Tuning profiles
#  Sets: PROFILE_HEARTBEAT (seconds, 0 = disabled)
#        PROFILE_NODELAY   (true/false)
#        PROFILE_RETRY     (seconds, client retry_interval)
# ============================================================
choose_profile() {
    echo
    colorize cyan "Select a tuning profile:" bold
    echo -e " 1) ${GREEN}Gaming${NC}   - lowest latency, no heartbeat overhead"
    echo -e " 2) ${YELLOW}Stable${NC}   - prioritizes uptime over raw speed"
    echo -e " 3) ${CYAN}Balanced${NC} - good middle ground for general use"
    echo -e " 4) ${MAGENTA}Speed${NC}    - maximum throughput (bulk downloads)"
    echo -e " 5) Custom     - ask heartbeat manually"
    echo
    read -p "Enter your choice [1-5]: " profile_choice

    case "$profile_choice" in
        1)
            PROFILE_NAME="gaming"
            PROFILE_HEARTBEAT=0
            PROFILE_NODELAY="true"
            PROFILE_RETRY=1
            ;;
        2)
            PROFILE_NAME="stable"
            PROFILE_HEARTBEAT=30
            PROFILE_NODELAY="false"
            PROFILE_RETRY=3
            ;;
        3)
            PROFILE_NAME="balanced"
            PROFILE_HEARTBEAT=20
            PROFILE_NODELAY="true"
            PROFILE_RETRY=2
            ;;
        4)
            PROFILE_NAME="speed"
            PROFILE_HEARTBEAT=0
            PROFILE_NODELAY="false"
            PROFILE_RETRY=1
            ;;
        5)
            PROFILE_NAME="custom"
            local hb=""
            while [[ "$hb" != "true" && "$hb" != "false" ]]; do
                echo -ne "[*] Enable HEARTBEAT (true/false): "
                read -r hb
            done
            if [[ "$hb" == "true" ]]; then
                echo -ne "[*] Heartbeat interval seconds (e.g. 30): "
                read -r PROFILE_HEARTBEAT
                [[ "$PROFILE_HEARTBEAT" =~ ^[0-9]+$ ]] || PROFILE_HEARTBEAT=30
            else
                PROFILE_HEARTBEAT=0
            fi
            PROFILE_NODELAY="false"
            PROFILE_RETRY=2
            ;;
        *)
            colorize red "Invalid choice, defaulting to 'balanced'."
            PROFILE_NAME="balanced"
            PROFILE_HEARTBEAT=20
            PROFILE_NODELAY="true"
            PROFILE_RETRY=2
            ;;
    esac

    echo
    colorize green "Profile '$PROFILE_NAME' selected (heartbeat=${PROFILE_HEARTBEAT}s, nodelay=${PROFILE_NODELAY}, retry=${PROFILE_RETRY}s)"
}

# Simple y/n prompt for TCP_NODELAY, defaulting to the profile suggestion
ask_nodelay() {
    local default_val="$1"
    local default_letter="n"
    [[ "$default_val" == "true" ]] && default_letter="y"

    echo
    read -p "[*] Enable TCP_NODELAY? (y/n) [default: $default_letter]: " nd_answer
    nd_answer="${nd_answer:-$default_letter}"

    if [[ "$nd_answer" == "y" || "$nd_answer" == "Y" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# ============================================================
#  Watchdog - detects disconnects / packet loss and forces an
#  instant restart of the matching rathole systemd service.
#  side       : "iran" or "kharej"
#  service    : e.g. rathole-iran8090.service
#  remote_addr: only used on kharej side, IP of the Iran server
#  remote_port: tunnel port to test connectivity against
# ============================================================
create_watchdog() {
    local side="$1"
    local service="$2"
    local remote_addr="$3"
    local remote_port="$4"

    local wd_name="watchdog-${service%.service}"
    local wd_script="${config_dir}/${wd_name}.sh"
    local wd_service="${service_dir}/${wd_name}.service"

    cat << EOF > "$wd_script"
#!/bin/bash
SERVICE="$service"
SIDE="$side"
REMOTE_ADDR="$remote_addr"
REMOTE_PORT="$remote_port"
FAIL_COUNT=0
MAX_FAIL=3

while true; do
    if ! systemctl is-active --quiet "\$SERVICE"; then
        systemctl restart "\$SERVICE" >/dev/null 2>&1
        FAIL_COUNT=0
        sleep 10
        continue
    fi

    if [[ "\$SIDE" == "kharej" && -n "\$REMOTE_ADDR" ]]; then
        if timeout 3 bash -c "echo > /dev/tcp/\${REMOTE_ADDR}/\${REMOTE_PORT}" 2>/dev/null; then
            FAIL_COUNT=0
        else
            FAIL_COUNT=\$((FAIL_COUNT+1))
        fi
    else
        if ss -tln | grep -q ":\${REMOTE_PORT} "; then
            FAIL_COUNT=0
        else
            FAIL_COUNT=\$((FAIL_COUNT+1))
        fi
    fi

    if [[ \$FAIL_COUNT -ge \$MAX_FAIL ]]; then
        systemctl restart "\$SERVICE" >/dev/null 2>&1
        FAIL_COUNT=0
    fi

    sleep 10
done
EOF

    chmod +x "$wd_script"

    cat << EOF > "$wd_service"
[Unit]
Description=Watchdog for $service (auto-reconnect / packet-loss guard)
After=network.target ${service}

[Service]
Type=simple
ExecStart=/bin/bash $wd_script
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now "${wd_name}.service" >/dev/null 2>&1
    colorize green "Watchdog installed and running for $service"
}

remove_watchdog() {
    local service="$1"
    local wd_name="watchdog-${service%.service}"
    local wd_script="${config_dir}/${wd_name}.sh"
    local wd_service="${service_dir}/${wd_name}.service"

    if [[ -f "$wd_service" ]]; then
        systemctl disable --now "${wd_name}.service" >/dev/null 2>&1
        rm -f "$wd_service"
    fi
    rm -f "$wd_script"
    systemctl daemon-reload >/dev/null 2>&1
}

# Function for configuring tunnel
configure_tunnel() {

if [[ ! -d "$config_dir" ]]; then
    echo -e "\n${RED}Rathole-core directory not found. Install it first through 'Install Rathole core' option.${NC}\n"
    read -p "Press Enter to continue..."
    return 1
fi

    clear
    colorize green "Essential tips:" bold
    colorize yellow "   Enable TCP_NODELAY to improve the latency but decrease the bandwidth.
   For the high number of connections, I recommend turning off the Heartbeat option"
    echo
    colorize green "1) Configure for IRAN server" bold
    colorize magenta "2) Configure for KHAREJ server" bold
    echo
    read -p "Enter your choice: " configure_choice
    case "$configure_choice" in
        1) iran_server_configuration ;;
        2) kharej_server_configuration ;;
        *) echo -e "${RED}Invalid option!${NC}" && sleep 1 ;;
    esac
    echo
    read -p "Press Enter to continue..."
}

# Global Variables
service_dir="/etc/systemd/system"

# Function to configure Iran server
iran_server_configuration() {
    clear
    colorize cyan "Configuring IRAN server" bold

    echo

    local_ip='0.0.0.0'
    read -p "[-] Listen for IPv6 address? (y/n): " answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        colorize yellow "IPv6 Enabled"
        local_ip='[::]'
    elif [ "$answer" = "n" ]; then
        colorize yellow "IPv4 Enabled"
        local_ip='0.0.0.0'
    else
        colorize yellow "Invalid choice. IPv4 enabled by default."
        local_ip='0.0.0.0'
    fi

    echo

    while true; do
        echo -ne "[*] Tunnel port [Enter = ${DEFAULT_TUNNEL_PORT}]: "
        read -r tunnel_port
        tunnel_port="${tunnel_port:-$DEFAULT_TUNNEL_PORT}"

        if [[ "$tunnel_port" =~ ^[0-9]+$ ]] && [ "$tunnel_port" -gt 22 ] && [ "$tunnel_port" -le 65535 ]; then
            if check_port "$tunnel_port" "tcp"; then
                colorize red "Port $tunnel_port is in use."
            else
                break
            fi
        else
            colorize red "Please enter a valid port number between 23 and 65535"
        fi
    done

    # Tuning profile decides heartbeat + suggested nodelay
    choose_profile
    HEARTBEAT="$PROFILE_HEARTBEAT"
    nodelay=$(ask_nodelay "$PROFILE_NODELAY")

    echo

    # Initialize transport variable
    local transport=""
    while [[ "$transport" != "tcp" && "$transport" != "udp" ]]; do
        echo -ne "[*] Transport type(tcp/udp): "
        read -r transport
        if [[ "$transport" != "tcp" && "$transport" != "udp" ]]; then
            colorize red "Invalid transport type. Please enter 'tcp' or 'udp'"
        fi
    done

    echo

    echo -ne "[-] Security Token (PSK) [Enter = ${DEFAULT_TOKEN}]: "
    read -r token
    token="${token:-$DEFAULT_TOKEN}"

    echo

    # Prompt for Ports
    echo -ne "[*] Enter your ports separated by commas (e.g. 2070,2080): "
    read -r input_ports
    input_ports=$(echo "$input_ports" | tr -d ' ')
    IFS=',' read -r -a ports <<< "$input_ports"
    declare -a config_ports
    for port in "${ports[@]}"; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 22 ] && [ "$port" -le 65535 ]; then
            if check_port "$port" "$transport"; then
                colorize red "[ERROR] Port $port is in use."
            else
                colorize green "[INFO] Port $port added to your configs"
                config_ports+=("$port")
            fi
        else
            colorize red "[ERROR] Port $port is Invalid. Please enter a valid port number between 23 and 65535"
        fi
    done

    if [ ${#config_ports[@]} -eq 0 ]; then
        colorize red "No ports were entered. Exiting." bold
        sleep 2
        return 1
    fi

    # Generate server configuration file
    cat << EOF > "${config_dir}/iran${tunnel_port}.toml"
[server]
bind_addr = "${local_ip}:${tunnel_port}"
default_token = "$token"
heartbeat_interval = $HEARTBEAT

[server.transport]
type = "tcp"

[server.transport.tcp]
nodelay = $nodelay

EOF

    for port in "${config_ports[@]}"; do
        cat << EOF >> "${config_dir}/iran${tunnel_port}.toml"
[server.services.${port}]
type = "$transport"
bind_addr = "${local_ip}:${port}"

EOF
    done

    echo

    cat << EOF > "${service_dir}/rathole-iran${tunnel_port}.service"
[Unit]
Description=Rathole Iran Port $tunnel_port (Iran)
After=network.target

[Service]
Type=simple
ExecStart=${config_dir}/rathole ${config_dir}/iran${tunnel_port}.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1

    if systemctl enable --now "rathole-iran${tunnel_port}.service" >/dev/null 2>&1; then
        colorize green "Iran service with port $tunnel_port enabled to start on boot and started."
    else
        colorize red "Failed to enable service with port $tunnel_port. Please check your system configuration."
        return 1
    fi

    create_watchdog "iran" "rathole-iran${tunnel_port}.service" "" "$tunnel_port"

    echo
    colorize green "IRAN server configuration completed successfully."
}

# Build ONE kharej client config+service+watchdog for a single Iran server
# Args: server_ip, tunnel_port, token, transport, nodelay, heartbeat, retry, local_ip, config_ports[]
build_kharej_profile() {
    local server_addr="$1"
    local tunnel_port="$2"
    local token="$3"
    local transport="$4"
    local nodelay="$5"
    local heartbeat="$6"
    local retry="$7"
    local local_ip="$8"
    shift 8
    local config_ports=("$@")

    # slug used in filenames: sanitize IPv6 colons/brackets
    local slug
    slug=$(echo "$server_addr" | tr -d '[]' | tr ':' '-' | tr '.' '-')
    local cfg_name="kharej-${slug}-${tunnel_port}"

    local_addr_for_check="$local_ip"
    if check_ipv6 "$server_addr"; then
        local_addr_for_check='[::]'
        server_addr="${server_addr#[}"
        server_addr="${server_addr%]}"
    fi

    cat << EOF > "${config_dir}/${cfg_name}.toml"
[client]
remote_addr = "${server_addr}:${tunnel_port}"
default_token = "$token"
heartbeat_timeout = $heartbeat
retry_interval = $retry

[client.transport]
type = "tcp"

[client.transport.tcp]
nodelay = $nodelay

EOF

    for port in "${config_ports[@]}"; do
        cat << EOF >> "${config_dir}/${cfg_name}.toml"
[client.services.${port}]
type = "$transport"
local_addr = "${local_addr_for_check}:${port}"

EOF
    done

    cat << EOF > "${service_dir}/rathole-${cfg_name}.service"
[Unit]
Description=Rathole Kharej -> ${server_addr}:${tunnel_port}
After=network.target

[Service]
Type=simple
ExecStart=${config_dir}/rathole ${config_dir}/${cfg_name}.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1

    if systemctl enable --now "rathole-${cfg_name}.service" >/dev/null 2>&1; then
        colorize green "Kharej service -> ${server_addr}:${tunnel_port} enabled and started."
    else
        colorize red "Failed to enable service for ${server_addr}:${tunnel_port}."
        return 1
    fi

    create_watchdog "kharej" "rathole-${cfg_name}.service" "$server_addr" "$tunnel_port"
}

# Function for configuring Kharej server (now supports multiple Iran servers)
kharej_server_configuration() {
    clear
    colorize cyan "Configuring kharej server" bold

    echo

    while true; do
        echo -ne "[*] How many IRAN servers do you want this client to connect to? "
        read -r iran_server_count
        if [[ "$iran_server_count" =~ ^[0-9]+$ ]] && [ "$iran_server_count" -ge 1 ]; then
            break
        else
            colorize red "Please enter a valid number (1 or more)."
        fi
    done

    declare -a server_addrs
    for ((i=1; i<=iran_server_count; i++)); do
        while true; do
            echo -ne "[*] IRAN server #$i IP address [IPv4/IPv6]: "
            read -r addr
            if [[ -n "$addr" ]]; then
                server_addrs+=("$addr")
                break
            else
                colorize red "Server address cannot be empty."
            fi
        done
    done

    echo

    echo -ne "[*] Tunnel port for ALL Iran servers [Enter = ${DEFAULT_TUNNEL_PORT}]: "
    read -r tunnel_port
    tunnel_port="${tunnel_port:-$DEFAULT_TUNNEL_PORT}"
    if ! [[ "$tunnel_port" =~ ^[0-9]+$ ]] || [ "$tunnel_port" -le 22 ] || [ "$tunnel_port" -gt 65535 ]; then
        colorize yellow "Invalid value, using default ${DEFAULT_TUNNEL_PORT}."
        tunnel_port=$DEFAULT_TUNNEL_PORT
    fi

    echo

    choose_profile
    HEARTBEAT="$PROFILE_HEARTBEAT"
    RETRY="$PROFILE_RETRY"
    nodelay=$(ask_nodelay "$PROFILE_NODELAY")

    echo

    local transport=""
    while [[ "$transport" != "tcp" && "$transport" != "udp" ]]; do
        echo -ne "[*] Transport type (tcp/udp): "
        read -r transport
        if [[ "$transport" != "tcp" && "$transport" != "udp" ]]; then
            colorize red "Invalid transport type. Please enter 'tcp' or 'udp'"
        fi
    done

    echo

    echo -ne "[-] Security Token (PSK) [Enter = ${DEFAULT_TOKEN}]: "
    read -r token
    token="${token:-$DEFAULT_TOKEN}"

    echo

    echo -ne "[*] Enter your local ports separated by commas (e.g. 2070,2080): "
    read -r input_ports
    input_ports=$(echo "$input_ports" | tr -d ' ')
    declare -a config_ports
    IFS=',' read -r -a ports <<< "$input_ports"
    for port in "${ports[@]}"; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 22 ] && [ "$port" -le 65535 ]; then
            if ! check_port "$port" "$transport"; then
                colorize yellow "[INFO] Port $port is not in LISTENING state."
            fi
            colorize green "[INFO] Port $port added to your configs"
            config_ports+=("$port")
        else
            colorize red "[ERROR] Port $port is Invalid. Please enter a valid port number between 23 and 65535"
        fi
    done

    if [ ${#config_ports[@]} -eq 0 ]; then
        colorize red "No ports were entered. Exiting." bold
        sleep 2
        return 1
    fi

    echo
    colorize cyan "Building ${iran_server_count} client profile(s), one per Iran server..." bold
    echo

    for addr in "${server_addrs[@]}"; do
        build_kharej_profile "$addr" "$tunnel_port" "$token" "$transport" "$nodelay" "$HEARTBEAT" "$RETRY" "0.0.0.0" "${config_ports[@]}"
    done

    echo
    colorize green "Kharej server configuration completed successfully for all ${iran_server_count} Iran server(s)."
}

# Function for checking tunnel status
check_tunnel_status() {
    echo

    if ! ls "$config_dir"/*.toml 1> /dev/null 2>&1; then
        colorize red "No config files found in the rathole directory." bold
        echo
        press_key
        return 1
    fi

    clear
    colorize yellow "Checking all services status..." bold
    sleep 1
    echo
    for config_path in "$config_dir"/iran*.toml; do
        if [ -f "$config_path" ]; then
            config_name=$(basename "$config_path")
            config_name="${config_name%.toml}"
            service_name="rathole-${config_name}.service"
            config_port="${config_name#iran}"

            if systemctl is-active --quiet "$service_name"; then
                colorize green "Iran service with tunnel port $config_port is running"
            else
                colorize red "Iran service with tunnel port $config_port is not running"
            fi

            wd_name="watchdog-${service_name%.service}"
            if systemctl is-active --quiet "${wd_name}.service"; then
                colorize cyan "   Watchdog: active"
            else
                colorize yellow "   Watchdog: not running"
            fi
        fi
    done

    for config_path in "$config_dir"/kharej-*.toml; do
        if [ -f "$config_path" ]; then
            config_name=$(basename "$config_path")
            config_name="${config_name%.toml}"
            service_name="rathole-${config_name}.service"

            if systemctl is-active --quiet "$service_name"; then
                colorize green "Kharej service ($config_name) is running"
            else
                colorize red "Kharej service ($config_name) is not running"
            fi

            wd_name="watchdog-${service_name%.service}"
            if systemctl is-active --quiet "${wd_name}.service"; then
                colorize cyan "   Watchdog: active"
            else
                colorize yellow "   Watchdog: not running"
            fi
        fi
    done

    echo
    press_key
}

# Function for destroying tunnel
tunnel_management() {
    echo
    if ! ls "$config_dir"/*.toml 1> /dev/null 2>&1; then
        colorize red "No config files found in the rathole directory." bold
        echo
        press_key
        return 1
    fi

    clear
    colorize cyan "List of existing services to manage:" bold
    echo

    local index=1
    declare -a configs

    for config_path in "$config_dir"/iran*.toml; do
        if [ -f "$config_path" ]; then
            config_name=$(basename "$config_path")
            config_port="${config_name#iran}"
            config_port="${config_port%.toml}"

            configs+=("$config_path")
            echo -e "${MAGENTA}${index}${NC}) ${GREEN}Iran${NC} service, Tunnel port: ${YELLOW}$config_port${NC}"
            ((index++))
        fi
    done

    for config_path in "$config_dir"/kharej-*.toml; do
        if [ -f "$config_path" ]; then
            config_name=$(basename "$config_path")
            configs+=("$config_path")
            echo -e "${MAGENTA}${index}${NC}) ${GREEN}Kharej${NC} service: ${YELLOW}$config_name${NC}"
            ((index++))
        fi
    done

    echo
    echo -ne "Enter your choice (0 to return): "
    read choice

    if (( choice == 0 )); then
        return
    fi
    while ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 0 || choice > ${#configs[@]} )); do
        colorize red "Invalid choice. Please enter a number between 1 and ${#configs[@]}." bold
        echo
        echo -ne "Enter your choice (0 to return): "
        read choice
        if (( choice == 0 )); then
            return
        fi
    done

    selected_config="${configs[$((choice - 1))]}"
    config_name=$(basename "${selected_config%.toml}")
    service_name="rathole-${config_name}.service"

    clear
    colorize cyan "List of available commands for $config_name:" bold
    echo
    colorize red "1) Remove this tunnel"
    colorize yellow "2) Restart this tunnel"
    colorize green "3) Add a new config for this tunnel"
    colorize reset "4) Add a cronjob for this tunnel"
    colorize reset "5) Remove existing cronjob for this tunnel"
    colorize reset "6) View service logs"
    colorize reset "7) View service status"
    colorize reset "8) View watchdog logs"
    echo
    read -p "Enter your choice (0 to return): " choice

    case $choice in
        1) destroy_tunnel "$selected_config" ;;
        2) restart_service "$service_name" ;;
        3) add_new_config "$selected_config" ;;
        4) add_cron_job_menu "$service_name";;
        5) delete_cron_job "$service_name";;
        6) view_service_logs "$service_name" ;;
        7) view_service_status "$service_name" ;;
        8) view_service_logs "watchdog-${config_name}.service" ;;
        0) return 1 ;;
        *) echo -e "${RED}Invalid option!${NC}" && sleep 1 && return 1;;
    esac

}

remove_core(){
    echo
    if find "$config_dir" -type f -name "*.toml" | grep -q .; then
        colorize red "You should delete all services first and then delete the rathole-core."
        sleep 3
        return 1
    else
        colorize cyan "No .toml file found in the directory."
    fi

    echo

    colorize yellow "Do you want to remove rathole-core? (y/n)"
    read -r confirm
    echo
    if [[ $confirm == [yY] ]]; then
        if [[ -d "$config_dir" ]]; then
            rm -rf "$config_dir" >/dev/null 2>&1
            colorize green "Rathole-core directory removed." bold
        else
            colorize red "Rathole-core directory not found." bold
        fi
    else
        colorize yellow "Rathole core removal canceled."
    fi

    echo
    press_key
}

destroy_tunnel(){
    echo
    config_path="$1"
    config_name=$(basename "${config_path%.toml}")
    service_name="rathole-${config_name}.service"
    service_path="$service_dir/$service_name"

    if [ -f "$config_path" ]; then
        rm -f "$config_path" >/dev/null 2>&1
    fi

    delete_cron_job "$service_name"
    remove_watchdog "$service_name"

    if [[ -f "$service_path" ]]; then
        if systemctl is-active "$service_name" &>/dev/null; then
            systemctl disable --now "$service_name" >/dev/null 2>&1
        fi
        rm -f "$service_path" >/dev/null 2>&1
    fi

    echo
    if systemctl daemon-reload >/dev/null 2>&1 ; then
        echo -e "Systemd daemon reloaded.\n"
    else
        echo -e "${RED}Failed to reload systemd daemon. Please check your system configuration.${NC}"
    fi

    echo -e "${GREEN}Tunnel (and its watchdog) destroyed successfully! ${NC}"
    echo
    sleep 1
}

# Function to restart services
restart_service() {
    echo
    service_name="$1"
    colorize yellow "Restarting $service_name" bold
    echo

    if systemctl list-units --type=service | grep -q "$service_name"; then
        systemctl restart "$service_name"
        colorize green "Service restarted successfully"
    else
        colorize red "Cannot restart the service"
    fi
    echo
    press_key
}

# Function to add cron-tab job
add_cron_job() {
    local restart_time="$1"
    local reset_path="$2"
    local service_name="$3"

    crontab -l > /tmp/crontab.tmp 2>/dev/null
    echo "$restart_time $reset_path #$service_name" >> /tmp/crontab.tmp
    crontab /tmp/crontab.tmp
    rm /tmp/crontab.tmp
}

delete_cron_job() {
    echo
    local service_name="$1"

    crontab -l 2>/dev/null | grep -v "#$service_name" | crontab -
    rm -f "$config_dir/${service_name%.service}.sh" >/dev/null 2>&1

    colorize green "Cron job for $service_name deleted successfully." bold
    sleep 2
}

add_new_config(){
    echo

    local config_path="$1"

    local_ip='0.0.0.0'
    read -p "[-] Listen for IPv6 address? (y/n): " answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        colorize yellow "IPv6 Enabled"
        local_ip='[::]'
    elif [ "$answer" = "n" ]; then
        colorize yellow "IPv4 Enabled"
        local_ip='0.0.0.0'
    else
        colorize yellow "Invalid choice. IPv4 enabled by default."
        local_ip='0.0.0.0'
    fi

    echo

    local transport=""
    while [[ "$transport" != "tcp" && "$transport" != "udp" ]]; do
        echo -ne "[*] Transport type(tcp/udp): "
        read -r transport
        if [[ "$transport" != "tcp" && "$transport" != "udp" ]]; then
            colorize red "Invalid transport type. Please enter 'tcp' or 'udp'"
        fi
    done

    echo

    echo -ne "[*] Enter your ports separated by commas (e.g. 2070,2080): "
    read -r input_ports
    input_ports=$(echo "$input_ports" | tr -d ' ')
    IFS=',' read -r -a ports <<< "$input_ports"
    declare -a config_ports
    for port in "${ports[@]}"; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 22 ] && [ "$port" -le 65535 ]; then
            config_ports+=("$port")
        else
            colorize red "[ERROR] Port $port is Invalid. Please enter a valid port number between 23 and 65535"
        fi
    done

    if [ ${#config_ports[@]} -eq 0 ]; then
        colorize red "No ports were entered. Exiting." bold
        sleep 2
        return 1
    fi

    echo

    if grep -q "iran" <<< "$config_path"; then
        for port in "${config_ports[@]}"; do
            cat << EOF >> "$config_path"
[server.services.${port}]
type = "$transport"
bind_addr = "${local_ip}:${port}"

EOF
        done
    else
        for port in "${config_ports[@]}"; do
            cat << EOF >> "$config_path"
[client.services.${port}]
type = "$transport"
local_addr = "${local_ip}:${port}"

EOF
        done
    fi

    colorize green "All ports added to your config successfully" bold
    sleep 1

    config_name=$(basename "${config_path%.toml}")
    service_name="rathole-${config_name}.service"
    restart_service "$service_name"
}

add_cron_job_menu() {
    echo
    service_name="$1"

    colorize cyan "Select the restart time interval:" bold
    echo
    echo "1. Every 30th minute"
    echo "2. Every 1 hour"
    echo "3. Every 2 hours"
    echo "4. Every 4 hours"
    echo "5. Every 6 hours"
    echo "6. Every 12 hours"
    echo "7. Every 24 hours"
    echo
    read -p "Enter your choice: " time_choice
    case $time_choice in
        1) restart_time="*/30 * * * *" ;;
        2) restart_time="0 * * * *" ;;
        3) restart_time="0 */2 * * *" ;;
        4) restart_time="0 */4 * * *" ;;
        5) restart_time="0 */6 * * *" ;;
        6) restart_time="0 */12 * * *" ;;
        7) restart_time="0 0 * * *" ;;
        *)
            echo -e "${RED}Invalid choice. Please enter a number between 1 and 7.${NC}\n"
            return 1
            ;;
    esac

    delete_cron_job "$service_name" > /dev/null 2>&1

    reset_path="$config_dir/${service_name%.service}.sh"

    cat << EOF > "$reset_path"
#! /bin/bash
pids=\$(pgrep rathole)
sudo kill -9 \$pids
sudo systemctl daemon-reload
sudo systemctl restart $service_name
EOF

    chmod +x "$reset_path"

    add_cron_job "$restart_time" "$reset_path" "$service_name"
    echo
    colorize green "Cron-job added successfully to restart the service '$service_name'." bold
    sleep 2
}

view_service_logs (){
    clear
    journalctl -eu "$1"
}

view_service_status (){
    clear
    systemctl status "$1"
}

update_script(){
DEST_DIR="/usr/bin/"
RATHOLE_SCRIPT="rathole"
SCRIPT_URL="https://github.com/Musixal/rathole-tunnel/raw/main/rathole_v2.sh"

echo
if [ -f "$DEST_DIR/$RATHOLE_SCRIPT" ]; then
    rm "$DEST_DIR/$RATHOLE_SCRIPT"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Existing $RATHOLE_SCRIPT has been successfully removed from $DEST_DIR.${NC}"
    else
        echo -e "${RED}Failed to remove existing $RATHOLE_SCRIPT from $DEST_DIR.${NC}"
        sleep 1
        return 1
    fi
else
    echo -e "${YELLOW}$RATHOLE_SCRIPT does not exist in $DEST_DIR. No need to remove.${NC}"
fi

curl -s -L -o "$DEST_DIR/$RATHOLE_SCRIPT" "$SCRIPT_URL"

echo
if [ $? -eq 0 ]; then
    chmod +x "$DEST_DIR/$RATHOLE_SCRIPT"
    colorize yellow "Type 'rathole' to run the script.\n" bold
    colorize yellow "For removing script type: 'rm -rf /usr/bin/rathole\n" bold
    press_key
    exit 0
else
    echo -e "${RED}Failed to download $RATHOLE_SCRIPT from $SCRIPT_URL.${NC}"
    sleep 1
    return 1
fi
}

# _________________________ HAWSHEMI SCRIPT OPT FOR UBUNTU _________________________
SYS_PATH="/etc/sysctl.conf"
PROF_PATH="/etc/profile"

ask_reboot() {
    echo -ne "${YELLOW}Reboot now? (Recommended) (y/n): ${NC}"
    while true; do
        read choice
        echo
        if [[ "$choice" == 'y' || "$choice" == 'Y' ]]; then
            sleep 0.5
            reboot
            exit 0
        fi
        if [[ "$choice" == 'n' || "$choice" == 'N' ]]; then
            break
        fi
    done
}

sysctl_optimizations() {
    cp $SYS_PATH /etc/sysctl.conf.bak

    echo
    echo -e "${YELLOW}Default sysctl.conf file Saved. Directory: /etc/sysctl.conf.bak${NC}"
    echo
    sleep 1

    echo
    echo -e  "${YELLOW}Optimizing the Network...${NC}"
    echo
    sleep 0.5

    sed -i -e '/fs.file-max/d' \
        -e '/net.core.default_qdisc/d' \
        -e '/net.core.netdev_max_backlog/d' \
        -e '/net.core.optmem_max/d' \
        -e '/net.core.somaxconn/d' \
        -e '/net.core.rmem_max/d' \
        -e '/net.core.wmem_max/d' \
        -e '/net.core.rmem_default/d' \
        -e '/net.core.wmem_default/d' \
        -e '/net.ipv4.tcp_rmem/d' \
        -e '/net.ipv4.tcp_wmem/d' \
        -e '/net.ipv4.tcp_congestion_control/d' \
        -e '/net.ipv4.tcp_fastopen/d' \
        -e '/net.ipv4.tcp_fin_timeout/d' \
        -e '/net.ipv4.tcp_keepalive_time/d' \
        -e '/net.ipv4.tcp_keepalive_probes/d' \
        -e '/net.ipv4.tcp_keepalive_intvl/d' \
        -e '/net.ipv4.tcp_max_orphans/d' \
        -e '/net.ipv4.tcp_max_syn_backlog/d' \
        -e '/net.ipv4.tcp_max_tw_buckets/d' \
        -e '/net.ipv4.tcp_mem/d' \
        -e '/net.ipv4.tcp_mtu_probing/d' \
        -e '/net.ipv4.tcp_notsent_lowat/d' \
        -e '/net.ipv4.tcp_retries2/d' \
        -e '/net.ipv4.tcp_sack/d' \
        -e '/net.ipv4.tcp_dsack/d' \
        -e '/net.ipv4.tcp_slow_start_after_idle/d' \
        -e '/net.ipv4.tcp_window_scaling/d' \
        -e '/net.ipv4.tcp_adv_win_scale/d' \
        -e '/net.ipv4.tcp_ecn/d' \
        -e '/net.ipv4.tcp_ecn_fallback/d' \
        -e '/net.ipv4.tcp_syncookies/d' \
        -e '/net.ipv4.udp_mem/d' \
        -e '/net.ipv6.conf.all.disable_ipv6/d' \
        -e '/net.ipv6.conf.default.disable_ipv6/d' \
        -e '/net.ipv6.conf.lo.disable_ipv6/d' \
        -e '/net.unix.max_dgram_qlen/d' \
        -e '/vm.min_free_kbytes/d' \
        -e '/vm.swappiness/d' \
        -e '/vm.vfs_cache_pressure/d' \
        -e '/net.ipv4.conf.default.rp_filter/d' \
        -e '/net.ipv4.conf.all.rp_filter/d' \
        -e '/net.ipv4.conf.all.accept_source_route/d' \
        -e '/net.ipv4.conf.default.accept_source_route/d' \
        -e '/net.ipv4.neigh.default.gc_thresh1/d' \
        -e '/net.ipv4.neigh.default.gc_thresh2/d' \
        -e '/net.ipv4.neigh.default.gc_thresh3/d' \
        -e '/net.ipv4.neigh.default.gc_stale_time/d' \
        -e '/net.ipv4.conf.default.arp_announce/d' \
        -e '/net.ipv4.conf.lo.arp_announce/d' \
        -e '/net.ipv4.conf.all.arp_announce/d' \
        -e '/kernel.panic/d' \
        -e '/vm.dirty_ratio/d' \
        -e '/^#/d' \
        -e '/^$/d' \
        "$SYS_PATH"

cat <<EOF >> "$SYS_PATH"


################################################################
################################################################


fs.file-max = 67108864

net.core.default_qdisc = fq_codel
net.core.netdev_max_backlog = 32768
net.core.optmem_max = 262144
net.core.somaxconn = 65536
net.core.rmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_max = 33554432
net.core.wmem_default = 1048576

net.ipv4.tcp_rmem = 16384 1048576 33554432
net.ipv4.tcp_wmem = 16384 1048576 33554432
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fin_timeout = 25
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 7
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_orphans = 819200
net.ipv4.tcp_max_syn_backlog = 20480
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_mem = 65536 1048576 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 32768
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_syncookies = 1

net.ipv4.udp_mem = 65536 1048576 33554432

net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0

net.unix.max_dgram_qlen = 256

vm.min_free_kbytes = 65536
vm.swappiness = 10
vm.vfs_cache_pressure = 250

net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 16384
net.ipv4.neigh.default.gc_stale_time = 60

net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2

kernel.panic = 1
vm.dirty_ratio = 20


################################################################
################################################################


EOF

    sudo sysctl -p

    echo
    echo -e "${GREEN}Network is Optimized.${NC}"
    echo
    sleep 0.5
}

limits_optimizations() {
    echo
    echo -e "${YELLOW}Optimizing System Limits...${NC}"
    echo
    sleep 0.5

    sed -i '/ulimit -c/d' $PROF_PATH
    sed -i '/ulimit -d/d' $PROF_PATH
    sed -i '/ulimit -f/d' $PROF_PATH
    sed -i '/ulimit -i/d' $PROF_PATH
    sed -i '/ulimit -l/d' $PROF_PATH
    sed -i '/ulimit -m/d' $PROF_PATH
    sed -i '/ulimit -n/d' $PROF_PATH
    sed -i '/ulimit -q/d' $PROF_PATH
    sed -i '/ulimit -s/d' $PROF_PATH
    sed -i '/ulimit -t/d' $PROF_PATH
    sed -i '/ulimit -u/d' $PROF_PATH
    sed -i '/ulimit -v/d' $PROF_PATH
    sed -i '/ulimit -x/d' $PROF_PATH
    sed -i '/ulimit -s/d' $PROF_PATH

    echo "ulimit -c unlimited" | tee -a $PROF_PATH
    echo "ulimit -d unlimited" | tee -a $PROF_PATH
    echo "ulimit -f unlimited" | tee -a $PROF_PATH
    echo "ulimit -i unlimited" | tee -a $PROF_PATH
    echo "ulimit -l unlimited" | tee -a $PROF_PATH
    echo "ulimit -m unlimited" | tee -a $PROF_PATH
    echo "ulimit -n 1048576" | tee -a $PROF_PATH
    echo "ulimit -q unlimited" | tee -a $PROF_PATH
    echo "ulimit -s -H 65536" | tee -a $PROF_PATH
    echo "ulimit -s 32768" | tee -a $PROF_PATH
    echo "ulimit -t unlimited" | tee -a $PROF_PATH
    echo "ulimit -u unlimited" | tee -a $PROF_PATH
    echo "ulimit -v unlimited" | tee -a $PROF_PATH
    echo "ulimit -x unlimited" | tee -a $PROF_PATH

    echo
    echo -e "${GREEN}System Limits are Optimized.${NC}"
    echo
    sleep 0.5
}

# _________________________ END OF HAWSHEMI SCRIPT OPT FOR UBUNTU _________________________

hawshemi_script(){
clear

echo -e "${MAGENTA}Special thanks to Hawshemi, the author of optimizer script...${NC}"
sleep 2
os_name=$(lsb_release -is)

echo -e
if [ "$os_name" == "Ubuntu" ]; then
  echo -e "${GREEN}The operating system is Ubuntu.${NC}"
  sleep 1
else
  echo -e "${RED} The operating system is not Ubuntu.${NC}"
  sleep 2
  return
fi

sysctl_optimizations
limits_optimizations
ask_reboot
read -p "Press Enter to continue..."
}

install_modified_core(){
    echo
    DOWNLOAD_URL='https://github.com/Musixal/rathole-tunnel/raw/main/core/rathole_modified.zip'

    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${RED}Failed to retrieve download URL.${NC}"
        sleep 1
        return 1
    fi

    DOWNLOAD_DIR=$(mktemp -d)
    echo -e "Downloading modifed rathole-core from $DOWNLOAD_URL...\n"
    sleep 1
    curl -sSL -o "$DOWNLOAD_DIR/rathole_modified.zip" "$DOWNLOAD_URL"
    echo -e "Extracting Rathole...\n"
    sleep 1
    unzip -o -q "$DOWNLOAD_DIR/rathole_modified.zip" -d "$config_dir"
    mv -f ${config_dir}/rathole_modified ${config_dir}/rathole
    echo -e "${GREEN}Rathole installation completed.${NC}"
    chmod u+x ${config_dir}/rathole
    rm -rf "$DOWNLOAD_DIR"
    echo
}

change_core(){
    echo
    ARCH=$(uname -m)
    if ! [[ "$ARCH" == "x86_64" ]]; then
        colorize red "Only x86_64 arch. is supported right now!" bold
        sleep 2
        return 1
    fi

    colorize cyan "Select your rathole-core:" bold
    echo
    colorize green "1) Default Core (latest official stable release)"
    colorize yellow "2) Modified Core (Lower connections, maybe higher latency)"
    colorize reset "3) return "
    echo
    read -p "Enter your choice [1-3]: " choice

    case $choice in
        1) rm -f "${config_dir}/rathole" &> /dev/null
        download_and_extract_rathole ;;
        2) rm -f "${config_dir}/rathole" &> /dev/null
        install_modified_core;;
        3) return 1 ;;
        *) echo -e "${RED} Invalid option!${NC}" && sleep 1 && return 1 ;;
    esac

    colorize red "IMPORTANT!" bold
    colorize yellow "To load the new core, restart all services." bold
    echo
    press_key
}

# Function to display menu
display_menu() {
    clear
    display_logo
    display_server_info
    display_rathole_core_status
    echo
    colorize green " 1. Configure a new tunnel [IPv4/IPv6]" bold
    colorize red " 2. Tunnel management menu" bold
    colorize cyan " 3. Check tunnels status" bold
    echo -e " 4. Optimize network & system limits"
    echo -e " 5. Install rathole core"
    echo -e " 6. Update & install script"
    echo -e " 7. Change core [experimental]"
    echo -e " 8. Remove rathole core"
    echo -e " 0. Exit"
    echo
    echo "-------------------------------"
}

# Function to read user input
read_option() {
    read -p "Enter your choice [0-8]: " choice
    case $choice in
        1) configure_tunnel ;;
        2) tunnel_management ;;
        3) check_tunnel_status ;;
        4) hawshemi_script ;;
        5) download_and_extract_rathole "sleep";;
        6) update_script ;;
        7) change_core ;;
        8) remove_core ;;
        0) exit 0 ;;
        *) echo -e "${RED} Invalid option!${NC}" && sleep 1 ;;
    esac
}

# Main script
while true
do
    display_menu
    read_option
done
