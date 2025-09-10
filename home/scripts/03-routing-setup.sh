#!/bin/bash
# Home Machine Setup - Routing and Network Configuration
# Configures routing, Docker networking, and service accessibility

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../shared/utils.sh"

# Global variables
PEER_NAME=""
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../config.yaml}"

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

    if ! validate_peer_name "$PEER_NAME"; then
        log_error "Peer '$PEER_NAME' not found in configuration"
        exit 1
    fi

    setup_system_routing
    setup_docker_networking
    setup_service_routing
    setup_service_firewall

    log_success "Routing and network setup completed for peer: $PEER_NAME"
}

setup_system_routing() {
    log "Configuring system routing for peer: $PEER_NAME"

    # Get VPS subnet (unused here but kept for context extensibility)
    local vps_subnet
    vps_subnet=$(get_config_value "vps.wireguard.subnet_cidr" "10.8.0.0/24")

    log "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    if ! grep -qE '^\s*net.ipv4.ip_forward\s*=\s*1\s*$' /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        log "IP forwarding enabled permanently"
    fi

    # Write tuning file
    cat > /etc/sysctl.d/99-vps-proxy-hub-home.conf << 'EOF'
# VPS Proxy Hub - Home machine network tuning

# Enable IP forwarding for local services
net.ipv4.ip_forward = 1

# Network performance tuning
net.core.rmem_default = 262144
net.core.rmem_max = 8388608
net.core.wmem_default = 262144
net.core.wmem_max = 8388608

# TCP tuning
net.ipv4.tcp_rmem = 4096 65536 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.ipv4.tcp_congestion_control = bbr

# Connection tracking (apply conditionally if available)
# net.netfilter.nf_conntrack_max = 131072
# net.netfilter.nf_conntrack_tcp_timeout_established = 7200
EOF

    # Ensure conntrack exists, then safely apply conntrack keys
    ensure_conntrack

    # Apply sysctl file without failing the whole script on missing keys
    sysctl -p /etc/sysctl.d/99-vps-proxy-hub-home.conf >/dev/null || true

    # If conntrack keys are present now, set them explicitly
    [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]] \
        && sysctl -w net.netfilter.nf_conntrack_max=131072 >/dev/null || true
    [[ -e /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established ]] \
        && sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=7200 >/dev/null || true

    log_success "System routing configured"
}

