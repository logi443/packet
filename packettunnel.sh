#!/bin/bash

set -e

INSTALL_DIR="/root/waterwall"
SERVICE_NAME="waterwall"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_FILE="${INSTALL_DIR}/config.json"
CORE_FILE="${INSTALL_DIR}/core.json"
CORE_URL="https://raw.githubusercontent.com/logi443/packet/main/core.json"
GITHUB_REPO="radkesvat/WaterWall"

function log() { echo "[+] $1"; }

function pause_return_menu() {
    echo
    read -rp "Press Enter to return to menu..." _
}

function banner() {
    clear
    echo -e "\e[31m"
    server_ip=$(get_public_ip)
    [[ -z "$server_ip" ]] && server_ip="Unknown"
    echo "=================================================="
    echo "██╗    ██╗ █████╗ ████████╗███████╗██████╗ ██╗    ██╗ █████╗ ██╗     ██╗"
    echo "██║    ██║██╔══██╗╚══██╔══╝██╔════╝██╔══██╗██║    ██║██╔══██╗██║     ██║"
    echo "██║ █╗ ██║███████║   ██║   █████╗  ██████╔╝██║ █╗ ██║███████║██║     ██║"
    echo "██║███╗██║██╔══██║   ██║   ██╔══╝  ██╔══██╗██║███╗██║██╔══██║██║     ██║"
    echo "╚███╔███╔╝██║  ██║   ██║   ███████╗██║  ██║╚███╔███╔╝██║  ██║███████╗███████╗"
    echo " ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚══════╝╚══════╝"
    echo "                  WATERWALL - BY MEYSAM"
    echo "                  SERVER IP: $server_ip"
    echo "=================================================="
    echo -e "\e[0m"
}

function get_public_ip() {
    # Try to get the primary public IP from default route interface
    local iface ip
    iface="$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+')"
    if [[ -n "$iface" ]]; then
        ip="$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+'| head -n1)"
        [[ -n "$ip" ]] && echo "$ip" && return
    fi
    # Fallback: first non-loopback IPv4
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$ip" ]] && echo "$ip"
}

function validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    (( p >= 1 && p <= 65535 )) || return 1
    return 0
}

