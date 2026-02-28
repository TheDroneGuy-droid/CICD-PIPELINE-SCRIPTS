#!/bin/bash
#===============================================================================
# NGINX & SSL SETUP SCRIPT
# Purpose: Nginx reverse proxy + SSL certificate configuration
# Usage: Run on your frontend/application VM after main-server-setup.sh
#===============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PARENT_DIR/.deploy-config"

# Default values
APP_PORT=3000
WEBHOOK_PORT=9000

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        "INFO")  echo -e "${GREEN}[INFO]${NC} ${timestamp} - $message" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} ${timestamp} - $message" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} ${timestamp} - $message" ;;
        "DEBUG") echo -e "${BLUE}[DEBUG]${NC} ${timestamp} - $message" ;;
    esac
}

print_section() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

confirm() {
    local prompt="${1:-Continue?}"
    echo -en "${YELLOW}${prompt} [Y/n]: ${NC}"
    read -r response
    case "$response" in
        [nN][oO]|[nN]) return 1 ;;
        *) return 0 ;;
    esac
}

command_exists() {
    command -v "$1" &> /dev/null
}

get_server_ip() {
    # Try multiple methods
    local ip=""
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$ip" ]; then
        ip=$(ip route get 1 2>/dev/null | awk '{print $(NF-2);exit}')
    fi
    if [ -z "$ip" ]; then
        ip=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | awk '{print $2}' | head -1)
    fi
    echo "$ip"
}

#===============================================================================
# INPUT COLLECTION
#===============================================================================

