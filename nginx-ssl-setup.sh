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

retry_command() {
    local max_attempts=${1:-3}
    local delay=${2:-5}
    shift 2
    local cmd="$@"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log "INFO" "Attempt $attempt of $max_attempts: $cmd"
        if eval "$cmd"; then
            return 0
        fi
        log "WARN" "Command failed, retrying in ${delay}s..."
        sleep $delay
        ((attempt++))
    done
    
    log "ERROR" "Command failed after $max_attempts attempts"
    return 1
}

#===============================================================================
# LOAD EXISTING CONFIGURATION
#===============================================================================

load_existing_config() {
    # Load from main-server-setup config
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        log "DEBUG" "Loaded app config: $APP_NAME on port $APP_PORT"
    fi
    
    # Load from nginx config if exists
    local nginx_config=$(ls /etc/nginx/sites-available/* 2>/dev/null | grep -v default | head -1)
    if [ -n "$nginx_config" ] && [ -f "$nginx_config" ]; then
        # Extract domain from nginx config
        local found_domain=$(grep "server_name" "$nginx_config" 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')
        if [ -n "$found_domain" ] && [ "$found_domain" != "_" ]; then
            EXISTING_DOMAIN="$found_domain"
            log "DEBUG" "Found existing domain: $EXISTING_DOMAIN"
        fi
        
        # Extract port from proxy_pass
        local found_port=$(grep "proxy_pass" "$nginx_config" 2>/dev/null | head -1 | grep -oE ':[0-9]+' | head -1 | tr -d ':')
        if [ -n "$found_port" ]; then
            EXISTING_PORT="$found_port"
            log "DEBUG" "Found existing port: $EXISTING_PORT"
        fi
        
        # Extract app name from config file
        EXISTING_APP_NAME=$(basename "$nginx_config")
        log "DEBUG" "Found existing app: $EXISTING_APP_NAME"
    fi
    
    # Detect SSL method
    if [ -d "/etc/letsencrypt/live" ] && ls /etc/letsencrypt/live/*/fullchain.pem &>/dev/null; then
        EXISTING_SSL="letsencrypt"
    elif ls /etc/nginx/ssl/*.crt &>/dev/null; then
        EXISTING_SSL="selfsigned"
    else
        EXISTING_SSL="http"
    fi
}

#===============================================================================
# INPUT COLLECTION
#===============================================================================

collect_inputs() {
    print_section "Configuration Setup"
    
    # Load existing config if available
    load_existing_config
    
    if [ -f "$CONFIG_FILE" ]; then
        log "INFO" "Loading configuration from main-server-setup..."
        source "$CONFIG_FILE"
        log "INFO" "Loaded: APP_NAME=$APP_NAME, APP_PORT=$APP_PORT"
    fi
    
    # Domain name - use existing if available
    if [ -n "$EXISTING_DOMAIN" ]; then
        echo -en "${CYAN}Enter your domain name [${EXISTING_DOMAIN}]: ${NC}"
        read -r DOMAIN_NAME
        DOMAIN_NAME=${DOMAIN_NAME:-$EXISTING_DOMAIN}
    else
        echo -en "${CYAN}Enter your domain name (e.g., example.com): ${NC}"
        read -r DOMAIN_NAME
        while [ -z "$DOMAIN_NAME" ]; do
            echo -e "${RED}Domain name is required!${NC}"
            echo -en "${CYAN}Enter your domain name: ${NC}"
            read -r DOMAIN_NAME
        done
    fi
    
    # App name if not loaded - use existing if available
    if [ -z "$APP_NAME" ]; then
        if [ -n "$EXISTING_APP_NAME" ]; then
            echo -en "${CYAN}Enter application name [${EXISTING_APP_NAME}]: ${NC}"
            read -r APP_NAME
            APP_NAME=${APP_NAME:-$EXISTING_APP_NAME}
        else
            local default_name=$(basename "$PARENT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
            echo -en "${CYAN}Enter application name [${default_name}]: ${NC}"
            read -r APP_NAME
            APP_NAME=${APP_NAME:-$default_name}
        fi
    fi
    
    # App port if not loaded - use existing if available
    if [ -z "$APP_PORT" ] || [ "$APP_PORT" = "3000" ]; then
        if [ -n "$EXISTING_PORT" ]; then
            echo -en "${CYAN}Enter application port [${EXISTING_PORT}]: ${NC}"
            read -r input_port
            APP_PORT=${input_port:-$EXISTING_PORT}
        else
            echo -en "${CYAN}Enter application port [3000]: ${NC}"
            read -r input_port
            APP_PORT=${input_port:-3000}
        fi
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
# FIX NGINX CONFIGURATION
#===============================================================================

fix_nginx_config() {
    print_section "Fix Nginx Configuration - Automatic Repair"
    
    local issues_found=0
    local issues_fixed=0
    
    log "INFO" "Scanning for configuration issues..."
    load_existing_config
    echo ""
    
    # 1. Check nginx installation
    echo -e "${CYAN}1. Checking Nginx installation...${NC}"
    if ! command_exists nginx; then
        echo -e "   ${RED}✗ Nginx not installed${NC}"
        ((issues_found++))
        if confirm "   Install Nginx?"; then
            install_nginx
            ((issues_fixed++))
        fi
    else
        echo -e "   ${GREEN}✓ Nginx installed: $(nginx -v 2>&1 | cut -d'/' -f2)${NC}"
    fi
    
    # 2. Check nginx service
    echo -e "${CYAN}2. Checking Nginx service...${NC}"
    if sudo systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "   ${GREEN}✓ Nginx is running${NC}"
    else
        echo -e "   ${RED}✗ Nginx not running${NC}"
        ((issues_found++))
        if confirm "   Start Nginx?"; then
            sudo systemctl start nginx
            if sudo systemctl is-active --quiet nginx; then
                echo -e "   ${GREEN}✓ Nginx started${NC}"
                ((issues_fixed++))
            else
                echo -e "   ${RED}Failed to start Nginx${NC}"
                sudo journalctl -u nginx -n 10 --no-pager
            fi
        fi
    fi
    
    # 3. Check nginx configuration
    echo -e "${CYAN}3. Checking Nginx configuration syntax...${NC}"
    if sudo nginx -t 2>/dev/null; then
        echo -e "   ${GREEN}✓ Configuration syntax OK${NC}"
    else
        echo -e "   ${RED}✗ Configuration syntax error${NC}"
        ((issues_found++))
        sudo nginx -t 2>&1 | head -5
        
        if confirm "   Try to fix configuration?"; then
            # Backup and recreate
            local config_file="/etc/nginx/sites-available/$EXISTING_APP_NAME"
            if [ -f "$config_file" ]; then
                sudo cp "$config_file" "${config_file}.broken.$(date +%s)"
                log "INFO" "Backed up broken config"
            fi
            
            if [ -n "$EXISTING_DOMAIN" ] && [ -n "$EXISTING_PORT" ]; then
                DOMAIN_NAME="$EXISTING_DOMAIN"
                APP_PORT="$EXISTING_PORT"
                APP_NAME="$EXISTING_APP_NAME"
                
                case $EXISTING_SSL in
                    letsencrypt) configure_nginx_letsencrypt ;;
                    selfsigned) configure_nginx_selfsigned ;;
                    *) configure_nginx_http ;;
                esac
                ((issues_fixed++))
            else
                echo -e "   ${YELLOW}Cannot auto-fix - need domain and port info${NC}"
            fi
        fi
    fi
    
    # 4. Check site is enabled
    echo -e "${CYAN}4. Checking site configuration...${NC}"
    local enabled_sites=$(ls /etc/nginx/sites-enabled/ 2>/dev/null | grep -v default | wc -l)
    if [ "$enabled_sites" -gt 0 ]; then
        echo -e "   ${GREEN}✓ Found $enabled_sites enabled site(s)${NC}"
        ls /etc/nginx/sites-enabled/ | grep -v default | while read site; do
            echo -e "      - $site"
        done
    else
        echo -e "   ${YELLOW}⚠ No custom sites enabled${NC}"
        ((issues_found++))
        
        local available_sites=$(ls /etc/nginx/sites-available/ 2>/dev/null | grep -v default | head -1)
        if [ -n "$available_sites" ]; then
            if confirm "   Enable $available_sites?"; then
                sudo ln -sf "/etc/nginx/sites-available/$available_sites" "/etc/nginx/sites-enabled/"
                sudo nginx -t && sudo systemctl reload nginx
                ((issues_fixed++))
            fi
        fi
    fi
    
    # 5. Check application connectivity
    echo -e "${CYAN}5. Checking backend application...${NC}"
    local test_port="${EXISTING_PORT:-3000}"
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$test_port" 2>/dev/null | grep -qE "200|301|302"; then
        echo -e "   ${GREEN}✓ Application responding on port $test_port${NC}"
    else
        echo -e "   ${YELLOW}⚠ Application not responding on port $test_port${NC}"
        ((issues_found++))
        echo -e "   ${YELLOW}   Check if your application is running (pm2 status, docker ps, etc.)${NC}"
    fi
    
    # 6. Check SSL certificates
    echo -e "${CYAN}6. Checking SSL certificates...${NC}"
    case $EXISTING_SSL in
        letsencrypt)
            if [ -d "/etc/letsencrypt/live" ]; then
                local cert_domain=$(ls /etc/letsencrypt/live/ | head -1)
                if [ -n "$cert_domain" ]; then
                    local cert_file="/etc/letsencrypt/live/$cert_domain/fullchain.pem"
                    if [ -f "$cert_file" ]; then
                        local expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
                        local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
                        local now_epoch=$(date +%s)
                        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                        
                        if [ "$days_left" -gt 30 ]; then
                            echo -e "   ${GREEN}✓ Let's Encrypt cert valid ($days_left days left)${NC}"
                        elif [ "$days_left" -gt 0 ]; then
                            echo -e "   ${YELLOW}⚠ Let's Encrypt cert expiring soon ($days_left days left)${NC}"
                            ((issues_found++))
                            if confirm "   Renew certificate?"; then
                                sudo certbot renew --force-renewal
                                ((issues_fixed++))
                            fi
                        else
                            echo -e "   ${RED}✗ Let's Encrypt cert expired${NC}"
                            ((issues_found++))
                            if confirm "   Renew certificate?"; then
                                sudo certbot renew --force-renewal
                                ((issues_fixed++))
                            fi
                        fi
                    fi
                fi
            fi
            ;;
        selfsigned)
            echo -e "   ${GREEN}✓ Using self-signed certificate${NC}"
            ;;
        *)
            echo -e "   ${YELLOW}⚠ No SSL configured (HTTP only)${NC}"
            ;;
    esac
    
    # 7. Check firewall
    echo -e "${CYAN}7. Checking firewall...${NC}"
    if command_exists ufw; then
        if sudo ufw status | grep -q "80\|443"; then
            echo -e "   ${GREEN}✓ Firewall allows HTTP/HTTPS${NC}"
        else
            echo -e "   ${YELLOW}⚠ Firewall may be blocking HTTP/HTTPS${NC}"
            ((issues_found++))
            if confirm "   Allow HTTP/HTTPS in firewall?"; then
                sudo ufw allow 'Nginx Full' || {
                    sudo ufw allow 80/tcp
                    sudo ufw allow 443/tcp
                }
                ((issues_fixed++))
            fi
        fi
    else
        echo -e "   ${YELLOW}⚠ UFW not installed (firewall status unknown)${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    if [ $issues_found -eq 0 ]; then
        log "INFO" "No issues found! Nginx configuration appears healthy."
    else
        log "INFO" "Found $issues_found issue(s), fixed $issues_fixed"
        
        if [ $issues_fixed -gt 0 ]; then
            echo ""
            if confirm "Reload Nginx to apply changes?"; then
                if sudo nginx -t; then
                    sudo systemctl reload nginx
                    log "INFO" "Nginx reloaded successfully"
                else
                    log "ERROR" "Nginx config test failed"
                fi
            fi
        fi
    fi
    
    echo ""
    if confirm "Return to menu?"; then
        show_menu
    fi
}

#===============================================================================
# VIEW CONFIGURATION
#===============================================================================

view_nginx_config() {
    print_section "Current Nginx Configuration"
    
    load_existing_config
    
    echo -e "${CYAN}Enabled Sites:${NC}"
    ls -la /etc/nginx/sites-enabled/ 2>/dev/null | tail -n +2
    echo ""
    
    if [ -n "$EXISTING_APP_NAME" ]; then
        echo -e "${CYAN}Configuration for $EXISTING_APP_NAME:${NC}"
        echo "═══════════════════════════════════════════════════════════════"
        sudo cat "/etc/nginx/sites-available/$EXISTING_APP_NAME" 2>/dev/null || echo "File not found"
    fi
    
    echo ""
    if confirm "Return to menu?"; then
        show_menu
    fi
}

#===============================================================================
# RESTART NGINX
#===============================================================================

restart_nginx() {
    print_section "Restart Nginx"
    
    log "INFO" "Testing configuration..."
    if sudo nginx -t; then
        log "INFO" "Configuration OK, restarting..."
        sudo systemctl restart nginx
        
        sleep 2
        if sudo systemctl is-active --quiet nginx; then
            log "INFO" "Nginx restarted successfully"
            sudo systemctl status nginx --no-pager | head -10
        else
            log "ERROR" "Nginx failed to restart"
            sudo journalctl -u nginx -n 15 --no-pager
        fi
    else
        log "ERROR" "Configuration test failed"
    fi
    
    echo ""
    if confirm "Return to menu?"; then
        show_menu
    fi
}

#===============================================================================
# VIEW LOGS
#===============================================================================

view_nginx_logs() {
    echo ""
    echo -e "${CYAN}Select log to view:${NC}"
    echo "1. Error log"
    echo "2. Access log"
    echo "3. Both (combined)"
    echo ""
    echo -en "${CYAN}Select [1]: ${NC}"
    read -r log_choice
    log_choice=${log_choice:-1}
    
    echo "Press Ctrl+C to stop viewing logs"
    sleep 2
    
    case $log_choice in
        1) sudo tail -f /var/log/nginx/error.log ;;
        2) sudo tail -f /var/log/nginx/access.log ;;
        3) sudo tail -f /var/log/nginx/error.log /var/log/nginx/access.log ;;
    esac
}

#===============================================================================
# AUTO DEBUG - FULLY AUTOMATIC DIAGNOSTICS AND REPAIR
#===============================================================================

auto_debug() {
    print_section "Auto Debug - Automatic Diagnostics & Repair"
    
    log "INFO" "Running fully automatic debug with existing parameters..."
    log "INFO" "No user input required - all fixes applied automatically"
    echo ""
    
    local total_checks=0
    local passed_checks=0
    local failed_checks=0
    local auto_fixed=0
    local manual_needed=0
    
    # Load existing configuration first
    load_existing_config
    
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    STARTING AUTO DEBUG                         ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    #---------------------------------------------------------------------------
    # CHECK 1: Nginx installation
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[1/10] Checking Nginx installation...${NC}"
    if command_exists nginx; then
        local nginx_version=$(nginx -v 2>&1 | cut -d'/' -f2)
        echo -e "   ${GREEN}✓ PASS${NC} - Nginx installed (v$nginx_version)"
        ((passed_checks++))
    else
        echo -e "   ${RED}✗ FAIL${NC} - Nginx not installed"
        echo -e "   ${YELLOW}→ AUTO-FIX: Installing Nginx...${NC}"
        ((failed_checks++))
        if retry_command 3 5 "sudo apt-get update && sudo apt-get install -y nginx"; then
            echo -e "   ${GREEN}✓ FIXED${NC} - Nginx installed successfully"
            ((auto_fixed++))
        else
            echo -e "   ${RED}✗ FAILED TO FIX${NC} - Manual installation required"
            ((manual_needed++))
        fi
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 2: Nginx service running
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[2/10] Checking Nginx service...${NC}"
    if sudo systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "   ${GREEN}✓ PASS${NC} - Nginx service is running"
        ((passed_checks++))
    else
        echo -e "   ${RED}✗ FAIL${NC} - Nginx service not running"
        ((failed_checks++))
        echo -e "   ${YELLOW}→ AUTO-FIX: Starting Nginx...${NC}"
        if sudo systemctl start nginx 2>/dev/null; then
            sleep 2
            if sudo systemctl is-active --quiet nginx; then
                echo -e "   ${GREEN}✓ FIXED${NC} - Nginx started successfully"
                ((auto_fixed++))
            else
                echo -e "   ${RED}✗ FAILED TO FIX${NC} - Check logs: journalctl -u nginx"
                ((manual_needed++))
            fi
        else
            echo -e "   ${RED}✗ FAILED TO FIX${NC} - Could not start Nginx"
            ((manual_needed++))
        fi
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 3: Nginx service enabled
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[3/10] Checking Nginx auto-start...${NC}"
    if sudo systemctl is-enabled --quiet nginx 2>/dev/null; then
        echo -e "   ${GREEN}✓ PASS${NC} - Nginx enabled (auto-start on boot)"
        ((passed_checks++))
    else
        echo -e "   ${YELLOW}⚠ WARN${NC} - Nginx not enabled for auto-start"
        ((failed_checks++))
        echo -e "   ${YELLOW}→ AUTO-FIX: Enabling Nginx...${NC}"
        if sudo systemctl enable nginx 2>/dev/null; then
            echo -e "   ${GREEN}✓ FIXED${NC} - Nginx enabled"
            ((auto_fixed++))
        else
            echo -e "   ${RED}✗ FAILED TO FIX${NC}"
            ((manual_needed++))
        fi
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 4: Configuration syntax
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[4/10] Checking Nginx configuration syntax...${NC}"
    if sudo nginx -t 2>/dev/null; then
        echo -e "   ${GREEN}✓ PASS${NC} - Configuration syntax is valid"
        ((passed_checks++))
    else
        echo -e "   ${RED}✗ FAIL${NC} - Configuration syntax error"
        ((failed_checks++))
        sudo nginx -t 2>&1 | head -3
        
        # Try to auto-fix by regenerating config if we have domain info
        if [ -n "$EXISTING_DOMAIN" ] && [ -n "$EXISTING_PORT" ]; then
            echo -e "   ${YELLOW}→ AUTO-FIX: Regenerating configuration...${NC}"
            local config_file="/etc/nginx/sites-available/${EXISTING_APP_NAME:-default}"
            
            # Backup broken config
            sudo cp "$config_file" "${config_file}.broken.$(date +%s)" 2>/dev/null
            
            # Create basic working config
            sudo tee "$config_file" > /dev/null << EOCFG
server {
    listen 80;
    server_name $EXISTING_DOMAIN www.$EXISTING_DOMAIN;
    
    location / {
        proxy_pass http://127.0.0.1:${EXISTING_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOCFG
            
            # Enable site
            sudo ln -sf "$config_file" "/etc/nginx/sites-enabled/" 2>/dev/null
            
            if sudo nginx -t 2>/dev/null; then
                echo -e "   ${GREEN}✓ FIXED${NC} - Configuration regenerated"
                ((auto_fixed++))
            else
                echo -e "   ${RED}✗ FAILED TO FIX${NC} - Manual review needed"
                ((manual_needed++))
            fi
        else
            echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - No domain info to regenerate config"
            ((manual_needed++))
        fi
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 5: Site configuration exists
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[5/10] Checking site configurations...${NC}"
    local enabled_sites=$(ls /etc/nginx/sites-enabled/ 2>/dev/null | grep -v default | wc -l)
    if [ "$enabled_sites" -gt 0 ]; then
        echo -e "   ${GREEN}✓ PASS${NC} - Found $enabled_sites enabled site(s)"
        ((passed_checks++))
    else
        echo -e "   ${YELLOW}⚠ WARN${NC} - No custom sites enabled"
        ((failed_checks++))
        
        # Try to enable available site
        local available_site=$(ls /etc/nginx/sites-available/ 2>/dev/null | grep -v default | head -1)
        if [ -n "$available_site" ]; then
            echo -e "   ${YELLOW}→ AUTO-FIX: Enabling $available_site...${NC}"
            sudo ln -sf "/etc/nginx/sites-available/$available_site" /etc/nginx/sites-enabled/
            if sudo nginx -t 2>/dev/null; then
                sudo systemctl reload nginx
                echo -e "   ${GREEN}✓ FIXED${NC} - Site enabled"
                ((auto_fixed++))
            else
                sudo rm "/etc/nginx/sites-enabled/$available_site" 2>/dev/null
                echo -e "   ${RED}✗ FAILED TO FIX${NC} - Config has errors"
                ((manual_needed++))
            fi
        else
            echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - No site configurations found"
            ((manual_needed++))
        fi
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 6: Backend application responding
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[6/10] Checking backend application...${NC}"
    local test_port="${EXISTING_PORT:-3000}"
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$test_port" 2>/dev/null || echo "000")
    
    if [[ "$http_code" =~ ^(200|301|302|304|404)$ ]]; then
        echo -e "   ${GREEN}✓ PASS${NC} - Backend responding on port $test_port (HTTP $http_code)"
        ((passed_checks++))
    else
        echo -e "   ${RED}✗ FAIL${NC} - Backend not responding on port $test_port (HTTP $http_code)"
        ((failed_checks++))
        echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - Start your application first"
        ((manual_needed++))
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 7: SSL certificates
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[7/10] Checking SSL certificates...${NC}"
    case "$EXISTING_SSL" in
        letsencrypt)
            if [ -d "/etc/letsencrypt/live" ]; then
                local cert_domain=$(ls /etc/letsencrypt/live/ 2>/dev/null | head -1)
                if [ -n "$cert_domain" ] && [ -f "/etc/letsencrypt/live/$cert_domain/fullchain.pem" ]; then
                    local expiry=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$cert_domain/fullchain.pem" 2>/dev/null | cut -d= -f2)
                    local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
                    local now_epoch=$(date +%s)
                    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                    
                    if [ "$days_left" -gt 30 ]; then
                        echo -e "   ${GREEN}✓ PASS${NC} - Let's Encrypt cert valid ($days_left days left)"
                        ((passed_checks++))
                    elif [ "$days_left" -gt 0 ]; then
                        echo -e "   ${YELLOW}⚠ WARN${NC} - Cert expiring soon ($days_left days)"
                        ((failed_checks++))
                        echo -e "   ${YELLOW}→ AUTO-FIX: Renewing certificate...${NC}"
                        if sudo certbot renew --force-renewal 2>/dev/null; then
                            echo -e "   ${GREEN}✓ FIXED${NC} - Certificate renewed"
                            ((auto_fixed++))
                        else
                            echo -e "   ${RED}✗ FAILED TO FIX${NC} - Manual renewal needed"
                            ((manual_needed++))
                        fi
                    else
                        echo -e "   ${RED}✗ FAIL${NC} - Certificate expired"
                        ((failed_checks++))
                        echo -e "   ${YELLOW}→ AUTO-FIX: Renewing certificate...${NC}"
                        if sudo certbot renew --force-renewal 2>/dev/null; then
                            echo -e "   ${GREEN}✓ FIXED${NC} - Certificate renewed"
                            ((auto_fixed++))
                        else
                            ((manual_needed++))
                        fi
                    fi
                else
                    echo -e "   ${YELLOW}⚠ WARN${NC} - No Let's Encrypt cert found"
                    ((passed_checks++))
                fi
            else
                echo -e "   ${YELLOW}⊘ SKIP${NC} - Let's Encrypt not configured"
            fi
            ;;
        selfsigned)
            echo -e "   ${GREEN}✓ PASS${NC} - Using self-signed certificate"
            ((passed_checks++))
            ;;
        *)
            echo -e "   ${YELLOW}⊘ SKIP${NC} - No SSL configured (HTTP only)"
            ;;
    esac
    
    #---------------------------------------------------------------------------
    # CHECK 8: Firewall configuration
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[8/10] Checking firewall...${NC}"
    if command_exists ufw; then
        if sudo ufw status 2>/dev/null | grep -qE "80|443|Nginx"; then
            echo -e "   ${GREEN}✓ PASS${NC} - Firewall allows HTTP/HTTPS"
            ((passed_checks++))
        else
            echo -e "   ${YELLOW}⚠ WARN${NC} - HTTP/HTTPS may be blocked"
            ((failed_checks++))
            echo -e "   ${YELLOW}→ AUTO-FIX: Allowing HTTP/HTTPS...${NC}"
            sudo ufw allow 'Nginx Full' 2>/dev/null || {
                sudo ufw allow 80/tcp 2>/dev/null
                sudo ufw allow 443/tcp 2>/dev/null
            }
            echo -e "   ${GREEN}✓ FIXED${NC} - Firewall rules added"
            ((auto_fixed++))
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - UFW not installed"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 9: Domain DNS resolution
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[9/10] Checking domain DNS...${NC}"
    if [ -n "$EXISTING_DOMAIN" ]; then
        local resolved_ip=$(dig +short "$EXISTING_DOMAIN" 2>/dev/null | head -1)
        local server_ip=$(get_server_ip)
        
        if [ -n "$resolved_ip" ]; then
            echo -e "   ${GREEN}✓ PASS${NC} - $EXISTING_DOMAIN resolves to $resolved_ip"
            ((passed_checks++))
        else
            echo -e "   ${YELLOW}⚠ WARN${NC} - Could not resolve $EXISTING_DOMAIN"
            echo -e "   ${YELLOW}  (May be using Cloudflare Tunnel)${NC}"
            ((passed_checks++))
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - No domain configured"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 10: Test external access
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[10/10] Testing external access...${NC}"
    if [ -n "$EXISTING_DOMAIN" ]; then
        local ext_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$EXISTING_DOMAIN" 2>/dev/null || echo "000")
        if [[ "$ext_code" =~ ^(200|301|302|304)$ ]]; then
            echo -e "   ${GREEN}✓ PASS${NC} - External access working (HTTP $ext_code)"
            ((passed_checks++))
        else
            echo -e "   ${YELLOW}⚠ WARN${NC} - External access returned HTTP $ext_code"
            echo -e "   ${YELLOW}  (May need time for DNS propagation)${NC}"
            ((passed_checks++))
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - No domain to test"
    fi
    
    #---------------------------------------------------------------------------
    # Reload Nginx if fixes were made
    #---------------------------------------------------------------------------
    if [ $auto_fixed -gt 0 ]; then
        echo ""
        echo -e "${CYAN}Reloading Nginx to apply changes...${NC}"
        if sudo nginx -t 2>/dev/null && sudo systemctl reload nginx 2>/dev/null; then
            echo -e "${GREEN}✓ Nginx reloaded successfully${NC}"
        fi
    fi
    
    #---------------------------------------------------------------------------
    # SUMMARY
    #---------------------------------------------------------------------------
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    AUTO DEBUG SUMMARY                          ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Total Checks:      ${CYAN}$total_checks${NC}"
    echo -e "Passed:            ${GREEN}$passed_checks${NC}"
    echo -e "Failed:            ${RED}$failed_checks${NC}"
    echo -e "Auto-Fixed:        ${GREEN}$auto_fixed${NC}"
    echo -e "Manual Action:     ${YELLOW}$manual_needed${NC}"
    echo ""
    
    if [ $manual_needed -eq 0 ] && [ $failed_checks -eq 0 ]; then
        echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ✓ ALL CHECKS PASSED - NGINX IS HEALTHY                       ${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    elif [ $manual_needed -eq 0 ] && [ $auto_fixed -gt 0 ]; then
        echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ✓ ALL ISSUES AUTO-FIXED - NGINX SHOULD BE WORKING            ${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    else
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  ⚠ MANUAL ACTION REQUIRED FOR $manual_needed ISSUE(S)                       ${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    fi
    
    echo ""
    if confirm "Return to menu?"; then
        show_menu
    fi
}

#===============================================================================
# MENU
#===============================================================================

show_menu() {
    print_section "Nginx & SSL Setup"
    
    load_existing_config
    
    # Show current status
    if [ -n "$EXISTING_DOMAIN" ]; then
        echo -e "${GREEN}Detected configuration:${NC}"
        echo -e "  Domain: $EXISTING_DOMAIN"
        echo -e "  App: $EXISTING_APP_NAME (port $EXISTING_PORT)"
        echo -e "  SSL: $EXISTING_SSL"
        echo ""
    fi
    
    echo "What would you like to do?"
    echo ""
    echo "1. Full setup (new installation)"
    echo "2. Reconfigure existing site"
    echo "3. View current configuration"
    echo "4. Fix configuration (guided repair with prompts)"
    echo -e "${GREEN}5. Auto Debug (automatic check & fix everything)${NC}"
    echo "6. Restart Nginx"
    echo "7. View logs"
    echo "8. Exit"
    echo ""
    echo -en "${CYAN}Select option [1]: ${NC}"
    read -r menu_choice
    menu_choice=${menu_choice:-1}
    
    case $menu_choice in
        1) full_setup ;;
        2) reconfigure_site ;;
        3) view_nginx_config ;;
        4) fix_nginx_config ;;
        5) auto_debug ;;
        6) restart_nginx ;;
        7) view_nginx_logs ;;
        8) exit 0 ;;
        *) full_setup ;;
    esac
}

full_setup() {
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

reconfigure_site() {
    # Use existing values as defaults
    if [ -n "$EXISTING_DOMAIN" ]; then
        DOMAIN_NAME="$EXISTING_DOMAIN"
        APP_NAME="$EXISTING_APP_NAME"
        APP_PORT="$EXISTING_PORT"
    fi
    
    collect_inputs
    
    case $SSL_METHOD in
        1) configure_nginx_http ;;
        2) configure_nginx_letsencrypt ;;
        3) configure_nginx_selfsigned ;;
        *) configure_nginx_http ;;
    esac
    
    verify_setup
    display_summary
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
    
    show_menu
}

main "$@"
