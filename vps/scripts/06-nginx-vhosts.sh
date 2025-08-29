#!/bin/bash
# VPS Setup - Nginx Virtual Hosts Configuration
# Generates Nginx virtual hosts from config.yaml with proper HTTP+HTTPS setup

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

main() {
    log "Starting Nginx virtual hosts configuration..."

    check_root
    check_config

    # Ensure ACME webroot exists
    ensure_directory "/var/www/html" "755"

    # Process each site in the configuration
    if ! process_sites; then
        log_error "Failed to process sites"
        return 1
    fi

    # Test nginx configuration
    if ! test_nginx_config; then
        log_error "Nginx configuration test failed, aborting"
        return 1
    fi

    # Reload nginx to apply sites
    if ! reload_nginx; then
        log_error "Failed to reload nginx, aborting"
        return 1
    fi

    # Obtain SSL certificates and enable HTTPS
    if ! obtain_ssl_certificates; then
        log_warning "SSL certificate setup had issues, but basic setup is complete"
        log "You can run certbot manually later: certbot --nginx"
    fi

    log_success "Nginx virtual hosts configuration completed"
}

# Process all sites from configuration
process_sites() {
    log "Processing sites from configuration..."

    # Remove existing VPS Proxy Hub vhosts (clean slate approach)
    log "Removing existing VPS Proxy Hub virtual host configurations..."
    rm -f /etc/nginx/sites-enabled/vps-proxy-hub-*
    rm -f /etc/nginx/sites-available/vps-proxy-hub-*

    local sites_processed=0
    
    if command -v yq &> /dev/null; then
        # Use yq to get all site names
        local site_names
        site_names=$(yq eval '.sites[] | .name' "$CONFIG_FILE" 2>/dev/null || echo "")
        
        if [[ -n "$site_names" ]]; then
            while IFS= read -r site_name; do
                if [[ -n "$site_name" && "$site_name" != "null" ]]; then
                    process_site "$site_name"
                    ((sites_processed++))
                fi
            done <<< "$site_names"
        fi
    else
        # Basic parsing for site names without yq
        local site_names
        site_names=$(awk '/^sites:/,/^[a-zA-Z_]/ {
            if (/^\s*-\s*name:/) {
                gsub(/^\s*-\s*name:\s*["'"'"']?/, "")
                gsub(/["'"'"'].*$/, "")
                if (length($0) > 0) print $0
            }
        }' "$CONFIG_FILE")
        
        if [[ -n "$site_names" ]]; then
            while IFS= read -r site_name; do
                if [[ -n "$site_name" ]]; then
                    process_site "$site_name"
                    ((sites_processed++))
                fi
            done <<< "$site_names"
        fi
    fi
    
    if [[ $sites_processed -eq 0 ]]; then
        log_warning "No sites found in configuration"
    else
        log_success "Processed $sites_processed site(s)"
    fi
}

# Process individual site configuration
process_site() {
    local site_name="$1"
    log "Processing site: $site_name"

    local server_names peer upstream_host upstream_port

    if command -v yq &> /dev/null; then
        # Get server names as a space-separated string
        server_names=$(yq eval ".sites[] | select(.name == \"$site_name\") | .server_names | join(\" \")" "$CONFIG_FILE" 2>/dev/null || echo "")
        peer=$(yq eval ".sites[] | select(.name == \"$site_name\") | .peer" "$CONFIG_FILE" 2>/dev/null || echo "")
    else
        server_names=$(extract_site_config "$site_name" "server_names")
        peer=$(extract_site_config "$site_name" "peer")
    fi

    # Validate required fields
    if [[ -z "$server_names" || "$server_names" == "null" ]]; then
        log_error "No server names found for site $site_name"
        return 1
    fi

    if [[ -z "$peer" || "$peer" == "null" ]]; then
        log_error "No peer specified for site $site_name"
        return 1
    fi

    # Get peer IP (WireGuard tunnel IP)
    local peer_ip
    peer_ip=$(get_peer_ip "$peer")
    if [[ -z "$peer_ip" || "$peer_ip" == "null" ]]; then
        log_error "Could not determine IP for peer $peer"
        return 1
    fi

    # Determine upstream configuration
    local upstream_config
    upstream_config=$(determine_upstream_config "$site_name" "$peer_ip") || return 1

    IFS="|" read -r upstream_host upstream_port <<< "$upstream_config"

    # Validate upstream configuration
    if [[ -z "$upstream_host" || -z "$upstream_port" ]]; then
        log_error "Invalid upstream configuration for site $site_name"
        return 1
    fi

    # Generate the virtual host
    generate_vhost "$site_name" "$server_names" "$upstream_host" "$upstream_port"

    log_success "Generated virtual host for $site_name"
}

