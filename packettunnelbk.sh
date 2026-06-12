#!/bin/bash

set -e

INSTALL_DIR="/root/packettunnel"
SERVICE_FILE="/etc/systemd/system/packettunnel.service"
CONFIG_FILE="/root/packettunnel/config.json"
CORE_URL="https://raw.githubusercontent.com/logi443/packet/main/core.json"
WATERWALL_URL="https://raw.githubusercontent.com/logi443/packet/main/Waterwall"
WATERWALL_OLDCPU_URL="https://raw.githubusercontent.com/logi443/packet/main/Waterwall-oldcpu"

function log() { echo "[+] $1"; }

function pause_return_menu() {
    echo
    read -rp "Press Enter to return to main menu..." _
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
    curl -s https://api.ipify.org
}

function confirm_uninstall() {
    echo
    read -rp "Are you sure you want to uninstall? (y/n): " ans
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
    [[ "$ans" == "y" || "$ans" == "yes" ]]
}

function uninstall() {
    if ! confirm_uninstall; then
        echo "Uninstall cancelled."
        pause_return_menu
        return
    fi
    log "Stopping and disabling systemd service..."
    systemctl stop packettunnel.service || true
    systemctl disable packettunnel.service || true
    log "Removing files..."
    rm -rf "$INSTALL_DIR"
    rm -f "$SERVICE_FILE"
    log "Reloading systemd..."
    systemctl daemon-reexec
    log "✅ Uninstall complete."
    pause_return_menu
}

function status_service() {
    echo
    if systemctl list-unit-files | grep -q '^packettunnel\.service'; then
        systemctl status packettunnel.service --no-pager || true
    else
        echo "packettunnel.service is not installed."
    fi
    pause_return_menu
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

function install_service() {
    log "Creating systemd service..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=packet Tunnel Service
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
    systemctl enable packettunnel.service
    systemctl restart packettunnel.service
}

function download_waterwall() {
    echo
    read -rp "Download old CPU build? (y/n): " oldcpu
    oldcpu="$(echo "$oldcpu" | tr '[:upper:]' '[:lower:]')"
    local url="$WATERWALL_URL"
    if [[ "$oldcpu" == "y" || "$oldcpu" == "yes" ]]; then
        url="$WATERWALL_OLDCPU_URL"
        log "Old CPU build selected."
    else
        log "Normal build selected."
    fi
    log "Downloading Waterwall binary..."
    curl -fsSL "$url" -o Waterwall
    chmod +x Waterwall
}

function install_menu() {
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
    log "✅ Tunnel setup complete. Service is running."
    pause_return_menu
}

# ==========================
#   Change Ports (config.json)
# ==========================

function validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    (( p >= 1 && p <= 65535 )) || return 1
    return 0
}

function port_change_restart_prompt() {
    echo
    echo "What next?"
    echo "1) Restart service (recommended)"
    echo "2) Reboot server"
    echo "3) Return to menu"
    read -rp "Choose [1-3]: " next
    case "$next" in
        1)
            if systemctl list-unit-files | grep -q '^packettunnel\.service'; then
                systemctl restart packettunnel.service || true
                echo "✅ Service restarted."
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

# --- Mode 1: Change both input & output ports (original behavior) ---
function change_ports_both() {
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
        echo "✅ Updated input$n/output$n port to: $newp"
    else
        echo "Found multiple port pairs: ${#INDICES[@]}"
        echo "You will be asked to change each one, one by one."
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
                    echo "✅ Updated input$n/output$n to: $newp"
                    break
                else
                    echo "Invalid port. Must be 1..65535."
                fi
            done
            echo "----------------------------------------"
        done
    fi
}

# --- Mode 2: Change only input ports ---
function change_ports_input_only() {
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
                echo "✅ Updated input$n port to: $newp"
                break
            else
                echo "Invalid port. Must be 1..65535."
            fi
        done
        echo "----------------------------------------"
    done
}

# --- Mode 3: Change only output ports ---
function change_ports_output_only() {
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
                echo "✅ Updated output$n port to: $newp"
                break
            else
                echo "Invalid port. Must be 1..65535."
            fi
        done
        echo "----------------------------------------"
    done
}

# --- Main change_ports with sub-menu ---
function change_ports() {
    [[ -f "$CONFIG_FILE" ]] || { echo "Config file not found: $CONFIG_FILE"; pause_return_menu; return; }
    command -v jq >/dev/null 2>&1 || { echo "jq is not installed. Install it: apt install -y jq"; pause_return_menu; return; }

    echo
    echo "Change Ports Menu"
    echo "=================="
    echo "1) Change both Input & Output ports"
    echo "2) Change only Input ports"
    echo "3) Change only Output ports"
    echo "0) Return to main menu"
    echo
    read -rp "Choose an option [0-3]: " port_choice

    case "$port_choice" in
        1) change_ports_both ;;
        2) change_ports_input_only ;;
        3) change_ports_output_only ;;
        0) return ;;
        *) echo "Invalid option."; pause_return_menu; return ;;
    esac

    port_change_restart_prompt
}

function main_menu() {
    while true; do
        banner
        echo "PacketTunnel Setup"
        echo "=================="
        echo "1) Install"
        echo "2) Uninstall"
        echo "3) Service Status"
        echo "4) Change Ports (config.json)"
        echo "0) Exit"
        echo
        read -rp "Choose an option [0-4]: " choice
        case "$choice" in
            1) install_menu ;;
            2) uninstall ;;
            3) status_service ;;
            4) change_ports ;;
            0) echo "Bye!"; exit 0 ;;
            *) echo "Invalid option."; pause_return_menu ;;
        esac
    done
}

main_menu
