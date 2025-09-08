# VPS Proxy Hub

A complete, modular solution for setting up a homelab edge gateway using a VPS as the front door, with WireGuard tunnels connecting to one or more home machines. The VPS terminates TLS (Let's Encrypt), runs Nginx as a reverse proxy, and forwards traffic through encrypted WireGuard tunnels to services running on your home machines.

## 🌟 Features

- **🔒 Secure Edge Gateway**: VPS acts as a public front door with TLS termination and firewall protection
- **🔐 Encrypted Tunnels**: WireGuard VPN connects VPS to home machines with modern cryptography
- **🏆 Automatic SSL**: Let's Encrypt certificates with auto-renewal and multiple fallback strategies
- **⚙️ Config-Driven**: Single YAML file controls entire infrastructure setup
- **🧩 Modular Architecture**: Clean, maintainable codebase with shared utility libraries
- **🐳 Docker Support**: Seamless proxy to Docker containers with internal DNS resolution
- **📈 Multi-Peer Scalable**: Support for multiple home machines and unlimited sites
- **🛠️ Management Tools**: Rich toolset for adding/removing sites, monitoring health, and troubleshooting

## 🏗️ Architecture

```
Internet ──→ VPS (Public IP) ──→ WireGuard Tunnel ──→ Home Machine(s)
             │                                       │
             ├─ Nginx Reverse Proxy                  ├─ Service on Port 8080
             ├─ Let's Encrypt SSL                    ├─ Docker Container
             ├─ UFW Firewall                         ├─ Multiple Services
             └─ Automated Management                 └─ Health Monitoring
```

**Traffic Flow:**
1. Client connects to `https://your-site.com` 
2. DNS points to VPS public IP
3. UFW firewall allows only necessary ports (22, 80, 443, WireGuard)
4. Nginx terminates SSL and proxies over encrypted WireGuard tunnel
5. Home machine receives request and responds through secure tunnel
6. Response travels back through tunnel to client with full encryption

## 📁 Repository Structure

```
vps-proxy-hub/
├── README.md                          # This comprehensive guide
├── REFACTORING_SUMMARY.md            # Code quality improvements documentation
├── config.yaml.example               # Configuration template with examples
├── config.yaml                       # Your customized configuration
├── shared/                           # 🆕 Shared utility libraries
│   ├── utils.sh                      # Core utilities (logging, YAML parsing, system ops)
│   ├── nginx_utils.sh                # Nginx and SSL certificate management
│   └── interactive_utils.sh          # User interaction and validation utilities
├── vps/                              # VPS setup scripts and configuration
│   ├── setup.sh                      # VPS orchestrator script (automated setup)
│   ├── scripts/                      # Individual VPS setup components
│   │   ├── 01-system-update.sh       # System updates and basic configuration
│   │   ├── 02-ufw-setup.sh          # UFW firewall configuration
│   │   ├── 03-wireguard-install.sh   # WireGuard installation and setup
│   │   ├── 04-wireguard-config.sh    # WireGuard server configuration
│   │   ├── 05-nginx-install.sh       # Nginx installation and optimization
│   │   ├── 06-nginx-vhosts.sh        # 🔄 Refactored virtual hosts and SSL setup
│   │   └── utils.sh                  # Legacy utilities (now imports shared/)
│   └── templates/                    # Configuration templates
│       ├── wg0.conf.template         # WireGuard server configuration template
│       └── nginx-vhost.template      # Nginx virtual host template
├── home/                             # Home machine setup scripts
│   ├── setup.sh                      # Home machine orchestrator script
│   ├── scripts/                      # Individual home setup components
│   │   ├── 01-wireguard-install.sh   # WireGuard client installation
│   │   ├── 02-wireguard-config.sh    # WireGuard client configuration
│   │   ├── 03-routing-setup.sh       # Routing and network configuration
│   │   └── utils.sh                  # Legacy utilities (now imports shared/)
│   └── templates/                    # Home machine configuration templates
│       └── wg0.conf.template         # WireGuard client configuration template
└── tools/                            # 🔄 Enhanced management and monitoring tools
    ├── add-site.sh                   # 🆕 Interactive/CLI tool for adding sites
    ├── add-peer-key.sh               # Add peer public key to VPS
    ├── remove-site.sh                # Remove site and clean up configuration
    └── status.sh                     # System status and health monitoring
```

## 🚀 Quick Start Guide

### Prerequisites

- **VPS Requirements**: Ubuntu 20.04+ with public IP and root access
- **Domain Setup**: DNS records pointing your domains to the VPS IP
- **Home Network**: Static IP or dynamic DNS for reliable connections

### 1. Initial Setup

**On both VPS and home machines:**
```bash
# Clone the repository
git clone https://github.com/your-username/vps-proxy-hub.git
cd vps-proxy-hub

# Copy and customize configuration
cp config.yaml.example config.yaml
nano config.yaml
```

### 2. Configuration

Edit `config.yaml` with your specific settings:

```yaml
# Essential VPS settings
vps:
  public_ip: "203.0.113.10"              # Your VPS public IP address
  firewall_open_ports: [22, 80, 443, 51820]  # Minimal security exposure
  
  wireguard:
    subnet_cidr: "10.8.0.0/24"           # Private tunnel network
    vps_address: "10.8.0.1/24"           # VPS tunnel IP
    listen_port: 51820                   # WireGuard UDP port

# SSL certificate configuration
tls:
  email: "you@example.com"               # Let's Encrypt registration email
  use_staging: false                     # Use staging for testing only

# Home machine definitions
peers:
  - name: "home-1"                       # Unique identifier
    address: "10.8.0.2/32"               # Tunnel IP for this peer
    endpoint: "203.0.113.10:51820"       # VPS connection details
    keepalive: 25                        # Connection keep-alive interval

# Website/service definitions
sites:
  # Direct port proxy example
  - name: "blog"
    server_names: ["blog.example.com", "www.blog.example.com"]
    peer: "home-1"
    upstream:
      port: 8080                         # Service port on home machine
      docker: false

  # Docker container proxy example
  - name: "media"
    server_names: ["media.example.com"]
    peer: "home-1"
    upstream:
      docker: true
      container_name: "jellyfin"          # Docker container name
      container_port: 8096               # Port inside container
```

### 3. VPS Setup (Cloud Server)

**Run the automated VPS setup:**
```bash
sudo ./vps/setup.sh
```

This comprehensive setup process will:
- ✅ Update system packages and configure timezone
- ✅ Install and configure UFW firewall with minimal attack surface
- ✅ Install WireGuard server with optimized configuration
- ✅ Generate WireGuard server keys and peer configurations
- ✅ Install and configure Nginx with security hardening
- ✅ Create virtual hosts for all configured sites
- ✅ Obtain and install Let's Encrypt SSL certificates
- ✅ Configure automatic certificate renewal

**Setup time**: Typically 5-10 minutes depending on server performance.

### 4. Home Machine Setup

**On each home machine, run:**
```bash
sudo ./home/setup.sh <peer-name>
```

**Example:**
```bash
sudo ./home/setup.sh home-1
```

This will:
- ✅ Install WireGuard client software
- ✅ Generate unique peer cryptographic keys
- ✅ Configure tunnel to VPS with proper routing
- ✅ Set up firewall rules for secure operation
- ✅ Display the command to run on VPS for connection

**Important**: Copy the displayed command (e.g., `add-peer-key home-1 'ABC123...='`) and run it on your VPS.

### 5. Connect Peers

After home setup, you'll see output like:
```bash
═══════════════════════════════════════════════════════════════════
COPY THE FOLLOWING COMMAND TO RUN ON YOUR VPS:
═══════════════════════════════════════════════════════════════════

add-peer-key home-1 'ABC123def456GHI789jkl012MNO345pqr678STU901='

═══════════════════════════════════════════════════════════════════
```

**Run this exact command on your VPS** to complete the secure connection.

### 6. Start Your Services

**For direct port services:**
```bash
# Example: Python web server
python3 -m http.server 8080

# Example: Node.js application
npm start  # (configured to listen on port 8080)
```

**For Docker containers:**
```bash
# Use automatic helper scripts (created during setup)
docker-blog-run nginx:latest

# Or run manually with proper networking
docker run -d --name myapp --network blog_net myapp:latest
```

### 7. Test and Verify

**Your sites should now be accessible:**
- `https://blog.example.com` → secure connection through VPS tunnel
- `https://media.example.com` → Docker container via encrypted proxy

**Verify the setup:**
```bash
# Check WireGuard tunnel status
sudo wg show wg0

# Test VPS connectivity from home machine
ping 10.8.0.1

# Monitor system status
sudo ./tools/status.sh --detailed

# Check SSL certificate status
sudo certbot certificates
```

## 🔧 Advanced Management

### Adding New Sites

**Interactive mode (recommended):**
```bash
sudo ./tools/add-site.sh --interactive
```

**Command line mode:**
```bash
sudo ./tools/add-site.sh \
  --site-name wiki \
  --domains "wiki.example.com,www.wiki.example.com" \
  --peer home-1 \
  --port 3000

# For Docker containers
sudo ./tools/add-site.sh \
  --site-name media \
  --domains "media.example.com" \
  --peer home-2 \
  --docker \
  --container jellyfin \
  --container-port 8096
```

### System Status and Monitoring

```bash
# Comprehensive system status
sudo ./tools/status.sh

# Detailed component analysis
sudo ./tools/status.sh --detailed

# Check specific component
sudo ./tools/status.sh --check nginx
sudo ./tools/status.sh --check wireguard
sudo ./tools/status.sh --check ssl
```

### Site Management

```bash
# Remove a site (with confirmation)
sudo ./tools/remove-site.sh wiki

# Force removal (no confirmation)
sudo ./tools/remove-site.sh --force wiki
```

### WireGuard Tunnel Management

```bash
# View tunnel status and connected peers
sudo wg show wg0

# Restart WireGuard service
sudo systemctl restart wg-quick@wg0

# Monitor tunnel traffic
sudo wg show wg0 transfer

# Check tunnel logs
sudo journalctl -u wg-quick@wg0 -f
```

### SSL Certificate Management

```bash
# View all certificates
sudo certbot certificates

# Test certificate renewal
sudo certbot renew --dry-run

# Force certificate renewal for specific domain
sudo certbot renew --cert-name example.com

# Manually request certificate for new domain
sudo certbot --nginx -d newsite.example.com
```

## 🔍 Troubleshooting Guide

### Connection Issues

**Can't reach services through tunnel:**

1. **Verify tunnel connectivity:**
   ```bash
   # From home machine, ping VPS tunnel IP
   ping 10.8.0.1
   
   # From VPS, check peer connection status
   sudo wg show wg0
   
   # Check for peer handshake
   sudo wg show wg0 latest-handshakes
   ```

2. **Check service status:**
   ```bash
   sudo ./tools/status.sh --check wireguard
   sudo systemctl status wg-quick@wg0
   ```

3. **Verify firewall configuration:**
   ```bash
   sudo ufw status verbose
   sudo iptables -L -n
   ```

### SSL Certificate Issues

**Certificate problems:**

1. **Check certificate status:**
   ```bash
   sudo certbot certificates
   sudo ./tools/status.sh --check ssl
   ```

2. **DNS verification:**
   ```bash
   # Ensure DNS points to your VPS
   nslookup your-domain.com
   dig your-domain.com A
   ```

3. **Manual certificate request:**
   ```bash
   sudo certbot --nginx -d yoursite.com -d www.yoursite.com
   ```

### Service Issues

**Nginx configuration problems:**

1. **Test and reload Nginx:**
   ```bash
   sudo nginx -t
   sudo systemctl reload nginx
   sudo ./tools/status.sh --check nginx
   ```

2. **Check site configurations:**
   ```bash
   ls -la /etc/nginx/sites-enabled/
   sudo nginx -T  # Show full configuration
   ```

**Docker connectivity issues:**

1. **Verify Docker network setup:**
   ```bash
   docker network ls
   docker inspect <network-name>
   
   # Test container accessibility
   curl http://10.8.0.2:8096  # Direct container access
   ```

### Performance Optimization

**Tunnel performance tuning:**

1. **Optimize WireGuard settings:**
   ```bash
   # Check MTU settings
   ip link show wg0
   
   # Monitor tunnel performance
   iperf3 -c 10.8.0.1  # From home machine to VPS
   ```

2. **Nginx performance tuning:**
   ```bash
   # Check Nginx worker processes
   ps aux | grep nginx
   
   # Monitor connection handling
   sudo netstat -plan | grep :80
   sudo netstat -plan | grep :443
   ```

### Log Analysis

**Key log locations:**
```bash
# System setup logs
sudo tail -f /var/log/vps-proxy-hub.log
sudo tail -f /var/log/vps-proxy-hub-home.log

# Service-specific logs
sudo journalctl -u wg-quick@wg0 -f          # WireGuard
sudo tail -f /var/log/nginx/error.log       # Nginx errors
sudo tail -f /var/log/nginx/access.log      # Nginx access
sudo journalctl -u nginx -f                 # Nginx service
sudo tail -f /var/log/ufw.log              # Firewall
sudo journalctl -u certbot.timer -f         # Certificate renewal
```

## 🔒 Security Features

### Network Security
- **Minimal Attack Surface**: Only essential ports (22, 80, 443, WireGuard) exposed to internet
- **Encrypted Tunnels**: All traffic between VPS and home encrypted with WireGuard
- **Firewall Protection**: UFW configured with strict rules and logging
- **No Direct Exposure**: Home services never directly accessible from internet
- **IP Allowlisting**: Optional VPS-only access controls

### TLS Security  
- **Modern TLS**: TLS 1.2+ with secure cipher suites and ECDSA certificates
- **Security Headers**: HSTS, XSS protection, content type sniffing prevention
- **Auto-renewal**: Certificates automatically renewed before expiration
- **OCSP Stapling**: Improved certificate validation performance

### Operational Security
- **Least Privilege**: Services run with minimal required permissions
- **Regular Updates**: Automated system package updates with security patches
- **Configuration Backups**: Automatic backups created before any changes
- **Audit Logging**: Comprehensive logging for security analysis and debugging
- **Key Management**: Secure WireGuard key generation and storage

## 📈 Scaling Your Setup

### Adding More Home Machines

1. **Update configuration:**
   ```yaml
   peers:
     - name: "home-3"
       address: "10.8.0.4/32"
       endpoint: "203.0.113.10:51820"
       keepalive: 25
   ```

2. **Apply VPS configuration:**
   ```bash
   sudo ./vps/scripts/04-wireguard-config.sh
   ```

3. **Setup new home machine:**
   ```bash
   sudo ./home/setup.sh home-3
   # Then run the displayed add-peer-key command on VPS
   ```

### Load Balancing and High Availability

```bash
# Add multiple peers for the same service
sites:
  - name: "app"
    server_names: ["app.example.com"]
    peer: "home-1"  # Primary
    upstream:
      port: 8080
      backup_peers: ["home-2", "home-3"]  # Automatic failover
```

### Performance Monitoring

```bash
# Monitor resource usage
sudo ./tools/status.sh --detailed --monitor

# Set up automated health checks
sudo ./tools/status.sh --check all --cron
```

## 🛠️ Development and Customization

### Code Architecture

The codebase uses a **modular architecture** with shared utility libraries:

- **`shared/utils.sh`**: Core utilities (logging, YAML parsing, system operations)
- **`shared/nginx_utils.sh`**: Nginx and SSL certificate management
- **`shared/interactive_utils.sh`**: User interaction and validation

### Adding Custom Scripts

```bash
#!/bin/bash
# Load shared utilities for consistency
source "$(dirname "$0")/../shared/utils.sh"

# Set logging prefix
export LOG_PREFIX="[MY-SCRIPT]"

# Your custom logic here
log "Starting custom operation..."
```

### Configuration Validation

```bash
# Validate configuration syntax
./tools/validate-config.sh

# Test configuration without applying changes
./vps/setup.sh --dry-run
```

## 🤝 Contributing

We welcome contributions! Here's how to get started:

1. **Fork the repository** and create your feature branch
2. **Follow the modular architecture** using shared utilities
3. **Add comprehensive comments** and update documentation
4. **Test thoroughly** on fresh VPS and home machine setups
5. **Ensure backward compatibility** with existing configurations
6. **Submit a pull request** with detailed description

### Development Guidelines

- **Script modularity**: Keep individual scripts focused on single responsibilities
- **Error handling**: Use proper error checking with informative messages
- **Documentation**: Comment complex logic and update relevant README sections
- **Testing**: Verify functionality across different distributions and versions
- **Security**: Follow security best practices and never commit sensitive data

## 📜 License

This project is licensed under the MIT License. See the LICENSE file for details.

## 🙏 Acknowledgments

- **[WireGuard](https://www.wireguard.com/)**: For the excellent, modern VPN technology
- **[Let's Encrypt](https://letsencrypt.org/)**: For free, automated SSL certificates
- **[Nginx](https://nginx.org/)**: For robust, high-performance reverse proxy capabilities
- **Community**: For feedback, bug reports, testing, and contributions

## 📞 Support

- **Issues**: Report bugs and request features via [GitHub Issues](https://github.com/your-username/vps-proxy-hub/issues)
- **Discussions**: Join the conversation in [GitHub Discussions](https://github.com/your-username/vps-proxy-hub/discussions)
- **Documentation**: Check the `REFACTORING_SUMMARY.md` for detailed technical information

---

**Happy homelabbing! 🏠💻🔒**

*Securely bridge your home services to the internet with enterprise-grade encryption and professional-level automation.*