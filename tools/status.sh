#!/bin/bash
# VPS Proxy Hub - Status Tool
# Shows status of WireGuard, Nginx, UFW, and configured sites

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../config.yaml}"

# Load shared utilities (includes colors and logging functions)
source "$SCRIPT_DIR/../shared/utils.sh"

# Status symbols
CHECK_MARK="✓"
CROSS_MARK="✗"
WARNING_MARK="⚠"

# Logging functions
log() {
    echo -e "${BLUE}$*${NC}"
}

log_success() {
    echo -e "${GREEN}${CHECK_MARK}${NC} $*"
}

log_error() {
    echo -e "${RED}${CROSS_MARK}${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}${WARNING_MARK}${NC} $*"
}

log_header() {
    echo -e "${BOLD}${CYAN}$*${NC}"
}

# Show usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Show status of VPS Proxy Hub components and services.

Options:
  --detailed, -d       Show detailed status information
  --json              Output status in JSON format
  --check COMPONENT   Check specific component only
  --help, -h          Show this help message

Available components:
  wireguard           WireGuard tunnel status
  nginx               Nginx web server status
  firewall            UFW firewall status
  sites               Individual site status
  ssl                 SSL certificate status
  system              System resource status

Examples:
  $0                  # Show summary status
  $0 --detailed       # Show detailed status
  $0 --check nginx    # Check only Nginx status
  $0 --json           # Output in JSON format
EOF
}

# Check if running on VPS or home machine
detect_machine_type() {
    if [[ -f "/etc/wireguard/wg0.conf" ]]; then
        if grep -q "ListenPort" "/etc/wireguard/wg0.conf" 2>/dev/null; then
            echo "vps"
        else
            echo "home"
        fi
    else
        # Try to determine based on available scripts
        if [[ -d "$SCRIPT_DIR/../vps/scripts" ]]; then
            echo "vps"
        elif [[ -d "$SCRIPT_DIR/../home/scripts" ]]; then
            echo "home"
        else
            echo "unknown"
        fi
    fi
}

# Parse command line arguments
parse_arguments() {
    DETAILED=false
    JSON_OUTPUT=false
    CHECK_COMPONENT=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --detailed|-d)
                DETAILED=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --check)
                CHECK_COMPONENT="$2"
                shift 2
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_usage
                exit 1
                ;;
        esac
    done
}

# Check WireGuard status
check_wireguard_status() {
    local status="unknown"
    local details=""
    local peers_info=""
    
    if command -v wg &> /dev/null; then
        if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
            status="active"
            if [[ "$DETAILED" == "true" ]]; then
                details=$(wg show wg0 2>/dev/null || echo "Interface not ready")
                # Count peers
                local peer_count
                peer_count=$(wg show wg0 peers 2>/dev/null | wc -l || echo "0")
                peers_info="$peer_count peer(s) connected"
            fi
        elif systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null; then
            status="enabled"
            details="Service enabled but not active"
        else
            status="inactive"
            details="Service not running"
        fi
    else
        status="not_installed"
        details="WireGuard not installed"
    fi
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "\"wireguard\": {\"status\": \"$status\", \"details\": \"$details\", \"peers\": \"$peers_info\"}"
    else
        case "$status" in
            "active")
                log_success "WireGuard: Running"
                if [[ "$DETAILED" == "true" && -n "$peers_info" ]]; then
                    echo "         $peers_info"
                    if [[ -n "$details" && "$details" != "Interface not ready" ]]; then
                        echo "$details" | sed 's/^/         /'
                    fi
                fi
                ;;
            "enabled")
                log_warning "WireGuard: Enabled but not running"
                ;;
            "inactive")
                log_error "WireGuard: Not running"
                ;;
            "not_installed")
                log_error "WireGuard: Not installed"
                ;;
        esac
    fi
}

# Check Nginx status
check_nginx_status() {
    local status="unknown"
    local details=""
    local vhost_count=0
    
    if command -v nginx &> /dev/null; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            status="active"
            # Count virtual hosts
            if [[ -d "/etc/nginx/sites-enabled" ]]; then
                vhost_count=$(find /etc/nginx/sites-enabled -name "vps-proxy-hub-*" -type f 2>/dev/null | wc -l)
            fi
            details="$vhost_count VPS Proxy Hub site(s) configured"
        elif systemctl is-enabled --quiet nginx 2>/dev/null; then
            status="enabled"
            details="Service enabled but not active"
        else
            status="inactive"
            details="Service not running"
        fi
    else
        status="not_installed"
        details="Nginx not installed"
    fi
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "\"nginx\": {\"status\": \"$status\", \"details\": \"$details\", \"sites\": $vhost_count}"
    else
        case "$status" in
            "active")
                log_success "Nginx: Running"
                if [[ "$DETAILED" == "true" ]]; then
                    echo "        $details"
                fi
                ;;
            "enabled")
                log_warning "Nginx: Enabled but not running"
                ;;
            "inactive")
                log_error "Nginx: Not running"
                ;;
            "not_installed")
                log_error "Nginx: Not installed"
                ;;
        esac
    fi
}

