#!/bin/bash

set -e

INSTALL_DIR="/root/waterwall"
SERVICE_NAME="waterwall"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_FILE="${INSTALL_DIR}/config.json"
CORE_FILE="${INSTALL_DIR}/core.json"
CORE_URL="https://raw.githubusercontent.com/logi443/packet/main/core.json"
GITHUB_REPO="radkesvat/WaterWall"
OPTIMIZE_MARKER="/etc/waterwall_optimize.ver"
OPTIMIZE_VERSION="3"

function log() { echo "[+] $1"; }

function pause_return_menu() {
    echo
    read -rp "Press Enter to return to menu..." _
}

function wait_for_apt() {
    local waited=false
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/cache/debconf/config.dat >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [[ "$waited" == false ]]; then
            log "Waiting for other apt/dpkg process to finish..."
            waited=true
        fi
        sleep 2
    done

    # Fix any broken/interrupted installs
    if [[ "$waited" == true ]]; then
        dpkg --configure -a >/dev/null 2>&1 || true
    fi
}

function install_prerequisites() {
    local pkgs=()
    command -v unzip >/dev/null 2>&1 || pkgs+=(unzip)
    command -v jq >/dev/null 2>&1 || pkgs+=(jq)
    command -v iptables >/dev/null 2>&1 || pkgs+=(iptables)
    command -v curl >/dev/null 2>&1 || pkgs+=(curl)
    if [[ "${#pkgs[@]}" -gt 0 ]]; then
        log "Installing prerequisites: ${pkgs[*]}..."
        wait_for_apt
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1
        log "Prerequisites installed."
    fi
}

function get_local_version() {
    local existing
    existing="$(find "$INSTALL_DIR" -maxdepth 1 -iname 'waterwall' -type f 2>/dev/null | head -n1)"
    if [[ -n "$existing" ]]; then
        "$existing" -v 2>&1 | grep -oP 'version \K[0-9]+(\.[0-9]+)+' | head -n1
    fi
}

function get_latest_version() {
    curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name":\s*"v?\K[0-9]+(\.[0-9]+)+' | head -n1
}

function banner() {
    clear
    echo -e "\e[31m"
    server_ip=$(get_public_ip)
    [[ -z "$server_ip" ]] && server_ip="Unknown"

    local local_ver latest_ver ver_status
    local_ver="$(get_local_version)"
    latest_ver="$(get_latest_version)"

    local BLUE="\e[34m" GREEN="\e[32m" YELLOW="\e[33m" RED="\e[31m" RST="\e[0m"

    if [[ -z "$local_ver" ]]; then
        ver_status="\e[37mNot installed${RST}"
    elif [[ -z "$latest_ver" ]]; then
        ver_status="${BLUE}v$local_ver${RST}"
    elif [[ "$local_ver" == "$latest_ver" ]]; then
        ver_status="${BLUE}v$local_ver${RST} - ${GREEN}latest${RST}"
    else
        ver_status="${BLUE}v$local_ver${RST} - ${YELLOW}new version available: v$latest_ver${RST}"
    fi

    echo "=================================================="
    echo "██╗    ██╗ █████╗ ████████╗███████╗██████╗ ██╗    ██╗ █████╗ ██╗     ██╗"
    echo "██║    ██║██╔══██╗╚══██╔══╝██╔════╝██╔══██╗██║    ██║██╔══██╗██║     ██║"
    echo "██║ █╗ ██║███████║   ██║   █████╗  ██████╔╝██║ █╗ ██║███████║██║     ██║"
    echo "██║███╗██║██╔══██║   ██║   ██╔══╝  ██╔══██╗██║███╗██║██╔══██║██║     ██║"
    echo "╚███╔███╔╝██║  ██║   ██║   ███████╗██║  ██║╚███╔███╔╝██║  ██║███████╗███████╗"
    echo " ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚══════╝╚══════╝"
    echo -e "                  WATERWALL - \e[36mBY MEYSAM\e[31m"
    echo "                  SERVER IP: $server_ip"
    echo -e "                  CORE: $ver_status"
    echo -e "\e[31m=================================================="
    echo -e "\e[0m"
}

function get_public_ip() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$ip" && "$ip" != 127.* ]] && echo "$ip"
}

function choose_server_ip() {
    local -a all_ips=()
    local ip

    while IFS= read -r ip; do
        [[ -n "$ip" && "$ip" != 127.* ]] && all_ips+=("$ip")
    done < <(hostname -I 2>/dev/null | tr ' ' '\n')

    if [[ "${#all_ips[@]}" -eq 0 ]]; then
        echo ""
        return
    fi

    if [[ "${#all_ips[@]}" -eq 1 ]]; then
        echo "${all_ips[0]}"
        return
    fi

    echo "Multiple IPs detected on this server:" >&2
    for i in "${!all_ips[@]}"; do
        echo "  $((i+1))) ${all_ips[i]}" >&2
    done
    while true; do
        read -rp "Choose IP [1-${#all_ips[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#all_ips[@]} )); then
            echo "${all_ips[$((choice-1))]}"
            return
        fi
        echo "Invalid choice." >&2
    done
}

function validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra octets <<< "$ip"
    for o in "${octets[@]}"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

function validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    (( p >= 1 && p <= 65535 )) || return 1
    return 0
}

function ask_ip() {
    local label="$1"
    local result=""
    while true; do
        read -rp "$label: " result
        [[ "$result" == "0" ]] && echo "" && return
        if validate_ip "$result"; then
            echo "$result"
            return
        fi
        echo "Invalid IP address. Please enter a valid IPv4 (e.g. 1.2.3.4)." >&2
    done
}

function ask_port() {
    local label="$1"
    local result=""
    while true; do
        read -rp "$label: " result
        [[ "$result" == "0" ]] && echo "" && return
        if validate_port "$result"; then
            echo "$result"
            return
        fi
        echo "Invalid port. Must be a number between 1 and 65535." >&2
    done
}

function ask_port_json() {
    local label="$1"
    local allow_empty="${2:-false}"
    local input
    while true; do
        read -rp "$label (comma-separated for multiport, e.g. 443 or 443,80,8443): " input
        [[ "$input" == "0" ]] && echo "" && return
        if [[ -z "$input" ]]; then
            if [[ "$allow_empty" == "true" ]]; then
                echo "SKIP"
                return
            fi
            echo "Cannot be empty. Please enter at least one port." >&2
            continue
        fi
        input="${input// /}"
        if [[ "$input" == *","* ]]; then
            local json_arr="["
            local first=true
            local valid=true
            IFS=',' read -ra port_arr <<< "$input"
            for p in "${port_arr[@]}"; do
                if ! validate_port "$p"; then
                    echo "Invalid port: $p. Must be between 1 and 65535." >&2
                    valid=false
                    break
                fi
                if [[ "$first" == true ]]; then
                    json_arr+="$p"
                    first=false
                else
                    json_arr+=", $p"
                fi
            done
            [[ "$valid" == false ]] && continue
            json_arr+="]"
            echo "$json_arr"
            return
        else
            if validate_port "$input"; then
                echo "$input"
                return
            fi
            echo "Invalid port. Must be a number between 1 and 65535." >&2
        fi
    done
}

function ask_role() {
    while true; do
        echo >&2
        echo "Which server is this?" >&2
        echo "  1) Iran" >&2
        echo "  2) Kharej" >&2
        echo "  0) Back" >&2
        read -rp "Choose [0-2]: " role
        case "$role" in
            0|1|2) echo "$role"; return ;;
            *) echo "Invalid choice. Please enter 1 or 2." >&2 ;;
        esac
    done
}

function ask_string() {
    local label="$1"
    local result=""
    while true; do
        read -rp "$label: " result
        [[ "$result" == "0" ]] && echo "" && return
        if [[ -n "$result" ]]; then
            echo "$result"
            return
        fi
        echo "Cannot be empty." >&2
    done
}

function ask_kharej_ips_whitelist() {
    local input
    while true; do
        read -rp "Enter Kharej server IP(s) (comma-separated for multiple helpers): " input
        [[ "$input" == "0" ]] && echo "" && return
        if [[ -z "$input" ]]; then
            echo "Cannot be empty." >&2
            continue
        fi
        input="${input// /}"
        local valid=true
        local whitelist=""
        local first=true
        IFS=',' read -ra arr <<< "$input"
        for kip in "${arr[@]}"; do
            if ! validate_ip "$kip"; then
                echo "Invalid IP: $kip" >&2
                valid=false
                break
            fi
            if [[ "$first" == true ]]; then
                whitelist="\"${kip}/32\""
                first=false
            else
                whitelist="${whitelist},
                    \"${kip}/32\""
            fi
        done
        [[ "$valid" == false ]] && continue
        echo "$whitelist"
        return
    done
}

function is_installed() {
    systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\\.service"
}

function prompt_ports() {
    ports=()
    log "Enter ports to forward (e.g. 443 8443 80), type 'done' to finish:"
    while true; do
        read -rp "Port: " p
        [[ "$p" == "0" ]] && ports=() && return 1
        [[ "$p" == "done" ]] && break
        if validate_port "$p"; then
            ports+=("$p")
        else
            echo "Invalid port. Must be between 1 and 65535."
        fi
    done
    return 0
}

