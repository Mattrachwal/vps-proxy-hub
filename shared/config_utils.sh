#!/bin/bash
# VPS Proxy Hub - Configuration Utilities
# Enhanced configuration parsing with computed values and validation
# Reduces redundancy by calculating common values from base settings

set -euo pipefail

# Source core utilities (use absolute path to avoid SCRIPT_DIR conflicts)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

# =============================================================================
# COMPUTED CONFIGURATION VALUES
# =============================================================================

# Get the computed VPS endpoint (public_ip:wireguard_port)
# Usage: get_vps_endpoint
get_vps_endpoint() {
    local public_ip listen_port
    public_ip=$(get_config_value "vps.public_ip")
    listen_port=$(get_config_value "vps.wireguard.listen_port")
    
    if [[ -z "$public_ip" || "$public_ip" == "null" ]]; then
        log_error "vps.public_ip not configured"
        return 1
    fi
    
    if [[ -z "$listen_port" || "$listen_port" == "null" ]]; then
        log_error "vps.wireguard.listen_port not configured"
        return 1
    fi
    
    echo "${public_ip}:${listen_port}"
}

# Get endpoint for a specific peer (uses computed VPS endpoint)
# Usage: get_peer_endpoint "peer_name"
get_peer_endpoint() {
    local peer_name="$1"
    
    # Check if peer has custom endpoint first
    local custom_endpoint
    custom_endpoint=$(get_peer_config "$peer_name" "endpoint" "")
    
    if [[ -n "$custom_endpoint" && "$custom_endpoint" != "null" ]]; then
        echo "$custom_endpoint"
    else
        # Use computed VPS endpoint
        get_vps_endpoint
    fi
}

# Get peer configuration with defaults applied
# Usage: get_peer_config_with_defaults "peer_name" "config_key"
get_peer_config_with_defaults() {
    local peer_name="$1"
    local key="$2"
    
    # Try to get peer-specific value first
    local value
    value=$(get_peer_config "$peer_name" "$key" "")
    
    if [[ -n "$value" && "$value" != "null" ]]; then
        echo "$value"
        return 0
    fi
    
    # Fall back to default value
    local default_key="defaults.peer.${key}"
    local default_value
    default_value=$(get_config_value "$default_key" "")
    
    if [[ -n "$default_value" && "$default_value" != "null" ]]; then
        echo "$default_value"
        return 0
    fi
    
    # Return empty if no default found
    echo ""
}

# Get complete firewall ports list (configured + computed)
# Usage: get_all_firewall_ports
get_all_firewall_ports() {
    local configured_ports ssh_port wg_port
    
    # Get explicitly configured ports
    configured_ports=$(get_config_array "vps.firewall_open_ports" | tr '\n' ' ')
    
    # Get computed ports that should always be open
    ssh_port=$(get_config_value "vps.ssh_port" "22")
    wg_port=$(get_config_value "vps.wireguard.listen_port" "51820")
    
    # Combine and deduplicate
    local all_ports="$configured_ports $ssh_port $wg_port 80 443"
    echo "$all_ports" | tr ' ' '\n' | sort -n | uniq | tr '\n' ' '
}

# =============================================================================
# CONFIGURATION VALIDATION
# =============================================================================

# Validate that required configuration sections exist
validate_base_config() {
    log "Validating base configuration..."
    
    local errors=0
    
    # Check required VPS settings
    if ! validate_config_value "vps.public_ip" "VPS public IP"; then
        ((errors++))
    fi
    
    if ! validate_config_value "vps.wireguard.subnet_cidr" "WireGuard subnet"; then
        ((errors++))
    fi
    
    if ! validate_config_value "vps.wireguard.vps_address" "VPS WireGuard address"; then
        ((errors++))
    fi
    
    if ! validate_config_value "vps.wireguard.listen_port" "WireGuard listen port"; then
        ((errors++))
    fi
    
    # Check TLS settings
    if ! validate_config_value "tls.email" "TLS email"; then
        ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        log_error "Configuration validation failed with $errors error(s)"
        return 1
    fi
    
    log_success "Base configuration validation passed"
    return 0
}