ensure_conntrack() {
    # If the files already exist, nothing to do
    if [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        return 0
    fi

    # Try to load the module if available
    if command -v modprobe >/dev/null 2>&1; then
        if modprobe -n nf_conntrack >/dev/null 2>&1; then
            log "Loading nf_conntrack kernel module..."
            modprobe nf_conntrack || true
            echo nf_conntrack > /etc/modules-load.d/nf_conntrack.conf
        else
            log_warning "nf_conntrack module not present (kernel/config). Skipping conntrack tuning."
        fi
    else
        log_warning "modprobe not found; cannot load nf_conntrack. Skipping conntrack tuning."
    fi
}

setup_docker_networking() {
    if ! command -v docker >/dev/null 2>&1; then
        log "Docker not found, skipping Docker networking setup"
        return 0
    fi

    log "Configuring Docker networking for peer: $PEER_NAME"

    local docker_sites=()
    if command -v yq >/dev/null 2>&1; then
        # Collect Docker-enabled sites for this peer
        while IFS= read -r site_name; do
            [[ -z "$site_name" ]] && continue
            local site_peer site_docker
            site_peer=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE")
            site_docker=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker" "$CONFIG_FILE")
            if [[ "$site_peer" == "$PEER_NAME" && "$site_docker" == "true" ]]; then
                docker_sites+=("$site_name")
            fi
        done < <(yq eval '.sites[] | .name' "$CONFIG_FILE")
    else
        log_warning "yq not installed. Install yq for automatic Docker site detection."
    fi

    if [[ ${#docker_sites[@]} -eq 0 ]]; then
        log "No Docker-based sites found for this peer"
    else
        log "Found Docker-based sites: ${docker_sites[*]}"
        for site in "${docker_sites[@]}"; do
            setup_docker_site_network "$site"
        done
        configure_docker_daemon
    fi

    log_success "Docker networking configured"
}

setup_docker_site_network() {
    local site_name="$1"
    log "Setting up Docker network for site: $site_name"

    local docker_network
    if command -v yq >/dev/null 2>&1; then
        docker_network=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker_network" "$CONFIG_FILE" 2>/dev/null)
        [[ "$docker_network" == "null" || -z "$docker_network" ]] && docker_network="${site_name}_net"
    else
        docker_network="${site_name}_net"
    fi

    if docker network ls --format "{{.Name}}" | grep -q "^${docker_network}$"; then
        log "Docker network $docker_network already exists"
    else
        log "Creating Docker network: $docker_network"
        docker network create \
            --driver bridge \
            --opt "com.docker.network.bridge.name=br-${site_name}" \
            "$docker_network"
        log_success "Created Docker network: $docker_network"
    fi

    create_docker_helper_script "$site_name" "$docker_network"
}

create_docker_helper_script() {
    local site_name="$1"
    local docker_network="$2"
    local script_path="/usr/local/bin/docker-${site_name}-run"

    cat > "$script_path" << EOF
#!/bin/bash
# Helper: run a container on the ${docker_network} network for site ${site_name}
set -euo pipefail

NETWORK="$docker_network"
CONTAINER_NAME="\${1:-$site_name}"
IMAGE="\${2:-}"

if [[ -z "\$IMAGE" ]]; then
  echo "Usage: \$0 [container-name] <image> [docker-run-args...]"
  echo "Example: \$0 $site_name nginx:latest -p 8080:80"
  exit 1
fi

shift 2

if docker ps -a --format "{{.Names}}" | grep -q "^\$CONTAINER_NAME\$"; then
  docker stop "\$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "\$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

docker run -d \\
  --name "\$CONTAINER_NAME" \\
  --network "\$NETWORK" \\
  --restart unless-stopped \\
  "\$@" \\
  "\$IMAGE"

echo "Container '\$CONTAINER_NAME' started on network '\$NETWORK'"
docker inspect -f 'Container IP: {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "\$CONTAINER_NAME"
EOF

    chmod +x "$script_path"
    log "Created Docker helper script: $script_path"
}

configure_docker_daemon() {
    log "Configuring Docker daemon for optimal networking..."

    local daemon_config="/etc/docker/daemon.json"
    backup_file "$daemon_config"

    local want_json='{
      "log-driver": "json-file",
      "log-opts": { "max-size": "10m", "max-file": "3" },
      "storage-driver": "overlay2",
      "userland-proxy": false,
      "experimental": false,
      "metrics-addr": "127.0.0.1:9323",
      "bip": "172.17.0.1/16"
    }'

    if command -v jq >/dev/null 2>&1 && [[ -f "$daemon_config" ]]; then
        jq '. + {
          "log-driver": "json-file",
          "log-opts": { "max-size": "10m", "max-file": "3" },
          "storage-driver": "overlay2",
          "userland-proxy": false,
          "experimental": false,
          "metrics-addr": "127.0.0.1:9323",
          "bip": "172.17.0.1/16"
        }' "$daemon_config" > "${daemon_config}.tmp" && mv "${daemon_config}.tmp" "$daemon_config"
    else
        printf '%s\n' "$want_json" > "$daemon_config"
    fi

    if systemctl is-active --quiet docker; then
        log "Restarting Docker daemon..."
        systemctl restart docker
        wait_for_service "docker"
        log_success "Docker daemon restarted with new configuration"
    fi
}

setup_service_routing() {
    log "Configuring service routing for peer: $PEER_NAME"

    local peer_sites=()
    if command -v yq >/dev/null 2>&1; then
        while IFS= read -r site_name; do
            [[ -z "$site_name" ]] && continue
            local site_peer
            site_peer=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE")
            [[ "$site_peer" == "$PEER_NAME" ]] && peer_sites+=("$site_name")
        done < <(yq eval '.sites[] | .name' "$CONFIG_FILE")
    fi

    if [[ ${#peer_sites[@]} -eq 0 ]]; then
        log "No sites configured for peer: $PEER_NAME"
        return 0
    fi

    log "Configuring routing for sites: ${peer_sites[*]}"
    for site in "${peer_sites[@]}"; do
        configure_site_routing "$site"
    done

    log_success "Service routing configured"
}

configure_site_routing() {
    local site_name="$1"
    log "Configuring routing for site: $site_name"

    local is_docker="false" port="null" container_name=""
    if command -v yq >/dev/null 2>&1; then
        is_docker=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker" "$CONFIG_FILE")
        port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.port" "$CONFIG_FILE")
        container_name=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.container_name" "$CONFIG_FILE")
    fi

    if [[ "$is_docker" == "true" ]]; then
        log "Site $site_name uses Docker container: ${container_name:-$site_name}"
        # Docker networking handles this
    else
        log "Site $site_name uses direct port: $port"
        if [[ -n "$port" && "$port" != "null" ]]; then
            log "Ensure the service is listening on localhost:$port"
        fi
    fi
}

setup_service_firewall() {
    log "Configuring firewall for services on peer: $PEER_NAME"

    if ! command -v ufw >/dev/null 2>&1; then
        install_package "ufw"
    fi

    if ! ufw status | grep -q "Status: active"; then
        log "Enabling UFW firewall..."
        ufw --force enable
    fi

    local vps_subnet
    vps_subnet=$(get_config_value "vps.wireguard.subnet_cidr" "10.8.0.0/24")

    if ! ufw status | grep -q "$vps_subnet"; then
        log "Allowing traffic from VPS subnet: $vps_subnet"
        ufw allow from "$vps_subnet" comment "VPS Proxy Hub"
    fi

    local peer_ports=()
    if command -v yq >/dev/null 2>&1; then
        while IFS= read -r site_name; do
            [[ -z "$site_name" ]] && continue
            local site_peer site_docker port
            site_peer=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE")
            site_docker=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker" "$CONFIG_FILE")
            port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.port" "$CONFIG_FILE")
            if [[ "$site_peer" == "$PEER_NAME" && "$site_docker" != "true" && -n "$port" && "$port" != "null" ]]; then
                peer_ports+=("$port")
            fi
        done < <(yq eval '.sites[] | .name' "$CONFIG_FILE")
    fi

    for port in "${peer_ports[@]}"; do
        # Avoid duplicate rules
        if ! ufw status | grep -qE "ALLOW.*$vps_subnet.*Anywhere.*$port|$port.*ALLOW.*$vps_subnet"; then
            log "Allowing access to port $port from $vps_subnet"
            ufw allow from "$vps_subnet" to any port "$port" comment "VPS Proxy Hub - Service Port"
        fi
    done

    log_success "Service firewall configured"
}

# Run main function
main "$@"