# ========================================
#   Waterwall Download
# ========================================

function download_waterwall() {
    local existing
    existing="$(find "$INSTALL_DIR" -maxdepth 1 -iname 'waterwall' -type f 2>/dev/null | head -n1)"
    if [[ -n "$existing" ]]; then
        if [[ "$existing" != "$INSTALL_DIR/Waterwall" ]]; then
            mv "$existing" "$INSTALL_DIR/Waterwall"
            chmod +x "$INSTALL_DIR/Waterwall"
        fi
        log "Waterwall binary already exists, skipping download."
        return
    fi

    local arch
    arch="$(uname -m)"
    log "Detecting CPU architecture: $arch"

    echo
    read -rp "Download old CPU build? (y/n): " oldcpu
    oldcpu="$(echo "$oldcpu" | tr '[:upper:]' '[:lower:]')"

    local asset_name=""
    case "$arch" in
        x86_64|amd64)
            if [[ "$oldcpu" == "y" || "$oldcpu" == "yes" ]]; then
                asset_name="Waterwall-linux-gcc-x64-old-cpu.zip"
            else
                asset_name="Waterwall-linux-gcc-x64.zip"
            fi
            ;;
        aarch64|arm64)
            if [[ "$oldcpu" == "y" || "$oldcpu" == "yes" ]]; then
                asset_name="Waterwall-linux-gcc-arm64-old-cpu.zip"
            else
                asset_name="Waterwall-linux-gcc-arm64.zip"
            fi
            ;;
    esac

    if [[ -z "$asset_name" ]]; then
        echo "Unsupported CPU architecture: $arch"
        echo "Supported: x86_64, aarch64 (arm64)"
        return 1
    fi

    log "Fetching latest release from GitHub..."
    local download_url
    download_url="$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases" \
        | grep -o "\"browser_download_url\": \"[^\"]*${asset_name}\"" \
        | head -n1 \
        | cut -d'"' -f4)"

    if [[ -z "$download_url" ]]; then
        echo "Could not find download URL for: $asset_name"
        return 1
    fi

    local version
    version="$(echo "$download_url" | grep -oP '/download/\K[^/]+')"
    log "Downloading $asset_name (version: $version)..."
    curl -fsSL "$download_url" -o "$asset_name"

    log "Extracting..."
    unzip -o "$asset_name" -d .
    rm -f "$asset_name"
    chmod +x Waterwall
    log "Waterwall downloaded and ready (version: $version)."
}

# ========================================
#   Systemd Service
# ========================================

function install_service() {
    log "Creating systemd service..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Waterwall Tunnel Service
After=network.target

[Service]
Type=idle
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/Waterwall
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    log "Reloading systemd and enabling service..."
    systemctl daemon-reexec
    systemctl enable "${SERVICE_NAME}.service"
    systemctl restart "${SERVICE_NAME}.service"
}

# ========================================
#   PacketTunnel (Classic) Config Generators
# ========================================

function generate_iran_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "name": "iran",
    "nodes": [
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun0",
                "device-ip": "10.10.0.1/24"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "$ip_iran"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "$ip_kharej"
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
                "ipv4": "10.10.0.2"
            },
            "next": "ipovdest2"
        },
        {
            "name": "ipovdest2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "10.10.0.1"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "$ip_kharej"
            }
        }
EOF
    for i in "${!ports[@]}"; do
        cat >> "$INSTALL_DIR/config.json" <<EOF
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
                "address": "10.10.0.2",
                "port": ${ports[i]}
            }
        }
EOF
    done
    echo "    ]" >> "$INSTALL_DIR/config.json"
    echo "}" >> "$INSTALL_DIR/config.json"
}

function generate_kharej_config() {
    local ip_kharej="$1"
    local ip_iran="$2"
    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "name": "kharej",
    "nodes": [
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun0",
                "device-ip": "10.10.0.1/24"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "$ip_kharej"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "$ip_iran"
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
                "ipv4": "10.10.0.2"
            },
            "next": "ipovdest2"
        },
        {
            "name": "ipovdest2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "10.10.0.1"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "$ip_iran"
            }
        }
    ]
}
EOF
}

# ========================================
#   BitSwap Config Generators
# ========================================

function generate_core_json() {
    local mtu="$1"
    cat > "$INSTALL_DIR/core.json" <<EOF
{
    "log": {
        "path": "log/",
        "internal": {
            "loglevel": "DEBUG",
            "file": "internal.log",
            "console": true
        },
        "core": {
            "loglevel": "DEBUG",
            "file": "core.log",
            "console": true
        },
        "network": {
            "loglevel": "DEBUG",
            "file": "network.log",
            "console": true
        },
        "dns": {
            "loglevel": "SILENT",
            "file": "dns.log",
            "console": false
        }
    },
    "dns": {},
    "misc": {
        "workers": 0,
        "ram-profile": "server",
        "mtu": $mtu,
        "libs-path": "libs/"
    },
    "configs": [
        "config.json"
    ]
}
EOF
}

function generate_bitswap_iran_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    local port_listen_json="$3"
    local port_connect_kharej="$4"
    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "name": "iran-tcp-bitswap-mux",
    "variables": {
        "ip_server_iran": "$ip_iran",
        "ip_server_kharej": "$ip_kharej",
        "port_to_listen": $port_listen_json,
        "port_to_connect_to_kharej": $port_connect_kharej,
        "each_worker_mux_connections_count": 8
    },
    "nodes": [
        {
            "name": "users_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": \$port_to_listen\$,
                "nodelay": true
            },
            "next": "header-client"
        },
        {
            "name": "header-client",
            "type": "HeaderClient",
            "settings": {
                "data": "src_context->port"
            },
            "next": "mux-client"
        },
        {
            "name": "mux-client",
            "type": "MuxClient",
            "settings": {
                "mode": "fixed-connections-count",
                "per-worker-connections-count": \$each_worker_mux_connections_count\$
            },
            "next": "tcp-out"
        },
        {
            "name": "tcp-out",
            "type": "TcpConnector",
            "settings": {
                "address": "10.10.0.2",
                "port": \$port_to_connect_to_kharej\$,
                "nodelay": true
            }
        },
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun1",
                "device-ip": "10.10.0.1/24"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": {
                        "ipv4": \$ip_server_iran\$
                    },
                    "dest-ip": {
                        "ipv4": \$ip_server_kharej\$
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "10.10.0.2"
                    },
                    "dest-ip": {
                        "ipv4": "10.10.0.1"
                    }
                }
            },
            "next": "splitter"
        },
        {
            "name": "splitter",
            "type": "PacketSplitStream",
            "settings": {
                "up": "obfuscator-c",
                "down": "obfuscator-s"
            }
        },
        {
            "name": "obfuscator-c",
            "type": "ObfuscatorClient",
            "settings": {
                "method": "xor",
                "xor_key": 90,
                "skip": "transport"
            },
            "next": "ip-manipulator-up"
        },
        {
            "name": "ip-manipulator-up",
            "type": "IpManipulator",
            "settings": {
                "up-tcp-bit-psh": "packet->cwr",
                "up-tcp-bit-cwr": "packet->psh"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "12.12.12.12/32"
            }
        },
        {
            "name": "obfuscator-s",
            "type": "ObfuscatorServer",
            "settings": {
                "method": "xor",
                "xor_key": 90,
                "skip": "transport"
            },
            "next": "ip-manipulator"
        },
        {
            "name": "ip-manipulator",
            "type": "IpManipulator",
            "settings": {
                "dw-tcp-bit-psh": "packet->rst",
                "dw-tcp-bit-rst": "packet->psh"
            },
            "next": "rd2"
        },
        {
            "name": "rd2",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": \$ip_server_kharej\$
            }
        }
    ]
}
EOF
}

