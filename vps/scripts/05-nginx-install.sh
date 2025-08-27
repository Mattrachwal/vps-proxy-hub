#!/bin/bash
# VPS Setup - Nginx Installation and Basic Configuration
# Installs Nginx and configures it for reverse proxy with security headers

set -euo pipefail

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

main() {
    log "Starting Nginx installation and configuration..."
    
    check_root
    check_config
    
    # Install Nginx
    install_nginx
    
    # Configure Nginx security settings
    configure_nginx_security
    
    # Setup SSL/TLS configuration
    setup_ssl_config
    
    # Install Certbot for Let's Encrypt
    install_certbot
    
    # Configure logrotate
    configure_nginx_logrotate
    
    # Enable and start Nginx
    enable_nginx_service
    
    log_success "Nginx installation and basic configuration completed"
}

install_nginx() {
    log "Installing Nginx..."
    
    if command -v nginx &> /dev/null; then
        log "Nginx is already installed"
        return 0
    fi
    
    if command -v apt-get &> /dev/null; then
        # Ubuntu/Debian
        apt-get update
        apt-get install -y nginx
        
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL
        yum install -y epel-release
        yum install -y nginx
        
    elif command -v dnf &> /dev/null; then
        # Fedora
        dnf install -y nginx
        
    else
        log_error "Unsupported distribution for Nginx installation"
        exit 1
    fi
    
    # Verify installation
    if command -v nginx &> /dev/null; then
        log_success "Nginx installed successfully"
        nginx -v
    else
        log_error "Nginx installation failed"
        exit 1
    fi
}

configure_nginx_security() {
    log "Configuring Nginx security settings..."
    
    # Backup original nginx.conf
    backup_file "/etc/nginx/nginx.conf"
    
    # Create enhanced nginx.conf
    cat > /etc/nginx/nginx.conf << 'EOF'
# VPS Proxy Hub - Nginx Configuration
# Optimized for reverse proxy with security and performance

user www-data;
worker_processes auto;
pid /run/nginx.pid;

# Load dynamic modules
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    ##
    # Basic Settings
    ##
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 15;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 100M;

    # Buffer settings
    client_body_buffer_size 128k;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 4k;
    output_buffers 1 32k;
    postpone_output 1460;

    # Timeout settings
    client_header_timeout 3m;
    client_body_timeout 3m;
    send_timeout 3m;

    ##
    # MIME Types
    ##
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ##
    # Security Headers (applied to all sites)
    ##
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    ##
    # SSL Configuration
    ##
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_stapling on;
    ssl_stapling_verify on;

    ##
    # Logging Settings
    ##
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                   '$status $body_bytes_sent "$http_referer" '
                   '"$http_user_agent" "$http_x_forwarded_for" '
                   'rt=$request_time uct="$upstream_connect_time" '
                   'uht="$upstream_header_time" urt="$upstream_response_time"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log;

    ##
    # Gzip Settings
    ##
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;

    ##
    # Rate Limiting
    ##
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=general:10m rate=30r/s;

    ##
    # Map for handling websockets
    ##
    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    ##
    # Default server block (catch-all)
    ##
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        
        # Return 444 for unknown hosts
        return 444;
    }

    ##
    # Include additional configuration files
    ##
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

    # Fix user directive for CentOS/RHEL
    if command -v yum &> /dev/null || command -v dnf &> /dev/null; then
        sed -i 's/user www-data;/user nginx;/' /etc/nginx/nginx.conf
    fi

    # Create conf.d directory if it doesn't exist
    ensure_directory "/etc/nginx/conf.d" "755"
    
    # Create sites-available and sites-enabled directories
    ensure_directory "/etc/nginx/sites-available" "755"
    ensure_directory "/etc/nginx/sites-enabled" "755"
    
    # Remove default site if it exists
    rm -f /etc/nginx/sites-enabled/default
    rm -f /var/www/html/index.*
    
    log_success "Nginx security configuration completed"
}

