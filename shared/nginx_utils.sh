#!/bin/bash
# VPS Proxy Hub - Nginx Configuration Utilities
# Specialized functions for managing nginx virtual hosts and SSL certificates
# Handles site processing, SSL certificate management, and nginx configuration

set -euo pipefail

# Source shared utilities (use absolute path to avoid SCRIPT_DIR conflicts)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

# =============================================================================
# NGINX SITE PROCESSING
# =============================================================================

# Process all sites from configuration and generate virtual hosts
# Returns: 0 on success, 1 on failure
process_all_sites() {
    log "Processing sites from configuration..."

    # Clean slate approach - remove existing VPS Proxy Hub vhosts
    remove_existing_vhosts

    local sites_processed=0
    local site_names
    site_names=$(get_all_site_names)
    
    if [[ -z "$site_names" ]]; then
        log_warning "No sites found in configuration"
        return 0
    fi
    
    # Process each site individually
    while IFS= read -r site_name; do
        if [[ -n "$site_name" && "$site_name" != "null" ]]; then
            if process_single_site "$site_name"; then
                ((sites_processed++))
            else
                log_error "Failed to process site: $site_name"
                return 1
            fi
        fi
    done <<< "$site_names"
    
    if [[ $sites_processed -eq 0 ]]; then
        log_warning "No sites were successfully processed"
        return 1
    else
        log_success "Successfully processed $sites_processed site(s)"
        return 0
    fi
}

# Remove all existing VPS Proxy Hub virtual host configurations
remove_existing_vhosts() {
    log "Removing existing VPS Proxy Hub virtual host configurations..."
    rm -f /etc/nginx/sites-enabled/vps-proxy-hub-*
    rm -f /etc/nginx/sites-available/vps-proxy-hub-*
}

# Get all site names from configuration
get_all_site_names() {
    local site_names=""
    if command -v yq &> /dev/null; then
        site_names=$(yq eval '.sites[] | .name' "$CONFIG_FILE" 2>/dev/null || echo "")
        
        # If yq fails or returns empty, use fallback parsing
        if [[ -z "$site_names" ]]; then
            log "yq failed to get site names, using fallback parsing"
            site_names=$(awk '/^sites:/,/^[a-zA-Z_]/ {
                if (/^\s*-\s*name:/) {
                    gsub(/^\s*-\s*name:\s*["'"'"']?/, "")
                    gsub(/["'"'"'].*$/, "")
                    if (length($0) > 0) print $0
                }
            }' "$CONFIG_FILE")
        fi
    else
        # Basic parsing fallback
        site_names=$(awk '/^sites:/,/^[a-zA-Z_]/ {
            if (/^\s*-\s*name:/) {
                gsub(/^\s*-\s*name:\s*["'"'"']?/, "")
                gsub(/["'"'"'].*$/, "")
                if (length($0) > 0) print $0
            }
        }' "$CONFIG_FILE")
    fi
    
    echo "$site_names"
}

# Process a single site configuration
# Usage: process_single_site "site_name"
process_single_site() {
    local site_name="$1"
    log "Processing site: $site_name"

    # Extract site configuration
    local site_config
    site_config=$(extract_site_configuration "$site_name") || return 1
    
    # Parse the extracted configuration
    local server_names peer upstream_host upstream_port
    IFS="|" read -r server_names peer upstream_host upstream_port <<< "$site_config"

    # Validate extracted configuration
    if ! validate_site_configuration "$site_name" "$server_names" "$peer" "$upstream_host" "$upstream_port"; then
        return 1
    fi

    # Generate the virtual host configuration
    if ! generate_site_vhost "$site_name" "$server_names" "$upstream_host" "$upstream_port"; then
        return 1
    fi

    log_success "Generated virtual host for $site_name"
    return 0
}