function generate_bitswap_kharej_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    local port_listen="$3"
    local final_port="$4"
    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "name": "germany-tcp-bitswap-mux",
    "variables": {
        "ip_server_iran": "$ip_iran",
        "ip_server_kharej": "$ip_kharej",
        "port_to_listen": $port_listen,
        "final_ip": "127.0.0.1",
        "final_port": $final_port
    },
    "nodes": [
        {
            "name": "users_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": \$port_to_listen\$,
                "nodelay": true
            },
            "next": "mux-s"
        },
        {
            "name": "mux-s",
            "type": "MuxServer",
            "settings": {},
            "next": "header-server"
        },
        {
            "name": "header-server",
            "type": "HeaderServer",
            "settings": {
                "override": "dest_context->port"
            },
            "next": "tcp-out"
        },
        {
            "name": "tcp-out",
            "type": "TcpConnector",
            "settings": {
                "address": \$final_ip\$,
                "port": "dest_context->port",
                "nodelay": true
            }
        },
        {
            "name": "my tun2",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun2",
                "device-ip": "10.20.0.1/24"
            },
            "next": "ipcorrect"
        },
        {
            "name": "ipcorrect",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": {
                        "ipv4": "10.10.0.2"
                    },
                    "dest-ip": {
                        "ipv4": "10.10.0.1"
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "10.10.0.2"
                    },
                    "dest-ip": {
                        "ipv4": "10.10.0.1"
                    }
                }
            },
            "next": "obfuscator-s"
        },
        {
            "name": "obfuscator-s",
            "type": "ObfuscatorServer",
            "settings": {
                "method": "xor",
                "xor_key": 90,
                "skip": "transport"
            },
            "next": "ip-manipulator-in"
        },
        {
            "name": "ip-manipulator-in",
            "type": "IpManipulator",
            "settings": {
                "dw-tcp-bit-psh": "packet->cwr",
                "dw-tcp-bit-cwr": "packet->psh"
            },
            "next": "rdin"
        },
        {
            "name": "rdin",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": \$ip_server_iran\$
            }
        },
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun1",
                "device-ip": "10.10.0.1/24"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": {
                        "ipv4": \$ip_server_kharej\$
                    },
                    "dest-ip": {
                        "ipv4": \$ip_server_iran\$
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "10.10.0.2"
                    },
                    "dest-ip": {
                        "ipv4": "10.10.0.1"
                    }
                }
            },
            "next": "obfuscator-c"
        },
        {
            "name": "obfuscator-c",
            "type": "ObfuscatorClient",
            "settings": {
                "method": "xor",
                "xor_key": 90,
                "skip": "transport"
            },
            "next": "ip-manipulator"
        },
        {
            "name": "ip-manipulator",
            "type": "IpManipulator",
            "settings": {
                "up-tcp-bit-psh": "packet->rst",
                "up-tcp-bit-rst": "packet->psh"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "12.13.12.13"
            }
        }
    ]
}
EOF
}

# ========================================
#   Reverse BitSwap Config Generators
# ========================================

function generate_reverse_bitswap_iran_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    local port_listen_json="$3"
    local reverse_port="$4"
    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "name": "iran-tcp-bitswap-mux-reverse",
    "variables": {
        "ip_server_iran": "$ip_iran",
        "ip_server_kharej": "$ip_kharej",
        "port_to_listen": $port_listen_json,
        "reverse_port": $reverse_port,
        "each_worker_mux_connections_count": 8
    },
    "nodes": [
        {
            "name": "users_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": \$port_to_listen\$,
                "nodelay": true
            },
            "next": "header-client"
        },
        {
            "name": "header-client",
            "type": "HeaderClient",
            "settings": {
                "data": "src_context->port"
            },
            "next": "mux-client"
        },
        {
            "name": "mux-client",
            "type": "MuxClient",
            "settings": {
                "mode": "fixed-connections-count",
                "per-worker-connections-count": \$each_worker_mux_connections_count\$
            },
            "next": "bridge_user_side"
        },
        {
            "name": "bridge_user_side",
            "type": "Bridge",
            "settings": {
                "pair": "bridge_reverse_side"
            }
        },
        {
            "name": "bridge_reverse_side",
            "type": "Bridge",
            "settings": {
                "pair": "bridge_user_side"
            }
        },
        {
            "name": "reverse_server",
            "type": "ReverseServer",
            "settings": {},
            "next": "bridge_reverse_side"
        },
        {
            "name": "kharej_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": \$reverse_port\$,
                "nodelay": true
            },
            "next": "reverse_server"
        },
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun1",
                "device-ip": "10.10.0.1/24"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": {
                        "ipv4": \$ip_server_iran\$
                    },
                    "dest-ip": {
                        "ipv4": \$ip_server_kharej\$
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "10.10.0.2"
                    },
                    "dest-ip": {
                        "ipv4": "10.10.0.1"
                    }
                }
            },
            "next": "splitter"
        },
        {
            "name": "splitter",
            "type": "PacketSplitStream",
            "settings": {
                "up": "obfuscator-c",
                "down": "obfuscator-s"
            }
        },
        {
            "name": "obfuscator-c",
            "type": "ObfuscatorClient",
            "settings": {
                "method": "xor",
                "xor_key": 90,
                "skip": "transport"
            },
            "next": "ip-manipulator-up"
        },
        {
            "name": "ip-manipulator-up",
            "type": "IpManipulator",
            "settings": {
                "up-tcp-bit-psh": "packet->cwr",
                "up-tcp-bit-cwr": "packet->psh"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "12.12.12.12/32"
            }
        },
        {
            "name": "obfuscator-s",
            "type": "ObfuscatorServer",
            "settings": {
                "method": "xor",
                "xor_key": 90,
                "skip": "transport"
            },
            "next": "ip-manipulator"
        },
        {
            "name": "ip-manipulator",
            "type": "IpManipulator",
            "settings": {
                "dw-tcp-bit-psh": "packet->rst",
                "dw-tcp-bit-rst": "packet->psh"
            },
            "next": "rd2"
        },
        {
            "name": "rd2",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": \$ip_server_kharej\$
            }
        }
    ]
}
EOF
}

function generate_reverse_bitswap_kharej_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    local reverse_port="$3"
    local final_port="$4"
    local min_connections="${5:-8}"
    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "name": "kharej-tcp-bitswap-mux-reverse",
    "variables": {
        "ip_server_iran": "$ip_iran",
        "ip_server_kharej": "$ip_kharej",
        "reverse_port": $reverse_port,
        "final_ip": "127.0.0.1",
        "final_port": $final_port,
        "min_held_connections": $min_connections
    },
    "nodes": [
        {
            "name": "outbound_to_service",
            "type": "TcpConnector",
            "settings": {
                "address": \$final_ip\$,
                "port": "dest_context->port",
                "nodelay": true
            }
        },
        {
            "name": "header-server",
            "type": "HeaderServer",
            "settings": {
                "override": "dest_context->port"
            },
            "next": "outbound_to_service"
        },
        {
            "name": "mux-server",
            "type": "MuxServer",
            "settings": {},
            "next": "header-server"
        },
        {
            "name": "bridge_local_side",
            "type": "Bridge",
            "settings": {
                "pair": "bridge_reverse_side"
            },
            "next": "mux-server"
        },
        {
            "name": "bridge_reverse_side",
            "type": "Bridge",
            "settings": {
                "pair": "bridge_local_side"
            },
            "next": "reverse_client"
        },
        {
            "name": "reverse_client",
            "type": "ReverseClient",
            "settings": {
                "minimum-unused": \$min_held_connections\$
            },
            "next": "tcp_to_iran"
        },
        {
            "name": "tcp_to_iran",
            "type": "TcpConnector",
            "settings": {
                "address": "10.10.0.2",
                "port": \$reverse_port\$,
                "nodelay": true
            }
        },
        {
            "name": "my tun2",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun2",
                "device-ip": "10.20.0.1/24"
            },
            "next": "ipcorrect"
        },
        {
            "name": "ipcorrect",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": {
                        "ipv4": "10.10.0.2"
                    },
                    "dest-ip": {
                        "ipv4": "10.10.0.1"
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "10.10.0.2"
                    },
                    "dest-ip": {
                        "ipv4": "10.10.0.1"
                    }
                }
            },
            "next": "obfuscator-s"
        },
        {
            "name": "obfuscator-s",
            "type": "ObfuscatorServer",
            "settings": {
                "method": "xor",
                "xor_key": 90,
                "skip": "transport"
            },
            "next": "ip-manipulator-in"
        },
        {
            "name": "ip-manipulator-in",
            "type": "IpManipulator",
            "settings": {
                "dw-tcp-bit-psh": "packet->cwr",
                "dw-tcp-bit-cwr": "packet->psh"
            },
            "next": "rdin"
        },
        {
            "name": "rdin",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": \$ip_server_iran\$
            }
        },
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun1",
                "device-ip": "10.10.0.1/24"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": {
                        "ipv4": \$ip_server_kharej\$
                    },
                    "dest-ip": {
                        "ipv4": \$ip_server_iran\$
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "10.10.0.2"
                    },
                    "dest-ip": {
                        "ipv4": "10.10.0.1"
                    }
                }
            },
            "next": "obfuscator-c"
        },
        {
            "name": "obfuscator-c",
            "type": "ObfuscatorClient",
            "settings": {
                "method": "xor",
                "xor_key": 90,
                "skip": "transport"
            },
            "next": "ip-manipulator"
        },
        {
            "name": "ip-manipulator",
            "type": "IpManipulator",
            "settings": {
                "up-tcp-bit-psh": "packet->rst",
                "up-tcp-bit-rst": "packet->psh"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "12.13.12.13"
            }
        }
    ]
}
EOF
}

# ========================================
#   Reverse Reality Config Generators
# ========================================