# Check UFW firewall status
check_firewall_status() {
    local status="unknown"
    local details=""
    local rules_count=0
    
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            status="active"
            rules_count=$(ufw status numbered | grep -c "vps-proxy-hub\|VPS Proxy Hub" 2>/dev/null || echo "0")
            details="$rules_count VPS Proxy Hub rule(s)"
        elif ufw status | grep -q "Status: inactive"; then
            status="inactive"
            details="UFW is installed but inactive"
        else
            status="unknown"
            details="UFW status unclear"
        fi
    else
        status="not_installed"
        details="UFW not installed"
    fi
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "\"firewall\": {\"status\": \"$status\", \"details\": \"$details\", \"rules\": $rules_count}"
    else
        case "$status" in
            "active")
                log_success "Firewall (UFW): Active"
                if [[ "$DETAILED" == "true" ]]; then
                    echo "             $details"
                fi
                ;;
            "inactive")
                log_warning "Firewall (UFW): Inactive"
                ;;
            "not_installed")
                log_warning "Firewall (UFW): Not installed"
                ;;
        esac
    fi
}

# Check individual sites
check_sites_status() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            echo "\"sites\": {\"status\": \"no_config\", \"details\": \"Configuration file not found\"}"
        else
            log_error "Sites: Configuration file not found"
        fi
        return
    fi
    
    # Install yq if needed for JSON output
    if [[ "$JSON_OUTPUT" == "true" ]] && ! command -v yq &> /dev/null; then
        echo "\"sites\": {\"status\": \"error\", \"details\": \"yq not available for JSON parsing\"}"
        return
    fi
    
    local sites_json=""
    local sites_found=false
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        sites_json="\"sites\": {\"status\": \"checked\", \"list\": ["
    else
        log_header "Sites Configuration:"
    fi
    
    # Check if yq is available
    if command -v yq &> /dev/null; then
        while IFS= read -r site_name; do
            if [[ -n "$site_name" && "$site_name" != "null" ]]; then
                sites_found=true
                check_individual_site "$site_name"
                if [[ "$JSON_OUTPUT" == "true" ]]; then
                    if [[ -n "$sites_json" && ! "$sites_json" =~ \[$ ]]; then
                        sites_json+=", "
                    fi
                    sites_json+="{\"name\": \"$site_name\"}"
                fi
            fi
        done < <(yq eval '.sites[]?.name' "$CONFIG_FILE" 2>/dev/null)
    else
        # Basic parsing without yq
        if [[ "$JSON_OUTPUT" != "true" ]]; then
            log_warning "Install yq for detailed site status"
            # Try basic grep-based parsing
            local site_count
            site_count=$(grep -c "name:" "$CONFIG_FILE" 2>/dev/null || echo "0")
            echo "         Approximately $site_count site(s) configured"
        fi
    fi
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        sites_json+="]}"
        echo "$sites_json"
    elif [[ "$sites_found" == "false" ]]; then
        echo "         No sites configured"
    fi
}

# Check individual site status
check_individual_site() {
    local site_name="$1"
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        return # JSON output handled by caller
    fi
    
    # Get site details
    local domains peer nginx_config ssl_status
    
    if command -v yq &> /dev/null; then
        domains=$(yq eval ".sites[] | select(.name == \"$site_name\") | .server_names | join(\", \")" "$CONFIG_FILE" 2>/dev/null)
        peer=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE" 2>/dev/null)
    else
        domains="N/A"
        peer="N/A"
    fi
    
    # Check Nginx configuration
    local nginx_file="/etc/nginx/sites-enabled/vps-proxy-hub-${site_name}"
    if [[ -f "$nginx_file" ]]; then
        nginx_config="${CHECK_MARK} Nginx config"
    else
        nginx_config="${CROSS_MARK} No Nginx config"
    fi
    
    # Check SSL certificate
    ssl_status=""
    if command -v certbot &> /dev/null && [[ -n "$domains" && "$domains" != "N/A" ]]; then
        local first_domain
        first_domain=$(echo "$domains" | cut -d',' -f1 | xargs)
        if certbot certificates 2>/dev/null | grep -q "$first_domain"; then
            ssl_status="${CHECK_MARK} SSL cert"
        else
            ssl_status="${CROSS_MARK} No SSL cert"
        fi
    fi
    
    echo "  • $site_name"
    echo "    Domains: $domains"
    echo "    Peer: $peer"
    echo "    Status: $nginx_config $ssl_status"
    
    if [[ "$DETAILED" == "true" ]]; then
        # Check if peer is connected
        if command -v wg &> /dev/null; then
            if wg show wg0 peers 2>/dev/null | grep -q .; then
                echo "    WireGuard: Peers connected"
            else
                echo "    WireGuard: No peers connected"
            fi
        fi
    fi
}

