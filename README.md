# VPS Proxy Hub

A complete, scriptable solution for setting up a homelab edge gateway using a VPS as the front door, with WireGuard tunnels connecting to one or more home machines. The VPS terminates TLS (Let's Encrypt), runs Nginx as a reverse proxy, and forwards traffic through encrypted WireGuard tunnels to services running on your home machines.

## 🌟 Features

- **Secure Edge Gateway**: VPS acts as a public front door with TLS termination
- **Encrypted Tunnels**: WireGuard VPN connects VPS to home machines
- **Automatic SSL**: Let's Encrypt certificates with auto-renewal
- **Config-Driven**: Single YAML file controls entire setup
- **Modular Scripts**: Small, focused scripts for each setup step  
- **Docker Support**: Proxy to Docker containers with internal DNS
- **Multi-Peer**: Scale to multiple home machines and sites
- **Management Tools**: Add/remove sites, check status, monitor health

## 🏗️ Architecture

```
Internet ──→ VPS (Public IP) ──→ WireGuard Tunnel ──→ Home Machine(s)
             │                                       │
             ├─ Nginx Reverse Proxy                  ├─ Service on Port 8080
             ├─ Let's Encrypt SSL                    ├─ Docker Container
             └─ UFW Firewall                         └─ Multiple Services
```

**Traffic Flow:**
1. Client connects to `https://your-site.com` 
2. DNS points to VPS public IP
3. Nginx on VPS terminates SSL and proxies over WireGuard tunnel
4. Home machine receives request and responds
5. Response travels back through tunnel to client

## 📁 Repository Structure

```
vps-proxy-hub/
├── README.md                    # This file
├── config.yaml.example         # Configuration template
├── vps/                         # VPS setup scripts
│   ├── setup.sh                # VPS orchestrator script  
│   ├── scripts/                # Individual setup scripts
│   │   ├── 01-system-update.sh
│   │   ├── 02-ufw-setup.sh
│   │   ├── 03-wireguard-install.sh
│   │   ├── 04-wireguard-config.sh
│   │   ├── 05-nginx-install.sh
│   │   ├── 06-nginx-vhosts.sh
│   │   └── utils.sh            # Shared utilities
│   └── templates/              # Configuration templates
│       ├── wg0.conf.template
│       └── nginx-vhost.template
├── home/                       # Home machine setup scripts
│   ├── setup.sh               # Home orchestrator script
│   ├── scripts/               # Individual setup scripts  
│   │   ├── 01-wireguard-install.sh
│   │   ├── 02-wireguard-config.sh
│   │   ├── 03-routing-setup.sh
│   │   └── utils.sh           # Shared utilities
│   └── templates/             # Configuration templates
│       └── wg0.conf.template
└── tools/                     # Management tools
    ├── add-site.sh           # Add new site/domain
    ├── remove-site.sh        # Remove site/domain  
    └── status.sh             # Show system status
```

## 🚀 Quick Start

### 1. Initial Setup

1. **Get a VPS** with a public IP (Ubuntu 20.04+ recommended)
2. **Point your domains** to the VPS IP address
3. **Clone this repository** on both VPS and home machines:
   ```bash
   git clone https://github.com/your-repo/vps-proxy-hub.git
   cd vps-proxy-hub
   ```

### 2. Configuration  

1. **Copy and edit the configuration**:
   ```bash
   cp config.yaml.example config.yaml
   nano config.yaml
   ```

2. **Key configuration sections**:
   - `vps.public_ip`: Your VPS public IP
   - `tls.email`: Your email for Let's Encrypt
   - `peers[]`: Your home machines
   - `sites[]`: Your websites/services

### 3. VPS Setup

Run the VPS setup on your cloud server:

```bash
sudo ./vps/setup.sh
```

This will:
- Update system and configure firewall
- Install and configure WireGuard server
- Install and configure Nginx with SSL
- Generate VPS WireGuard keys
- Create virtual hosts for your sites

### 4. Home Machine Setup

On each home machine, run:

```bash
sudo ./home/setup.sh <peer-name>
```

Example:
```bash
sudo ./home/setup.sh home-1
```

This will:
- Install WireGuard client
- Generate peer keys  
- Configure tunnel to VPS
- Set up routing and firewall
- Display the command to run on VPS

### 5. Connect Peers

After home setup, you'll see output like:
```
add-peer-key home-1 'ABC123...DEF456='
```

**Run this command on your VPS** to complete the connection.

### 6. Start Your Services

Start your services on home machines:

**For direct ports:**
```bash
# Start your service on the configured port
python -m http.server 8080
```

**For Docker containers:**
```bash  
# Use the generated helper script
docker-mysite-run nginx:latest

# Or run manually
docker run -d --name myapp --network mysite_net myapp:latest
```

### 7. Test Your Sites

Your sites should now be accessible:
- `https://yoursite.com` → routed through VPS → WireGuard tunnel → home service

## 📋 Configuration Reference

### VPS Configuration
```yaml
vps:
  public_ip: "203.0.113.10"          # Your VPS public IP
  ssh_port: 22                        # SSH port (adjust firewall if changed)
  timezone: "America/Chicago"         # VPS timezone
  firewall_open_ports: [22, 80, 443, 51820]  # UFW open ports
  
  wireguard:
    subnet_cidr: "10.8.0.0/24"        # WireGuard subnet
    vps_address: "10.8.0.1/24"        # VPS tunnel IP
    listen_port: 51820                # WireGuard UDP port
```

### TLS Configuration  
```yaml
tls:
  email: "you@example.com"            # Let's Encrypt email
  use_staging: false                  # Use staging for testing
  key_type: "ecdsa"                   # Certificate key type
```

### Peer Configuration
```yaml
peers:
  - name: "home-1"                    # Peer identifier
    address: "10.8.0.2/32"            # Peer tunnel IP
    endpoint: "203.0.113.10:51820"    # VPS endpoint
    keepalive: 25                     # Keep-alive interval
    hostname: "home1.local"           # Optional hostname
```

### Site Configuration
```yaml
sites:
  # Direct port example
  - name: "blog"
    server_names: ["blog.example.com", "www.blog.example.com"]
    peer: "home-1" 
    upstream:
      port: 8080                      # Service port on peer
      docker: false
    nginx:
      force_https_redirect: true
      extra_headers:
        Strict-Transport-Security: "max-age=15552000"

  # Docker container example  
  - name: "media"
    server_names: ["media.example.com"]
    peer: "home-2"
    upstream:
      docker: true
      container_name: "jellyfin"      # Container name
      container_port: 8096            # Container port
      docker_network: "media_net"     # Docker network
    nginx:
      proxy_read_timeout: "300s"      # Longer timeout for media
```

## 🔧 Management Commands

### Check Status
```bash
# Overall status
sudo ./tools/status.sh

# Detailed status
sudo ./tools/status.sh --detailed

# Specific component
sudo ./tools/status.sh --check nginx
```

### Add New Site
```bash  
# Interactive mode
sudo ./tools/add-site.sh --interactive

# Command line
sudo ./tools/add-site.sh \
  --site-name wiki \
  --domains "wiki.example.com" \
  --peer home-1 \
  --port 3000
```

### Remove Site
```bash
# With confirmation
sudo ./tools/remove-site.sh wiki

# Force removal
sudo ./tools/remove-site.sh --force wiki
```

### WireGuard Management
```bash
# Check tunnel status
sudo wg show wg0

# Restart WireGuard
sudo systemctl restart wg-quick@wg0

# Add peer public key (VPS only)
sudo add-peer-key home-1 'PUBLIC_KEY_HERE'
```

## 🔍 Troubleshooting

### Connection Issues

**Can't reach services through tunnel:**

1. **Check WireGuard status:**
   ```bash
   sudo ./tools/status.sh --check wireguard
   sudo wg show wg0
   ```

2. **Test tunnel connectivity:**
   ```bash
   # From home machine, ping VPS
   ping 10.8.0.1
   
   # From VPS, check peer connection
   sudo wg show wg0
   ```

3. **Check firewall rules:**
   ```bash
   sudo ufw status verbose
   ```

**SSL Certificate Issues:**

1. **Check certificate status:**
   ```bash
   sudo certbot certificates
   sudo ./tools/status.sh --check ssl
   ```

2. **Test certificate renewal:**
   ```bash
   sudo certbot renew --dry-run
   ```

3. **Manual certificate request:**
   ```bash
   sudo certbot --nginx -d yoursite.com
   ```

### Service Issues

**Nginx not serving sites:**

1. **Test Nginx configuration:**
   ```bash
   sudo nginx -t
   sudo systemctl status nginx
   ```

2. **Check site configuration:**
   ```bash
   ls -la /etc/nginx/sites-enabled/
   sudo ./tools/status.sh --check sites
   ```

**Docker containers not accessible:**

1. **Check Docker networks:**
   ```bash
   docker network ls
   docker inspect <network-name>
   ```

2. **Test container connectivity:**
   ```bash
   # From VPS, test container
   curl http://10.8.0.2:8096  # Direct IP:port
   ```

### Log Files

**Key log locations:**
- **VPS Setup**: `/var/log/vps-proxy-hub.log`
- **Home Setup**: `/var/log/vps-proxy-hub-home.log`  
- **WireGuard**: `journalctl -u wg-quick@wg0`
- **Nginx**: `/var/log/nginx/error.log`, `/var/log/nginx/access.log`
- **UFW**: `/var/log/ufw.log`

## 🔒 Security Considerations

### Network Security
- **Minimal attack surface**: Only ports 22, 80, 443, and WireGuard port exposed
- **Encrypted tunnels**: All traffic between VPS and home encrypted  
- **Firewall configured**: UFW blocks unnecessary connections
- **No direct home exposure**: Home services not directly accessible from internet

### TLS Security  
- **Modern TLS**: TLS 1.2+ with secure cipher suites
- **HSTS headers**: Prevent downgrade attacks
- **Auto-renewal**: Certificates automatically renewed
- **Security headers**: XSS protection, content type sniffing prevention

### Operational Security
- **Principle of least privilege**: Services run with minimal permissions
- **Regular updates**: System packages kept up to date
- **Log monitoring**: Centralized logging for security analysis
- **Configuration backups**: Automatic backups before changes

## 📈 Scaling

### Adding More Home Machines

1. **Add peer to config.yaml:**
   ```yaml
   peers:
     - name: "home-3"
       address: "10.8.0.4/32" 
       endpoint: "203.0.113.10:51820"
   ```

2. **Update VPS configuration:**
   ```bash
   sudo ./vps/scripts/04-wireguard-config.sh
   ```

3. **Setup new home machine:**
   ```bash
   sudo ./home/setup.sh home-3
   ```

### Adding More Sites

```bash
sudo ./tools/add-site.sh \
  --site-name newapp \
  --domains "app.example.com" \
  --peer home-2 \
  --docker \
  --container myapp \
  --container-port 3000
```

## 🛠️ Advanced Configuration

### Custom Nginx Configuration

Add custom Nginx settings per site:

```yaml
sites:
  - name: "api"
    server_names: ["api.example.com"]
    peer: "home-1"
    upstream:
      port: 8080
    nginx:
      proxy_read_timeout: "60s"
      proxy_connect_timeout: "10s" 
      client_max_body_size: "50M"
      extra_headers:
        Access-Control-Allow-Origin: "*"
        X-API-Version: "v2"
```

### Custom WireGuard Settings

```yaml
vps:
  wireguard:
    # Custom subnet
    subnet_cidr: "192.168.100.0/24"
    vps_address: "192.168.100.1/24"
    
    # Custom port
    listen_port: 443  # Hide behind HTTPS port
    
peers:
  - name: "home-1"
    address: "192.168.100.2/32"
    keepalive: 15     # More frequent keepalive
```

## 🤝 Contributing

1. **Fork the repository**
2. **Create a feature branch**: `git checkout -b feature-name`  
3. **Make your changes** and test thoroughly
4. **Submit a pull request** with detailed description

### Development Guidelines

- **Script modularity**: Keep individual scripts focused on one task
- **Error handling**: Use proper error checking and logging
- **Documentation**: Comment complex logic and update README
- **Testing**: Test on fresh VPS and home machine setups
- **Backward compatibility**: Don't break existing configurations

## 📜 License

This project is licensed under the MIT License.

## 🙏 Acknowledgments

- **WireGuard**: For the excellent VPN technology
- **Let's Encrypt**: For free, automated SSL certificates  
- **Nginx**: For the robust reverse proxy capabilities
- **Community**: For feedback, bug reports, and contributions

---

**Happy homelabbing! 🏠💻**