function generate_rreality_iran_config() {
    local domain_white="$1"
    local ip_behind_domain="$2"
    local ip_kharej="$3"
    local port="$4"
    local password="$5"
    local tls_enabled="$6"
    local cert_path="${7:-/root/fullchain.pem}"
    local key_path="${8:-/root/privkey.pem}"

    local tls_vars=""
    local tls_node=""
    local user_next="bridge_user_side"

    if [[ "$tls_enabled" == "yes" ]]; then
        user_next="tls_server_user_side_tls_termination"
        tls_vars=",
        \"certificate_path\": \"$cert_path\",
        \"key_path\": \"$key_path\""
        tls_node=",
        {
            \"name\": \"tls_server_user_side_tls_termination\",
            \"type\": \"TlsServer\",
            \"settings\": {
                \"cert-file\": \"\\\$certificate_path\\\$\",
                \"key-file\": \"\\\$key_path\\\$\",
                \"min-version\": \"TLSv1.2\",
                \"max-version\": \"TLSv1.3\",
                \"ciphers\": \"HIGH:!aNULL:!MD5\",
                \"session-cache\": \"none\",
                \"session-tickets\": true,
                \"verbose\": false
            },
            \"next\": \"bridge_user_side\"
        }"
    fi

    cat > "$INSTALL_DIR/config.json" <<CONFIGEOF
{
    "name": "iran-reverse-reality-server",
    "variables": {
        "domain_white": "$domain_white",
        "ip_behind_domain_white": "$ip_behind_domain",
        "ip_server_kharej": "$ip_kharej/32",
        "user_and_server_kharej_port": $port,
        "password": "$password"$tls_vars
    },
    "nodes": [
        {
            "name": "users_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": \$user_and_server_kharej_port\$,
                "nodelay": true
            },
            "next": "$user_next"
        },
CONFIGEOF

    if [[ -n "$tls_node" ]]; then
        # Write TLS node (already has leading comma)
        cat >> "$INSTALL_DIR/config.json" <<TLSEOF
        {
            "name": "tls_server_user_side_tls_termination",
            "type": "TlsServer",
            "settings": {
                "cert-file": \$certificate_path\$,
                "key-file": \$key_path\$,
                "min-version": "TLSv1.2",
                "max-version": "TLSv1.3",
                "ciphers": "HIGH:!aNULL:!MD5",
                "session-cache": "none",
                "session-tickets": true,
                "verbose": false
            },
            "next": "bridge_user_side"
        },
TLSEOF
    fi

    cat >> "$INSTALL_DIR/config.json" <<RESTEOF
        {
            "name": "bridge_user_side",
            "type": "Bridge",
            "settings": {
                "pair": "bridge_reverse_side"
            }
        },
        {
            "name": "bridge_reverse_side",
            "type": "Bridge",
            "settings": {
                "pair": "bridge_user_side"
            }
        },
        {
            "name": "reverse_server",
            "type": "ReverseServer",
            "settings": {},
            "next": "bridge_reverse_side"
        },
        {
            "name": "reality-server",
            "type": "RealityServer",
            "settings": {
                "destination": "dest-visitor",
                "password": \$password\$,
                "algorithm": "chacha20-poly1305",
                "kdf-iterations": 12000,
                "sniffing-attempts": 8
            },
            "next": "reverse_server"
        },
        {
            "name": "dest-visitor",
            "type": "TcpConnector",
            "settings": {
                "address": \$ip_behind_domain_white\$,
                "port": 443,
                "nodelay": true
            }
        },
        {
            "name": "germany_reverse_tls_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": \$user_and_server_kharej_port\$,
                "nodelay": true,
                "whitelist": [
                    \$ip_server_kharej\$
                ]
            },
            "next": "reality-server"
        }
    ]
}
RESTEOF
}

function generate_rreality_kharej_config() {
    local ip_iran="$1"
    local connect_port="$2"
    local domain="$3"
    local password="$4"
    local final_ip="$5"
    local final_port="$6"
    local min_connections="${7:-8}"

    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "name": "germany-reverse-reality-client",
    "variables": {
        "ip_server_iran": "$ip_iran",
        "connect_to_iran_port": $connect_port,
        "domain_to_handshake_reality": "$domain",
        "password": "$password",
        "final_port": $final_port,
        "min_held_connections": $min_connections
    },
    "nodes": [
        {
            "name": "outbound_to_local_service",
            "type": "TcpConnector",
            "settings": {
                "address": "$final_ip",
                "port": \$final_port\$,
                "nodelay": true
            }
        },
        {
            "name": "bridge_local_side",
            "type": "Bridge",
            "settings": {
                "pair": "bridge_reverse_client_side"
            },
            "next": "outbound_to_local_service"
        },
        {
            "name": "bridge_reverse_client_side",
            "type": "Bridge",
            "settings": {
                "pair": "bridge_local_side"
            },
            "next": "reverse_client"
        },
        {
            "name": "reverse_client",
            "type": "ReverseClient",
            "settings": {
                "minimum-unused": \$min_held_connections\$
            },
            "next": "reality-client"
        },
        {
            "name": "reality-client",
            "type": "RealityClient",
            "settings": {
                "sni": \$domain_to_handshake_reality\$,
                "verify": true,
                "password": \$password\$,
                "algorithm": "chacha20-poly1305",
                "kdf-iterations": 12000
            },
            "next": "tcp_to_iran"
        },
        {
            "name": "tcp_to_iran",
            "type": "TcpConnector",
            "settings": {
                "address": \$ip_server_iran\$,
                "port": \$connect_to_iran_port\$,
                "nodelay": true
            }
        }
    ]
}
EOF
}

# ========================================
#   Install - BitSwap
# ========================================

function install_bitswap() {
    if is_installed; then
        echo "Waterwall is already installed. Please uninstall first."
        pause_return_menu
        return
    fi

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    download_waterwall || { pause_return_menu; return; }

    local role
    role="$(ask_role)"
    [[ "$role" == "0" ]] && return

    server_ip=$(choose_server_ip)
    if [[ -z "$server_ip" ]]; then
        echo "Could not detect public IP automatically."
        server_ip="$(ask_ip "Enter this server public IP")"
        [[ -z "$server_ip" ]] && return
    fi

    read -rp "Enter MTU value [default: 1400]: " mtu_val
    [[ -z "$mtu_val" ]] && mtu_val=1400

    if [[ "$role" == "1" ]]; then
        ip_iran="$server_ip"
        echo "Detected Iran server IP: $ip_iran"

        ip_kharej="$(ask_ip "Enter Kharej server public IP")"
        [[ -z "$ip_kharej" ]] && return

        local port_listen_json
        port_listen_json="$(ask_port_json "Enter listen port(s)")"
        [[ -z "$port_listen_json" ]] && return

        local port_connect_kharej
        port_connect_kharej="$(ask_port "Enter port to connect to Kharej (Waterwall port on Kharej)")"
        [[ -z "$port_connect_kharej" ]] && return

        generate_core_json "$mtu_val"
        generate_bitswap_iran_config "$ip_iran" "$ip_kharej" "$port_listen_json" "$port_connect_kharej"

    elif [[ "$role" == "2" ]]; then
        ip_kharej="$server_ip"
        echo "Detected Kharej server IP: $ip_kharej"

        ip_iran="$(ask_ip "Enter Iran server public IP")"
        [[ -z "$ip_iran" ]] && return

        local port_listen
        port_listen="$(ask_port "Enter port to listen (Waterwall listen port, same as Iran's connect port)")"
        [[ -z "$port_listen" ]] && return

        local final_port
        final_port="$(ask_port "Enter final inbound port (Xray listen port)")"
        [[ -z "$final_port" ]] && return

        generate_core_json "$mtu_val"
        generate_bitswap_kharej_config "$ip_iran" "$ip_kharej" "$port_listen" "$final_port"
    fi

    install_service
    log "BitSwap tunnel setup complete. Service is running."

    if [[ "$role" == "2" ]]; then
        echo
        read -rp "Do you want to test the tunnel now? (y/n): " test_ans
        test_ans="$(echo "$test_ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$test_ans" == "y" || "$test_ans" == "yes" ]]; then
            echo
            log "Testing tunnel (ping 10.10.0.2 - 10 packets)..."
            echo
            if ping -c 10 -W 2 10.10.0.2; then
                echo
                echo "=== Tunnel is UP and working ==="
            else
                echo
                echo "=== Tunnel is NOT connected ==="
            fi
        fi
    fi

    pause_return_menu
}

# ========================================
#   Install - Reverse BitSwap
# ========================================

function install_reverse_bitswap() {
    if is_installed; then
        echo "Waterwall is already installed. Please uninstall first."
        pause_return_menu
        return
    fi

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    download_waterwall || { pause_return_menu; return; }

    local role
    while true; do
        echo
        echo "Which server is this?"
        echo "  1) Iran"
        echo "  2) Kharej"
        echo "  0) Back"
        read -rp "Choose [0-2]: " role
        case "$role" in
            0|1|2) break ;;
            *) echo "Invalid choice. Please enter 1 or 2." ;;
        esac
    done
    [[ "$role" == "0" ]] && return

    server_ip=$(choose_server_ip)
    if [[ -z "$server_ip" ]]; then
        echo "Could not detect public IP automatically."
        server_ip="$(ask_ip "Enter this server public IP")"
        [[ -z "$server_ip" ]] && return
    fi

    read -rp "Enter MTU value [default: 1400]: " mtu_val
    [[ -z "$mtu_val" ]] && mtu_val=1400

    if [[ "$role" == "1" ]]; then
        ip_iran="$server_ip"
        echo "Detected Iran server IP: $ip_iran"

        ip_kharej="$(ask_ip "Enter Kharej server public IP")"
        [[ -z "$ip_kharej" ]] && return

        local port_listen_json
        port_listen_json="$(ask_port_json "Enter user listen port(s)")"
        [[ -z "$port_listen_json" ]] && return

        local reverse_port
        reverse_port="$(ask_port "Enter reverse port (Kharej connects to this port)")"
        [[ -z "$reverse_port" ]] && return

        generate_core_json "$mtu_val"
        generate_reverse_bitswap_iran_config "$ip_iran" "$ip_kharej" "$port_listen_json" "$reverse_port"

    elif [[ "$role" == "2" ]]; then
        ip_kharej="$server_ip"
        echo "Detected Kharej server IP: $ip_kharej"

        ip_iran="$(ask_ip "Enter Iran server public IP")"
        [[ -z "$ip_iran" ]] && return

        local reverse_port
        reverse_port="$(ask_port "Enter reverse port (same port set on Iran)")"
        [[ -z "$reverse_port" ]] && return

        local final_port
        final_port="$(ask_port "Enter final inbound port (Xray listen port)")"
        [[ -z "$final_port" ]] && return

        local min_conn
        read -rp "Minimum held connections [default: 8]: " min_conn
        [[ -z "$min_conn" ]] && min_conn=8

        generate_core_json "$mtu_val"
        generate_reverse_bitswap_kharej_config "$ip_iran" "$ip_kharej" "$reverse_port" "$final_port" "$min_conn"
    fi

    install_service
    log "Reverse BitSwap tunnel setup complete. Service is running."

    if [[ "$role" == "2" ]]; then
        echo
        read -rp "Do you want to test the tunnel now? (y/n): " test_ans
        test_ans="$(echo "$test_ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$test_ans" == "y" || "$test_ans" == "yes" ]]; then
            echo
            log "Testing tunnel (ping 10.10.0.2 - 10 packets)..."
            echo
            if ping -c 10 -W 2 10.10.0.2; then
                echo
                echo "=== Tunnel is UP and working ==="
            else
                echo
                echo "=== Tunnel is NOT connected ==="
            fi
        fi
    fi

    pause_return_menu
}