# Validate a single configuration value exists
validate_config_value() {
    local key="$1"
    local description="$2"
    
    local value
    value=$(get_config_value "$key")
    
    if [[ -z "$value" || "$value" == "null" ]]; then
        log_error "Missing required configuration: $key ($description)"
        return 1
    fi
    
    return 0
}

# Validate peer configuration
validate_peer_config() {
    local peer_name="$1"
    
    log "Validating peer configuration: $peer_name"
    
    # Check peer exists
    if ! validate_peer_name "$peer_name"; then
        log_error "Peer '$peer_name' not found in configuration"
        return 1
    fi
    
    # Check peer has required address
    local peer_address
    peer_address=$(get_peer_config "$peer_name" "address")
    if [[ -z "$peer_address" || "$peer_address" == "null" ]]; then
        log_error "Peer '$peer_name' missing required 'address' field"
        return 1
    fi
    
    # Validate address format (should include CIDR)
    if [[ ! "$peer_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        log_error "Peer '$peer_name' address '$peer_address' should include CIDR notation (e.g., 10.8.0.2/32)"
        return 1
    fi
    
    log_success "Peer '$peer_name' configuration is valid"
    return 0
}

# Validate site configuration
validate_site_config() {
    local site_name="$1"
    
    log "Validating site configuration: $site_name"
    
    # Check required fields exist
    local server_names peer_name
    
    if command -v yq &> /dev/null; then
        server_names=$(yq eval ".sites[] | select(.name == \"$site_name\") | .server_names | length" "$CONFIG_FILE" 2>/dev/null || echo "0")
        peer_name=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE" 2>/dev/null || echo "")
    else
        # Basic validation without yq
        if ! grep -q "name:.*\"\\?${site_name}\"\\?" "$CONFIG_FILE"; then
            log_error "Site '$site_name' not found in configuration"
            return 1
        fi
        server_names="1"  # Assume exists if we found the site
        peer_name=$(grep -A 10 "name:.*\"\\?${site_name}\"\\?" "$CONFIG_FILE" | grep "peer:" | head -1 | sed 's/.*peer:[[:space:]]*//' | sed 's/[\"'\'']//g')
    fi
    
    # Validate server names exist
    if [[ "$server_names" == "0" || -z "$server_names" ]]; then
        log_error "Site '$site_name' missing server_names"
        return 1
    fi
    
    # Validate peer exists
    if [[ -z "$peer_name" || "$peer_name" == "null" ]]; then
        log_error "Site '$site_name' missing peer assignment"
        return 1
    fi
    
    if ! validate_peer_name "$peer_name"; then
        log_error "Site '$site_name' references unknown peer '$peer_name'"
        return 1
    fi
    
    log_success "Site '$site_name' configuration is valid"
    return 0
}

# Migration functions removed since starting fresh with v2 format

# =============================================================================
# CONFIGURATION DISPLAY
# =============================================================================

# Show computed configuration values for debugging
show_computed_config() {
    log "Computed configuration values:"
    echo ""
    
    echo "VPS Endpoint: $(get_vps_endpoint 2>/dev/null || echo 'ERROR: Cannot compute')"
    echo "Firewall Ports: $(get_all_firewall_ports)"
    echo ""
    
    echo "Peer Endpoints:"
    if command -v yq &> /dev/null; then
        local peer_names
        peer_names=$(yq eval '.peers[] | .name' "$CONFIG_FILE" 2>/dev/null || echo "")
        while IFS= read -r peer_name; do
            if [[ -n "$peer_name" && "$peer_name" != "null" ]]; then
                local endpoint
                endpoint=$(get_peer_endpoint "$peer_name" 2>/dev/null || echo "ERROR")
                echo "  - $peer_name: $endpoint"
            fi
        done <<< "$peer_names"
    else
        echo "  (install yq for detailed peer info)"
    fi
    echo ""
}

# Log successful loading of configuration utilities
log_debug "Configuration utilities loaded successfully"