# Extract complete site configuration for processing
# Returns: "server_names|peer|upstream_host|upstream_port"
extract_site_configuration() {
    local site_name="$1"
    
    # Get basic site info
    local server_names peer
    if command -v yq &> /dev/null; then
        server_names=$(yq eval ".sites[] | select(.name == \"$site_name\") | .server_names | join(\" \")" "$CONFIG_FILE" 2>/dev/null || echo "")
        peer=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE" 2>/dev/null || echo "")
        
        # If yq returns empty results, fall back to manual parsing
        if [[ -z "$server_names" || -z "$peer" ]]; then
            log "yq failed to parse config, falling back to manual parsing"
            server_names=$(extract_site_field "$site_name" "server_names")
            peer=$(extract_site_field "$site_name" "peer")
        fi
    else
        server_names=$(extract_site_field "$site_name" "server_names")
        peer=$(extract_site_field "$site_name" "peer")
    fi

    # Get peer IP address
    local peer_ip
    log "Debug: Looking up tunnel IP for peer: $peer"
    peer_ip=$(get_peer_tunnel_ip "$peer") || return 1
    log "Debug: Found peer IP: $peer_ip"

    # Determine upstream configuration
    local upstream_config
    upstream_config=$(extract_upstream_configuration "$site_name" "$peer_ip") || return 1
    
    local upstream_host upstream_port
    IFS="|" read -r upstream_host upstream_port <<< "$upstream_config"
    
    echo "${server_names}|${peer}|${upstream_host}|${upstream_port}"
}

# Extract a specific field from site configuration (fallback parser)
extract_site_field() {
    local site_name="$1" 
    local field="$2"
    
    awk -v site="$site_name" -v field="$field" '
    BEGIN { in_site = 0; found = 0 }
    
    # Match site by name
    /^\s*-\s*name:/ {
        if ($0 ~ site) {
            in_site = 1
            found = 1
            next
        } else {
            in_site = 0
        }
    }
    
    # Exit current site when we hit another site or top-level key
    in_site && (/^\s*-\s*name:/ || /^[a-zA-Z_]/) && !/^\s*-\s*name:.*'"$site_name"'/ {
        in_site = 0
    }
    
    # Extract the value when in the correct site
    in_site && $0 ~ field {
        if (field == "server_names") {
            # Handle array format
            if ($0 ~ /\[.*\]/) {
                gsub(/.*\[/, "")
                gsub(/\].*/, "")
                gsub(/["'"'"',]/, " ")
                gsub(/\s+/, " ")
                gsub(/^\s+|\s+$/, "")
                print
                exit
            } else {
                # Look for array items on following lines
                values = ""
                getline
                while ($0 ~ /^\s*-/ || $0 ~ /^\s+"/) {
                    gsub(/^\s*-\s*["'"'"']?/, "")
                    gsub(/["'"'"'].*$/, "")
                    if (length($0) > 0) {
                        if (values) values = values " " $0
                        else values = $0
                    }
                    if ((getline) <= 0) break
                }
                print values
                exit
            }
        } else {
            # Extract simple value
            gsub(/.*'"$field"':\s*["'"'"']?/, "")
            gsub(/["'"'"'].*$/, "")
            print
            exit
        }
    }
    ' "$CONFIG_FILE"
}

# Get peer tunnel IP address (without CIDR notation)
# Uses improved config utilities for better error handling
get_peer_tunnel_ip() {
    local peer_name="$1"
    
    # First validate the peer exists
    if ! validate_peer_config "$peer_name"; then
        return 1
    fi
    
    local address
    address=$(get_peer_config "$peer_name" "address")
    
    if [[ -n "$address" && "$address" != "null" ]]; then
        # Remove CIDR notation to get just the IP
        echo "${address%/*}"
    else
        log_error "Could not find address for peer: $peer_name"
        return 1
    fi
}

# Extract peer field using fallback parser
extract_peer_field() {
    local peer_name="$1"
    local field="$2"
    
    awk -v peer="$peer_name" -v field="$field" '
    BEGIN { in_peer = 0 }
    
    # Match peer by name
    /^\s*-\s*name:/ {
        if ($0 ~ peer) {
            in_peer = 1
            next
        } else {
            in_peer = 0
        }
    }
    
    # Exit current peer when we hit another peer or top-level key
    in_peer && (/^\s*-\s*name:/ || /^[a-zA-Z_]/) && !/^\s*-\s*name:.*'"$peer_name"'/ {
        in_peer = 0
    }
    
    # Extract the field value
    in_peer && $0 ~ field {
        gsub(/.*'"$field"':\s*["'"'"']?/, "")
        gsub(/["'"'"'].*$/, "")
        if (length($0) > 0) {
            print
            exit
        }
    }
    ' "$CONFIG_FILE"
}