# ========================================
#   Install - Reverse Reality
# ========================================

function install_reverse_reality() {
    if is_installed; then
        echo "Waterwall is already installed. Please uninstall first."
        pause_return_menu
        return
    fi

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    download_waterwall || { pause_return_menu; return; }

    local role
    role="$(ask_role)"
    [[ "$role" == "0" ]] && return

    server_ip=$(choose_server_ip)
    if [[ -z "$server_ip" ]]; then
        echo "Could not detect public IP automatically."
        server_ip="$(ask_ip "Enter this server public IP")"
        [[ -z "$server_ip" ]] && return
    fi

    read -rp "Enter MTU value [default: 1400]: " mtu_val
    [[ -z "$mtu_val" ]] && mtu_val=1400

    if [[ "$role" == "1" ]]; then
        echo "Detected Iran server IP: $server_ip"

        local ip_kharej
        ip_kharej="$(ask_ip "Enter Kharej server IP")"
        [[ -z "$ip_kharej" ]] && return

        local domain
        domain="$(ask_string "Enter domain for Reality handshake (e.g. google.com)")"
        [[ -z "$domain" ]] && return

        local ip_behind_domain
        ip_behind_domain="$(ask_ip "Enter IP behind domain (DNS resolve of $domain)")"
        [[ -z "$ip_behind_domain" ]] && return

        local listen_port
        listen_port="$(ask_port "Enter port (used for both users and Kharej connection)")"
        [[ -z "$listen_port" ]] && return

        local password
        password="$(ask_string "Enter password (must match Kharej)")"
        [[ -z "$password" ]] && return

        local tls_enabled="no"
        local cert_path="" key_path=""
        read -rp "Enable TLS Termination? (y/n) [default: n]: " tls_ans
        tls_ans="$(echo "$tls_ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$tls_ans" == "y" || "$tls_ans" == "yes" ]]; then
            tls_enabled="yes"
            read -rp "Certificate path [default: /root/fullchain.pem]: " cert_path
            [[ -z "$cert_path" ]] && cert_path="/root/fullchain.pem"
            read -rp "Key path [default: /root/privkey.pem]: " key_path
            [[ -z "$key_path" ]] && key_path="/root/privkey.pem"
        fi

        generate_core_json "$mtu_val"
        generate_rreality_iran_config "$domain" "$ip_behind_domain" "$ip_kharej" "$listen_port" "$password" "$tls_enabled" "$cert_path" "$key_path"

    elif [[ "$role" == "2" ]]; then
        echo "Detected Kharej server IP: $server_ip"

        local ip_iran
        ip_iran="$(ask_ip "Enter Iran server IP")"
        [[ -z "$ip_iran" ]] && return

        local connect_port
        connect_port="$(ask_port "Enter port to connect to Iran (same port set on Iran)")"
        [[ -z "$connect_port" ]] && return

        local domain
        domain="$(ask_string "Enter domain for Reality handshake (must match Iran)")"
        [[ -z "$domain" ]] && return

        local password
        password="$(ask_string "Enter password (must match Iran)")"
        [[ -z "$password" ]] && return

        local final_ip="127.0.0.1"
        read -rp "Is this a helper (auxiliary) Kharej server? (y/n) [default: n]: " helper_ans
        helper_ans="$(echo "$helper_ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$helper_ans" == "y" || "$helper_ans" == "yes" ]]; then
            final_ip="$(ask_ip "Enter main Kharej server IP")"
            [[ -z "$final_ip" ]] && return
        fi

        local final_port
        final_port="$(ask_port "Enter final port (Xray/service listen port)")"
        [[ -z "$final_port" ]] && return

        local min_conn
        read -rp "Minimum held connections [default: 8]: " min_conn
        [[ -z "$min_conn" ]] && min_conn=8

        generate_core_json "$mtu_val"
        generate_rreality_kharej_config "$ip_iran" "$connect_port" "$domain" "$password" "$final_ip" "$final_port" "$min_conn"
    fi

    install_service
    log "Reverse Reality tunnel setup complete. Service is running."
    pause_return_menu
}

# ========================================
#   Install - PacketTunnel (Classic)
# ========================================

function install_packettunnel() {
    if is_installed; then
        echo "Waterwall is already installed. Please uninstall first."
        pause_return_menu
        return
    fi

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    download_waterwall || { pause_return_menu; return; }
    log "Downloading core.json..."
    curl -fsSL "$CORE_URL" -o core.json

    local role
    role="$(ask_role)"
    [[ "$role" == "0" ]] && return

    server_ip=$(choose_server_ip)
    if [[ -z "$server_ip" ]]; then
        echo "Could not detect public IP automatically."
        server_ip="$(ask_ip "Enter this server public IP")"
        [[ -z "$server_ip" ]] && return
    fi

    if [[ "$role" == "1" ]]; then
        ip_iran="$server_ip"
        echo "Detected Iran server IP: $ip_iran"

        ip_kharej="$(ask_ip "Enter Kharej server public IP")"
        [[ -z "$ip_kharej" ]] && return

        prompt_ports || return
        generate_iran_config "$ip_iran" "$ip_kharej"

    elif [[ "$role" == "2" ]]; then
        ip_kharej="$server_ip"
        echo "Detected Kharej server IP: $ip_kharej"

        ip_iran="$(ask_ip "Enter Iran server public IP")"
        [[ -z "$ip_iran" ]] && return

        generate_kharej_config "$ip_kharej" "$ip_iran"
    fi

    install_service
    log "PacketTunnel setup complete. Service is running."

    if [[ "$role" == "2" ]]; then
        echo
        read -rp "Do you want to test the tunnel now? (y/n): " test_ans
        test_ans="$(echo "$test_ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$test_ans" == "y" || "$test_ans" == "yes" ]]; then
            echo
            log "Testing tunnel (ping 10.10.0.2 - 10 packets)..."
            echo
            if ping -c 10 -W 2 10.10.0.2; then
                echo
                echo "=== Tunnel is UP and working ==="
            else
                echo
                echo "=== Tunnel is NOT connected ==="
            fi
        fi
    fi

    pause_return_menu
}

# ========================================
#   Install Menu
# ========================================

function install_menu() {
    clear
    echo
    echo "Install Tunnel"
    echo "=================="
    echo "1) BitSwap"
    echo "2) Reverse Reality"
    echo "3) PacketTunnel (Classic)"
    echo "0) Back"
    echo
    read -rp "Choose an option [0-3]: " install_choice
    case "$install_choice" in
        1) install_bitswap ;;
        2) install_reverse_reality ;;
        3) install_packettunnel ;;
        99) install_reverse_bitswap ;;
        0) return ;;
        *) echo "Invalid option."; pause_return_menu ;;
    esac
}