function prompt_ports() {
    ports=()
    log "Enter ports to forward (e.g. 443 8443 80), type 'done' to finish:"
    while true; do
        read -rp "Port: " p
        [[ "$p" == "done" ]] && break
        [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p") || echo "Invalid port number."
    done
}

# ========================================
#   Waterwall Download
# ========================================

function download_waterwall() {
    # Check for existing binary (any case variation)
    local existing
    existing="$(find "$INSTALL_DIR" -maxdepth 1 -iname 'waterwall' -type f 2>/dev/null | head -n1)"
    if [[ -n "$existing" ]]; then
        # Rename to expected name if needed
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
        pause_return_menu
        return
    fi

    log "Fetching latest release from GitHub..."
    local download_url
    download_url="$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases" \
        | grep -o "\"browser_download_url\": \"[^\"]*${asset_name}\"" \
        | head -n1 \
        | cut -d'"' -f4)"

    if [[ -z "$download_url" ]]; then
        echo "Could not find download URL for: $asset_name"
        pause_return_menu
        return
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
    local port_listen="$3"
    local port_connect_kharej="$4"
    local mux_count="${5:-8}"
    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "name": "iran-tcp-bitswap-mux",
    "variables": {
        "ip_server_iran": "$ip_iran",
        "ip_server_kharej": "$ip_kharej",
        "port_to_listen": $port_listen,
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
            "next": "tcp-out"
        },
        {
            "name": "tcp-out",
            "type": "TcpConnector",
            "settings": {
                "address": \$final_ip\$,
                "port": \$final_port\$,
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
#   Install - BitSwap
# ========================================

function install_bitswap() {
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    download_waterwall

    read -rp "Is this server '1-iran' or '2-kharej'? " role

    server_ip=$(get_public_ip)
    if [[ -z "$server_ip" ]]; then
        echo "Could not detect public IP automatically."
        read -rp "Enter this server public IP manually: " server_ip
    fi

    read -rp "Enter MTU value [default: 1400]: " mtu_val
    [[ -z "$mtu_val" ]] && mtu_val=1400

    if [[ "$role" == "1" ]]; then
        ip_iran="$server_ip"
        echo "Detected Iran server IP: $ip_iran"
        read -rp "Enter Kharej server public IP: " ip_kharej

        read -rp "Enter port to listen (users connect to this port): " port_listen
        validate_port "$port_listen" || { echo "Invalid port."; pause_return_menu; return; }

        read -rp "Enter port to connect to Kharej (Waterwall port on Kharej): " port_connect_kharej
        validate_port "$port_connect_kharej" || { echo "Invalid port."; pause_return_menu; return; }

        generate_core_json "$mtu_val"
        generate_bitswap_iran_config "$ip_iran" "$ip_kharej" "$port_listen" "$port_connect_kharej"

    elif [[ "$role" == "2" ]]; then
        ip_kharej="$server_ip"
        echo "Detected Kharej server IP: $ip_kharej"
        read -rp "Enter Iran server public IP: " ip_iran

        read -rp "Enter port to listen (Waterwall listen port, same as Iran's 'port to connect to Kharej'): " port_listen
        validate_port "$port_listen" || { echo "Invalid port."; pause_return_menu; return; }

        read -rp "Enter final inbound port (Xray listen port): " final_port
        validate_port "$final_port" || { echo "Invalid port."; pause_return_menu; return; }

        generate_core_json "$mtu_val"
        generate_bitswap_kharej_config "$ip_iran" "$ip_kharej" "$port_listen" "$final_port"

    else
        echo "Invalid role. Must be '1' or '2'."
        pause_return_menu
        return
    fi

    install_service
    log "BitSwap tunnel setup complete. Service is running."
    pause_return_menu
}

# ========================================
#   Install - PacketTunnel (Classic)
# ========================================

function install_packettunnel() {
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    download_waterwall
    log "Downloading core.json..."
    curl -fsSL "$CORE_URL" -o core.json
    read -rp "Is this server '1-iran' or '2-kharej'? " role
    server_ip=$(get_public_ip)
    if [[ -z "$server_ip" ]]; then
        echo "Could not detect public IP automatically."
        read -rp "Enter this server public IP manually: " server_ip
    fi
    if [[ "$role" == "1" ]]; then
        ip_iran="$server_ip"
        echo "Detected Iran server IP: $ip_iran"
        read -rp "Enter Kharej server public IP: " ip_kharej
        prompt_ports
        generate_iran_config "$ip_iran" "$ip_kharej"
    elif [[ "$role" == "2" ]]; then
        ip_kharej="$server_ip"
        echo "Detected Kharej server IP: $ip_kharej"
        read -rp "Enter Iran server public IP: " ip_iran
        generate_kharej_config "$ip_kharej" "$ip_iran"
    else
        echo "Invalid role. Must be '1' or '2'."
        pause_return_menu
        return
    fi
    install_service
    log "PacketTunnel setup complete. Service is running."
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
    echo "2) PacketTunnel (Classic)"
    echo "0) Back"
    echo
    read -rp "Choose an option [0-2]: " install_choice
    case "$install_choice" in
        1) install_bitswap ;;
        2) install_packettunnel ;;
        0) return ;;
        *) echo "Invalid option."; pause_return_menu ;;
    esac
}

# ========================================
#   Service Management
# ========================================

function restart_service() {
    echo
    if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\\.service"; then
        systemctl restart "${SERVICE_NAME}.service"
        echo "Service restarted successfully."
    else
        echo "${SERVICE_NAME}.service is not installed."
    fi
    pause_return_menu
}

function status_service() {
    echo
    if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\\.service"; then
        systemctl status "${SERVICE_NAME}.service" --no-pager || true
    else
        echo "${SERVICE_NAME}.service is not installed."
    fi
    pause_return_menu
}

