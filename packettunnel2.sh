#!/bin/bash
set -e

INSTALL_DIR="/root/packettunnel"
SERVICE_FILE="/etc/systemd/system/packettunnel.service"
CORE_URL="https://raw.githubusercontent.com/logi443/packet/main/core.json"
WATERWALL_URL="https://raw.githubusercontent.com/logi443/packet/main/Waterwall"
SERVICE_NAME="packettunnel.service"

# ---------- helpers ----------
function log() { echo "[+] $1"; }
function warn() { echo "[!] $1"; }

function require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
  fi
}

function header() {
  clear
  echo "MultiServerPacket-By Meysam"
  echo "==================="
  local ip
  ip="$(get_public_ip || true)"
  if [[ -n "$ip" ]]; then
    echo "Server Public IP: $ip"
  else
    echo "Server Public IP: (could not detect)"
  fi
  echo
}

function ensure_install_dir() {
  mkdir -p "$INSTALL_DIR"
}

function get_public_ip() {
  local ip=""
  ip="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -fsSL --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -fsSL --max-time 5 https://icanhazip.com 2>/dev/null || true)"
  ip="$(echo "$ip" | tr -d ' \n\r\t')"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  echo "$ip"
}

function service_status() {
  header
  echo "Service: $SERVICE_NAME"
  echo "--------------------"
  systemctl status "$SERVICE_NAME" --no-pager || true
  echo
  read -rp "Press Enter to return to menu..."
}

function uninstall() {
  header
  log "Stopping and disabling systemd service..."
  systemctl stop "$SERVICE_NAME" || true
  systemctl disable "$SERVICE_NAME" || true

  log "Removing files..."
  rm -rf "$INSTALL_DIR"
  rm -f "$SERVICE_FILE"

  log "Reloading systemd..."
  systemctl daemon-reexec
  log "✅ Uninstall complete."
  echo
  read -rp "Press Enter to return to menu..."
}

function prompt_ports() {
  ports=()
  log "Enter ports to forward (e.g. 443 8443 80), type 'done' to finish:"
  while true; do
    read -rp "Port: " p
    [[ "$p" == "done" ]] && break
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
      ports+=("$p")
    else
      echo "Invalid port number."
    fi
  done
}

function next_config_filename() {
  local n=2
  while [[ -f "$INSTALL_DIR/config${n}.json" ]]; do
    n=$((n+1))
  done
  echo "$INSTALL_DIR/config${n}.json"
}

function update_core_json_add_config() {
  local cfg_name="$1"   # e.g. "config.json" or "config2.json"
  local core_path="$INSTALL_DIR/core.json"

  if [[ -f "$core_path" ]]; then
    cp -f "$core_path" "$core_path.bak.$(date +%s)" || true
  fi

  python3 - "$core_path" "$cfg_name" <<'PY'
import json, sys, os
core_path = sys.argv[1]
cfg_name  = sys.argv[2]

def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=4)
        f.write("\n")
    os.replace(tmp, path)

data = None
if os.path.exists(core_path):
    try:
        with open(core_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = None

if isinstance(data, dict) and isinstance(data.get("configs"), list):
    configs = data["configs"]
    if cfg_name not in configs:
        configs.append(cfg_name)
    data["configs"] = configs
    write_json(core_path, data)
else:
    write_json(core_path, {"configs": [cfg_name]})
PY
}

# ---------- PairID / tun plan ----------
# PairID = N (1..10)
# iran  -> wtunN, 10.10.N.1/24 (peer=10.10.N.2)
# kharej-> wtunN, 10.10.N.2/24 (peer=10.10.N.1)
function ask_pairid() {
  local pid
  while true; do
    read -rp "Enter PairID (1-10): " pid
    if [[ "$pid" =~ ^[0-9]+$ ]] && (( pid >= 1 && pid <= 10 )); then
      PAIRID="$pid"
      return 0
    fi
    echo "Invalid PairID. Must be a number from 1 to 10."
  done
}

function compute_tun_vars() {
  # Inputs: ROLE (1=iran,2=kharej), PAIRID
  TUN_DEV="wtun${PAIRID}"
  if [[ "$ROLE" == "1" ]]; then
    TUN_LOCAL_CIDR="10.10.${PAIRID}.1/24"
    TUN_PEER_IP="10.10.${PAIRID}.2"
    TUN_LOCAL_IP="10.10.${PAIRID}.1"
  else
    TUN_LOCAL_CIDR="10.10.${PAIRID}.2/24"
    TUN_PEER_IP="10.10.${PAIRID}.1"
    TUN_LOCAL_IP="10.10.${PAIRID}.2"
  fi
}

function print_pairing_info() {
  echo
  echo "PAIRING INFO"
  echo "------------"
  echo "PairID: $PAIRID"
  echo "Device: $TUN_DEV"
  echo "Tun subnet: 10.10.${PAIRID}.0/24"
  echo "Iran  Tun IP:  10.10.${PAIRID}.1"
  echo "Kharej Tun IP: 10.10.${PAIRID}.2"
  echo "⚠️  Peer MUST use the same PairID to match."
  echo
}

# ---------- config generators ----------
function generate_iran_config() {
  local ip_local_pub="$1"
  local ip_peer_pub="$2"
  local out_file="$3"

  cat > "$out_file" <<EOF
{
    "name": "iran",
    "nodes": [
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "$TUN_DEV",
                "device-ip": "$TUN_LOCAL_CIDR"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "$ip_local_pub"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "$ip_peer_pub"
            },
            "next": "manip"
        },
        {
            "name": "manip",
            "type": "IpManipulator",
            "settings": {
                "protoswap": 18
            },
            "next": "ipovsrc2"
        },
        {
            "name": "ipovsrc2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "source-ip",
                "ipv4": "$TUN_PEER_IP"
            },
            "next": "ipovdest2"
        },
        {
            "name": "ipovdest2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "$TUN_LOCAL_IP"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "$ip_peer_pub"
            }
        }