collect_inputs() {
    print_section "Configuration Setup"
    
    # Load existing config if available
    if [ -f "$CONFIG_FILE" ]; then
        log "INFO" "Loading configuration from main-server-setup..."
        source "$CONFIG_FILE"
        log "INFO" "Loaded: APP_NAME=$APP_NAME, APP_PORT=$APP_PORT"
    fi
    
    # Domain name
    echo -en "${CYAN}Enter your domain name (e.g., example.com): ${NC}"
    read -r DOMAIN_NAME
    while [ -z "$DOMAIN_NAME" ]; do
        echo -e "${RED}Domain name is required!${NC}"
        echo -en "${CYAN}Enter your domain name: ${NC}"
        read -r DOMAIN_NAME
    done
    
    # App name if not loaded
    if [ -z "$APP_NAME" ]; then
        local default_name=$(basename "$PARENT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
        echo -en "${CYAN}Enter application name [${default_name}]: ${NC}"
        read -r APP_NAME
        APP_NAME=${APP_NAME:-$default_name}
    fi
    
    # App port if not loaded
    if [ -z "$APP_PORT" ] || [ "$APP_PORT" = "3000" ]; then
        echo -en "${CYAN}Enter application port [3000]: ${NC}"
        read -r input_port
        APP_PORT=${input_port:-3000}
    fi
    
    # SSL setup method
    echo ""
    echo -e "${YELLOW}SSL Certificate Options:${NC}"
    echo "1. Cloudflare Tunnel (no local SSL needed - recommended)"
    echo "2. Let's Encrypt (requires domain pointing to this server)"
    echo "3. Self-signed certificate (for testing only)"
    echo ""
    echo -en "${CYAN}Select SSL method [1]: ${NC}"
    read -r SSL_METHOD
    SSL_METHOD=${SSL_METHOD:-1}
    
    # Server IP
    SERVER_IP=$(get_server_ip)
    log "INFO" "Detected server IP: $SERVER_IP"
    
    # Summary
    print_section "Configuration Summary"
    echo -e "  Domain:          ${GREEN}$DOMAIN_NAME${NC}"
    echo -e "  Application:     ${GREEN}$APP_NAME${NC}"
    echo -e "  App Port:        ${GREEN}$APP_PORT${NC}"
    echo -e "  Server IP:       ${GREEN}$SERVER_IP${NC}"
    echo -e "  SSL Method:      ${GREEN}$(case $SSL_METHOD in 1) echo 'Cloudflare Tunnel';; 2) echo 'Let'\''s Encrypt';; 3) echo 'Self-signed';; esac)${NC}"
    echo ""
    
    if ! confirm "Proceed with these settings?"; then
        log "INFO" "Setup cancelled"
        exit 0
    fi
}

#===============================================================================
# INSTALL NGINX
#===============================================================================

install_nginx() {
    print_section "Installing Nginx"
    
    if command_exists nginx; then
        log "INFO" "Nginx already installed: $(nginx -v 2>&1)"
        return 0
    fi
    
    log "INFO" "Installing Nginx..."
    
    # Method 1: apt
    if sudo apt-get update && sudo apt-get install -y nginx; then
        log "INFO" "Nginx installed via apt"
    else
        # Method 2: Official Nginx repo
        log "WARN" "apt install failed, trying official repo..."
        
        # Add Nginx signing key
        curl -fsSL https://nginx.org/keys/nginx_signing.key | sudo gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
        
        # Add repo
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list
        
        sudo apt-get update
        sudo apt-get install -y nginx || {
            log "ERROR" "Failed to install Nginx"
            exit 1
        }
    fi
    
    # Start and enable
    sudo systemctl start nginx
    sudo systemctl enable nginx
    
    log "INFO" "Nginx installed and started"
}

#===============================================================================
# CONFIGURE NGINX (HTTP ONLY - For Cloudflare Tunnel)
#===============================================================================

configure_nginx_http() {
    print_section "Configuring Nginx (HTTP for Cloudflare Tunnel)"
    
    # Backup existing config
    if [ -f "/etc/nginx/sites-available/$APP_NAME" ]; then
        sudo cp "/etc/nginx/sites-available/$APP_NAME" "/etc/nginx/sites-available/$APP_NAME.bak.$(date +%s)"
    fi
    
    # Remove default site
    sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    
    # Create Nginx config
    log "INFO" "Creating Nginx configuration..."
    sudo tee /etc/nginx/sites-available/$APP_NAME > /dev/null << EOF
# Nginx configuration for $APP_NAME
# Domain: $DOMAIN_NAME
# SSL handled by Cloudflare Tunnel
# www redirects to non-www

# Redirect www to non-www (Cloudflare handles HTTPS)
server {
    listen 80;
    listen [::]:80;
    server_name www.$DOMAIN_NAME;
    return 301 http://$DOMAIN_NAME\$request_uri;
}

# Main server block
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json image/svg+xml;
    gzip_comp_level 6;

    # Main application
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Webhook endpoint (CI/CD)
    location /hooks/ {
        proxy_pass http://127.0.0.1:$WEBHOOK_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Health check endpoint
    location /health {
        access_log off;
        return 200 'OK';
        add_header Content-Type text/plain;
    }

    # Static file caching
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
EOF
    
    # Enable site
    sudo ln -sf /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled/
    
    # Test config
    log "INFO" "Testing Nginx configuration..."
    if sudo nginx -t; then
        log "INFO" "Nginx configuration valid"
    else
        log "ERROR" "Nginx configuration invalid"
        exit 1
    fi
    
    # Reload Nginx
    sudo systemctl reload nginx
    log "INFO" "Nginx configured and reloaded"
}

#===============================================================================
# CONFIGURE NGINX WITH LET'S ENCRYPT
#===============================================================================

configure_nginx_letsencrypt() {
    print_section "Configuring Nginx with Let's Encrypt SSL"
    
    # First setup HTTP config
    configure_nginx_http
    
    # Install Certbot
    log "INFO" "Installing Certbot..."
    if ! command_exists certbot; then
        # Method 1: snap (recommended)
        if command_exists snap; then
            sudo snap install --classic certbot || {
                # Method 2: apt
                log "WARN" "Snap install failed, trying apt..."
                sudo apt-get install -y certbot python3-certbot-nginx
            }
            sudo ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
        else
            # Method 2: apt directly
            sudo apt-get install -y certbot python3-certbot-nginx
        fi
    fi
    
    # Verify certbot
    if ! command_exists certbot; then
        log "ERROR" "Certbot installation failed"
        log "INFO" "You can manually install with: sudo snap install --classic certbot"
        return 1
    fi
    
    # Check if domain points to this server
    log "INFO" "Verifying domain DNS..."
    local domain_ip=$(dig +short $DOMAIN_NAME 2>/dev/null | head -1)
    local public_ip=$(curl -s ifconfig.me 2>/dev/null)
    
    if [ "$domain_ip" != "$public_ip" ]; then
        log "WARN" "Domain $DOMAIN_NAME does not point to this server"
        log "WARN" "Domain resolves to: $domain_ip"
        log "WARN" "This server's public IP: $public_ip"
        if ! confirm "Continue anyway? (May fail)"; then
            return 1
        fi
    fi
    
    # Get certificate
    log "INFO" "Obtaining SSL certificate..."
    local CERT_EMAIL="murli.sharma06@gmail.com"
    log "INFO" "Using email: $CERT_EMAIL"
    
    if sudo certbot --nginx -d $DOMAIN_NAME -d www.$DOMAIN_NAME --non-interactive --agree-tos --email "$CERT_EMAIL" --redirect; then
        log "INFO" "SSL certificate obtained successfully"
    else
        log "ERROR" "Failed to obtain SSL certificate"
        log "INFO" "Trying with HTTP challenge only..."
        sudo certbot --nginx -d $DOMAIN_NAME --non-interactive --agree-tos --email "$CERT_EMAIL" --redirect || {
            log "ERROR" "SSL setup failed. Domain may not be pointing to this server."
            return 1
        }
    fi
    
    # Setup auto-renewal
    log "INFO" "Setting up auto-renewal..."
    sudo systemctl enable certbot.timer 2>/dev/null || true
    sudo systemctl start certbot.timer 2>/dev/null || true
    
    # Test renewal
    sudo certbot renew --dry-run
    
    # Now update nginx config to redirect www to non-www properly
    log "INFO" "Updating Nginx config for www to non-www redirect..."
    update_nginx_www_redirect
    
    log "INFO" "Let's Encrypt SSL configured with auto-renewal"
}

#===============================================================================
# UPDATE NGINX WWW REDIRECT
#===============================================================================

update_nginx_www_redirect() {
    # Create proper redirect config
    sudo tee /etc/nginx/sites-available/$APP_NAME > /dev/null << EOF
# Nginx configuration for $APP_NAME with Let's Encrypt SSL
# Domain: $DOMAIN_NAME
# HTTP -> HTTPS redirect and www -> non-www redirect

# Redirect HTTP to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    return 301 https://$DOMAIN_NAME\$request_uri;
}

# Redirect www HTTPS to non-www HTTPS
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name www.$DOMAIN_NAME;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    return 301 https://$DOMAIN_NAME\$request_uri;
}

# Main HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_NAME;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json image/svg+xml;
    gzip_comp_level 6;

    # Main application
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Webhook endpoint (CI/CD)
    location /hooks/ {
        proxy_pass http://127.0.0.1:$WEBHOOK_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Health check endpoint
    location /health {
        access_log off;
        return 200 'OK';
        add_header Content-Type text/plain;
    }

    # Static file caching
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
EOF

    # Test and reload
    if sudo nginx -t; then
        sudo systemctl reload nginx
        log "INFO" "Nginx www redirect configured"
    else
        log "WARN" "Nginx config test failed, keeping certbot-generated config"
    fi
}

#===============================================================================
# CONFIGURE NGINX WITH SELF-SIGNED CERT
#===============================================================================

configure_nginx_selfsigned() {
    print_section "Configuring Nginx with Self-Signed Certificate"
    
    # Create SSL directory
    sudo mkdir -p /etc/nginx/ssl
    
    # Generate self-signed certificate
    log "INFO" "Generating self-signed certificate..."
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/$APP_NAME.key \
        -out /etc/nginx/ssl/$APP_NAME.crt \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=$DOMAIN_NAME"
    
    # Create Nginx config with SSL
    sudo tee /etc/nginx/sites-available/$APP_NAME > /dev/null << EOF
# Nginx configuration for $APP_NAME with self-signed SSL
# Domain: $DOMAIN_NAME
# HTTP -> HTTPS redirect and www -> non-www redirect

# Redirect HTTP to HTTPS (always to non-www)
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    return 301 https://$DOMAIN_NAME\$request_uri;
}

# Redirect www HTTPS to non-www HTTPS
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name www.$DOMAIN_NAME;

    ssl_certificate /etc/nginx/ssl/$APP_NAME.crt;
    ssl_certificate_key /etc/nginx/ssl/$APP_NAME.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;

    return 301 https://$DOMAIN_NAME\$request_uri;
}