setup_ssl_config() {
    log "Setting up SSL/TLS configuration..."
    
    # Create SSL configuration snippet
    cat > /etc/nginx/conf.d/ssl.conf << 'EOF'
# VPS Proxy Hub - SSL/TLS Configuration
# Modern SSL configuration for security

# SSL session settings
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;

# SSL protocols and ciphers
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;

ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";

# HSTS (optional - will be enabled per site)
# add_header Strict-Transport-Security "max-age=63072000" always;

# OCSP stapling
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
resolver_timeout 2s;
EOF

    # Create proxy configuration snippet for WireGuard backends
    cat > /etc/nginx/conf.d/proxy.conf << 'EOF'
# VPS Proxy Hub - Proxy Configuration
# Settings for proxying to WireGuard tunnel endpoints

# Proxy headers
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port $server_port;

# Proxy timeouts
proxy_connect_timeout 60s;
proxy_send_timeout 60s;
proxy_read_timeout 60s;

# Proxy buffering
proxy_buffering on;
proxy_buffer_size 4k;
proxy_buffers 8 4k;
proxy_busy_buffers_size 8k;

# WebSocket support
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;

# Don't proxy server headers we set ourselves
proxy_hide_header X-Frame-Options;
proxy_hide_header X-Content-Type-Options;
proxy_hide_header X-XSS-Protection;
EOF

    log_success "SSL/TLS configuration created"
}

install_certbot() {
    log "Installing Certbot for Let's Encrypt..."
    
    if command -v certbot &> /dev/null; then
        log "Certbot is already installed"
        return 0
    fi
    
    if command -v apt-get &> /dev/null; then
        # Ubuntu/Debian
        apt-get install -y certbot python3-certbot-nginx
        
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL 7
        yum install -y epel-release
        yum install -y certbot python2-certbot-nginx
        
    elif command -v dnf &> /dev/null; then
        # Fedora/CentOS 8+
        dnf install -y certbot python3-certbot-nginx
        
    else
        log_warning "Could not install certbot automatically"
        return 1
    fi
    
    # Set up automatic renewal
    if [[ -f /etc/crontab ]]; then
        if ! grep -q "certbot renew" /etc/crontab; then
            echo "0 12 * * * root certbot renew --quiet" >> /etc/crontab
            log "Added certbot renewal to crontab"
        fi
    fi
    
    # Test certbot installation
    if command -v certbot &> /dev/null; then
        log_success "Certbot installed successfully"
        certbot --version
    else
        log_error "Certbot installation failed"
        exit 1
    fi
}

configure_nginx_logrotate() {
    log "Configuring Nginx log rotation..."
    
    # Check if logrotate config exists and enhance it
    if [[ -f /etc/logrotate.d/nginx ]]; then
        backup_file "/etc/logrotate.d/nginx"
    fi
    
    cat > /etc/logrotate.d/nginx << 'EOF'
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then \
            run-parts /etc/logrotate.d/httpd-prerotate; \
        fi
    endscript
    postrotate
        invoke-rc.d nginx rotate >/dev/null 2>&1 || true
    endscript
}
EOF

    # Fix user for CentOS/RHEL
    if command -v yum &> /dev/null || command -v dnf &> /dev/null; then
        sed -i 's/www-data adm/nginx nginx/' /etc/logrotate.d/nginx
        sed -i 's/invoke-rc.d nginx rotate/systemctl reload nginx/' /etc/logrotate.d/nginx
    fi
    
    log_success "Nginx log rotation configured"
}

enable_nginx_service() {
    log "Enabling and starting Nginx service..."
    
    # Test nginx configuration
    if ! nginx -t; then
        log_error "Nginx configuration test failed"
        exit 1
    fi
    
    # Enable and start nginx
    systemctl enable nginx
    
    # Stop nginx if running (to restart cleanly)
    if systemctl is-active --quiet nginx; then
        systemctl stop nginx
    fi
    
    systemctl start nginx
    
    # Wait for service to be ready
    wait_for_service "nginx"
    
    # Test if nginx is responding
    if curl -s -o /dev/null -w "%{http_code}" http://localhost | grep -q "444"; then
        log_success "Nginx is responding (returning 444 for unknown hosts as expected)"
    else
        log_warning "Nginx response test inconclusive"
    fi
    
    log_success "Nginx service is running and enabled"
}

# Run main function
main "$@"