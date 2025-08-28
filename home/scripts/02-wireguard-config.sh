#!/bin/bash
# Home Machine Setup - WireGuard Configuration
# Configures WireGuard peer to connect to VPS through encrypted tunnel

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# Globals set during runtime
PEER_NAME=""
PRIVATE_KEY_PATH=""
PUBLIC_KEY_PATH=""

main() {
    local peer_name="${1:-}"

    if [[ -z "$peer_name" ]]; then
        log_error "Peer name is required"
        echo "Usage: $0 <peer-name>"
        echo "Available peers from config:"
        show_available_peers
        exit 1
    fi

    PEER_NAME="$peer_name"

    log "Starting WireGuard configuration for peer: $PEER_NAME"

    check_root
    check_config

    # Validate peer exists
    if ! validate_peer_name "$PEER_NAME"; then
        log_error "Peer '$PEER_NAME' not found in configuration"
        echo "Available peers:"
        show_available_peers
        exit 1
    fi

    # Generate/load this peer's keys (home side)
    setup_peer_keys

    # Generate WireGuard configuration (resolves VPS pubkey/endpoint from config.yaml)
    generate_wg_config

    # Enable and start wg-quick@wg0 (only if config is complete)
    enable_wireguard_service

    # Print status and the command to add this peer on the VPS
    display_connection_instructions

    log_success "WireGuard configuration completed for peer: $PEER_NAME"
}

show_available_peers() {
    if command -v yq &>/dev/null; then
        yq eval -r '.peers[] | "  - " + .name + " (" + .address + ")"' "$CONFIG_FILE"
    else
        log "Install yq for nicer output. Peers listed in $CONFIG_FILE under .peers[]."
    fi
}

setup_peer_keys() {
    log "Setting up WireGuard keys for peer: $PEER_NAME"

    # Paths can be overridden per-peer in config.yaml
    local private_key_path public_key_path
    private_key_path=$(get_peer_config "$PEER_NAME" "home_private_key_path" "/etc/wireguard/home-private.key")
    public_key_path=$(get_peer_config "$PEER_NAME" "home_public_key_path" "/etc/wireguard/home-public.key")

    # Ensure directory exists
    mkdir -p "$(dirname "$private_key_path")"
    mkdir -p "$(dirname "$public_key_path")"

    # Generate private key if missing
    if [[ ! -f "$private_key_path" ]]; then
        log "Generating peer private key…"
        generate_wg_private_key > "$private_key_path"
        chmod 600 "$private_key_path"
        log_success "Peer private key generated: $private_key_path"
    else
        log "Peer private key already exists: $private_key_path"
    fi

    # Generate public key if missing
    if [[ ! -f "$public_key_path" ]]; then
        log "Generating peer public key…"
        local private_key
        private_key=$(cat "$private_key_path")
        generate_wg_public_key "$private_key" > "$public_key_path"
        chmod 644 "$public_key_path"
        log_success "Peer public key generated: $public_key_path"
    else
        log "Peer public key already exists: $public_key_path"
    fi

    PRIVATE_KEY_PATH="$private_key_path"
    PUBLIC_KEY_PATH="$public_key_path"
}

# Pull the VPS public key and endpoint from config.yaml (preferred) with fallbacks.
_resolve_vps_identity() {
    # Preferred: inline public key and endpoint in config.yaml
    local vps_public_key vps_endpoint vps_public_key_path vps_ip vps_port

    vps_public_key=$(get_config_value "vps.wireguard.public_key" "")
    vps_endpoint=$(get_config_value "vps.wireguard.endpoint" "")

    # Backward compatible: allow peer-scoped endpoint override (e.g., multi-VPS)
    if [[ -z "$vps_endpoint" || "$vps_endpoint" == "null" ]]; then
        vps_endpoint=$(get_peer_config "$PEER_NAME" "endpoint" "")
    fi

    # If endpoint still empty, try building from public_ip + listen_port
    if [[ -z "$vps_endpoint" || "$vps_endpoint" == "null" ]]; then
        vps_ip=$(get_config_value "vps.public_ip" "")
        vps_port=$(get_config_value "vps.wireguard.listen_port" "51820")
        if [[ -n "$vps_ip" && "$vps_ip" != "null" ]]; then
            vps_endpoint="${vps_ip}:${vps_port}"
        fi
    fi

    # If public_key not inline, allow a path or /tmp fallback
    if [[ -z "$vps_public_key" || "$vps_public_key" == "null" ]]; then
        vps_public_key_path=$(get_config_value "vps.wireguard.public_key_path" "/etc/wireguard/vps-public.key")
        if [[ -f "$vps_public_key_path" ]]; then
            vps_public_key=$(cat "$vps_public_key_path" | tr -d '\r\n ')
        elif [[ -f "/tmp/vps-public.key" ]]; then
            vps_public_key=$(cat "/tmp/vps-public.key" | tr -d '\r\n ')
        else
            log_error "VPS public key not found. Set one of:
  - vps.wireguard.public_key (inline base64) in config.yaml
  - vps.wireguard.public_key_path (file path) in config.yaml
  - or drop the key into /tmp/vps-public.key"
            exit 1
        fi
    fi

    # Light sanity check (WireGuard pubkeys are 44-char base64 ending with '=')
    if ! [[ "$vps_public_key" =~ ^[A-Za-z0-9+/]{42,43}=+$ ]]; then
        log_error "vps.wireguard.public_key format looks wrong: '$vps_public_key'"
        exit 1
    fi

    if [[ -z "$vps_endpoint" || "$vps_endpoint" == "null" ]]; then
        log_error "VPS endpoint missing. Set one of:
  - vps.wireguard.endpoint (e.g., 203.0.113.10:51820) in config.yaml
  - peers[].endpoint for peer '$PEER_NAME'
  - or provide vps.public_ip + vps.wireguard.listen_port"
        exit 1
    fi

    echo "$vps_public_key|$vps_endpoint"
}