# Determine upstream configuration (Docker or direct port)
# Returns: "upstream_host|upstream_port"
extract_upstream_configuration() {
    local site_name="$1" 
    local peer_ip="$2"
    
    local is_docker container_port port
    
    if command -v yq &> /dev/null; then
        is_docker=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker" "$CONFIG_FILE" 2>/dev/null || echo "false")
        container_port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.container_port" "$CONFIG_FILE" 2>/dev/null || echo "")
        port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.port" "$CONFIG_FILE" 2>/dev/null || echo "")
        
        # If yq returns null/empty values, fall back to manual parsing
        if [[ "$is_docker" == "null" || "$port" == "null" ]]; then
            log "yq returned null values, falling back to manual parsing"
            is_docker=$(extract_upstream_field "$site_name" "docker")
            container_port=$(extract_upstream_field "$site_name" "container_port")
            port=$(extract_upstream_field "$site_name" "port")
        fi
    else
        is_docker=$(extract_upstream_field "$site_name" "docker")
        container_port=$(extract_upstream_field "$site_name" "container_port")
        port=$(extract_upstream_field "$site_name" "port")
    fi

    # Debug logging  
    log "Debug: Site: $site_name, Peer IP: $peer_ip, Docker: $is_docker, Port: '$port', Container Port: '$container_port'"

    if [[ "$is_docker" == "true" ]]; then
        if [[ -n "$container_port" && "$container_port" != "null" ]]; then
            echo "${peer_ip}|${container_port}"
        else
            log_error "Docker upstream specified but container_port missing for $site_name"
            return 1
        fi
    else
        if [[ -n "$port" && "$port" != "null" ]]; then
            echo "${peer_ip}|${port}"
        else
            log_error "Port not specified for site $site_name (found: '$port')"
            log_error "Please check the upstream.port configuration in your config file"
            return 1
        fi
    fi
}

# Extract upstream field using fallback parser
extract_upstream_field() {
    local site_name="$1" 
    local field="$2"
    
    awk -v site="$site_name" -v field="$field" '
    BEGIN { in_site = 0; in_upstream = 0 }
    
    # Match site by name
    /^\s*-\s*name:/ {
        if ($0 ~ site) {
            in_site = 1
            next
        } else {
            in_site = 0
            in_upstream = 0
        }
    }
    
    # Enter upstream section
    in_site && /upstream:/ {
        in_upstream = 1
        next
    }
    
    # Exit upstream section
    in_upstream && /^\s*[a-zA-Z_]+:/ && !/^\s+/ && !/'$field':/ {
        in_upstream = 0
    }
    
    # Exit site
    in_site && (/^\s*-\s*name:/ || /^[a-zA-Z_]/) && !/^\s*-\s*name:.*'"$site_name"'/ {
        in_site = 0
        in_upstream = 0
    }
    
    # Extract value from upstream section
    in_upstream && $0 ~ field {
        gsub(/.*'"$field"':\s*["'"'"']?/, "")
        gsub(/["'"'"'].*$/, "")
        print
        exit
    }
    ' "$CONFIG_FILE"
}

# Validate extracted site configuration
validate_site_configuration() {
    local site_name="$1" 
    local server_names="$2" 
    local peer="$3" 
    local upstream_host="$4" 
    local upstream_port="$5"

    if [[ -z "$server_names" || "$server_names" == "null" ]]; then
        log_error "No server names found for site $site_name"
        return 1
    fi

    if [[ -z "$peer" || "$peer" == "null" ]]; then
        log_error "No peer specified for site $site_name"
        return 1
    fi

    if [[ -z "$upstream_host" || -z "$upstream_port" ]]; then
        log_error "Invalid upstream configuration for site $site_name"
        return 1
    fi

    return 0
}

# =============================================================================
# VIRTUAL HOST GENERATION
# =============================================================================

# Generate virtual host configuration file for a site
generate_site_vhost() {
    local site_name="$1" 
    local server_names="$2" 
    local upstream_host="$3" 
    local upstream_port="$4"

    local vhost_file="/etc/nginx/sites-available/vps-proxy-hub-${site_name}.conf"
    local template_path="$SCRIPT_DIR/../vps/templates/nginx-vhost.template"

    # Clean server names formatting
    server_names=$(clean_server_names "$server_names")

    log "Generating vhost for $site_name with domains: $server_names"
    log "Upstream: ${upstream_host}:${upstream_port}"

    # Use template if available, otherwise generate directly
    if [[ -f "$template_path" ]]; then
        generate_vhost_from_template "$vhost_file" "$template_path" "$server_names" "$upstream_host" "$upstream_port"
    else
        log_warning "Template not found, generating configuration directly..."
        generate_vhost_direct "$vhost_file" "$server_names" "$upstream_host" "$upstream_port"
    fi

    # Enable the site by creating symlink
    ln -sf "$vhost_file" "/etc/nginx/sites-enabled/vps-proxy-hub-${site_name}.conf"
    log "Created and enabled virtual host: $vhost_file"
    
    return 0
}

