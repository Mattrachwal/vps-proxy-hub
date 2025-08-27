#!/bin/bash
# Home Machine Setup - WireGuard Configuration
# Configures WireGuard peer to connect to VPS through encrypted tunnel

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# Global variables
PEER_NAME=""

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
    
    # Validate peer name exists in config
    if ! validate_peer_name "$PEER_NAME"; then
        log_error "Peer '$PEER_NAME' not found in configuration"
        echo "Available peers:"
        show_available_peers
        exit 1
    fi
    
    # Generate or load peer keys
    setup_peer_keys
    
    # Generate WireGuard configuration
    generate_wg_config
    
    # Enable and start WireGuard service
    enable_wireguard_service
    
    # Display connection instructions
    display_connection_instructions
    
    log_success "WireGuard configuration completed for peer: $PEER_NAME"
}

show_available_peers() {
    if command -v yq &> /dev/null; then
        yq eval '.peers[] | "  - " + .name + " (" + .address + ")"' "$CONFIG_FILE"
    else
        grep -A 5 "^peers:" "$CONFIG_FILE" | grep -E "name:|address:" | paste - - | \
        sed 's/.*name: *["'\'']*/  - /' | sed 's/["'\'']*.* address: */ (/' | sed 's/[)\s]*$/))/' || \
        log "Check config.yaml for available peer names"
    fi
}

setup_peer_keys() {
    log "Setting up WireGuard keys for peer: $PEER_NAME"
    
    # Get key paths from config
    local private_key_path public_key_path
    private_key_path=$(get_peer_config "$PEER_NAME" "home_private_key_path" "/etc/wireguard/home-private.key")
    public_key_path=$(get_peer_config "$PEER_NAME" "home_public_key_path" "/etc/wireguard/home-public.key")
    
    # Generate private key if it doesn't exist
    if [[ ! -f "$private_key_path" ]]; then
        log "Generating peer private key..."
        generate_wg_private_key > "$private_key_path"
        chmod 600 "$private_key_path"
        log_success "Peer private key generated: $private_key_path"
    else
        log "Peer private key already exists: $private_key_path"
    fi
    
    # Generate public key if it doesn't exist
    if [[ ! -f "$public_key_path" ]]; then
        log "Generating peer public key..."
        local private_key
        private_key=$(cat "$private_key_path")
        generate_wg_public_key "$private_key" > "$public_key_path"
        chmod 644 "$public_key_path"
        log_success "Peer public key generated: $public_key_path"
    else
        log "Peer public key already exists: $public_key_path"
    fi
    
    # Store paths for later use
    PRIVATE_KEY_PATH="$private_key_path"
    PUBLIC_KEY_PATH="$public_key_path"
}

generate_wg_config() {
    log "Generating WireGuard configuration for peer: $PEER_NAME"
    
    # Get peer configuration
    local peer_address peer_endpoint peer_keepalive vps_public_key_path
    peer_address=$(get_peer_config "$PEER_NAME" "address")
    peer_endpoint=$(get_peer_config "$PEER_NAME" "endpoint")
    peer_keepalive=$(get_peer_config "$PEER_NAME" "keepalive" "25")
    
    # Get VPS configuration
    local vps_public_key vps_subnet
    vps_public_key_path=$(get_config_value "vps.wireguard.public_key_path" "/etc/wireguard/vps-public.key")
    vps_subnet=$(get_config_value "vps.wireguard.subnet_cidr" "10.8.0.0/24")
    
    # Read private key
    local private_key
    if [[ -f "$PRIVATE_KEY_PATH" ]]; then
        private_key=$(cat "$PRIVATE_KEY_PATH")
    else
        log_error "Private key not found: $PRIVATE_KEY_PATH"
        exit 1
    fi
    
    # For home setup, we need to get VPS public key from the user or config
    # Since we can't access VPS files from home machine, we'll create a placeholder
    local vps_public_key="VPS_PUBLIC_KEY_NEEDED"
    
    # Check if VPS public key is available in a shared location or config
    if [[ -f "/tmp/vps-public.key" ]]; then
        vps_public_key=$(cat "/tmp/vps-public.key")
        log "Using VPS public key from /tmp/vps-public.key"
    else
        log_warning "VPS public key not available - configuration will need manual completion"
    fi
    
    # Generate WireGuard configuration using template
    local template_path="$SCRIPT_DIR/../templates/wg0.conf.template"
    local config_path="/etc/wireguard/wg0.conf"
    
    if [[ -f "$template_path" ]]; then
        substitute_template "$template_path" "$config_path" \
            "PRIVATE_KEY=$private_key" \
            "PEER_ADDRESS=$peer_address" \
            "VPS_PUBLIC_KEY=$vps_public_key" \
            "VPS_ENDPOINT=$peer_endpoint" \
            "VPS_SUBNET=$vps_subnet" \
            "KEEPALIVE=$peer_keepalive"
    else
        # Generate config directly if template doesn't exist
        log "Template not found, generating configuration directly..."
        generate_wg_config_direct "$config_path" "$private_key" "$peer_address" \
            "$vps_public_key" "$peer_endpoint" "$vps_subnet" "$peer_keepalive"
    fi
    
    # Set proper permissions
    chmod 600 "$config_path"
    
    log_success "WireGuard configuration generated: $config_path"
    
    if [[ "$vps_public_key" == "VPS_PUBLIC_KEY_NEEDED" ]]; then
        log_warning "Configuration requires VPS public key - edit $config_path before starting WireGuard"
    fi
}