generate_wg_config() {
    log "Generating WireGuard configuration for peer: $PEER_NAME"

    # Per-peer settings
    local peer_address peer_keepalive
    peer_address=$(get_peer_config "$PEER_NAME" "address")
    peer_keepalive=$(get_peer_config "$PEER_NAME" "keepalive" "25")

    # Global WG subnet (what we route over wg0)
    local vps_subnet
    vps_subnet=$(get_config_value "vps.wireguard.subnet_cidr" "10.8.0.0/24")

    # Required: VPS identity
    IFS="|" read -r vps_public_key vps_endpoint < <(_resolve_vps_identity)

    # Read this peer's private key
    local private_key
    if [[ -f "$PRIVATE_KEY_PATH" ]]; then
        private_key=$(tr -d '\r\n ' < "$PRIVATE_KEY_PATH")
    else
        log_error "Private key not found: $PRIVATE_KEY_PATH"
        exit 1
    fi

    local template_path="$SCRIPT_DIR/../templates/wg0.conf.template"
    local config_path="/etc/wireguard/wg0.conf"

    # Backup existing config safely
    backup_file "$config_path"

    if [[ -f "$template_path" ]]; then
        # Render template with all placeholders replaced
        substitute_template "$template_path" "$config_path" \
            "PRIVATE_KEY=$private_key" \
            "PEER_ADDRESS=$peer_address" \
            "VPS_PUBLIC_KEY=$vps_public_key" \
            "VPS_ENDPOINT=$vps_endpoint" \
            "VPS_SUBNET=$vps_subnet" \
            "KEEPALIVE=$peer_keepalive"
    else
        # Fallback: generate directly
        cat > "$config_path" <<EOF
# Home Machine WireGuard Configuration
# Peer: $PEER_NAME
# Generated by vps-proxy-hub home setup

[Interface]
PrivateKey = $private_key
Address = $peer_address
DNS = 1.1.1.1, 8.8.8.8

# Route the WG subnet through the tunnel
PostUp = ip route add $vps_subnet dev %i || true
PostDown = ip route del $vps_subnet dev %i 2>/dev/null || true

[Peer]
# VPS WireGuard Server
PublicKey = $vps_public_key
Endpoint = $vps_endpoint
AllowedIPs = $vps_subnet
PersistentKeepalive = $peer_keepalive
EOF
        log "Generated WireGuard configuration directly"
    fi

    chmod 600 "$config_path"
    log_success "WireGuard configuration generated: $config_path"
}

enable_wireguard_service() {
    log "Configuring WireGuard service for peer: $PEER_NAME"

    # Stop if already running (clean restart)
    if systemctl is-active --quiet wg-quick@wg0; then
        log "Stopping existing WireGuard service…"
        systemctl stop wg-quick@wg0
    fi

    # Validate config before bringing up
    if ! wg-quick up wg0 &>/dev/null; then
        log_error "WireGuard configuration test failed (wg-quick --dry-run)"
        log "Inspect config: cat /etc/wireguard/wg0.conf"
        return 1
    fi

    systemctl enable wg-quick@wg0 >/dev/null
    systemctl start wg-quick@wg0

    # Wait until the interface appears
    wait_for_service "wg-quick@wg0"

    if ip link show wg0 &>/dev/null; then
        log_success "WireGuard interface wg0 is up"

        # Optional: quick reachability check to VPS wg IP (strip CIDR)
        local vps_ip
        vps_ip=$(get_config_value "vps.wireguard.vps_address" "10.8.0.1/24")
        vps_ip="${vps_ip%/*}"
        if ping -c 1 -W 3 "$vps_ip" &>/dev/null; then
            log_success "Reachable: $vps_ip over WireGuard"
        else
            log_warning "wg0 up but cannot reach VPS $vps_ip yet (may be normal until VPS adds this peer)"
        fi
    else
        log_error "WireGuard interface wg0 failed to start"
        log "Check logs: journalctl -u wg-quick@wg0"
        return 1
    fi
}

display_connection_instructions() {
    log "WireGuard peer setup information:"

    # Show status if available
    if command -v wg &>/dev/null && ip link show wg0 &>/dev/null; then
        echo "--- WireGuard Status ---"
        wg show wg0 2>/dev/null || log_warning "WireGuard interface not ready"
    fi

    # Print the command you need to run on the VPS to add this peer
    if [[ -f "$PUBLIC_KEY_PATH" ]]; then
        local home_pub
        home_pub=$(tr -d '\r\n ' < "$PUBLIC_KEY_PATH")
        # Pull the home peer address for AllowedIPs (single /32 recommended)
        local home_addr
        home_addr=$(get_peer_config "$PEER_NAME" "address")
        # Convert CIDR to /32 if a /24 was provided for the peer
        local home_ip="${home_addr%/*}"
        echo
        echo "--- Add this peer on the VPS ---"
        echo "sudo wg set wg0 peer \"$home_pub\" allowed-ips ${home_ip}/32"
        echo "Then persist it in /etc/wireguard/wg0.conf on the VPS and restart:"
        echo "sudo systemctl restart wg-quick@wg0"
        echo
    fi

    # Also show any peer-specific info (existing helper)
    display_peer_info "$PEER_NAME" "$PUBLIC_KEY_PATH"
}

# Run main
main "$@"