# Clean and normalize server names
clean_server_names() {
    local server_names="$1"
    echo "$server_names" | sed 's/["\[\],]//g' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# Generate virtual host from template
generate_vhost_from_template() {
    local vhost_file="$1" 
    local template_path="$2" 
    local server_names="$3" 
    local upstream_host="$4" 
    local upstream_port="$5"

    substitute_template "$template_path" "$vhost_file" \
        "SERVER_NAMES=$server_names" \
        "UPSTREAM_HOST=$upstream_host" \
        "UPSTREAM_PORT=$upstream_port"

    log "Generated vhost from template: $vhost_file"
}

# Generate virtual host configuration directly (fallback)
generate_vhost_direct() {
    local vhost_file="$1" 
    local server_names="$2" 
    local upstream_host="$3" 
    local upstream_port="$4"

    cat > "$vhost_file" << EOF
# HTTP: ACME challenges and initial setup
server {
    listen 80;
    listen [::]:80;
    server_name $server_names;

    # Let Certbot reach the ACME challenge
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }

    # Proxy to upstream service (will be replaced with redirect after SSL setup)
    location / {
        proxy_pass http://${upstream_host}:${upstream_port};
        include /etc/nginx/conf.d/proxy.conf;
        proxy_next_upstream error timeout http_502 http_503 http_504;
        
        # Debug header to confirm upstream configuration
        add_header X-Proxy-Upstream "${upstream_host}:${upstream_port}" always;
    }

    # Health check endpoint for monitoring
    location = /.proxy-hub-health {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "OK\\n";
    }
}
EOF
}

# =============================================================================
# NGINX CONFIGURATION MANAGEMENT
# =============================================================================

# Test nginx configuration syntax
test_nginx_configuration() {
    log "Testing Nginx configuration..."
    if nginx -t 2>&1; then
        log_success "Nginx configuration test passed"
        return 0
    else
        log_error "Nginx configuration test failed"
        log "Nginx configuration errors:"
        nginx -t 2>&1 | sed 's/^/  /'
        log "Check the configuration files in /etc/nginx/sites-available/"
        return 1
    fi
}

# Reload nginx configuration
reload_nginx_configuration() {
    log "Reloading Nginx configuration..."
    if systemctl reload nginx 2>&1; then
        log_success "Nginx reloaded successfully"
        return 0
    else
        local status_output
        status_output=$(systemctl status nginx --no-pager -l 2>&1 || true)
        log_error "Failed to reload Nginx"
        log "Nginx service status:"
        echo "$status_output" | sed 's/^/  /'
        return 1
    fi
}

# =============================================================================
# SSL CERTIFICATE MANAGEMENT
# =============================================================================

# Obtain SSL certificates for all configured sites
obtain_all_ssl_certificates() {
    log "Obtaining SSL certificates with Let's Encrypt..."

    # Validate certbot is available
    if ! command -v certbot >/dev/null 2>&1; then
        log_error "Certbot is not installed or not in PATH"
        log "Install per your distro or snap: https://certbot.eff.org"
        return 1
    fi

    # Get TLS configuration
    local email staging_flag
    email=$(get_config_value "tls.email")
    local use_staging
    use_staging=$(get_config_value "tls.use_staging" "false")

    if [[ -z "$email" || "$email" == "null" ]]; then
        log_error "TLS email not configured in config.yaml"
        log "Run manually when ready: certbot --nginx -d example.com"
        return 1
    fi

    staging_flag=""
    if [[ "$use_staging" == "true" ]]; then
        staging_flag="--staging"
        log_warning "Using Let's Encrypt staging server (test certificates)"
    fi

    # Process each site for SSL
    local sites_processed=0 sites_failed=0
    local site_names
    site_names=$(get_all_site_names)

    if [[ -z "$site_names" ]]; then
        log_warning "No sites found to enable TLS for"
        return 0
    fi

    while IFS= read -r site_name; do
        [[ -z "$site_name" || "$site_name" == "null" ]] && continue
        
        if obtain_site_ssl_certificate "$site_name" "$email" "$staging_flag"; then
            ((sites_processed++))
        else
            ((sites_failed++))
        fi
    done <<< "$site_names"

    if [[ $sites_failed -gt 0 ]]; then
        log_warning "SSL processed for $sites_processed site(s), failed for $sites_failed site(s)"
        return 0
    fi

    log_success "SSL certificates processed for $sites_processed site(s)"
    return 0
}

