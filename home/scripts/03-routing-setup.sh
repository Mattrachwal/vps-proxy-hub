#!/bin/bash
# Home Machine Setup - Routing and Network Configuration
# Configures routing, Docker networking, and service accessibility

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
        exit 1
    fi
    
    PEER_NAME="$peer_name"
    
    log "Starting routing and network setup for peer: $PEER_NAME"
    
    check_root
    check_config
    
    # Validate peer name exists in config
    if ! validate_peer_name "$PEER_NAME"; then
        log_error "Peer '$PEER_NAME' not found in configuration"
        exit 1
    fi
    
    # Configure system routing
    setup_system_routing
    
    # Configure Docker networking if Docker is present
    setup_docker_networking
    
    # Configure service routing
    setup_service_routing
    
    # Configure firewall rules for services
    setup_service_firewall
    
    log_success "Routing and network setup completed for peer: $PEER_NAME"
}

setup_system_routing() {
    log "Configuring system routing for peer: $PEER_NAME"
    
    # Get VPS subnet from config
    local vps_subnet
    vps_subnet=$(get_config_value "vps.wireguard.subnet_cidr" "10.8.0.0/24")
    
    # Ensure IP forwarding is enabled for local services
    log "Enabling IP forwarding..."
    
    # Set kernel parameter
    sysctl -w net.ipv4.ip_forward=1
    
    # Make permanent
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        log "IP forwarding enabled permanently"
    fi
    
    # Configure routing for better performance
    cat > /etc/sysctl.d/99-vps-proxy-hub-home.conf << EOF
# VPS Proxy Hub - Home machine network tuning

# Enable IP forwarding for local services
net.ipv4.ip_forward=1

# Network performance tuning
net.core.rmem_default = 262144
net.core.rmem_max = 8388608
net.core.wmem_default = 262144
net.core.wmem_max = 8388608

# TCP tuning
net.ipv4.tcp_rmem = 4096 65536 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.ipv4.tcp_congestion_control = bbr

# Connection tracking
net.netfilter.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
EOF
    
    # Apply settings
    sysctl -p /etc/sysctl.d/99-vps-proxy-hub-home.conf
    
    log_success "System routing configured"
}