# Helper function for basic YAML parsing (when yq not available)
extract_site_config() {
    local site_name="$1" key="$2"
    
    # Find the site section and extract the key
    awk -v site="$site_name" -v key="$key" '
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
    in_site && $0 ~ key {
        if (key == "server_names") {
            # Handle array format [item1, item2] or - item format
            if ($0 ~ /\[.*\]/) {
                # Extract array format
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
            gsub(/.*'"$key"':\s*["'"'"']?/, "")
            gsub(/["'"'"'].*$/, "")
            print
            exit
        }
    }
    ' "$CONFIG_FILE"
}

# Get peer IP address from WireGuard address
get_peer_ip() {
    local peer_name="$1"
    
    if command -v yq &> /dev/null; then
        local address
        address=$(yq eval ".peers[] | select(.name == \"$peer_name\") | .address" "$CONFIG_FILE" 2>/dev/null || echo "")
        if [[ -n "$address" && "$address" != "null" ]]; then
            echo "${address%/*}"  # Remove CIDR notation
        fi
    else
        # Basic parsing
        awk -v peer="$peer_name" '
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
        
        # Extract address
        in_peer && /address:/ {
            gsub(/.*address:\s*["'"'"']?/, "")
            gsub(/\/[0-9]*/, "")  # Remove CIDR
            gsub(/["'"'"'].*$/, "")
            if (length($0) > 0) {
                print
                exit
            }
        }
        ' "$CONFIG_FILE"
    fi
}

# Determine upstream host and port configuration
determine_upstream_config() {
    local site_name="$1" peer_ip="$2"
    local is_docker container_name container_port port

    if command -v yq &> /dev/null; then
        is_docker=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.docker" "$CONFIG_FILE" 2>/dev/null || echo "false")
        container_name=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.container_name" "$CONFIG_FILE" 2>/dev/null || echo "")
        container_port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.container_port" "$CONFIG_FILE" 2>/dev/null || echo "")
        port=$(yq eval ".sites[] | select(.name == \"$site_name\") | .upstream.port" "$CONFIG_FILE" 2>/dev/null || echo "")
    else
        is_docker=$(extract_upstream_config "$site_name" "docker")
        container_name=$(extract_upstream_config "$site_name" "container_name")
        container_port=$(extract_upstream_config "$site_name" "container_port")
        port=$(extract_upstream_config "$site_name" "port")
    fi

    if [[ "$is_docker" == "true" ]]; then
        if [[ -n "$container_name" && "$container_name" != "null" && -n "$container_port" && "$container_port" != "null" ]]; then
            # For Docker containers, we still proxy to the peer IP but use the container port
            # The peer machine should handle container networking internally
            echo "${peer_ip}|${container_port}"
        else
            log_error "Docker upstream specified but container_name or container_port missing for $site_name"
            return 1
        fi
    else
        if [[ -n "$port" && "$port" != "null" ]]; then
            echo "${peer_ip}|${port}"
        else
            log_error "Port not specified for site $site_name"
            return 1
        fi
    fi
}

# Helper function to extract upstream config (when yq not available)
extract_upstream_config() {
    local site_name="$1" key="$2"
    
    awk -v site="$site_name" -v key="$key" '
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
    in_upstream && /^\s*[a-zA-Z_]+:/ && !/^\s+/ && !/'"$key"':/ {
        in_upstream = 0
    }
    
    # Exit site
    in_site && (/^\s*-\s*name:/ || /^[a-zA-Z_]/) && !/^\s*-\s*name:.*'"$site_name"'/ {
        in_site = 0
        in_upstream = 0
    }
    
    # Extract value
    in_upstream && $0 ~ key {
        gsub(/.*'"$key"':\s*["'"'"']?/, "")
        gsub(/["'"'"'].*$/, "")
        print
        exit
    }
    ' "$CONFIG_FILE"
}

# Generate virtual host configuration using template
generate_vhost() {
    local site_name="$1" server_names="$2" upstream_host="$3" upstream_port="$4"

    local vhost_file="/etc/nginx/sites-available/vps-proxy-hub-${site_name}.conf"
    local template_path="$SCRIPT_DIR/../templates/nginx-vhost.template"

    # Clean up server names (remove extra whitespace and quotes)
    server_names=$(echo "$server_names" | sed 's/["\[\],]//g' | tr -s ' ' | sed 's/^ *//; s/ *$//')

    log "Generating vhost for $site_name with domains: $server_names"
    log "Upstream: ${upstream_host}:${upstream_port}"

    # Use template if available, otherwise generate directly
    if [[ -f "$template_path" ]]; then
        generate_vhost_from_template "$vhost_file" "$template_path" "$server_names" "$upstream_host" "$upstream_port"
    else
        log_warning "Template not found, generating configuration directly..."
        generate_vhost_direct "$vhost_file" "$server_names" "$upstream_host" "$upstream_port"
    fi

    # Enable the site (symlink to sites-enabled)
    ln -sf "$vhost_file" "/etc/nginx/sites-enabled/vps-proxy-hub-${site_name}.conf"

    log "Created and enabled virtual host: $vhost_file"
}

# Generate vhost from template with proper substitution
generate_vhost_from_template() {
    local vhost_file="$1" template_path="$2" server_names="$3" upstream_host="$4" upstream_port="$5"

    # Read the template
    local template_content
    template_content=$(cat "$template_path")

    # Define the HTTP body (initially empty, will be filled after SSL setup)
    local http_body="  # Redirect to HTTPS (will be enabled after SSL setup)
  # return 301 https://\$host\$request_uri;"

    # Define the SSL block (placeholder for certbot)
    local ssl_block="  # SSL configuration will be managed by Certbot
  # ssl_certificate     /etc/letsencrypt/live/DOMAIN/fullchain.pem;
  # ssl_certificate_key /etc/letsencrypt/live/DOMAIN/privkey.pem;
  # include /etc/letsencrypt/options-ssl-nginx.conf;
  # ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;"

    # Perform substitutions
    template_content="${template_content//\{\{SERVER_NAMES\}\}/$server_names}"
    template_content="${template_content//\{\{UPSTREAM_HOST\}\}/$upstream_host}"
    template_content="${template_content//\{\{UPSTREAM_PORT\}\}/$upstream_port}"
    template_content="${template_content//\{\{HTTP_BODY\}\}/$http_body}"
    template_content="${template_content//\{\{SSL_BLOCK\}\}/$ssl_block}"

    # Write the final configuration
    echo "$template_content" > "$vhost_file"

    log "Generated vhost from template: $vhost_file"
}

# Generate vhost file directly (fallback when template not available)
generate_vhost_direct() {
    local vhost_file="$1" server_names="$2" upstream_host="$3" upstream_port="$4"

    cat > "$vhost_file" << EOF
# HTTP: ACME + redirect to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $server_names;

    # Let Certbot reach the challenge
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }

    # Redirect to HTTPS (will be uncommented after SSL setup)
    # return 301 https://\$host\$request_uri;
}

