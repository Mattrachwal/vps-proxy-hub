#!/bin/bash
# VPS Setup - System Update and Basic Configuration
# Updates system packages, configures timezone, and sets up swap if needed

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

main() {
    log "Starting system update and configuration..."
    
    check_root
    check_config
    install_yq
    
    # Get configuration values
    local timezone
    timezone=$(get_config_value "vps.timezone" "UTC")
    
    local create_swap
    create_swap=$(get_config_value "ops.create_swapfile_gb" "0")
    
    # Update system packages
    log "Updating system packages..."
    if command -v apt-get &> /dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get upgrade -y
        apt-get autoremove -y
        apt-get autoclean
    elif command -v yum &> /dev/null; then
        yum update -y
        yum clean all
    elif command -v dnf &> /dev/null; then
        dnf update -y
        dnf clean all
    else
        log_error "No supported package manager found"
        exit 1
    fi
    
    # Install essential packages
    log "Installing essential packages..."
    local essential_packages="curl wget unzip jq net-tools"
    
    if command -v apt-get &> /dev/null; then
        apt-get install -y $essential_packages
    elif command -v yum &> /dev/null; then
        yum install -y $essential_packages
    elif command -v dnf &> /dev/null; then
        dnf install -y $essential_packages
    fi
    
    # Set timezone
    if [[ "$timezone" != "UTC" ]]; then
        log "Setting timezone to $timezone..."
        timedatectl set-timezone "$timezone"
        log_success "Timezone set to $(timedatectl show --property=Timezone --value)"
    fi
    
    # Configure system limits
    log "Configuring system limits..."
    cat >> /etc/security/limits.conf << 'EOF'
# VPS Proxy Hub - Increase limits for network services
* soft nofile 65536
* hard nofile 65536
* soft nproc 32768
* hard nproc 32768
EOF
    
    # Configure sysctl settings
    log "Configuring kernel parameters..."
    local ipv4_forward
    ipv4_forward=$(get_config_value "vps.sysctl.ipv4_forward" "true")
    
    cat > /etc/sysctl.d/99-vps-proxy-hub.conf << EOF
# VPS Proxy Hub - Network and performance tuning

# Enable IP forwarding for WireGuard
net.ipv4.ip_forward=$([[ "$ipv4_forward" == "true" ]] && echo "1" || echo "0")
net.ipv6.conf.all.forwarding=0

# Network performance tuning
net.core.rmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_default = 262144
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 5000

# TCP tuning
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1

# Security hardening
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# File descriptor limits
fs.file-max = 2097152
EOF

    # Apply basic sysctl settings (skip conntrack settings for now)
    log "Applying initial sysctl settings..."
    sysctl -p /etc/sysctl.d/99-vps-proxy-hub.conf || {
        log_warning "Some sysctl settings couldn't be applied yet (will be set after reboot)"
    }
    
    # Create a separate conntrack configuration that will be applied later
    cat > /etc/sysctl.d/99-vps-proxy-hub-conntrack.conf << 'EOF'
# VPS Proxy Hub - Connection tracking settings
# These require netfilter modules to be loaded

# Connection tracking (will be applied when modules are loaded)
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
EOF
    
    # Load netfilter modules
    load_netfilter_modules
    
    # Create swap file if requested
    if [[ "$create_swap" != "0" && "$create_swap" != "" ]]; then
        create_swapfile "$create_swap"
    fi
    
    # Configure log rotation for our log file
    cat > /etc/logrotate.d/vps-proxy-hub << 'EOF'
/var/log/vps-proxy-hub.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0644 root root
}
EOF
    
    log_success "System update and configuration completed"
}

# Load netfilter modules needed for connection tracking
load_netfilter_modules() {
    log "Loading netfilter modules..."
    
    # Try to load connection tracking modules
    local modules=("nf_conntrack" "nf_conntrack_ipv4" "xt_conntrack")
    
    for module in "${modules[@]}"; do
        if modprobe "$module" 2>/dev/null; then
            log "Loaded module: $module"
        else
            log_warning "Could not load module: $module (may not be available)"
        fi
    done
    
    # Add modules to be loaded at boot
    cat > /etc/modules-load.d/vps-proxy-hub.conf << 'EOF'
# VPS Proxy Hub - Required kernel modules
nf_conntrack
xt_conntrack
EOF
    
    # Try to apply conntrack settings now that modules might be loaded
    if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        log "Applying connection tracking settings..."
        sysctl -p /etc/sysctl.d/99-vps-proxy-hub-conntrack.conf
    else
        log_warning "Connection tracking settings will be applied after reboot"
    fi
}

# Create swap file if it doesn't exist
create_swapfile() {
    local size_gb="$1"
    local swapfile="/swapfile"
    
    # Check if swap is already configured
    if swapon --show | grep -q "$swapfile"; then
        log "Swapfile already exists and is active"
        return 0
    fi
    
    if [[ -f "$swapfile" ]]; then
        log "Swapfile exists but is not active, activating..."
        swapon "$swapfile"
        return 0
    fi
    
    log "Creating ${size_gb}GB swap file..."
    
    # Create swap file
    fallocate -l "${size_gb}G" "$swapfile" || dd if=/dev/zero of="$swapfile" bs=1024 count=$((size_gb * 1024 * 1024))
    
    # Set permissions
    chmod 600 "$swapfile"
    
    # Make it a swap file
    mkswap "$swapfile"
    
    # Enable swap
    swapon "$swapfile"
    
    # Add to fstab for persistence
    if ! grep -q "$swapfile" /etc/fstab; then
        echo "$swapfile none swap sw 0 0" >> /etc/fstab
    fi
    
    log_success "Created and activated ${size_gb}GB swap file"
}

# Run main function
main "$@"