setup_docker_networking() {
    if ! command -v docker &> /dev/null; then
        log "Docker not found, skipping Docker networking setup"
        return 0
    fi
    
    log "Configuring Docker networking for peer: $PEER_NAME"
    
    # Check which sites on this peer use Docker
    local docker_sites=()
    
    if command -v yq &> /dev/null; then
        while IFS= read -r site_name; do
            if [[ -n "$site_name" ]]; then
                local site_peer site_docker
                site_peer=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE")
                site_docker=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker" "$CONFIG_FILE")
                
                if [[ "$site_peer" == "$PEER_NAME" && "$site_docker" == "true" ]]; then
                    docker_sites+=("$site_name")
                fi
            fi
        done < <(yq eval '.sites[] | .name' "$CONFIG_FILE")
    else
        log "Using basic YAML parsing for Docker site detection"
        # Basic parsing would be complex here, so just note it
        log_warning "Install yq for automatic Docker site detection"
    fi
    
    if [[ ${#docker_sites[@]} -eq 0 ]]; then
        log "No Docker-based sites found for this peer"
        return 0
    fi
    
    log "Found Docker-based sites: ${docker_sites[*]}"
    
    # Create custom Docker networks for better isolation
    for site in "${docker_sites[@]}"; do
        setup_docker_site_network "$site"
    done
    
    # Configure Docker daemon for better networking
    configure_docker_daemon
    
    log_success "Docker networking configured"
}

setup_docker_site_network() {
    local site_name="$1"
    
    log "Setting up Docker network for site: $site_name"
    
    # Get network configuration
    local docker_network
    if command -v yq &> /dev/null; then
        docker_network=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker_network" "$CONFIG_FILE" 2>/dev/null)
        if [[ "$docker_network" == "null" || -z "$docker_network" ]]; then
            docker_network="${site_name}_net"
        fi
    else
        docker_network="${site_name}_net"
    fi
    
    # Check if network exists
    if docker network ls --format "{{.Name}}" | grep -q "^${docker_network}$"; then
        log "Docker network $docker_network already exists"
    else
        log "Creating Docker network: $docker_network"
        docker network create \
            --driver bridge \
            --opt com.docker.network.bridge.name="br-${site_name}" \
            "$docker_network"
        log_success "Created Docker network: $docker_network"
    fi
    
    # Create helper script for this site
    create_docker_helper_script "$site_name" "$docker_network"
}

create_docker_helper_script() {
    local site_name="$1"
    local docker_network="$2"
    
    local script_path="/usr/local/bin/docker-${site_name}-run"
    
    cat > "$script_path" << EOF
#!/bin/bash
# Helper script for running Docker containers for site: $site_name
# Generated by vps-proxy-hub home setup

set -euo pipefail

NETWORK="$docker_network"
CONTAINER_NAME="\${1:-$site_name}"
IMAGE="\${2:-}"

if [[ -z "\$IMAGE" ]]; then
    echo "Usage: \$0 [container-name] <image> [docker-run-args...]"
    echo "Example: \$0 $site_name nginx:latest -p 8080:80"
    exit 1
fi

shift 2  # Remove container name and image from args

echo "Starting container '\$CONTAINER_NAME' on network '\$NETWORK'"

# Stop and remove existing container if it exists
if docker ps -a --format "{{.Names}}" | grep -q "^\$CONTAINER_NAME\$"; then
    echo "Stopping existing container..."
    docker stop "\$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "\$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Run the container
docker run -d \\
    --name "\$CONTAINER_NAME" \\
    --network "\$NETWORK" \\
    --restart unless-stopped \\
    "\$@" \\
    "\$IMAGE"

echo "Container '\$CONTAINER_NAME' started successfully"
echo "Network: \$NETWORK"
echo "Container IP: \$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "\$CONTAINER_NAME")"
EOF
    
    chmod +x "$script_path"
    log "Created Docker helper script: $script_path"
}

configure_docker_daemon() {
    log "Configuring Docker daemon for optimal networking..."
    
    local daemon_config="/etc/docker/daemon.json"
    
    # Backup existing config
    backup_file "$daemon_config"
    
    # Create or update daemon.json
    local config_content
    if [[ -f "$daemon_config" ]]; then
        config_content=$(cat "$daemon_config")
    else
        config_content="{}"
    fi
    
    # Add VPS proxy hub specific configuration
    if command -v jq &> /dev/null; then
        echo "$config_content" | jq '. + {
            "log-driver": "json-file",
            "log-opts": {
                "max-size": "10m",
                "max-file": "3"
            },
            "storage-driver": "overlay2",
            "userland-proxy": false,
            "experimental": false,
            "metrics-addr": "127.0.0.1:9323",
            "bip": "172.17.0.1/16"
        }' > "$daemon_config"
    else
        # Simple configuration without jq
        cat > "$daemon_config" << 'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "userland-proxy": false,
    "experimental": false,
    "bip": "172.17.0.1/16"
}
EOF
    fi
    
    # Restart Docker to apply changes
    if systemctl is-active --quiet docker; then
        log "Restarting Docker daemon..."
        systemctl restart docker
        wait_for_service "docker"
        log_success "Docker daemon restarted with new configuration"
    fi
}

setup_service_routing() {
    log "Configuring service routing for peer: $PEER_NAME"
    
    # Get all sites for this peer
    local peer_sites=()
    
    if command -v yq &> /dev/null; then
        while IFS= read -r site_name; do
            if [[ -n "$site_name" ]]; then
                local site_peer
                site_peer=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE")
                
                if [[ "$site_peer" == "$PEER_NAME" ]]; then
                    peer_sites+=("$site_name")
                fi
            fi
        done < <(yq eval '.sites[] | .name' "$CONFIG_FILE")
    fi
    
    if [[ ${#peer_sites[@]} -eq 0 ]]; then
        log "No sites configured for peer: $PEER_NAME"
        return 0
    fi
    
    log "Configuring routing for sites: ${peer_sites[*]}"
    
    # For each site, ensure services are accessible
    for site in "${peer_sites[@]}"; do
        configure_site_routing "$site"
    done
    
    log_success "Service routing configured"
}

configure_site_routing() {
    local site_name="$1"
    
    log "Configuring routing for site: $site_name"
    
    # Get site configuration
    local is_docker port container_name
    
    if command -v yq &> /dev/null; then
        is_docker=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker" "$CONFIG_FILE")
        port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.port" "$CONFIG_FILE")
        container_name=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.container_name" "$CONFIG_FILE")
    fi
    
    if [[ "$is_docker" == "true" ]]; then
        log "Site $site_name uses Docker container: ${container_name:-$site_name}"
        # Docker networking handles routing automatically
    else
        log "Site $site_name uses direct port: $port"
        # Ensure service is accessible on the specified port
        if [[ -n "$port" && "$port" != "null" ]]; then
            # Add any specific routing rules if needed
            log "Service should be running on localhost:$port"
        fi
    fi
}

setup_service_firewall() {
    log "Configuring firewall for services on peer: $PEER_NAME"
    
    # Check if UFW is available and configured
    if ! command -v ufw &> /dev/null; then
        install_package "ufw"
    fi
    
    # Enable UFW if not already enabled
    if ! ufw status | grep -q "Status: active"; then
        log "Enabling UFW firewall..."
        ufw --force enable
    fi
    
    # Allow VPS to access services through WireGuard interface
    local vps_subnet
    vps_subnet=$(get_config_value "vps.wireguard.subnet_cidr" "10.8.0.0/24")
    
    # Allow traffic from VPS subnet
    if ! ufw status | grep -q "$vps_subnet"; then
        log "Allowing traffic from VPS subnet: $vps_subnet"
        ufw allow from "$vps_subnet" comment "VPS Proxy Hub"
    fi
    
    # Get peer-specific ports that need to be accessible
    local peer_ports=()
    
    if command -v yq &> /dev/null; then
        while IFS= read -r site_name; do
            if [[ -n "$site_name" ]]; then
                local site_peer site_docker port
                site_peer=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE")
                site_docker=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker" "$CONFIG_FILE")
                port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.port" "$CONFIG_FILE")
                
                if [[ "$site_peer" == "$PEER_NAME" && "$site_docker" != "true" && -n "$port" && "$port" != "null" ]]; then
                    peer_ports+=("$port")
                fi
            fi
        done < <(yq eval '.sites[] | .name' "$CONFIG_FILE")
    fi
    
    # Allow access to service ports from VPS subnet
    for port in "${peer_ports[@]}"; do
        if ! ufw status | grep -q "$port.*$vps_subnet"; then
            log "Allowing access to port $port from VPS subnet"
            ufw allow from "$vps_subnet" to any port "$port" comment "VPS Proxy Hub - Service Port"
        fi
    done
    
    log_success "Service firewall configured"
}

# Run main function
main "$@"