# ========================================
#   Service Management
# ========================================

function restart_service() {
    echo
    if is_installed; then
        systemctl restart "${SERVICE_NAME}.service"
        echo "Service restarted successfully."
    else
        echo "${SERVICE_NAME}.service is not installed."
    fi
    pause_return_menu
}

function status_service() {
    echo
    if is_installed; then
        systemctl status "${SERVICE_NAME}.service" --no-pager || true
    else
        echo "${SERVICE_NAME}.service is not installed."
    fi
    pause_return_menu
}

function test_tunnel() {
    echo
    log "Testing tunnel connection (ping 10.10.0.2 - 10 packets)..."
    echo
    if ping -c 10 -W 2 10.10.0.2; then
        echo
        echo "=== Tunnel is UP and working ==="
    else
        echo
        echo "=== Tunnel is NOT connected ==="
    fi
    pause_return_menu
}

function uninstall() {
    echo
    if ! is_installed && [[ ! -d "$INSTALL_DIR" ]]; then
        echo "Nothing to uninstall."
        pause_return_menu
        return
    fi

    read -rp "Are you sure you want to uninstall? (y/n): " ans
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ans" != "y" && "$ans" != "yes" ]]; then
        echo "Uninstall cancelled."
        pause_return_menu
        return
    fi

    if is_installed; then
        log "Stopping and disabling service..."
        systemctl stop "${SERVICE_NAME}.service" || true
        systemctl disable "${SERVICE_NAME}.service" || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reexec
        log "Service removed."
    fi

    log "Removing config files..."
    rm -f "$CONFIG_FILE" "$CORE_FILE" 2>/dev/null
    rm -rf "$INSTALL_DIR/log" 2>/dev/null

    if [[ -f "$INSTALL_DIR/Waterwall" ]]; then
        echo
        read -rp "Delete the Waterwall binary too? (y/n): " del_bin
        del_bin="$(echo "$del_bin" | tr '[:upper:]' '[:lower:]')"
        if [[ "$del_bin" == "y" || "$del_bin" == "yes" ]]; then
            rm -rf "$INSTALL_DIR"
            log "All files removed."
        else
            # Remove everything except Waterwall binary
            find "$INSTALL_DIR" -maxdepth 1 ! -name 'Waterwall' ! -path "$INSTALL_DIR" -exec rm -rf {} + 2>/dev/null
            log "Binary kept. Config and other files removed."
        fi
    else
        rm -rf "$INSTALL_DIR"
    fi

    log "Uninstall complete."
    pause_return_menu
}

# ========================================
#   Change Ports
# ========================================

function port_change_restart_prompt() {
    echo
    echo "What next?"
    echo "1) Restart service (recommended)"
    echo "2) Reboot server"
    echo "0) Return to menu"
    read -rp "Choose [0-2]: " next
    case "$next" in
        1)
            if is_installed; then
                systemctl restart "${SERVICE_NAME}.service" || true
                echo "Service restarted."
            else
                echo "Service not installed."
            fi
            pause_return_menu
            ;;
        2)
            echo "Rebooting..."
            reboot
            ;;
        *)
            return
            ;;
    esac
}

function detect_config_type() {
    local name
    name="$(jq -r '.name // empty' "$CONFIG_FILE" 2>/dev/null)"
    case "$name" in
        *bitswap*|*germany*) echo "bitswap" ;;
        *) echo "classic" ;;
    esac
}

function change_ports_bitswap() {
    local config_name
    config_name="$(jq -r '.name // empty' "$CONFIG_FILE")"

    backup="${CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
    cp -f "$CONFIG_FILE" "$backup"
    log "Backup saved: $backup"

    echo "Detected BitSwap config: $config_name"
    echo

    mapfile -t PORT_VARS < <(jq -r '.variables | to_entries[] | select(.key | test("port";"i")) | "\(.key)=\(.value)"' "$CONFIG_FILE" 2>/dev/null)

    if [[ "${#PORT_VARS[@]}" -eq 0 ]]; then
        echo "No port variables found in config."
        return
    fi

    for entry in "${PORT_VARS[@]}"; do
        local var_name="${entry%%=*}"
        local var_value="${entry#*=}"

        echo "Variable: $var_name"
        echo "Current value: $var_value"

        local new_port_json
        new_port_json="$(ask_port_json "Enter new value (or press Enter to keep current)" "true")"

        if [[ "$new_port_json" == "SKIP" || -z "$new_port_json" ]]; then
            echo "Keeping $var_value"
        else
            tmp="$(mktemp)"
            jq --arg key "$var_name" --argjson val "$new_port_json" '.variables[$key] = $val' "$CONFIG_FILE" > "$tmp"
            mv -f "$tmp" "$CONFIG_FILE"
            echo "Updated $var_name to: $new_port_json"
        fi
        echo "----------------------------------------"
    done
}

function change_ports_classic_both() {
    mapfile -t INDICES < <(
        jq -r '
          [ .. | objects
            | select(has("name") and (.name|test("^input[0-9]+$")))
            | .name
          ]
          | map(sub("^input";""))
          | map(tonumber)
          | unique
          | sort
          | .[]
        ' "$CONFIG_FILE"
    )

    if [[ "${#INDICES[@]}" -eq 0 ]]; then
        echo "No inputN nodes found in config.json."
        return
    fi

    backup="${CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
    cp -f "$CONFIG_FILE" "$backup"
    log "Backup saved: $backup"

    for n in "${INDICES[@]}"; do
        current_in=$(jq -r --arg name "input$n" '..|objects|select(has("name") and .name==$name and has("settings") and (.settings|has("port")))|.settings.port' "$CONFIG_FILE" | head -n1)
        current_out=$(jq -r --arg name "output$n" '..|objects|select(has("name") and .name==$name and has("settings") and (.settings|has("port")))|.settings.port' "$CONFIG_FILE" | head -n1)

        if [[ -z "$current_in" || -z "$current_out" ]]; then
            echo "Skipping input$n/output$n (missing port field)."
            continue
        fi

        echo "Pair: input$n/output$n"
        echo "Current port: $current_in"
        while true; do
            read -rp "Enter new port (or press Enter to keep $current_in): " newp
            if [[ -z "$newp" ]]; then
                echo "Keeping port $current_in"
                break
            fi
            if validate_port "$newp"; then
                tmp="$(mktemp)"
                jq --argjson p "$newp" --arg in "input$n" --arg out "output$n" '
                  (.. | objects
                    | select(has("name") and (.name==$in or .name==$out) and has("settings") and (.settings|has("port")))
                  ) |= (.settings.port = $p)
                ' "$CONFIG_FILE" > "$tmp"
                mv -f "$tmp" "$CONFIG_FILE"
                echo "Updated input$n/output$n to: $newp"
                break
            else
                echo "Invalid port. Must be 1..65535."
            fi
        done
        echo "----------------------------------------"
    done
}

function change_ports_classic_input_only() {
    mapfile -t INDICES < <(
        jq -r '
          [ .. | objects
            | select(has("name") and (.name|test("^input[0-9]+$")))
            | .name
          ]
          | map(sub("^input";""))
          | map(tonumber)
          | unique
          | sort
          | .[]
        ' "$CONFIG_FILE"
    )

    if [[ "${#INDICES[@]}" -eq 0 ]]; then
        echo "No inputN nodes found in config.json."
        return
    fi

    backup="${CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
    cp -f "$CONFIG_FILE" "$backup"
    log "Backup saved: $backup"

    for n in "${INDICES[@]}"; do
        current_in=$(jq -r --arg name "input$n" '..|objects|select(has("name") and .name==$name and has("settings") and (.settings|has("port")))|.settings.port' "$CONFIG_FILE" | head -n1)

        if [[ -z "$current_in" ]]; then
            echo "Skipping input$n (missing port field)."
            continue
        fi

        echo "Node: input$n"
        echo "Current port: $current_in"
        while true; do
            read -rp "Enter new port for input$n (or press Enter to keep $current_in): " newp
            if [[ -z "$newp" ]]; then
                echo "Keeping port $current_in"
                break
            fi
            if validate_port "$newp"; then
                tmp="$(mktemp)"
                jq --argjson p "$newp" --arg name "input$n" '
                  (.. | objects
                    | select(has("name") and .name==$name and has("settings") and (.settings|has("port")))
                  ) |= (.settings.port = $p)
                ' "$CONFIG_FILE" > "$tmp"
                mv -f "$tmp" "$CONFIG_FILE"
                echo "Updated input$n port to: $newp"
                break
            else
                echo "Invalid port. Must be 1..65535."
            fi
        done
        echo "----------------------------------------"
    done
}