generate_wg_config_direct() {
    local config_path="$1"
    local private_key="$2"
    local peer_address="$3"
    local vps_public_key="$4"
    local vps_endpoint="$5"
    local vps_subnet="$6"
    local keepalive="$7"
    
    # Backup existing config
    backup_file "$config_path"
    
    # Generate configuration
    cat > "$config_path" << EOF
# Home Machine WireGuard Configuration
# Peer: $PEER_NAME
# Generated by vps-proxy-hub home setup

[Interface]
PrivateKey = $private_key
Address = $peer_address
DNS = 1.1.1.1, 8.8.8.8

# Routes for accessing services through the tunnel
# This routes traffic to the VPS subnet through the tunnel
PostUp = ip route add $vps_subnet dev %i

# Clean up routes on shutdown
PostDown = ip route del $vps_subnet dev %i 2>/dev/null || true

[Peer]
# VPS WireGuard Server
PublicKey = $vps_public_key
Endpoint = $vps_endpoint
AllowedIPs = $vps_subnet

# Keep connection alive through NAT/firewalls
PersistentKeepalive = $keepalive
EOF

    if [[ "$vps_public_key" == "VPS_PUBLIC_KEY_NEEDED" ]]; then
        # Comment out the peer section if VPS key is not available
        sed -i 's/^PublicKey = VPS_PUBLIC_KEY_NEEDED/# PublicKey = REPLACE_WITH_VPS_PUBLIC_KEY/' "$config_path"
        sed -i '/^\[Peer\]/a # CONFIGURATION INCOMPLETE - VPS public key needed' "$config_path"
        sed -i '/^\[Peer\]/a # Get the VPS public key and replace the placeholder above' "$config_path"
    fi
    
    log "Generated WireGuard configuration directly"
}

enable_wireguard_service() {
    log "Configuring WireGuard service for peer: $PEER_NAME"
    
    # Check if VPS public key is available
    if grep -q "VPS_PUBLIC_KEY_NEEDED\|REPLACE_WITH_VPS_PUBLIC_KEY" /etc/wireguard/wg0.conf; then
        log_warning "WireGuard service not started - VPS public key required"
        log "Complete the configuration and run: systemctl start wg-quick@wg0"
        return 0
    fi
    
    # Stop service if running
    if systemctl is-active --quiet wg-quick@wg0; then
        log "Stopping existing WireGuard service..."
        systemctl stop wg-quick@wg0
    fi
    
    # Test configuration
    if ! wg-quick up wg0 --dry-run &>/dev/null; then
        log_error "WireGuard configuration test failed"
        log "Check configuration: wg-quick up wg0 --dry-run"
        return 1
    fi
    
    # Enable and start WireGuard
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
    
    # Wait for service to be ready
    wait_for_service "wg-quick@wg0"
    
    # Verify interface is up
    if ip link show wg0 &>/dev/null; then
        log_success "WireGuard interface wg0 is up"
        
        # Test connectivity to VPS
        local vps_ip
        vps_ip=$(get_config_value "vps.wireguard.vps_address" "10.8.0.1/24")
        vps_ip="${vps_ip%/*}"  # Remove CIDR suffix
        
        if ping -c 1 -W 5 "$vps_ip" &>/dev/null; then
            log_success "Successfully connected to VPS through WireGuard tunnel"
        else
            log_warning "WireGuard interface is up but cannot reach VPS ($vps_ip)"
            log "This may be normal if the VPS hasn't been configured with this peer yet"
        fi
    else
        log_error "WireGuard interface wg0 failed to start"
        log "Check logs: journalctl -u wg-quick@wg0"
        return 1
    fi
}

display_connection_instructions() {
    log "WireGuard peer setup information:"
    
    # Show interface status
    if command -v wg &> /dev/null && ip link show wg0 &>/dev/null; then
        echo "--- WireGuard Status ---"
        wg show wg0 2>/dev/null || log_warning "WireGuard interface not ready"
    fi
    
    # Display the peer information for VPS setup
    display_peer_info "$PEER_NAME" "$PUBLIC_KEY_PATH"
}

# Run main function
main "$@"