# Main HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_NAME;

    # SSL configuration
    ssl_certificate /etc/nginx/ssl/$APP_NAME.crt;
    ssl_certificate_key /etc/nginx/ssl/$APP_NAME.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;

    # Main application
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Webhook endpoint
    location /hooks/ {
        proxy_pass http://127.0.0.1:$WEBHOOK_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Health check
    location /health {
        access_log off;
        return 200 'OK';
        add_header Content-Type text/plain;
    }

    # Static file caching
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
EOF
    
    # Enable and test
    sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    sudo ln -sf /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled/
    
    if sudo nginx -t; then
        sudo systemctl reload nginx
        log "INFO" "Self-signed SSL configured"
    else
        log "ERROR" "Nginx configuration invalid"
        exit 1
    fi
}

#===============================================================================
# VERIFY SETUP
#===============================================================================

verify_setup() {
    print_section "Verifying Setup"
    
    # Check Nginx status
    if sudo systemctl is-active --quiet nginx; then
        log "INFO" "Nginx is running"
    else
        log "ERROR" "Nginx is not running"
        sudo systemctl status nginx
        exit 1
    fi
    
    # Test local connection
    log "INFO" "Testing local connection..."
    local response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost)
    if [ "$response" = "200" ] || [ "$response" = "301" ] || [ "$response" = "302" ]; then
        log "INFO" "Local connection successful (HTTP $response)"
    else
        log "WARN" "Local connection returned HTTP $response"
    fi
    
    # Test app proxy
    local app_response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$APP_PORT)
    if [ "$app_response" = "200" ]; then
        log "INFO" "Application responding on port $APP_PORT"
    else
        log "WARN" "Application returned HTTP $app_response on port $APP_PORT"
        log "INFO" "Check PM2 status: pm2 status"
    fi
}