# Check SSL certificates
check_ssl_status() {
    local status="unknown"
    local details=""
    local cert_count=0
    
    if command -v certbot &> /dev/null; then
        cert_count=$(certbot certificates 2>/dev/null | grep -c "Certificate Name:" || echo "0")
        if [[ $cert_count -gt 0 ]]; then
            status="active"
            details="$cert_count certificate(s) managed"
        else
            status="none"
            details="No certificates found"
        fi
    else
        status="not_installed"
        details="Certbot not installed"
    fi
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "\"ssl\": {\"status\": \"$status\", \"details\": \"$details\", \"count\": $cert_count}"
    else
        case "$status" in
            "active")
                log_success "SSL Certificates: $details"
                if [[ "$DETAILED" == "true" ]]; then
                    certbot certificates 2>/dev/null | grep "Certificate Name:\|Domains:\|Expiry Date:" | sed 's/^/         /' || true
                fi
                ;;
            "none")
                log_warning "SSL Certificates: None found"
                ;;
            "not_installed")
                log_error "SSL Certificates: Certbot not installed"
                ;;
        esac
    fi
}

# Check system resources
check_system_status() {
    local cpu_usage memory_usage disk_usage load_avg
    
    # CPU usage (1 minute average)
    if command -v top &> /dev/null; then
        cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo "N/A")
    else
        cpu_usage="N/A"
    fi
    
    # Memory usage
    if command -v free &> /dev/null; then
        memory_usage=$(free | awk '/^Mem:/{printf "%.1f%%", $3/$2 * 100.0}' || echo "N/A")
    else
        memory_usage="N/A"
    fi
    
    # Disk usage (root filesystem)
    if command -v df &> /dev/null; then
        disk_usage=$(df / | awk '/^\//{print $5}' || echo "N/A")
    else
        disk_usage="N/A"
    fi
    
    # Load average
    if [[ -f /proc/loadavg ]]; then
        load_avg=$(cut -d' ' -f1 /proc/loadavg)
    else
        load_avg="N/A"
    fi
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "\"system\": {\"cpu\": \"$cpu_usage\", \"memory\": \"$memory_usage\", \"disk\": \"$disk_usage\", \"load\": \"$load_avg\"}"
    else
        log_header "System Resources:"
        echo "  CPU Usage: $cpu_usage"
        echo "  Memory Usage: $memory_usage"
        echo "  Disk Usage: $disk_usage"
        echo "  Load Average: $load_avg"
    fi
}

# Show summary status
show_summary() {
    local machine_type
    machine_type=$(detect_machine_type)
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "{"
        echo "\"machine_type\": \"$machine_type\","
        check_wireguard_status
        echo ","
        if [[ "$machine_type" == "vps" ]]; then
            check_nginx_status
            echo ","
            check_ssl_status
            echo ","
        fi
        check_firewall_status
        echo ","
        check_sites_status
        echo ","
        check_system_status
        echo "}"
    else
        log_header "═══ VPS Proxy Hub Status ═══"
        echo "Machine Type: $machine_type"
        echo ""
        
        check_wireguard_status
        
        if [[ "$machine_type" == "vps" ]]; then
            check_nginx_status
            check_ssl_status
        fi
        
        check_firewall_status
        echo ""
        
        check_sites_status
        echo ""
        
        if [[ "$DETAILED" == "true" ]]; then
            check_system_status
        fi
    fi
}

# Main function
main() {
    # Parse arguments
    parse_arguments "$@"
    
    # Handle specific component check
    if [[ -n "$CHECK_COMPONENT" ]]; then
        case "$CHECK_COMPONENT" in
            "wireguard")
                check_wireguard_status
                ;;
            "nginx")
                check_nginx_status
                ;;
            "firewall")
                check_firewall_status
                ;;
            "sites")
                check_sites_status
                ;;
            "ssl")
                check_ssl_status
                ;;
            "system")
                check_system_status
                ;;
            *)
                echo "Unknown component: $CHECK_COMPONENT" >&2
                echo "Available components: wireguard, nginx, firewall, sites, ssl, system" >&2
                exit 1
                ;;
        esac
    else
        # Show full status
        show_summary
    fi
}

# Run main function with all arguments
main "$@"