# Obtain SSL certificate for a single site
obtain_site_ssl_certificate() {
    local site_name="$1" 
    local email="$2" 
    local staging_flag="$3"

    log "Processing SSL certificate for site: $site_name"

    # Get server names for this site
    local server_names
    if command -v yq >/dev/null 2>&1; then
        server_names=$(yq eval ".sites[] | select(.name == \"$site_name\") | .server_names | join(\" \")" "$CONFIG_FILE" 2>/dev/null || echo "")
    else
        server_names=$(extract_site_field "$site_name" "server_names")
    fi
    
    server_names=$(clean_server_names "$server_names")

    if [[ -z "$server_names" ]]; then
        log_error "No server names found for site $site_name"
        return 1
    fi

    # Build domain arguments for certbot
    local first_domain=""
    local domain_args=()
    for domain in $server_names; do
        [[ -z "$first_domain" ]] && first_domain="$domain"
        domain_args+=("-d" "$domain")
    done

    log "Domains: $server_names"

    # Check if dry run is configured
    local dry_run_enabled
    dry_run_enabled=$(get_config_value "ops.certbot_dry_run_on_apply" "false")
    if [[ "$dry_run_enabled" == "true" ]]; then
        if ! perform_certbot_dry_run "$email" "$staging_flag" "${domain_args[@]}"; then
            log_error "Dry run failed for $site_name"
            return 1
        fi
    fi

    # Attempt to obtain/install certificate
    if attempt_certificate_installation "$email" "$staging_flag" "${domain_args[@]}"; then
        log_success "Certificate obtained/installed for $site_name"
        return 0
    fi

    # Fallback: try to reinstall existing certificate
    if attempt_certificate_reinstall "$first_domain"; then
        log_success "Reinstalled existing certificate for $site_name"
        return 0
    fi

    # Last resort: force renewal
    if attempt_certificate_force_renewal "$email" "$staging_flag" "${domain_args[@]}"; then
        log_success "Forced renewal succeeded for $site_name"
        return 0
    fi

    log_error "Failed to obtain/reinstall certificate for $site_name"
    return 1
}

# Perform certbot dry run test
perform_certbot_dry_run() {
    local email="$1" 
    local staging_flag="$2"
    shift 2
    local domain_args=("$@")

    log "Performing certbot dry run (pre-flight test)"
    certbot certonly --nginx \
        --email "$email" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        --dry-run \
        $staging_flag \
        "${domain_args[@]}" 2>&1
}

# Attempt standard certificate installation
attempt_certificate_installation() {
    local email="$1" 
    local staging_flag="$2"
    shift 2
    local domain_args=("$@")

    certbot --nginx \
        --email "$email" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        --redirect \
        $staging_flag \
        "${domain_args[@]}" 2>&1 && \
    nginx -t && systemctl reload nginx
}

# Attempt to reinstall existing certificate
attempt_certificate_reinstall() {
    local first_domain="$1"

    log "Attempting non-interactive reinstall of existing certificate for $first_domain"
    certbot install \
        --nginx \
        --cert-name "$first_domain" \
        --non-interactive \
        --redirect 2>&1 && \
    nginx -t && systemctl reload nginx
}

# Attempt forced certificate renewal
attempt_certificate_force_renewal() {
    local email="$1" 
    local staging_flag="$2"
    shift 2
    local domain_args=("$@")

    log_warning "Attempting forced renewal (use sparingly to avoid rate limits)"
    certbot --nginx \
        --email "$email" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        --redirect \
        --force-renewal \
        $staging_flag \
        "${domain_args[@]}" 2>&1 && \
    nginx -t && systemctl reload nginx
}

# Log successful loading of nginx utilities
log_debug "Nginx utilities loaded successfully"