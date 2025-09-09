#!/bin/bash
# VPS Proxy Hub - Interactive Utilities
# Common functions for interactive user input and validation
# Provides reusable prompts, validation, and confirmation dialogs

set -euo pipefail

# Source shared utilities (use absolute path to avoid SCRIPT_DIR conflicts)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

# =============================================================================
# INPUT VALIDATION FUNCTIONS
# =============================================================================

# Validate port number is in valid range
# Usage: validate_port_number "8080"
validate_port_number() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]
}

# Validate that a string is not empty after trimming
# Usage: validate_non_empty "some string"
validate_non_empty() {
    local value="$1"
    value=$(echo "$value" | xargs)  # Trim whitespace
    [[ -n "$value" ]]
}

# =============================================================================
# INTERACTIVE PROMPT FUNCTIONS
# =============================================================================

# Prompt for a required non-empty string with validation
# Usage: prompt_required_string "Site name" site_name_var
prompt_required_string() {
    local prompt_text="$1"
    local var_name="$2"
    local validation_func="${3:-validate_non_empty}"
    
    local value=""
    while true; do
        read -p "$prompt_text: " value
        if $validation_func "$value"; then
            # Use nameref to set the variable in the calling scope
            declare -n result_var="$var_name"
            result_var="$value"
            break
        else
            echo "Invalid input. Please try again."
        fi
    done
}

# Prompt for a port number with validation
# Usage: prompt_port_number "Service port" port_var
prompt_port_number() {
    local prompt_text="$1"
    local var_name="$2"
    
    local port=""
    while true; do
        read -p "$prompt_text: " port
        if validate_port_number "$port"; then
            declare -n result_var="$var_name"
            result_var="$port"
            break
        else
            echo "Invalid port number. Please enter a number between 1 and 65535."
        fi
    done
}

# Prompt for comma-separated domains and return as array
# Usage: prompt_domains_list domains_array_var
prompt_domains_list() {
    local var_name="$1"
    local domains_input=""
    
    echo "Enter domains (comma-separated, e.g., 'site.com,www.site.com'):"
    while true; do
        read -p "Domains: " domains_input
        if validate_non_empty "$domains_input"; then
            # Parse comma-separated domains into array
            IFS=',' read -ra domains_array <<< "$domains_input"
            declare -n result_array="$var_name"
            result_array=()
            
            local has_valid_domain=false
            for domain in "${domains_array[@]}"; do
                domain=$(echo "$domain" | xargs)  # Trim whitespace
                if [[ -n "$domain" ]]; then
                    result_array+=("$domain")
                    has_valid_domain=true
                fi
            done
            
            if [[ "$has_valid_domain" == "true" ]]; then
                break
            else
                echo "Please enter at least one valid domain."
            fi
        else
            echo "At least one domain is required."
        fi
    done
}

# Prompt for peer selection from available peers
# Usage: prompt_peer_selection peer_var
prompt_peer_selection() {
    local var_name="$1"
    
    echo ""
    show_available_peers
    echo ""
    
    local peer_name=""
    while true; do
        read -p "Peer name: " peer_name
        if validate_non_empty "$peer_name" && validate_peer_name "$peer_name"; then
            declare -n result_var="$var_name"
            result_var="$peer_name"
            break
        else
            echo "Invalid peer name. Please select from the available peers above."
        fi
    done
}

# Show available peers from configuration
show_available_peers() {
    log "Available peers:"
    if command -v yq &> /dev/null; then
        yq eval '.peers[] | "  - " + .name + " (" + .address + ")"' "$CONFIG_FILE"
    else
        # Fallback for when yq is not available
        log "Check config.yaml for available peer names"
    fi
}