function change_ports_classic_output_only() {
    mapfile -t INDICES < <(
        jq -r '
          [ .. | objects
            | select(has("name") and (.name|test("^output[0-9]+$")))
            | .name
          ]
          | map(sub("^output";""))
          | map(tonumber)
          | unique
          | sort
          | .[]
        ' "$CONFIG_FILE"
    )

    if [[ "${#INDICES[@]}" -eq 0 ]]; then
        echo "No outputN nodes found in config.json."
        return
    fi

    backup="${CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
    cp -f "$CONFIG_FILE" "$backup"
    log "Backup saved: $backup"

    for n in "${INDICES[@]}"; do
        current_out=$(jq -r --arg name "output$n" '..|objects|select(has("name") and .name==$name and has("settings") and (.settings|has("port")))|.settings.port' "$CONFIG_FILE" | head -n1)

        if [[ -z "$current_out" ]]; then
            echo "Skipping output$n (missing port field)."
            continue
        fi

        echo "Node: output$n"
        echo "Current port: $current_out"
        while true; do
            read -rp "Enter new port for output$n (or press Enter to keep $current_out): " newp
            if [[ -z "$newp" ]]; then
                echo "Keeping port $current_out"
                break
            fi
            if validate_port "$newp"; then
                tmp="$(mktemp)"
                jq --argjson p "$newp" --arg name "output$n" '
                  (.. | objects
                    | select(has("name") and .name==$name and has("settings") and (.settings|has("port")))
                  ) |= (.settings.port = $p)
                ' "$CONFIG_FILE" > "$tmp"
                mv -f "$tmp" "$CONFIG_FILE"
                echo "Updated output$n port to: $newp"
                break
            else
                echo "Invalid port. Must be 1..65535."
            fi
        done
        echo "----------------------------------------"
    done
}

function change_ports() {
    [[ -f "$CONFIG_FILE" ]] || { echo "Config file not found: $CONFIG_FILE"; pause_return_menu; return; }

    local config_type
    config_type="$(detect_config_type)"

    if [[ "$config_type" == "bitswap" ]]; then
        change_ports_bitswap
    else
        echo
        echo "Change Ports (Classic)"
        echo "======================"
        echo "1) Change both Input & Output ports"
        echo "2) Change only Input ports"
        echo "3) Change only Output ports"
        echo "0) Back"
        echo
        read -rp "Choose an option [0-3]: " port_choice

        case "$port_choice" in
            1) change_ports_classic_both ;;
            2) change_ports_classic_input_only ;;
            3) change_ports_classic_output_only ;;
            0) return ;;
            *) echo "Invalid option."; pause_return_menu; return ;;
        esac
    fi

    port_change_restart_prompt
}

# ========================================
#   Service Management Menu
# ========================================

function iperf3_test() {
    echo

    # Install iperf3 if not present
    if ! command -v iperf3 >/dev/null 2>&1; then
        log "Installing iperf3..."
        wait_for_apt
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq iperf3 >/dev/null 2>&1
        if ! command -v iperf3 >/dev/null 2>&1; then
            echo "Failed to install iperf3."
            pause_return_menu
            return
        fi
        log "iperf3 installed."
    fi

    echo "iPerf3 Speed Test"
    echo "===================="
    echo "1) Server (listen mode - run this on destination server first)"
    echo "2) Client (connect mode - run this on source server)"
    echo "0) Back"
    echo
    read -rp "Choose [0-2]: " iperf_role
    case "$iperf_role" in
        1)
            echo
            log "Starting iperf3 server (listening on port 5201)..."
            echo "Waiting for client to connect... (Ctrl+C to stop)"
            echo
            iperf3 -s
            ;;
        2)
            echo
            read -rp "Enter destination IP [default: 10.10.0.2]: " dest_ip
            [[ -z "$dest_ip" ]] && dest_ip="10.10.0.2"
            echo
            log "Running iperf3 client -> $dest_ip (single stream, reverse, 30s)..."
            echo
            iperf3 -c "$dest_ip" -P1 -R -t30
            ;;
        0) return ;;
        *) echo "Invalid option." ;;
    esac
    pause_return_menu
}

function mtu_test() {
    echo
    echo "MTU Discovery Test"
    echo "===================="
    echo
    read -rp "Enter destination IP [default: 10.10.0.2]: " dest_ip
    [[ -z "$dest_ip" ]] && dest_ip="10.10.0.2"

    echo
    log "Finding optimal MTU for $dest_ip ..."
    echo

    local mtu=1500
    local step=10
    local best_mtu=1400

    # First quick check: does 1500 work?
    if ping -c 1 -W 2 -M do -s $((mtu - 28)) "$dest_ip" >/dev/null 2>&1; then
        echo "MTU 1500 works - no fragmentation issues."
        best_mtu=1500
    else
        # Binary search for optimal MTU
        local low=1200
        local high=1500
        while (( low <= high )); do
            mtu=$(( (low + high) / 2 ))
            local payload=$((mtu - 28))
            if ping -c 1 -W 2 -M do -s "$payload" "$dest_ip" >/dev/null 2>&1; then
                best_mtu=$mtu
                low=$((mtu + 1))
            else
                high=$((mtu - 1))
            fi
        done
    fi

    echo "========================================="
    echo " Optimal MTU: $best_mtu"
    echo "========================================="
    echo
    echo " Recommended Waterwall MTU: $((best_mtu - 80))"
    echo " (subtract ~80 bytes for tunnel overhead)"
    echo
    echo "========================================="

    if [[ -f "$CORE_FILE" ]] && command -v jq >/dev/null 2>&1; then
        local current_mtu
        current_mtu="$(jq -r '.misc.mtu // empty' "$CORE_FILE" 2>/dev/null)"
        if [[ -n "$current_mtu" ]]; then
            echo
            echo "Current Waterwall MTU in core.json: $current_mtu"
            local recommended=$((best_mtu - 80))
            if [[ "$current_mtu" -ne "$recommended" ]]; then
                read -rp "Update core.json MTU to $recommended? (y/n): " update_mtu
                update_mtu="$(echo "$update_mtu" | tr '[:upper:]' '[:lower:]')"
                if [[ "$update_mtu" == "y" || "$update_mtu" == "yes" ]]; then
                    local tmp
                    tmp="$(mktemp)"
                    jq --argjson m "$recommended" '.misc.mtu = $m' "$CORE_FILE" > "$tmp"
                    mv -f "$tmp" "$CORE_FILE"
                    log "core.json MTU updated to $recommended."
                    echo
                    read -rp "Restart service to apply? (y/n): " restart_ans
                    restart_ans="$(echo "$restart_ans" | tr '[:upper:]' '[:lower:]')"
                    if [[ "$restart_ans" == "y" || "$restart_ans" == "yes" ]]; then
                        systemctl restart "${SERVICE_NAME}.service" || true
                        log "Service restarted."
                    fi
                fi
            else
                echo "Already set to optimal value."
            fi
        fi
    fi

    pause_return_menu
}

function service_management_menu() {
    if ! is_installed; then
        echo
        echo "Service is not installed. Please install first."
        pause_return_menu
        return
    fi

    clear
    echo
    echo "Service Management"
    echo "===================="
    echo "1) Restart Service"
    echo "2) Service Status"
    echo "3) Test Tunnel"
    echo "4) Change Ports"
    echo "5) iPerf3 Speed Test"
    echo "6) MTU Test & Optimize"
    echo "7) Uninstall"
    echo "0) Back"
    echo
    read -rp "Choose an option [0-7]: " svc_choice
    case "$svc_choice" in
        1) restart_service ;;
        2) status_service ;;
        3) test_tunnel ;;
        4) change_ports ;;
        5) iperf3_test ;;
        6) mtu_test ;;
        7) uninstall ;;
        0) return ;;
        *) echo "Invalid option."; pause_return_menu ;;
    esac
}

# ========================================
#   Update Core
# ========================================

function update_core() {
    echo

    local local_ver latest_ver
    local_ver="$(get_local_version)"
    latest_ver="$(get_latest_version)"

    if [[ -z "$local_ver" ]]; then
        echo "Waterwall binary not found. Use Install first."
        pause_return_menu
        return
    fi

    if [[ -z "$latest_ver" ]]; then
        echo "Could not fetch latest version from GitHub."
        pause_return_menu
        return
    fi

    if [[ "$local_ver" == "$latest_ver" ]]; then
        echo "You already have the latest version (v$local_ver)."
        pause_return_menu
        return
    fi

    echo "Current version: v$local_ver"
    echo "Latest version:  v$latest_ver"
    echo
    read -rp "Update to v$latest_ver? (y/n): " ans
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ans" != "y" && "$ans" != "yes" ]]; then
        echo "Update cancelled."
        pause_return_menu
        return
    fi

    # Remove old binary so download_waterwall fetches new one
    rm -f "$INSTALL_DIR/Waterwall"

    cd "$INSTALL_DIR"
    download_waterwall || { pause_return_menu; return; }

    if is_installed; then
        log "Restarting service..."
        systemctl restart "${SERVICE_NAME}.service"
        echo "Service restarted with new version."
    fi

    pause_return_menu
}

# ========================================
#   Server Optimize
# ========================================

function detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID"
    elif command -v lsb_release >/dev/null 2>&1; then
        lsb_release -is | tr '[:upper:]' '[:lower:]'
    else
        echo "unknown"
    fi
}