#===============================================================================
# DISPLAY SUMMARY
#===============================================================================

display_summary() {
    print_section "Nginx & SSL Setup Complete!"
    
    local server_ip=$(get_server_ip)
    
    echo -e "${GREEN}Configuration:${NC}"
    echo -e "  Domain:      $DOMAIN_NAME"
    echo -e "  Server IP:   $server_ip"
    echo -e "  App Port:    $APP_PORT"
    echo ""
    
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}ACCESS INFORMATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Internal URL:  ${GREEN}http://$server_ip${NC}"
    
    case $SSL_METHOD in
        1)
            echo -e "External URL:  ${GREEN}https://$DOMAIN_NAME${NC} (via Cloudflare Tunnel)"
            echo ""
            echo -e "${YELLOW}Next Step:${NC}"
            echo "Run cloudflare-tunnel-setup.sh on your Cloudflare Tunnel VM"
            echo "Point the tunnel to: http://$server_ip:80"
            ;;
        2)
            echo -e "External URL:  ${GREEN}https://$DOMAIN_NAME${NC}"
            echo ""
            echo -e "${YELLOW}SSL Certificate:${NC} Let's Encrypt (auto-renews)"
            ;;
        3)
            echo -e "External URL:  ${GREEN}https://$DOMAIN_NAME${NC} (self-signed - browser warning)"
            ;;
    esac
    
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  sudo nginx -t                    # Test config"
    echo "  sudo systemctl reload nginx      # Reload config"
    echo "  sudo systemctl status nginx      # Check status"
    echo "  sudo tail -f /var/log/nginx/error.log  # View errors"
    echo ""
    
    # Update config file
    if [ -f "$CONFIG_FILE" ]; then
        echo "DOMAIN_NAME=$DOMAIN_NAME" >> "$CONFIG_FILE"
        echo "SERVER_IP=$server_ip" >> "$CONFIG_FILE"
        echo "SSL_METHOD=$SSL_METHOD" >> "$CONFIG_FILE"
    fi
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

main() {
    print_section "Nginx & SSL Setup Script"
    echo "This script will configure:"
    echo "  - Nginx reverse proxy"
    echo "  - SSL certificate (optional)"
    echo "  - Security headers"
    echo "  - Gzip compression"
    echo ""
    
    if ! confirm "Continue with setup?"; then
        exit 0
    fi
    
    collect_inputs
    install_nginx
    
    case $SSL_METHOD in
        1) configure_nginx_http ;;
        2) configure_nginx_letsencrypt ;;
        3) configure_nginx_selfsigned ;;
        *) configure_nginx_http ;;
    esac
    
    verify_setup
    display_summary
}

main "$@"
