#!/bin/bash
# VPS Setup - Nginx Virtual Hosts Configuration
# Generates Nginx virtual hosts from config.yaml and obtains SSL certificates

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

main() {
    log "Starting Nginx virtual hosts configuration..."
    
    check_root
    check_config
    
    # Process each site in the configuration
    process_sites
    
    # Test nginx configuration
    test_nginx_config
    
    # Reload nginx to apply changes
    reload_nginx
    
    # Obtain SSL certificates
    obtain_ssl_certificates
    
    log_success "Nginx virtual hosts configuration completed"
}

process_sites() {
    log "Processing sites from configuration..."
    
    # Clear existing vhosts
    log "Removing existing virtual host configurations..."
    rm -f /etc/nginx/sites-enabled/*
    rm -f /etc/nginx/sites-available/vps-proxy-hub-*
    
    # Process each site
    if command -v yq &> /dev/null; then
        yq eval '.sites[] | .name' "$CONFIG_FILE" | while IFS= read -r site_name; do
            if [[ -n "$site_name" ]]; then
                process_site "$site_name"
            fi
        done
    else
        # Basic parsing for site names
        grep -A 50 "^sites:" "$CONFIG_FILE" | grep "name:" | sed 's/.*name: *["'\'']*//' | sed 's/["'\'']*.*//' | while IFS= read -r site_name; do
            if [[ -n "$site_name" ]]; then
                process_site "$site_name"
            fi
        done
    fi
}

process_site() {
    local site_name="$1"
    log "Processing site: $site_name"
    
    # Extract site configuration
    local server_names peer upstream_config nginx_config
    
    if command -v yq &> /dev/null; then
        server_names=$(yq eval ".sites[] | select(.name == \"$site_name\") | .server_names[]" "$CONFIG_FILE" | tr '\n' ' ')
        peer=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE")
        upstream_config=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream" "$CONFIG_FILE")
        nginx_config=$(yq eval ".sites[] | select(.name == \"$site_name\") | .nginx" "$CONFIG_FILE")
    else
        # Basic parsing for site configuration
        server_names=$(extract_site_config "$site_name" "server_names")
        peer=$(extract_site_config "$site_name" "peer")
    fi
    
    if [[ -z "$peer" ]]; then
        log_error "No peer specified for site $site_name"
        return 1
    fi
    
    # Get peer IP address
    local peer_ip
    peer_ip=$(get_peer_ip "$peer")
    
    if [[ -z "$peer_ip" ]]; then
        log_error "Could not determine IP for peer $peer"
        return 1
    fi
    
    # Determine upstream URL
    local upstream_url
    upstream_url=$(determine_upstream_url "$site_name" "$peer_ip")
    
    # Generate virtual host configuration
    generate_vhost "$site_name" "$server_names" "$upstream_url"
    
    log_success "Generated virtual host for $site_name"
}

extract_site_config() {
    local site_name="$1"
    local key="$2"
    
    # Find the site block and extract the key
    awk "
    /name:.*\"?${site_name}\"?/ {
        in_site = 1
        next
    }
    in_site && /^[[:space:]]*-[[:space:]]*name:/ && !/name:.*\"?${site_name}\"?/ {
        in_site = 0
    }
    in_site && /^[^[:space:]]/ && !/name:.*\"?${site_name}\"?/ {
        in_site = 0
    }
    in_site && /${key}:/ {
        if (/${key}:.*\[/) {
            # Array format
            gsub(/.*\[/, \"\")
            gsub(/\].*/, \"\")
            gsub(/[\"',]/, \" \")
            print \$0
        } else {
            # Simple value
            gsub(/.*${key}:[[:space:]]*[\"']?/, \"\")
            gsub(/[\"'].*/, \"\")
            print \$0
        }
        next
    }
    " "$CONFIG_FILE"
}

get_peer_ip() {
    local peer_name="$1"
    
    # Get peer address from configuration
    if command -v yq &> /dev/null; then
        local address
        address=$(yq eval ".peers[] | select(.name == \"$peer_name\") | .address" "$CONFIG_FILE")
        # Extract IP from CIDR notation (e.g., 10.8.0.2/32 -> 10.8.0.2)
        echo "${address%/*}"
    else
        # Basic parsing
        awk "/name:.*\"?${peer_name}\"?/,/^[[:space:]]*-[[:space:]]*name:|^[^[:space:]]/ {
            if (/address:/) {
                gsub(/.*address:[[:space:]]*[\"']?/, \"\")
                gsub(/\/[0-9]*/, \"\")
                gsub(/[\"'].*/, \"\")
                print \$0
                exit
            }
        }" "$CONFIG_FILE"
    fi
}

determine_upstream_url() {
    local site_name="$1"
    local peer_ip="$2"
    
    # Check if this is a Docker container upstream
    local is_docker container_name container_port port
    
    if command -v yq &> /dev/null; then
        is_docker=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker" "$CONFIG_FILE")
        container_name=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.container_name" "$CONFIG_FILE")
        container_port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.container_port" "$CONFIG_FILE")
        port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.port" "$CONFIG_FILE")
    else
        # Basic parsing for upstream configuration
        is_docker=$(extract_upstream_config "$site_name" "docker")
        container_name=$(extract_upstream_config "$site_name" "container_name")  
        container_port=$(extract_upstream_config "$site_name" "container_port")
        port=$(extract_upstream_config "$site_name" "port")
    fi
    
    if [[ "$is_docker" == "true" ]]; then
        # Docker container upstream
        if [[ -n "$container_name" && -n "$container_port" ]]; then
            echo "http://${container_name}:${container_port}"
        else
            log_error "Docker upstream specified but container_name or container_port missing for $site_name"
            return 1
        fi
    else
        # Direct IP:port upstream
        if [[ -n "$port" ]]; then
            echo "http://${peer_ip}:${port}"
        else
            log_error "Port not specified for site $site_name"
            return 1
        fi
    fi
}

extract_upstream_config() {
    local site_name="$1"
    local key="$2"
    
    awk "
    /name:.*\"?${site_name}\"?/ {
        in_site = 1
        next
    }
    in_site && /upstream:/ {
        in_upstream = 1
        next
    }
    in_upstream && /^[[:space:]]*[a-zA-Z_]+:/ && !/${key}:/ {
        if (!/^[[:space:]]+/) in_upstream = 0
        next
    }
    in_upstream && /${key}:/ {
        gsub(/.*${key}:[[:space:]]*[\"']?/, \"\")
        gsub(/[\"'].*/, \"\")
        print \$0
        exit
    }
    in_site && /^[[:space:]]*-[[:space:]]*name:/ && !/name:.*\"?${site_name}\"?/ {
        in_site = 0
        in_upstream = 0
    }
    " "$CONFIG_FILE"
}

generate_vhost() {
    local site_name="$1"
    local server_names="$2"
    local upstream_url="$3"
    
    local vhost_file="/etc/nginx/sites-available/vps-proxy-hub-${site_name}"
    local template_file="$SCRIPT_DIR/../templates/nginx-vhost.template"
    
    # Clean up server names (remove extra spaces, quotes)
    server_names=$(echo "$server_names" | sed 's/["\[\],]//g' | tr -s ' ')
    
    # Get additional nginx configuration for this site
    local extra_headers proxy_read_timeout force_https_redirect
    
    if command -v yq &> /dev/null; then
        extra_headers=$(yq eval ".sites[] | select(.name == \"$site_name\") | .nginx.extra_headers" "$CONFIG_FILE" 2>/dev/null || echo "null")
        proxy_read_timeout=$(yq eval ".sites[] | select(.name == \"$site_name\") | .nginx.proxy_read_timeout" "$CONFIG_FILE" 2>/dev/null || echo "60s")
        force_https_redirect=$(yq eval ".sites[] | select(.name == \"$site_name\") | .nginx.force_https_redirect" "$CONFIG_FILE" 2>/dev/null || echo "true")
    else
        proxy_read_timeout="60s"
        force_https_redirect="true"
    fi
    
    if [[ -f "$template_file" ]]; then
        # Use template if available
        substitute_template "$template_file" "$vhost_file" \
            "SITE_NAME=$site_name" \
            "SERVER_NAMES=$server_names" \
            "UPSTREAM_URL=$upstream_url" \
            "PROXY_READ_TIMEOUT=$proxy_read_timeout"
    else
        # Generate vhost directly
        generate_vhost_direct "$vhost_file" "$site_name" "$server_names" "$upstream_url" "$proxy_read_timeout" "$extra_headers"
    fi
    
    # Enable the site
    ln -sf "$vhost_file" "/etc/nginx/sites-enabled/vps-proxy-hub-${site_name}"
    
    log "Created virtual host: $vhost_file"
}

generate_vhost_direct() {
    local vhost_file="$1"
    local site_name="$2"
    local server_names="$3"
    local upstream_url="$4"
    local proxy_read_timeout="$5"
    local extra_headers="$6"
    
    cat > "$vhost_file" << EOF
# VPS Proxy Hub - Virtual Host for $site_name
# Generated automatically - do not edit manually

# HTTP server block - redirects to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $server_names;
    
    # ACME challenge for Let's Encrypt
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }
    
    # Redirect all HTTP to HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS server block - main configuration
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $server_names;
    
    # SSL configuration (certificates will be added by certbot)
    include /etc/nginx/conf.d/ssl.conf;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=15552000; includeSubDomains; preload" always;
EOF

    # Add extra headers if specified
    if [[ "$extra_headers" != "null" && -n "$extra_headers" ]]; then
        if command -v yq &> /dev/null; then
            yq eval ".sites[] | select(.name == \"$site_name\") | .nginx.extra_headers | to_entries | .[] | \"    add_header \" + .key + \" \\\"\" + .value + \"\\\" always;\"" "$CONFIG_FILE" >> "$vhost_file"
        fi
    fi
    
    cat >> "$vhost_file" << EOF
    
    # Rate limiting
    limit_req zone=general burst=20 nodelay;
    
    # Proxy configuration
    location / {
        # Include proxy settings
        include /etc/nginx/conf.d/proxy.conf;
        
        # Custom proxy timeout for this site
        proxy_read_timeout $proxy_read_timeout;
        
        # Proxy to upstream through WireGuard tunnel
        proxy_pass $upstream_url;
        
        # Handle connection errors gracefully
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }
    
    # Health check endpoint (optional)
    location = /.proxy-hub-health {
        access_log off;
        return 200 "OK\\n";
        add_header Content-Type text/plain;
    }
}
EOF

    log "Generated virtual host configuration for $site_name"
}

test_nginx_config() {
    log "Testing Nginx configuration..."
    
    if nginx -t; then
        log_success "Nginx configuration test passed"
    else
        log_error "Nginx configuration test failed"
        log "Check the configuration files in /etc/nginx/sites-available/"
        exit 1
    fi
}

reload_nginx() {
    log "Reloading Nginx configuration..."
    
    if systemctl reload nginx; then
        log_success "Nginx reloaded successfully"
    else
        log_error "Failed to reload Nginx"
        log "Check nginx status: systemctl status nginx"
        exit 1
    fi
}

obtain_ssl_certificates() {
    log "Obtaining SSL certificates with Let's Encrypt..."
    
    # Get email and staging flag from config
    local email staging_flag
    email=$(get_config_value "tls.email")
    local use_staging
    use_staging=$(get_config_value "tls.use_staging" "false")
    
    if [[ "$use_staging" == "true" ]]; then
        staging_flag="--staging"
        log_warning "Using Let's Encrypt staging environment (test certificates)"
    else
        staging_flag=""
    fi
    
    if [[ -z "$email" ]]; then
        log_error "TLS email not configured in config.yaml"
        log "SSL certificates will need to be obtained manually"
        return 1
    fi
    
    # Check if dry run should be performed
    local dry_run_flag=""
    local dry_run_on_apply
    dry_run_on_apply=$(get_config_value "ops.certbot_dry_run_on_apply" "false")
    
    if [[ "$dry_run_on_apply" == "true" ]]; then
        dry_run_flag="--dry-run"
        log "Performing certbot dry run (test mode)"
    fi
    
    # Process each site for SSL
    if command -v yq &> /dev/null; then
        yq eval '.sites[] | .name' "$CONFIG_FILE" | while IFS= read -r site_name; do
            if [[ -n "$site_name" ]]; then
                obtain_site_ssl "$site_name" "$email" "$staging_flag" "$dry_run_flag"
            fi
        done
    else
        # Basic parsing for site names
        grep -A 50 "^sites:" "$CONFIG_FILE" | grep "name:" | sed 's/.*name: *["'\'']*//' | sed 's/["'\'']*.*//' | while IFS= read -r site_name; do
            if [[ -n "$site_name" ]]; then
                obtain_site_ssl "$site_name" "$email" "$staging_flag" "$dry_run_flag"
            fi
        done
    fi
}

obtain_site_ssl() {
    local site_name="$1"
    local email="$2"
    local staging_flag="$3"
    local dry_run_flag="$4"
    
    log "Obtaining SSL certificate for site: $site_name"
    
    # Get server names for this site
    local server_names
    if command -v yq &> /dev/null; then
        server_names=$(yq eval ".sites[] | select(.name == \"$site_name\") | .server_names[]" "$CONFIG_FILE" | tr '\n' ' ')
    else
        server_names=$(extract_site_config "$site_name" "server_names")
    fi
    
    # Clean up server names
    server_names=$(echo "$server_names" | sed 's/["\[\],]//g' | tr -s ' ')
    
    if [[ -z "$server_names" ]]; then
        log_error "No server names found for site $site_name"
        return 1
    fi
    
    # Create domain arguments for certbot
    local domain_args=""
    for domain in $server_names; do
        domain_args="$domain_args -d $domain"
    done
    
    log "Requesting certificate for domains: $server_names"
    
    # Run certbot
    if certbot --nginx \
        --email "$email" \
        --agree-tos \
        --no-eff-email \
        --redirect \
        $staging_flag \
        $dry_run_flag \
        $domain_args; then
        
        if [[ -z "$dry_run_flag" ]]; then
            log_success "SSL certificate obtained for $site_name"
        else
            log_success "SSL certificate dry run completed for $site_name"
        fi
    else
        log_error "Failed to obtain SSL certificate for $site_name"
        log "Check that domains point to this server and port 80/443 are accessible"
        return 1
    fi
}

# Run main function
main "$@"