function sysctl_optimizations() {
    log "Backing up /etc/sysctl.conf to /etc/sysctl.conf.bak ..."
    cp -f /etc/sysctl.conf /etc/sysctl.conf.bak 2>/dev/null || true

    log "Applying sysctl optimizations..."
    cat > /etc/sysctl.conf <<'SYSEOF'
# ===== File System =====
fs.file-max = 67108864

# ===== Network Core =====
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 65536
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 20000
net.core.optmem_max = 262144
net.core.somaxconn = 65536
net.core.rmem_default = 1048576
net.core.rmem_max = 33554432
net.core.wmem_default = 1048576
net.core.wmem_max = 33554432

# ===== TCP =====
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 8192 1048576 33554432
net.ipv4.tcp_wmem = 8192 1048576 33554432
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 25
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 7
net.ipv4.tcp_max_orphans = 819200
net.ipv4.tcp_max_syn_backlog = 20480
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# ===== UDP =====
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# ===== IPv4 Misc =====
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 1024 65535

# ===== IPv6 =====
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1

# ===== Virtual Memory =====
vm.swappiness = 10
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 250
vm.min_free_kbytes = 65536

# ===== Netfilter (conntrack) =====
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
SYSEOF

    sysctl -p >/dev/null 2>&1
    log "sysctl parameters applied."
}

function optimize_tunnel_interfaces() {
    log "Optimizing tunnel interfaces..."
    local iface
    for iface in wtun0 wtun1 wtun2; do
        if ip link show "$iface" >/dev/null 2>&1; then
            # Disable offloading on tunnel interfaces to reduce fragmentation
            ethtool -K "$iface" gro off gso off tso off 2>/dev/null || true
            # Set txqueuelen higher for better throughput
            ip link set "$iface" txqueuelen 10000 2>/dev/null || true
            log "  $iface: offload disabled, txqueuelen=10000"
        fi
    done

    # Also optimize physical interfaces
    local phys_iface
    phys_iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)"
    if [[ -n "$phys_iface" ]]; then
        ip link set "$phys_iface" txqueuelen 10000 2>/dev/null || true
        log "  $phys_iface: txqueuelen=10000"
    fi

    # Install ethtool if not present
    if ! command -v ethtool >/dev/null 2>&1; then
        wait_for_apt
        apt-get install -y -qq ethtool >/dev/null 2>&1 || true
    fi
}

function limits_optimizations() {
    log "Applying system limits..."

    # /etc/security/limits.conf
    local limits_file="/etc/security/limits.conf"
    if ! grep -q "# Waterwall Optimize" "$limits_file" 2>/dev/null; then
        cp -f "$limits_file" "${limits_file}.bak" 2>/dev/null || true
        cat >> "$limits_file" <<'LIMEOF'

# Waterwall Optimize
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc unlimited
* hard nproc unlimited
* soft core unlimited
* hard core unlimited
* soft stack unlimited
* hard stack unlimited
LIMEOF
        log "limits.conf updated."
    else
        log "limits.conf already optimized, skipping."
    fi

    # /etc/profile ulimit
    if ! grep -q "# Waterwall Optimize" /etc/profile 2>/dev/null; then
        cat >> /etc/profile <<'PROFEOF'

# Waterwall Optimize
ulimit -n 1048576
ulimit -s unlimited
ulimit -c unlimited
PROFEOF
        log "/etc/profile updated."
    else
        log "/etc/profile already optimized, skipping."
    fi
}

function enable_bbr() {
    log "Checking BBR support..."
    local distro="$1"

    # Load tcp_bbr module if not loaded
    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr 2>/dev/null || true
    fi

    # Ensure tcp_bbr loads on boot
    if ! grep -q "tcp_bbr" /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        log "BBR module set to load on boot."
    fi

    # Verify
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        log "BBR is active."
    else
        log "BBR may require a reboot to take effect."
    fi
}

function install_tunnel_tune_service() {
    log "Creating tunnel-tune service for post-boot interface tuning..."
    cat > /etc/systemd/system/waterwall-tune.service <<'TUNESVC'
[Unit]
Description=Waterwall Tunnel Interface Tuning
After=network-online.target waterwall.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 3
ExecStart=/bin/bash -c '\
for iface in wtun0 wtun1 wtun2; do \
    if ip link show "$iface" 2>/dev/null; then \
        ethtool -K "$iface" gro off gso off tso off 2>/dev/null || true; \
        ip link set "$iface" txqueuelen 10000 2>/dev/null || true; \
    fi; \
done; \
PHYS=$(ip route show default | awk "/default/ {print \$5}" | head -n1); \
[ -n "$PHYS" ] && ip link set "$PHYS" txqueuelen 10000 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
TUNESVC
    systemctl daemon-reexec
    systemctl enable waterwall-tune.service >/dev/null 2>&1
    log "waterwall-tune.service enabled (runs after each boot)."
}

function get_installed_optimize_version() {
    if [[ -f "$OPTIMIZE_MARKER" ]]; then
        cat "$OPTIMIZE_MARKER" 2>/dev/null
    else
        echo ""
    fi
}

function save_optimize_version() {
    echo "$OPTIMIZE_VERSION" > "$OPTIMIZE_MARKER"
}

function optimize_server() {
    echo
    echo "Server Optimization"
    echo "====================="

    local distro
    distro="$(detect_distro)"

    case "$distro" in
        ubuntu|debian)
            log "Detected OS: $distro"
            ;;
        *)
            echo "This optimization supports Ubuntu and Debian only."
            echo "Detected: $distro"
            pause_return_menu
            return
            ;;
    esac

    local installed_ver
    installed_ver="$(get_installed_optimize_version)"

    if [[ -n "$installed_ver" ]]; then
        if [[ "$installed_ver" == "$OPTIMIZE_VERSION" ]]; then
            # Same version - ask user
            echo
            echo "Optimization v${installed_ver} is already applied on this server."
            read -rp "Re-apply? (y/n): " reapply
            reapply="$(echo "$reapply" | tr '[:upper:]' '[:lower:]')"
            if [[ "$reapply" != "y" && "$reapply" != "yes" ]]; then
                echo "Skipped."
                pause_return_menu
                return
            fi
        else
            # Old version - auto update
            echo
            log "Old optimization (v${installed_ver}) detected. Updating to v${OPTIMIZE_VERSION}..."
        fi
    fi

    echo
    echo "This will apply the following optimizations:"
    echo "  - Kernel & TCP tuning (sysctl + BBR with fq qdisc)"
    echo "  - System limits (ulimits / nofile)"
    echo "  - Network buffer & conntrack optimization"
    echo "  - Tunnel interface tuning (offload, txqueuelen)"
    echo

    if [[ -z "$installed_ver" ]]; then
        read -rp "Continue? (y/n): " ans
        ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$ans" != "y" && "$ans" != "yes" ]]; then
            echo "Cancelled."
            pause_return_menu
            return
        fi
    fi

    echo

    # Install required kernel modules package on Debian if needed
    if [[ "$distro" == "debian" ]]; then
        if ! dpkg -l | grep -q linux-modules 2>/dev/null; then
            log "Ensuring kernel headers/modules are available..."
            wait_for_apt
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq linux-headers-"$(uname -r)" 2>/dev/null || true
        fi
    fi

    # Install ethtool for interface tuning
    if ! command -v ethtool >/dev/null 2>&1; then
        log "Installing ethtool..."
        wait_for_apt
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq ethtool >/dev/null 2>&1 || true
    fi

    # Load conntrack module for nf_conntrack sysctl params
    modprobe nf_conntrack 2>/dev/null || true
    if ! grep -q "nf_conntrack" /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "nf_conntrack" >> /etc/modules-load.d/bbr.conf
    fi

    sysctl_optimizations
    limits_optimizations
    enable_bbr "$distro"
    optimize_tunnel_interfaces
    install_tunnel_tune_service
    save_optimize_version

    echo
    echo "========================================="
    echo " Optimization v${OPTIMIZE_VERSION} applied!"
    echo "========================================="
    echo
    echo "A reboot is recommended for all changes to take full effect."
    echo
    echo "1) Reboot now"
    echo "0) Return to menu"
    read -rp "Choose [0-1]: " reboot_choice
    case "$reboot_choice" in
        1) echo "Rebooting..."; reboot ;;
        *) return ;;
    esac
}

# ========================================
#   Main Menu
# ========================================

function main_menu() {
    install_prerequisites
    while true; do
        banner
        echo "Waterwall Setup"
        echo "=================="
        echo "1) Install Tunnel"
        echo "2) Service Management"
        echo "3) Update Core"
        echo "4) Optimize Server"
        echo "0) Exit"
        echo
        read -rp "Choose an option [0-4]: " choice
        case "$choice" in
            1) install_menu ;;
            2) service_management_menu ;;
            3) update_core ;;
            4) optimize_server ;;
            0) echo "Bye!"; exit 0 ;;
            *) echo "Invalid option."; pause_return_menu ;;
        esac
    done
}

main_menu