EOF

  for i in "${!ports[@]}"; do
    cat >> "$out_file" <<EOF
,
        {
            "name": "input$((i+1))",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": ${ports[i]},
                "nodelay": true
            },
            "next": "output$((i+1))"
        },
        {
            "name": "output$((i+1))",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "$TUN_PEER_IP",
                "port": ${ports[i]}
            }
        }
EOF
  done

  echo "    ]" >> "$out_file"
  echo "}" >> "$out_file"
}

function generate_kharej_config() {
  local ip_local_pub="$1"
  local ip_peer_pub="$2"
  local out_file="$3"

  cat > "$out_file" <<EOF
{
    "name": "kharej",
    "nodes": [
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "$TUN_DEV",
                "device-ip": "$TUN_LOCAL_CIDR"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "$ip_local_pub"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "$ip_peer_pub"
            },
            "next": "manip"
        },
        {
            "name": "manip",
            "type": "IpManipulator",
            "settings": {
                "protoswap": 18
            },
            "next": "ipovsrc2"
        },
        {
            "name": "ipovsrc2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "source-ip",
                "ipv4": "$TUN_PEER_IP"
            },
            "next": "ipovdest2"
        },
        {
            "name": "ipovdest2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "$TUN_LOCAL_IP"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "$ip_peer_pub"
            }
        }
    ]
}
EOF
}

# ---------- install / add logic ----------
function install_service() {
  log "Creating systemd service..."
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=packet Tunnel Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/Waterwall
Restart=on-failure
RestartSec=2

# If you hit permissions for TUN/RAW on some distros, uncomment:
# AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
# CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

  log "Reloading systemd and enabling service..."
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME" || true
}

function ensure_waterwall_and_core() {
  ensure_install_dir
  cd "$INSTALL_DIR"

  if [[ ! -f "$INSTALL_DIR/Waterwall" ]]; then
    log "Downloading Waterwall binary..."
    curl -fsSL "$WATERWALL_URL" -o Waterwall
    chmod +x Waterwall
  fi

  if [[ ! -f "$INSTALL_DIR/core.json" ]]; then
    log "Downloading core.json..."
    curl -fsSL "$CORE_URL" -o core.json
  fi
}

function ask_role_and_peer_ip() {
  local role
  read -rp "Is this server '1-iran' or '2-kharej'? " role
  if [[ "$role" != "1" && "$role" != "2" ]]; then
    echo "Invalid role. Must be '1' or '2'."
    return 1
  fi
  ROLE="$role"

  local ip_local
  ip_local="$(get_public_ip)" || {
    echo "Could not detect public IP automatically."
    echo "Tip: Ensure outbound internet access (curl) is available."
    return 1
  }
  IP_LOCAL_PUB="$ip_local"

  local ip_peer=""
  if [[ "$ROLE" == "1" ]]; then
    read -rp "Enter Kharej server public IP: " ip_peer
  else
    read -rp "Enter Iran server public IP: " ip_peer
  fi
  IP_PEER_PUB="$ip_peer"
}

function install_menu() {
  header
  ensure_waterwall_and_core

  ask_role_and_peer_ip
  ask_pairid
  compute_tun_vars
  print_pairing_info

  local cfg_path="$INSTALL_DIR/config.json"
  if [[ "$ROLE" == "1" ]]; then
    prompt_ports
    generate_iran_config "$IP_LOCAL_PUB" "$IP_PEER_PUB" "$cfg_path"
  else
    generate_kharej_config "$IP_LOCAL_PUB" "$IP_PEER_PUB" "$cfg_path"
  fi

  update_core_json_add_config "config.json"
  install_service

  log "✅ Install complete. Config: config.json"
  echo
  read -rp "Press Enter to return to menu..."
}

function add_config_menu() {
  header

  if [[ ! -d "$INSTALL_DIR" || ! -x "$INSTALL_DIR/Waterwall" ]]; then
    echo "Not installed yet. Please run Install first."
    echo
    read -rp "Press Enter to return to menu..."
    return
  fi
  if [[ ! -f "$INSTALL_DIR/core.json" ]]; then
    echo "core.json not found. Please run Install first (or restore core.json)."
    echo
    read -rp "Press Enter to return to menu..."
    return
  fi

  ask_role_and_peer_ip
  ask_pairid
  compute_tun_vars
  print_pairing_info

  local cfg_path
  cfg_path="$(next_config_filename)"
  local cfg_base
  cfg_base="$(basename "$cfg_path")"

  if [[ "$ROLE" == "1" ]]; then
    prompt_ports
    generate_iran_config "$IP_LOCAL_PUB" "$IP_PEER_PUB" "$cfg_path"
  else
    generate_kharej_config "$IP_LOCAL_PUB" "$IP_PEER_PUB" "$cfg_path"
  fi

  update_core_json_add_config "$cfg_base"
  systemctl restart "$SERVICE_NAME" || true

  log "✅ Added config: $cfg_base"
  log "✅ core.json updated and service restarted."
  echo
  read -rp "Press Enter to return to menu..."
}

# ---------- main loop ----------
require_root

while true; do
  header
  echo "1) Install"
  echo "2) Uninstall"
  echo "3) Service status"
  echo "4) Add config"
  echo "0) Exit"
  echo

  read -rp "Choose an option [0-4]: " choice
  case "$choice" in
    1) install_menu ;;
    2) uninstall ;;
    3) service_status ;;
    4) add_config_menu ;;
    0) exit 0 ;;
    *) echo "Invalid option." ; sleep 1 ;;
  esac
done