# HTTPS: proxy to WireGuard peer
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $server_names;

    # SSL configuration will be managed by Certbot
    # ssl_certificate     /etc/letsencrypt/live/DOMAIN/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/DOMAIN/privkey.pem;
    # include /etc/letsencrypt/options-ssl-nginx.conf;
    # ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Debug header to confirm upstream
    add_header X-Proxy-Upstream "${upstream_host}:${upstream_port}" always;

    # Reverse proxy over WireGuard
    location / {
        proxy_pass http://${upstream_host}:${upstream_port};
        include /etc/nginx/conf.d/proxy.conf;
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }

    # Optional health check
    location = /.proxy-hub-health {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "OK\\n";
    }
}
EOF
}

# Test nginx configuration
test_nginx_config() {
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

# Reload nginx
reload_nginx() {
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

# Obtain SSL certificates and enable HTTPS redirects
obtain_ssl_certificates() {
    log "Obtaining SSL certificates with Let's Encrypt..."

    local email staging_flag=""
    email=$(get_config_value "tls.email")
    local use_staging
    use_staging=$(get_config_value "tls.use_staging" "false")

    if [[ "$use_staging" == "true" ]]; then
        staging_flag="--staging"
        log_warning "Using Let's Encrypt staging environment (test certificates)"
    fi

    if [[ -z "$email" || "$email" == "null" ]]; then
        log_error "TLS email not configured in config.yaml"
        log "SSL certificates will need to be obtained manually"
        log "Run: certbot --nginx --email your@email.com"
        return 1
    fi

    # Check if certbot is available
    if ! command -v certbot &> /dev/null; then
        log_error "Certbot is not installed"
        log "SSL certificates cannot be obtained automatically"
        return 1
    fi

    local sites_processed=0
    local sites_failed=0

    # Process each site for SSL
    if command -v yq &> /dev/null; then
        local site_names
        site_names=$(yq eval '.sites[] | .name' "$CONFIG_FILE" 2>/dev/null || echo "")
        
        if [[ -n "$site_names" ]]; then
            while IFS= read -r site_name; do
                if [[ -n "$site_name" && "$site_name" != "null" ]]; then
                    if obtain_site_ssl "$site_name" "$email" "$staging_flag"; then
                        ((sites_processed++))
                    else
                        ((sites_failed++))
                    fi
                fi
            done <<< "$site_names"
        fi
    else
        local site_names
        site_names=$(awk '/^sites:/,/^[a-zA-Z_]/ {
            if (/^\s*-\s*name:/) {
                gsub(/^\s*-\s*name:\s*["'"'"']?/, "")
                gsub(/["'"'"'].*$/, "")
                if (length($0) > 0) print $0
            }
        }' "$CONFIG_FILE")
        
        if [[ -n "$site_names" ]]; then
            while IFS= read -r site_name; do
                if [[ -n "$site_name" ]]; then
                    if obtain_site_ssl "$site_name" "$email" "$staging_flag"; then
                        ((sites_processed++))
                    else
                        ((sites_failed++))
                    fi
                fi
            done <<< "$site_names"
        fi
    fi

    if [[ $sites_processed -eq 0 && $sites_failed -gt 0 ]]; then
        log_error "Failed to obtain SSL certificates for all sites"
        log "Common issues:"
        log "  - DNS records don't point to this VPS"
        log "  - Domains are not accessible from the internet"
        log "  - Port 80 is blocked by firewall"
        log "  - Another web server is using port 80"
        log ""
        log "To debug: curl -I http://yourdomain.com/.well-known/acme-challenge/test"
        return 1
    elif [[ $sites_failed -gt 0 ]]; then
        log_warning "SSL certificates obtained for $sites_processed site(s), failed for $sites_failed site(s)"
        return 0
    else
        log_success "SSL certificates processed for $sites_processed site(s)"
        return 0
    fi
}

# Obtain SSL certificate for individual site
obtain_site_ssl() {
    local site_name="$1" email="$2" staging_flag="$3"

    log "Obtaining SSL certificate for site: $site_name"

    # Get server names for the site
    local server_names
    if command -v yq &> /dev/null; then
        server_names=$(yq eval ".sites[] | select(.name == \"$site_name\") | .server_names | join(\" \")" "$CONFIG_FILE" 2>/dev/null || echo "")
    else
        server_names=$(extract_site_config "$site_name" "server_names")
    fi

    # Clean up server names
    server_names=$(echo "$server_names" | sed 's/["\[\],]//g' | tr -s ' ' | sed 's/^ *//; s/ *$//')

    if [[ -z "$server_names" ]]; then
        log_error "No server names found for site $site_name"
        return 1
    fi

    # Build domain arguments for certbot
    local domain_args=""
    local first_domain=""
    for domain in $server_names; do
        if [[ -n "$domain" ]]; then
            domain_args+=" -d $domain"
            if [[ -z "$first_domain" ]]; then
                first_domain="$domain"
            fi
        fi
    done

    if [[ -z "$domain_args" ]]; then
        log_error "No valid domains found for site $site_name"
        return 1
    fi

    log "Requesting certificate for domains: $server_names"

    # Check for dry run mode
    local dry_run_flag=""
    local dry_run_on_apply
    dry_run_on_apply=$(get_config_value "ops.certbot_dry_run_on_apply" "false")
    if [[ "$dry_run_on_apply" == "true" ]]; then
        dry_run_flag="--dry-run"
        log "Performing certbot dry run (test mode)"
    fi

    # Test domain accessibility before running certbot
    log "Testing domain accessibility..."
    for domain in $server_names; do
        local test_url="http://$domain/.well-known/acme-challenge/test"
        if ! curl -s -f -I "$test_url" >/dev/null 2>&1; then
            log_warning "Domain $domain may not be accessible (this is normal if no challenge exists yet)"
        fi
    done

    # Run certbot to obtain certificate and configure nginx
    if [[ -n "$dry_run_flag" ]]; then
        # Dry run - just test certificate issuance
        log "Running certbot dry run..."
        if certbot certonly --nginx \
            --email "$email" \
            --agree-tos \
            --no-eff-email \
            --non-interactive \
            $staging_flag \
            --dry-run \
            $domain_args 2>&1; then
            log_success "SSL certificate dry run completed for $site_name"
            return 0
        else
            log_error "Failed certbot dry run for $site_name"
            return 1
        fi
    else
        # Real certificate issuance and nginx configuration
        log "Running certbot for real certificate..."
        local certbot_output
        if certbot_output=$(certbot --nginx \
            --email "$email" \
            --agree-tos \
            --no-eff-email \
            --redirect \
            --non-interactive \
            $staging_flag \
            $domain_args 2>&1); then
            log_success "SSL certificate obtained and configured for $site_name"
            
            # Enable HTTPS redirect in the HTTP block
            enable_https_redirect "$site_name"
            return 0
        else
            log_error "Failed to obtain SSL certificate for $site_name"
            log "Certbot output:"
            echo "$certbot_output" | sed 's/^/  /'
            log ""
            log "Common issues:"
            log "  - DNS records for $server_names don't point to this VPS"
            log "  - Port 80 is not accessible from the internet"
            log "  - Another web server is using port 80"
            log "  - Domain validation failed"
            log ""
            log "To debug manually:"
            log "  curl -I http://$first_domain/.well-known/acme-challenge/"
            return 1
        fi
    fi
}

# Enable HTTPS redirect in HTTP server block after SSL is configured
enable_https_redirect() {
    local site_name="$1"
    local vhost_file="/etc/nginx/sites-available/vps-proxy-hub-${site_name}.conf"
    
    if [[ -f "$vhost_file" ]]; then
        # Uncomment the redirect line if it's commented
        sed -i 's/# return 301 https:/return 301 https:/' "$vhost_file"
        
        # If the redirect line doesn't exist, add it
        if ! grep -q "return 301 https:" "$vhost_file"; then
            # Add redirect after the ACME location block in HTTP server
            sed -i '/location.*acme-challenge/,/}/ { 
                /}/ a\\n    # Redirect to HTTPS\n    return 301 https://$host$request_uri;
            }' "$vhost_file"
        fi
        
        log "Enabled HTTPS redirect for $site_name"
        
        # Reload nginx to apply the changes
        if nginx -t && systemctl reload nginx; then
            log_success "Nginx reloaded with HTTPS redirect for $site_name"
        else
            log_warning "Failed to reload nginx after enabling HTTPS redirect"
        fi
    fi
}

# Run main function
main "$@"