# Prompt for service type selection (direct port vs Docker)
# Usage: prompt_service_type is_docker_var service_port_var container_name_var container_port_var
prompt_service_type() {
    local is_docker_var="$1"
    local service_port_var="$2"
    local container_name_var="$3"
    local container_port_var="$4"
    
    echo ""
    echo "Service type:"
    echo "1. Direct port (service running on peer machine)"
    echo "2. Docker container (service running in Docker)"
    
    local service_type=""
    read -p "Select option (1 or 2): " service_type
    
    declare -n is_docker_result="$is_docker_var"
    
    case "$service_type" in
        1)
            # Direct port configuration
            is_docker_result=false
            echo ""
            prompt_port_number "Service port" "$service_port_var"
            ;;
        2)
            # Docker container configuration
            is_docker_result=true
            echo ""
            prompt_required_string "Container name" "$container_name_var"
            prompt_port_number "Container port" "$container_port_var"
            ;;
        *)
            log_error "Invalid selection"
            exit 1
            ;;
    esac
}

# Display configuration summary and get confirmation
# Usage: show_configuration_summary site_name domains_array peer_name is_docker [service_port] [container_name] [container_port]
show_configuration_summary() {
    local site_name="$1"
    local -n domains_ref="$2"  # Array reference
    local peer_name="$3"
    local is_docker="$4"
    local service_port="${5:-}"
    local container_name="${6:-}"
    local container_port="${7:-}"
    
    echo ""
    echo "═══ Site Configuration Summary ═══"
    echo "Site Name: $site_name"
    echo "Domains: ${domains_ref[*]}"
    echo "Peer: $peer_name"
    
    if [[ "$is_docker" == "true" ]]; then
        echo "Type: Docker container"
        echo "Container: $container_name"
        echo "Port: $container_port"
    else
        echo "Type: Direct port"
        echo "Port: $service_port"
    fi
    echo ""
}

# Get yes/no confirmation from user
# Usage: get_confirmation "Add this site?"
get_confirmation() {
    local prompt_text="$1"
    local confirm=""
    
    read -p "$prompt_text (y/N): " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]]
}

# =============================================================================
# SITE CONFIGURATION VALIDATION
# =============================================================================

# Check if site name already exists in configuration
# Usage: check_site_exists "site_name"
check_site_exists() {
    local site_name="$1"
    
    if command -v yq &> /dev/null; then
        if yq eval ".sites[] | select(.name == \"$site_name\") | .name" "$CONFIG_FILE" 2>/dev/null | grep -q "$site_name"; then
            return 0  # Site exists
        else
            return 1  # Site does not exist
        fi
    else
        # Fallback parsing
        if grep -q "name:.*\"\\?${site_name}\"\\?" "$CONFIG_FILE"; then
            return 0
        else
            return 1
        fi
    fi
}

# Validate all required arguments for non-interactive mode
# Usage: validate_site_arguments site_name domains_array peer_name is_docker service_port container_name container_port
validate_site_arguments() {
    local site_name="$1"
    local -n domains_ref="$2"
    local peer_name="$3"
    local is_docker="$4"
    local service_port="${5:-}"
    local container_name="${6:-}"
    local container_port="${7:-}"
    
    # Required arguments validation
    if [[ -z "$site_name" ]]; then
        log_error "--site-name is required"
        return 1
    fi
    
    if [[ ${#domains_ref[@]} -eq 0 ]]; then
        log_error "--domains is required"
        return 1
    fi
    
    if [[ -z "$peer_name" ]]; then
        log_error "--peer is required"
        return 1
    fi
    
    # Validate peer exists
    if ! validate_peer_name "$peer_name"; then
        log_error "Peer '$peer_name' not found in configuration"
        echo ""
        show_available_peers
        return 1
    fi
    
    # Check if site name already exists
    if check_site_exists "$site_name"; then
        log_error "Site '$site_name' already exists in configuration"
        return 1
    fi
    
    # Service configuration validation
    if [[ "$is_docker" == "true" ]]; then
        if [[ -z "$container_name" ]]; then
            log_error "--container is required when using --docker"
            return 1
        fi
        if [[ -z "$container_port" ]] || ! validate_port_number "$container_port"; then
            log_error "--container-port is required and must be valid when using --docker"
            return 1
        fi
    else
        if [[ -z "$service_port" ]] || ! validate_port_number "$service_port"; then
            log_error "--port is required and must be valid when not using --docker"
            return 1
        fi
    fi
    
    return 0
}

# Log successful loading of interactive utilities
log_debug "Interactive utilities loaded successfully"