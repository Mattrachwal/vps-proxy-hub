#!/bin/bash
# VPS Setup - UFW Firewall Configuration
# Configures UFW firewall with minimal required ports for security

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

main() {
    log "Starting UFW firewall configuration..."

    check_root
    check_config

    # Install UFW if not present
    install_package "ufw"

    # Get open ports from config
    local open_ports
    open_ports=$(get_config_array "vps.firewall_open_ports")

    # Reset UFW to defaults (removes all rules)
    log "Resetting UFW to defaults..."
    ufw --force reset

    # Set default policies
    log "Setting default UFW policies..."
    ufw default deny incoming
    ufw default allow outgoing

    # Allow configured ports
    log "Configuring firewall rules..."

    if [[ -n "$open_ports" ]]; then
        while IFS= read -r port; do
            if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
                case "$port" in
                    22)
                        log "Allowing SSH on port $port"
                        ufw allow "$port/tcp" comment "SSH"
                        ;;
                    80)
                        log "Allowing HTTP on port $port"
                        ufw allow "$port/tcp" comment "HTTP"
                        ;;
                    443)
                        log "Allowing HTTPS on port $port"
                        ufw allow "$port/tcp" comment "HTTPS"
                        ;;
                    51820)
                        log "Allowing WireGuard on port $port"
                        ufw allow "$port/udp" comment "WireGuard"
                        ;;
                    *)
                        log "Allowing port $port"
                        ufw allow "$port" comment "Custom"
                        ;;
                esac
            fi
        done <<< "$open_ports"
    else
        log_warning "No open ports specified in config, using defaults"
        ufw allow 22/tcp comment "SSH"
        ufw allow 80/tcp comment "HTTP"
        ufw allow 443/tcp comment "HTTPS"
        ufw allow 51820/udp comment "WireGuard"
    fi

    # Configure UFW for WireGuard forwarding
    log "Configuring UFW for WireGuard traffic forwarding..."

    # Get WireGuard subnet from config
    local wg_subnet
    wg_subnet=$(get_config_value "vps.wireguard.subnet_cidr" "10.8.0.0/24")

    # Get default network interface
    local default_interface
    default_interface=$(get_default_interface)

    if [[ -n "$default_interface" ]]; then
        log "Default network interface: $default_interface"

        # Forwarded packets require the 'route' keyword in UFW
        # Allow routed traffic from wg0 to the Internet via default interface
        ufw route allow in on wg0 out on "$default_interface" comment "WireGuard -> Internet"

        # (Optional) If you NEED replies from Internet to wg0 as routed flows, uncomment below.
        # In most WG egress gateway scenarios you do NOT need this.
        # ufw route allow in on "$default_interface" out on wg0 comment "Internet -> WireGuard"

        # Allow traffic within WireGuard subnet
        ufw allow from "$wg_subnet" to "$wg_subnet" comment "WireGuard internal"
    else
        log_warning "Could not determine default network interface"
    fi

    # Ensure UFW default forward policy is ACCEPT for routing/NAT
    backup_file "/etc/default/ufw"
    if grep -q '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw; then
        sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    else
        echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> /etc/default/ufw
    fi
    log "Set DEFAULT_FORWARD_POLICY to ACCEPT"

    # Configure UFW before rules for NAT
    backup_file "/etc/ufw/before.rules"

    # Add NAT rules to before.rules if not already present
    if ! grep -q "vps-proxy-hub" /etc/ufw/before.rules; then
        log "Adding NAT rules to UFW before.rules..."

        # Create temporary file with NAT rules
        cat > /tmp/ufw-nat-rules << EOF

# vps-proxy-hub: NAT rules for WireGuard
*nat
:POSTROUTING ACCEPT [0:0]

# Forward WireGuard traffic through the default interface
-A POSTROUTING -s $wg_subnet -o $default_interface -j MASQUERADE

COMMIT

# vps-proxy-hub: End of NAT rules
EOF

        # Insert NAT rules at the beginning of before.rules (after initial comments)
        local temp_file="/tmp/before-rules-new"
        {
            # Copy everything up to the first filter table
            sed '/^\*filter/,$d' /etc/ufw/before.rules
            # Add our NAT rules
            cat /tmp/ufw-nat-rules
            # Add the rest of the file from filter table onwards
            sed -n '/^\*filter/,$p' /etc/ufw/before.rules
        } > "$temp_file"

        mv "$temp_file" /etc/ufw/before.rules
        rm -f /tmp/ufw-nat-rules

        log "Added NAT rules to UFW configuration"
    else
        log "NAT rules already present in UFW configuration"
    fi

    # Configure UFW sysctl settings for forwarding
    backup_file "/etc/ufw/sysctl.conf"

    if ! grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*1' /etc/ufw/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/ufw/sysctl.conf
        log "Enabled IP forwarding in UFW sysctl config"
    fi

    # Configure logging
    log "Configuring UFW logging..."
    ufw logging low

    # Enable UFW (or reload if already enabled)
    if systemctl is-active --quiet ufw; then
        log "Reloading UFW firewall..."
        ufw --force reload
    else
        log "Enabling UFW firewall..."
        ufw --force enable
    fi

    # Show status
    log "UFW firewall status:"
    ufw status verbose

    log_success "UFW firewall configuration completed"
}

# Run main function
main "$@"