function uninstall() {
    echo
    local service_exists=false
    if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\\.service"; then
        service_exists=true
    fi

    if [[ "$service_exists" == true ]]; then
        read -rp "Service is installed. Do you want to remove it? (y/n): " ans
        ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$ans" == "y" || "$ans" == "yes" ]]; then
            log "Stopping and disabling systemd service..."
            systemctl stop "${SERVICE_NAME}.service" || true
            systemctl disable "${SERVICE_NAME}.service" || true
            rm -f "$SERVICE_FILE"
            systemctl daemon-reexec
            log "Service removed."
        else
            echo "Service kept."
        fi
    else
        echo "No service found."
    fi

    echo
    if [[ -f "$INSTALL_DIR/Waterwall" ]]; then
        read -rp "Do you want to remove the Waterwall binary and all files? (y/n): " ans2
        ans2="$(echo "$ans2" | tr '[:upper:]' '[:lower:]')"
        if [[ "$ans2" == "y" || "$ans2" == "yes" ]]; then
            log "Removing files..."
            rm -rf "$INSTALL_DIR"
            log "All files removed."
        else
            echo "Files kept."
        fi
    else
        echo "No Waterwall binary found in $INSTALL_DIR."
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
    echo "3) Return to menu"
    read -rp "Choose [1-3]: " next
    case "$next" in
        1)
            if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\\.service"; then
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
            pause_return_menu
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

    # Collect all variable keys that contain "port" (case-insensitive)
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
        while true; do
            read -rp "Enter new value (or press Enter to keep $var_value): " newp
            if [[ -z "$newp" ]]; then
                echo "Keeping $var_value"
                break
            fi
            if validate_port "$newp"; then
                tmp="$(mktemp)"
                jq --arg key "$var_name" --argjson val "$newp" '.variables[$key] = $val' "$CONFIG_FILE" > "$tmp"
                mv -f "$tmp" "$CONFIG_FILE"
                echo "Updated $var_name to: $newp"
                break
            else
                echo "Invalid port. Must be 1..65535."
            fi
        done
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

    if [[ "${#INDICES[@]}" -eq 1 ]]; then
        n="${INDICES[0]}"
        current_in=$(jq -r --arg name "input$n" '..|objects|select(has("name") and .name==$name and has("settings") and (.settings|has("port")))|.settings.port' "$CONFIG_FILE" | head -n1)
        current_out=$(jq -r --arg name "output$n" '..|objects|select(has("name") and .name==$name and has("settings") and (.settings|has("port")))|.settings.port' "$CONFIG_FILE" | head -n1)

        if [[ -z "$current_in" || -z "$current_out" ]]; then
            echo "Could not read ports for input$n/output$n."
            return
        fi

        echo "Found: input$n/output$n"
        echo "Current port: $current_in"
        read -rp "Enter new port: " newp
        validate_port "$newp" || { echo "Invalid port (must be 1..65535)."; return; }

        tmp="$(mktemp)"
        jq --argjson p "$newp" --arg in "input$n" --arg out "output$n" '
          (.. | objects
            | select(has("name") and (.name==$in or .name==$out) and has("settings") and (.settings|has("port")))
          ) |= (.settings.port = $p)
        ' "$CONFIG_FILE" > "$tmp"
        mv -f "$tmp" "$CONFIG_FILE"
        echo "Updated input$n/output$n port to: $newp"
    else
        echo "Found multiple port pairs: ${#INDICES[@]}"
        echo "You will be asked to change each one."
        echo
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
                read -rp "Enter new port for this pair (or press Enter to keep $current_in): " newp
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
    fi
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
    command -v jq >/dev/null 2>&1 || { echo "jq is not installed. Install it: apt install -y jq"; pause_return_menu; return; }

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

function service_management_menu() {
    clear
    echo
    echo "Service Management"
    echo "===================="
    echo "1) Restart Service"
    echo "2) Service Status"
    echo "3) Change Ports"
    echo "4) Uninstall"
    echo "0) Back"
    echo
    read -rp "Choose an option [0-4]: " svc_choice
    case "$svc_choice" in
        1) restart_service ;;
        2) status_service ;;
        3) change_ports ;;
        4) uninstall ;;
        0) return ;;
        *) echo "Invalid option."; pause_return_menu ;;
    esac
}

# ========================================
#   Main Menu
# ========================================

function main_menu() {
    while true; do
        banner
        echo "Waterwall Setup"
        echo "=================="
        echo "1) Install Tunnel"
        echo "2) Service Management"
        echo "0) Exit"
        echo
        read -rp "Choose an option [0-2]: " choice
        case "$choice" in
            1) install_menu ;;
            2) service_management_menu ;;
            0) echo "Bye!"; exit 0 ;;
            *) echo "Invalid option."; pause_return_menu ;;
        esac
    done
}

main_menu
