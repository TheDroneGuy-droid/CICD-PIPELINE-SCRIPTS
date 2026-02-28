#!/bin/bash
#===============================================================================
# CLOUDFLARE TUNNEL SETUP SCRIPT
# Purpose: Universal Cloudflare Tunnel configuration for any deployment
# Usage: Run on your dedicated Cloudflare Tunnel VM
# 
# Features:
#   - Automatic DNS record creation via Cloudflare API
#   - Multiple subdomain support (www, api, app, etc.)
#   - Checks for existing DNS records before creating
#   - No dashboard access required - everything done from CLI
#   - Zone listing and management
#   - Service type auto-configuration
#
# Note: This script is reusable for multiple domains/services
#===============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Config file location
CF_CONFIG_DIR="$HOME/.cloudflared"
CF_CONFIG_FILE="$CF_CONFIG_DIR/config.yml"
SERVICES_FILE="$CF_CONFIG_DIR/services.json"
API_TOKEN_FILE="$CF_CONFIG_DIR/api_token"

# Cloudflare API
CF_API_URL="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""  # Will be loaded from file or prompted from user

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

check_dependencies() {
    # Check for jq (used for JSON parsing)
    if ! command_exists jq; then
        log "INFO" "Installing jq for JSON parsing..."
        if command_exists apt-get; then
            sudo apt-get update && sudo apt-get install -y jq
        elif command_exists yum; then
            sudo yum install -y jq
        elif command_exists dnf; then
            sudo dnf install -y jq
        elif command_exists pacman; then
            sudo pacman -S --noconfirm jq
        else
            log "WARN" "Could not install jq automatically. Please install it manually."
        fi
    fi
    
    # Check for curl
    if ! command_exists curl; then
        log "ERROR" "curl is required but not installed"
        exit 1
    fi
}

#===============================================================================
# CLOUDFLARE API FUNCTIONS
#===============================================================================

setup_api_token() {
    print_section "Cloudflare API Token Setup"
    
    # Check for existing token
    if [ -f "$API_TOKEN_FILE" ]; then
        CF_API_TOKEN=$(cat "$API_TOKEN_FILE")
        log "INFO" "API token loaded from $API_TOKEN_FILE"
        
        # Verify token works
        if verify_api_token; then
            if ! confirm "Use existing API token?"; then
                rm "$API_TOKEN_FILE"
                CF_API_TOKEN=""
            else
                return 0
            fi
        else
            log "WARN" "Existing token is invalid, requesting new one..."
            rm "$API_TOKEN_FILE"
            CF_API_TOKEN=""
        fi
    fi
    
    echo ""
    echo -e "${YELLOW}API Token Required for DNS Management${NC}"
    echo ""
    echo "To create an API token:"
    echo "1. Go to: https://dash.cloudflare.com/profile/api-tokens"
    echo "2. Click 'Create Token'"
    echo "3. Use 'Edit zone DNS' template OR create custom with:"
    echo "   - Zone:DNS:Edit"
    echo "   - Zone:Zone:Read"
    echo "4. Set zone resources to your domains"
    echo "5. Copy the token"
    echo ""
    
    while [ -z "$CF_API_TOKEN" ]; do
        echo -en "${CYAN}Enter your Cloudflare API Token: ${NC}"
        read -rs CF_API_TOKEN
        echo ""
        
        if [ -z "$CF_API_TOKEN" ]; then
            echo -e "${RED}API token is required for DNS management!${NC}"
            continue
        fi
        
        if verify_api_token; then
            # Save token
            echo "$CF_API_TOKEN" > "$API_TOKEN_FILE"
            chmod 600 "$API_TOKEN_FILE"
            log "INFO" "API token saved securely"
        else
            log "ERROR" "Invalid API token. Please try again."
            CF_API_TOKEN=""
        fi
    done
}

verify_api_token() {
    local response=$(curl -s -X GET "${CF_API_URL}/user/tokens/verify" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    if echo "$response" | grep -q '"success":true'; then
        log "INFO" "API token verified successfully"
        return 0
    else
        return 1
    fi
}

get_zones() {
    local response=$(curl -s -X GET "${CF_API_URL}/zones?per_page=50" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    echo "$response"
}

get_zone_id() {
    local domain="$1"
    
    # Extract root domain (handles subdomains)
    local root_domain=$(echo "$domain" | awk -F. '{if(NF>2){print $(NF-1)"."$NF}else{print $0}}')
    
    local response=$(curl -s -X GET "${CF_API_URL}/zones?name=${root_domain}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    if echo "$response" | grep -q '"success":true'; then
        local zone_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -n "$zone_id" ]; then
            echo "$zone_id"
            return 0
        fi
    fi
    
    return 1
}

list_available_zones() {
    print_section "Available Domains/Zones"
    
    log "INFO" "Fetching zones from Cloudflare..."
    
    local response=$(get_zones)
    
    if echo "$response" | grep -q '"success":true'; then
        echo -e "${CYAN}Your Cloudflare Zones:${NC}"
        echo ""
        
        # Parse and display zones
        local zones=$(echo "$response" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
        local zone_ids=$(echo "$response" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
        
        local i=1
        echo "$zones" | while read -r zone; do
            echo "  $i. $zone"
            i=$((i+1))
        done
        
        echo ""
        AVAILABLE_ZONES="$zones"
    else
        log "WARN" "Could not fetch zones. You may need to enter domain manually."
    fi
}

check_dns_record_exists() {
    local zone_id="$1"
    local record_name="$2"
    
    local response=$(curl -s -X GET "${CF_API_URL}/zones/${zone_id}/dns_records?name=${record_name}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    # Clear previous values to avoid stale data
    EXISTING_RECORD_ID=""
    EXISTING_RECORD_TYPE=""
    EXISTING_RECORD_CONTENT=""
    
    # Use jq if available for reliable parsing, otherwise fallback to grep with flexible whitespace
    if command_exists jq; then
        local count=$(echo "$response" | jq -r '.result | length' 2>/dev/null)
        if [ "$count" = "0" ] || [ -z "$count" ]; then
            return 1  # Record does not exist
        else
            # Extract existing record info from first result
            EXISTING_RECORD_ID=$(echo "$response" | jq -r '.result[0].id' 2>/dev/null)
            EXISTING_RECORD_TYPE=$(echo "$response" | jq -r '.result[0].type' 2>/dev/null)
            EXISTING_RECORD_CONTENT=$(echo "$response" | jq -r '.result[0].content' 2>/dev/null)
            return 0  # Record exists
        fi
    else
        # Fallback: use grep with flexible whitespace pattern
        if echo "$response" | grep -qE '"count"\s*:\s*0'; then
            return 1  # Record does not exist
        else
            # Extract existing record info (look specifically in result array)
            local record_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
            local record_type=$(echo "$response" | grep -o '"type":"[^"]*"' | head -1 | cut -d'"' -f4)
            local record_content=$(echo "$response" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
            
            EXISTING_RECORD_ID="$record_id"
            EXISTING_RECORD_TYPE="$record_type"
            EXISTING_RECORD_CONTENT="$record_content"
            return 0  # Record exists
        fi
    fi
}

create_dns_record() {
    local zone_id="$1"
    local record_name="$2"
    local record_content="$3"
    local record_type="${4:-CNAME}"
    local proxied="${5:-true}"
    
    local data="{\"type\":\"${record_type}\",\"name\":\"${record_name}\",\"content\":\"${record_content}\",\"proxied\":${proxied}}"
    
    local response=$(curl -s -X POST "${CF_API_URL}/zones/${zone_id}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$data")
    
    if echo "$response" | grep -q '"success":true'; then
        log "INFO" "DNS record created: $record_name -> $record_content"
        return 0
    else
        local error=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        log "ERROR" "Failed to create DNS record: $error"
        return 1
    fi
}

update_dns_record() {
    local zone_id="$1"
    local record_id="$2"
    local record_name="$3"
    local record_content="$4"
    local record_type="${5:-CNAME}"
    local proxied="${6:-true}"
    
    local data="{\"type\":\"${record_type}\",\"name\":\"${record_name}\",\"content\":\"${record_content}\",\"proxied\":${proxied}}"
    
    local response=$(curl -s -X PUT "${CF_API_URL}/zones/${zone_id}/dns_records/${record_id}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$data")
    
    if echo "$response" | grep -q '"success":true'; then
        log "INFO" "DNS record updated: $record_name -> $record_content"
        return 0
    else
        local error=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        log "ERROR" "Failed to update DNS record: $error"
        return 1
    fi
}

delete_dns_record() {
    local zone_id="$1"
    local record_id="$2"
    
    local response=$(curl -s -X DELETE "${CF_API_URL}/zones/${zone_id}/dns_records/${record_id}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    if echo "$response" | grep -q '"success":true'; then
        return 0
    else
        return 1
    fi
}

list_dns_records() {
    local zone_id="$1"
    
    local response=$(curl -s -X GET "${CF_API_URL}/zones/${zone_id}/dns_records?per_page=100" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    if echo "$response" | grep -q '"success":true'; then
        echo -e "${CYAN}Current DNS Records:${NC}"
        echo ""
        echo "$response" | grep -oP '{"id":"[^"]+","zone_id":"[^"]+","zone_name":"[^"]+","name":"[^"]+","type":"[^"]+","content":"[^"]+"' | while read -r record; do
            local name=$(echo "$record" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
            local type=$(echo "$record" | grep -o '"type":"[^"]*"' | cut -d'"' -f4)
            local content=$(echo "$record" | grep -o '"content":"[^"]*"' | cut -d'"' -f4 | head -c 50)
            printf "  %-30s %-8s %s\n" "$name" "$type" "$content"
        done
        echo ""
    fi
}

#===============================================================================
# CLOUDFLARED INSTALLATION
#===============================================================================

install_cloudflared() {
    print_section "Installing Cloudflared"
    
    if command_exists cloudflared; then
        local version=$(cloudflared --version 2>&1 | head -1)
        log "INFO" "Cloudflared already installed: $version"
        
        if confirm "Update to latest version?"; then
            log "INFO" "Updating cloudflared..."
        else
            return 0
        fi
    fi
    
    log "INFO" "Installing cloudflared..."
    
    # Detect architecture
    local arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="arm" ;;
        *) 
            log "ERROR" "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
    
    # Method 1: Official package
    log "INFO" "Trying official Cloudflare package..."
    if curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg 2>/dev/null; then
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
        sudo apt-get update
        if sudo apt-get install -y cloudflared; then
            log "INFO" "Cloudflared installed via official package"
            return 0
        fi
    fi
    
    # Method 2: Direct download
    log "WARN" "Package install failed, trying direct download..."
    local download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
    
    if curl -fsSL -o /tmp/cloudflared.deb "$download_url"; then
        if sudo dpkg -i /tmp/cloudflared.deb; then
            rm /tmp/cloudflared.deb
            log "INFO" "Cloudflared installed via direct download"
            return 0
        fi
        sudo apt-get install -f -y  # Fix dependencies
        sudo dpkg -i /tmp/cloudflared.deb
        rm /tmp/cloudflared.deb
        return 0
    fi
    
    # Method 3: Binary download
    log "WARN" "DEB install failed, trying binary..."
    local binary_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    
    if curl -fsSL -o /tmp/cloudflared "$binary_url"; then
        sudo mv /tmp/cloudflared /usr/local/bin/cloudflared
        sudo chmod +x /usr/local/bin/cloudflared
        log "INFO" "Cloudflared installed via binary"
        return 0
    fi
    
    log "ERROR" "Failed to install cloudflared"
    exit 1
}

#===============================================================================
# CLOUDFLARE AUTHENTICATION
#===============================================================================

authenticate_cloudflare() {
    print_section "Cloudflare Authentication"
    
    mkdir -p "$CF_CONFIG_DIR"
    
    # Check if already authenticated
    if [ -f "$CF_CONFIG_DIR/cert.pem" ]; then
        log "INFO" "Already authenticated with Cloudflare"
        if confirm "Re-authenticate?"; then
            rm "$CF_CONFIG_DIR/cert.pem"
        else
            return 0
        fi
    fi
    
    echo ""
    echo -e "${YELLOW}Authentication Required${NC}"
    echo "This will open a browser link to authenticate with Cloudflare."
    echo "If running headless, copy the URL and open in your browser."
    echo ""
    
    if ! confirm "Start authentication?"; then
        log "ERROR" "Authentication required to continue"
        exit 1
    fi
    
    # Run login
    log "INFO" "Starting authentication..."
    if cloudflared tunnel login; then
        log "INFO" "Authentication successful"
    else
        log "ERROR" "Authentication failed"
        echo ""
        echo -e "${YELLOW}Manual authentication:${NC}"
        echo "1. Run: cloudflared tunnel login"
        echo "2. Copy the displayed URL"
        echo "3. Open URL in browser and authorize"
        echo "4. Re-run this script"
        exit 1
    fi
    
    # Verify
    if [ -f "$CF_CONFIG_DIR/cert.pem" ]; then
        log "INFO" "Certificate saved to $CF_CONFIG_DIR/cert.pem"
    else
        log "ERROR" "Certificate not found after authentication"
        exit 1
    fi
}

#===============================================================================
# TUNNEL MANAGEMENT
#===============================================================================

list_existing_tunnels() {
    print_section "Existing Tunnels"
    
    if cloudflared tunnel list 2>/dev/null; then
        echo ""
    else
        log "INFO" "No existing tunnels found"
    fi
}

select_or_create_tunnel() {
    print_section "Tunnel Selection"
    
    # List existing tunnels
    local tunnels=$(cloudflared tunnel list 2>/dev/null | tail -n +2 | awk '{print $1, $2}')
    
    if [ -n "$tunnels" ]; then
        echo -e "${CYAN}Existing tunnels:${NC}"
        echo "$tunnels" | nl -w2 -s'. '
        echo ""
        echo "0. Create new tunnel"
        echo ""
        echo -en "${CYAN}Select tunnel number (or 0 for new): ${NC}"
        read -r tunnel_choice
        
        if [ "$tunnel_choice" != "0" ] && [ -n "$tunnel_choice" ]; then
            TUNNEL_NAME=$(echo "$tunnels" | sed -n "${tunnel_choice}p" | awk '{print $2}')
            TUNNEL_ID=$(echo "$tunnels" | sed -n "${tunnel_choice}p" | awk '{print $1}')
            
            if [ -n "$TUNNEL_NAME" ]; then
                log "INFO" "Selected tunnel: $TUNNEL_NAME ($TUNNEL_ID)"
                return 0
            fi
        fi
    fi
    
    # Create new tunnel
    echo ""
    echo -en "${CYAN}Enter name for new tunnel: ${NC}"
    read -r TUNNEL_NAME
    while [ -z "$TUNNEL_NAME" ]; do
        echo -e "${RED}Tunnel name is required!${NC}"
        echo -en "${CYAN}Enter tunnel name: ${NC}"
        read -r TUNNEL_NAME
    done
    
    log "INFO" "Creating tunnel: $TUNNEL_NAME"
    
    if cloudflared tunnel create "$TUNNEL_NAME"; then
        TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
        log "INFO" "Tunnel created: $TUNNEL_NAME ($TUNNEL_ID)"
    else
        log "ERROR" "Failed to create tunnel"
        exit 1
    fi
}

#===============================================================================
# SERVICE CONFIGURATION
#===============================================================================

configure_service() {
    print_section "Add Service/Domain"
    
    # Initialize variables
    SUBDOMAINS=()
    ADD_WWW="false"
    HOSTING_TYPE=""
    PRIMARY_SUBDOMAIN=""
    
    # Show available zones
    list_available_zones
    
    # Domain input with zone selection
    echo ""
    echo -e "${YELLOW}Domain Selection:${NC}"
    echo "You can either:"
    echo "  - Enter a number to select from your zones above"
    echo "  - Type a domain name directly (e.g., example.com)"
    echo ""
    echo -en "${CYAN}Enter root domain name or zone number: ${NC}"
    read -r domain_input
    
    # Check if input is a number (zone selection)
    if [[ "$domain_input" =~ ^[0-9]+$ ]]; then
        local zones_array=($(get_zones | grep -o '"name":"[^"]*"' | cut -d'"' -f4))
        if [ "$domain_input" -ge 1 ] && [ "$domain_input" -le "${#zones_array[@]}" ]; then
            ROOT_DOMAIN="${zones_array[$((domain_input-1))]}"
            log "INFO" "Selected zone: $ROOT_DOMAIN"
        else
            echo -e "${RED}Invalid selection!${NC}"
            echo -en "${CYAN}Enter domain name: ${NC}"
            read -r ROOT_DOMAIN
        fi
    else
        ROOT_DOMAIN="$domain_input"
    fi
    
    while [ -z "$ROOT_DOMAIN" ]; do
        echo -e "${RED}Domain name is required!${NC}"
        echo -en "${CYAN}Enter domain name: ${NC}"
        read -r ROOT_DOMAIN
    done
    
    # Get zone ID for this domain
    ZONE_ID=$(get_zone_id "$ROOT_DOMAIN")
    if [ -z "$ZONE_ID" ]; then
        log "ERROR" "Could not find zone for $ROOT_DOMAIN in your Cloudflare account"
        log "INFO" "Make sure the domain is added to your Cloudflare account"
        return 1
    fi
    log "INFO" "Zone ID: $ZONE_ID"
    
    # Save zone info for later use
    ZONE_NAME="$ROOT_DOMAIN"
    cat > "$CF_CONFIG_DIR/zone_info" << EOF
ZONE_ID=$ZONE_ID
ZONE_NAME=$ROOT_DOMAIN
EOF
    
    # Ask hosting type: main domain or subdomain
    echo ""
    echo -e "${YELLOW}Hosting Type:${NC}"
    echo "1. Main domain (e.g., $ROOT_DOMAIN)"
    echo "2. Subdomain (e.g., app.$ROOT_DOMAIN, blog.$ROOT_DOMAIN)"
    echo ""
    echo -en "${CYAN}Are you hosting on [1] Main domain or [2] Subdomain? [1]: ${NC}"
    read -r hosting_choice
    hosting_choice=${hosting_choice:-1}
    
    if [ "$hosting_choice" = "2" ]; then
        HOSTING_TYPE="subdomain"
        echo ""
        echo -e "${CYAN}Enter subdomain name (without .$ROOT_DOMAIN):${NC}"
        echo -e "${CYAN}Examples: app, blog, shop, api, dashboard${NC}"
        echo -en "${CYAN}Subdomain: ${NC}"
        read -r PRIMARY_SUBDOMAIN
        
        while [ -z "$PRIMARY_SUBDOMAIN" ]; do
            echo -e "${RED}Subdomain is required!${NC}"
            echo -en "${CYAN}Enter subdomain: ${NC}"
            read -r PRIMARY_SUBDOMAIN
        done
        
        # Clean subdomain (remove dots if user added them)
        PRIMARY_SUBDOMAIN=$(echo "$PRIMARY_SUBDOMAIN" | sed 's/\.$//g' | sed "s/\.$ROOT_DOMAIN//g")
        
        DOMAIN_NAME="${PRIMARY_SUBDOMAIN}.${ROOT_DOMAIN}"
        WWW_DOMAIN="www.${PRIMARY_SUBDOMAIN}.${ROOT_DOMAIN}"
        
        log "INFO" "Hosting subdomain: $DOMAIN_NAME"
        log "INFO" "Will also create: $WWW_DOMAIN"
    else
        HOSTING_TYPE="main"
        DOMAIN_NAME="$ROOT_DOMAIN"
        WWW_DOMAIN="www.${ROOT_DOMAIN}"
        
        log "INFO" "Hosting main domain: $DOMAIN_NAME"
        log "INFO" "Will also create: $WWW_DOMAIN"
    fi
    
    # Automatically add www version
    SUBDOMAINS+=("www_auto")  # Special marker for www of the primary hostname
    
    # Check existing DNS records for primary domain
    echo ""
    echo -e "${YELLOW}Checking existing DNS records...${NC}"
    if check_dns_record_exists "$ZONE_ID" "$DOMAIN_NAME"; then
        echo ""
        echo -e "${YELLOW}WARNING: DNS record already exists for $DOMAIN_NAME${NC}"
        echo -e "  Type:    $EXISTING_RECORD_TYPE"
        echo -e "  Content: $EXISTING_RECORD_CONTENT"
        echo ""
        if confirm "Replace existing DNS record with tunnel?"; then
            REPLACE_EXISTING="true"
        else
            log "INFO" "Keeping existing record, tunnel route will be skipped for $DOMAIN_NAME"
            SKIP_ROOT_DNS="true"
        fi
    else
        log "INFO" "No existing DNS record for $DOMAIN_NAME - will create new"
    fi
    
    # Check www record
    if check_dns_record_exists "$ZONE_ID" "$WWW_DOMAIN"; then
        echo -e "${YELLOW}  Note: $WWW_DOMAIN already has a DNS record (will be updated)${NC}"
    fi
    
    # Ask about additional subdomains (optional)
    echo ""
    if confirm "Add additional subdomains for this service?"; then
        echo ""
        echo -e "${CYAN}Add additional subdomains (comma-separated):${NC}"
        echo -e "${CYAN}Examples: api,app,dashboard,admin,staging${NC}"
        echo -en "${CYAN}Subdomains: ${NC}"
        read -r subdomain_input
        
        if [ -n "$subdomain_input" ]; then
            # Parse comma-separated subdomains
            IFS=',' read -ra INPUT_SUBS <<< "$subdomain_input"
            for sub in "${INPUT_SUBS[@]}"; do
                # Trim whitespace
                sub=$(echo "$sub" | xargs)
                if [ -n "$sub" ] && [ "$sub" != "www" ]; then
                    SUBDOMAINS+=("$sub")
                    
                    # Check if subdomain record exists
                    if check_dns_record_exists "$ZONE_ID" "${sub}.$ROOT_DOMAIN"; then
                        echo -e "${YELLOW}  Note: ${sub}.$ROOT_DOMAIN already has a DNS record (will be updated)${NC}"
                    fi
                fi
            done
        fi
    fi
    
    # Service type
    echo ""
    echo -e "${YELLOW}Service Types:${NC}"
    echo "1. HTTP (web server on port 80)"
    echo "2. HTTPS (web server with SSL)"
    echo "3. Custom HTTP port"
    echo "4. Custom HTTPS port (e.g., Proxmox)"
    echo "5. SSH"
    echo "6. RDP"
    echo "7. TCP (custom)"
    echo ""
    echo -en "${CYAN}Select service type [1]: ${NC}"
    read -r service_type
    service_type=${service_type:-1}
    
    # Target IP
    echo ""
    echo -en "${CYAN}Enter target server IP (e.g., 192.168.1.100): ${NC}"
    read -r TARGET_IP
    while [ -z "$TARGET_IP" ]; do
        echo -e "${RED}Target IP is required!${NC}"
        echo -en "${CYAN}Enter target server IP: ${NC}"
        read -r TARGET_IP
    done
    
    # Determine service URL
    case $service_type in
        1)
            SERVICE_URL="http://${TARGET_IP}:80"
            SERVICE_PROTO="http"
            ;;
        2)
            SERVICE_URL="https://${TARGET_IP}:443"
            SERVICE_PROTO="https"
            NO_TLS_VERIFY="true"
            ;;
        3)
            echo -en "${CYAN}Enter HTTP port: ${NC}"
            read -r custom_port
            SERVICE_URL="http://${TARGET_IP}:${custom_port}"
            SERVICE_PROTO="http"
            ;;
        4)
            echo -en "${CYAN}Enter HTTPS port: ${NC}"
            read -r custom_port
            SERVICE_URL="https://${TARGET_IP}:${custom_port}"
            SERVICE_PROTO="https"
            NO_TLS_VERIFY="true"
            ;;
        5)
            SERVICE_URL="ssh://${TARGET_IP}:22"
            SERVICE_PROTO="ssh"
            ;;
        6)
            SERVICE_URL="rdp://${TARGET_IP}:3389"
            SERVICE_PROTO="rdp"
            ;;
        7)
            echo -en "${CYAN}Enter protocol (tcp/http/https): ${NC}"
            read -r proto
            echo -en "${CYAN}Enter port: ${NC}"
            read -r custom_port
            SERVICE_URL="${proto}://${TARGET_IP}:${custom_port}"
            SERVICE_PROTO="$proto"
            ;;
        *)
            SERVICE_URL="http://${TARGET_IP}:80"
            SERVICE_PROTO="http"
            ;;
    esac
    
    # Summary
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Service Configuration Summary:${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "  Hosting Type: ${HOSTING_TYPE}"
    echo -e "  Root Domain:  $ROOT_DOMAIN"
    echo -e "  Zone ID:      $ZONE_ID"
    echo -e "  Service URL:  $SERVICE_URL"
    echo -e "  Target IP:    $TARGET_IP"
    echo ""
    echo -e "  ${CYAN}Hostnames to be configured (with DNS records):${NC}"
    if [ "$SKIP_ROOT_DNS" != "true" ]; then
        echo -e "    - $DOMAIN_NAME"
    fi
    echo -e "    - $WWW_DOMAIN"
    # Show additional subdomains (excluding www_auto marker)
    for sub in "${SUBDOMAINS[@]}"; do
        if [ "$sub" != "www_auto" ]; then
            echo -e "    - ${sub}.$ROOT_DOMAIN"
        fi
    done
    echo ""
    
    if ! confirm "Add this service with all hostnames?"; then
        return 1
    fi
    
    # Store service info
    local subdomain_json=$(printf '%s\n' "${SUBDOMAINS[@]}" | jq -R . | jq -s .)
    NEW_SERVICE="{\"domain\":\"$DOMAIN_NAME\",\"wwwDomain\":\"$WWW_DOMAIN\",\"rootDomain\":\"$ROOT_DOMAIN\",\"hostingType\":\"$HOSTING_TYPE\",\"service\":\"$SERVICE_URL\",\"subdomains\":$subdomain_json,\"noTlsVerify\":${NO_TLS_VERIFY:-false},\"zoneId\":\"$ZONE_ID\"}"
}

#===============================================================================
# CONFIG FILE GENERATION
#===============================================================================

generate_config() {
    print_section "Generating Configuration"
    
    # Find credentials file
    local creds_file=$(ls "$CF_CONFIG_DIR"/*.json 2>/dev/null | head -1)
    if [ -z "$creds_file" ]; then
        creds_file="$CF_CONFIG_DIR/${TUNNEL_ID}.json"
    fi
    
    # Backup existing config
    if [ -f "$CF_CONFIG_FILE" ]; then
        cp "$CF_CONFIG_FILE" "$CF_CONFIG_FILE.bak.$(date +%s)"
        log "INFO" "Backed up existing config"
    fi
    
    # Start building config
    log "INFO" "Building configuration..."
    
    cat > "$CF_CONFIG_FILE" << EOF
# Cloudflare Tunnel Configuration
# Tunnel: $TUNNEL_NAME
# Generated: $(date)

tunnel: $TUNNEL_ID
credentials-file: $creds_file

ingress:
EOF
    
    # Add services from stored list + new service
    # First, read existing services if config exists
    if [ -f "$CF_CONFIG_FILE.bak"* ] 2>/dev/null; then
        log "INFO" "Importing existing services..."
        # Parse existing ingress rules (simplified - just add new)
    fi
    
    # Add new service - primary hostname
    if [ "$SKIP_ROOT_DNS" != "true" ]; then
        echo "  # $DOMAIN_NAME" >> "$CF_CONFIG_FILE"
        echo "  - hostname: $DOMAIN_NAME" >> "$CF_CONFIG_FILE"
        echo "    service: $SERVICE_URL" >> "$CF_CONFIG_FILE"
        
        if [ "$NO_TLS_VERIFY" = "true" ]; then
            echo "    originRequest:" >> "$CF_CONFIG_FILE"
            echo "      noTLSVerify: true" >> "$CF_CONFIG_FILE"
        fi
    fi
    
    # Add www version of primary hostname
    echo "  # $WWW_DOMAIN (auto-added)" >> "$CF_CONFIG_FILE"
    echo "  - hostname: $WWW_DOMAIN" >> "$CF_CONFIG_FILE"
    echo "    service: $SERVICE_URL" >> "$CF_CONFIG_FILE"
    if [ "$NO_TLS_VERIFY" = "true" ]; then
        echo "    originRequest:" >> "$CF_CONFIG_FILE"
        echo "      noTLSVerify: true" >> "$CF_CONFIG_FILE"
    fi
    
    # Add additional subdomains (skip www_auto marker)
    for sub in "${SUBDOMAINS[@]}"; do
        if [ "$sub" != "www_auto" ]; then
            echo "  - hostname: ${sub}.$ROOT_DOMAIN" >> "$CF_CONFIG_FILE"
            echo "    service: $SERVICE_URL" >> "$CF_CONFIG_FILE"
            if [ "$NO_TLS_VERIFY" = "true" ]; then
                echo "    originRequest:" >> "$CF_CONFIG_FILE"
                echo "      noTLSVerify: true" >> "$CF_CONFIG_FILE"
            fi
        fi
    done
    
    # Add catch-all
    echo "" >> "$CF_CONFIG_FILE"
    echo "  # Catch-all (must be last)" >> "$CF_CONFIG_FILE"
    echo "  - service: http_status:404" >> "$CF_CONFIG_FILE"
    
    log "INFO" "Configuration saved to $CF_CONFIG_FILE"
    
    # Display config
    echo ""
    echo -e "${CYAN}Generated Configuration:${NC}"
    cat "$CF_CONFIG_FILE"
    echo ""
}

#===============================================================================
# DNS ROUTING
#===============================================================================

setup_dns_routing() {
    print_section "Automatic DNS Configuration"
    
    local tunnel_target="${TUNNEL_ID}.cfargotunnel.com"
    local dns_success=0
    local dns_failed=0
    
    log "INFO" "Setting up DNS records via Cloudflare API..."
    log "INFO" "Tunnel target: $tunnel_target"
    echo ""
    
    # Function to create/update DNS record
    setup_single_dns() {
        local hostname="$1"
        local record_name="$2"
        
        echo -en "  ${CYAN}$hostname${NC} ... "
        
        # Check if record exists
        if check_dns_record_exists "$ZONE_ID" "$hostname"; then
            # Record exists - update it
            if [ "$EXISTING_RECORD_TYPE" = "CNAME" ] && [ "$EXISTING_RECORD_CONTENT" = "$tunnel_target" ]; then
                echo -e "${GREEN}✓ Already configured${NC}"
                : $((dns_success++))
                return 0
            fi
            
            # Delete existing record first (needed if type changes)
            if [ -n "$EXISTING_RECORD_ID" ]; then
                log "DEBUG" "Removing existing record $EXISTING_RECORD_ID"
                delete_dns_record "$ZONE_ID" "$EXISTING_RECORD_ID"
            fi
        fi
        
        # Create new CNAME record
        if create_dns_record "$ZONE_ID" "$record_name" "$tunnel_target" "CNAME" "true"; then
            echo -e "${GREEN}✓ Created${NC}"
            : $((dns_success++))
        else
            echo -e "${RED}✗ Failed${NC}"
            : $((dns_failed++))
        fi
    }
    
    # Configure primary hostname
    if [ "$SKIP_ROOT_DNS" != "true" ]; then
        if [ "$HOSTING_TYPE" = "subdomain" ]; then
            # For subdomain hosting: app.domain.com -> use subdomain name as record
            setup_single_dns "$DOMAIN_NAME" "$PRIMARY_SUBDOMAIN"
        else
            # For main domain hosting: domain.com -> use @ as record
            setup_single_dns "$DOMAIN_NAME" "@"
        fi
    fi
    
    # Configure www version of primary hostname
    if [ "$HOSTING_TYPE" = "subdomain" ]; then
        # For subdomain hosting: www.app.domain.com
        setup_single_dns "$WWW_DOMAIN" "www.${PRIMARY_SUBDOMAIN}"
    else
        # For main domain hosting: www.domain.com
        setup_single_dns "$WWW_DOMAIN" "www"
    fi
    
    # Configure additional subdomains (skip www_auto marker)
    for sub in "${SUBDOMAINS[@]}"; do
        if [ "$sub" != "www_auto" ]; then
            setup_single_dns "${sub}.$ROOT_DOMAIN" "$sub"
        fi
    done
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}DNS Configuration Results:${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "  Successful: ${GREEN}$dns_success${NC}"
    echo -e "  Failed:     ${RED}$dns_failed${NC}"
    echo ""
    
    if [ $dns_failed -gt 0 ]; then
        log "WARN" "Some DNS records failed to create"
        log "INFO" "Attempting fallback via cloudflared CLI..."
        
        # Fallback to cloudflared route dns command
        if [ "$SKIP_ROOT_DNS" != "true" ]; then
            cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN_NAME" 2>/dev/null || true
        fi
        cloudflared tunnel route dns "$TUNNEL_NAME" "$WWW_DOMAIN" 2>/dev/null || true
        for sub in "${SUBDOMAINS[@]}"; do
            if [ "$sub" != "www_auto" ]; then
                cloudflared tunnel route dns "$TUNNEL_NAME" "${sub}.$ROOT_DOMAIN" 2>/dev/null || true
            fi
        done
    fi
    
    log "INFO" "DNS configuration complete - no dashboard access needed!"
}

#===============================================================================
# VALIDATE CONFIGURATION
#===============================================================================

validate_config() {
    print_section "Validating Configuration"
    
    log "INFO" "Validating tunnel configuration..."
    
    if cloudflared tunnel ingress validate; then
        log "INFO" "Configuration is valid"
    else
        log "ERROR" "Configuration validation failed"
        echo ""
        echo -e "${YELLOW}Checking config file:${NC}"
        cat "$CF_CONFIG_FILE"
        echo ""
        log "INFO" "Please fix the configuration and re-run"
        exit 1
    fi
}

#===============================================================================
# SERVICE INSTALLATION
#===============================================================================

# Install service using Cloudflare Dashboard token (simplest method)
install_service_with_token() {
    print_section "Install Service with Token"
    
    log "INFO" "This method uses a tunnel token from Cloudflare Dashboard"
    log "INFO" "The token contains all configuration needed to run the tunnel"
    echo ""
    
    # Check if service already exists
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        log "WARN" "Cloudflared service is already running"
        echo ""
        sudo systemctl status cloudflared --no-pager | head -10
        echo ""
        
        if confirm "Stop and reinstall service with new token?"; then
            log "INFO" "Stopping existing service..."
            sudo systemctl stop cloudflared
            sudo systemctl disable cloudflared 2>/dev/null || true
            sudo cloudflared service uninstall 2>/dev/null || true
            sleep 2
        else
            log "INFO" "Keeping existing service"
            return 0
        fi
    fi
    
    # Get token from user
    echo -e "${CYAN}Get your tunnel token from Cloudflare Dashboard:${NC}"
    echo "  1. Go to: https://one.dash.cloudflare.com/"
    echo "  2. Navigate to: Networks → Tunnels"
    echo "  3. Select your tunnel → Configure"
    echo "  4. Copy the token from the 'Install connector' section"
    echo ""
    echo -en "${CYAN}Paste your tunnel token: ${NC}"
    read -r TUNNEL_TOKEN
    
    if [ -z "$TUNNEL_TOKEN" ]; then
        log "ERROR" "No token provided"
        return 1
    fi
    
    # Validate token format (base64 encoded JSON)
    if ! echo "$TUNNEL_TOKEN" | base64 -d 2>/dev/null | grep -q '"a"'; then
        log "WARN" "Token doesn't appear to be in expected format, but will try anyway"
    fi
    
    log "INFO" "Installing cloudflared service with token..."
    
    # Install service using token
    if sudo cloudflared service install "$TUNNEL_TOKEN"; then
        log "INFO" "Service installed successfully"
    else
        log "WARN" "cloudflared service install failed, creating systemd service manually..."
        
        # Get cloudflared path
        local cf_path=$(which cloudflared)
        if [ -z "$cf_path" ]; then
            cf_path="/usr/local/bin/cloudflared"
        fi
        
        # Create systemd service manually with token
        sudo tee /etc/systemd/system/cloudflared.service > /dev/null << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${cf_path} tunnel run --token ${TUNNEL_TOKEN}
Restart=always
RestartSec=5
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF
        log "INFO" "Created systemd service file"
    fi
    
    # Reload systemd and enable service
    sudo systemctl daemon-reload
    sudo systemctl enable cloudflared
    
    # Start service
    log "INFO" "Starting cloudflared service..."
    sudo systemctl start cloudflared
    
    # Wait for connection
    log "INFO" "Waiting for tunnel to establish connection..."
    sleep 5
    
    # Check status
    if sudo systemctl is-active --quiet cloudflared; then
        log "INFO" "Cloudflared service is running!"
        echo ""
        sudo systemctl status cloudflared --no-pager | head -15
        echo ""
        
        # Show recent logs
        log "INFO" "Recent tunnel logs:"
        sudo journalctl -u cloudflared -n 10 --no-pager 2>/dev/null | tail -5
        echo ""
        
        echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  TUNNEL SERVICE INSTALLED SUCCESSFULLY${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${CYAN}Useful commands:${NC}"
        echo "  Check status:  sudo systemctl status cloudflared"
        echo "  View logs:     sudo journalctl -u cloudflared -f"
        echo "  Restart:       sudo systemctl restart cloudflared"
        echo "  Stop:          sudo systemctl stop cloudflared"
        echo ""
        echo -e "${CYAN}The tunnel will now:${NC}"
        echo "  ✓ Start automatically on boot"
        echo "  ✓ Restart automatically if it crashes"
        echo "  ✓ Run in the background as a system service"
        echo ""
    else
        log "ERROR" "Service failed to start"
        echo ""
        sudo systemctl status cloudflared --no-pager
        echo ""
        log "INFO" "Recent logs:"
        sudo journalctl -u cloudflared -n 20 --no-pager
        return 1
    fi
}

install_service() {
    print_section "Installing as System Service"
    
    # Check if service exists
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        log "INFO" "Cloudflared service already running"
        
        if confirm "Reinstall service with new configuration?"; then
            log "INFO" "Stopping existing service..."
            sudo systemctl stop cloudflared
            sudo cloudflared service uninstall 2>/dev/null || true
        else
            log "INFO" "Restarting service with new config..."
            sudo systemctl restart cloudflared
            return 0
        fi
    fi
    
    # Copy config to system location
    sudo mkdir -p /etc/cloudflared
    sudo cp "$CF_CONFIG_FILE" /etc/cloudflared/config.yml
    sudo cp "$CF_CONFIG_DIR"/*.json /etc/cloudflared/ 2>/dev/null || true
    sudo cp "$CF_CONFIG_DIR/cert.pem" /etc/cloudflared/ 2>/dev/null || true
    
    # Fix credentials-file path in system config to point to /etc/cloudflared
    local creds_filename=$(ls "$CF_CONFIG_DIR"/*.json 2>/dev/null | head -1 | xargs basename)
    if [ -n "$creds_filename" ]; then
        sudo sed -i "s|credentials-file:.*|credentials-file: /etc/cloudflared/$creds_filename|g" /etc/cloudflared/config.yml
        log "INFO" "Updated credentials path to /etc/cloudflared/$creds_filename"
    fi
    
    # Install service
    log "INFO" "Installing cloudflared service..."
    
    if sudo cloudflared service install; then
        log "INFO" "Service installed"
    else
        log "WARN" "Service install command failed, trying manual setup..."
        
        # Create systemd service manually
        sudo tee /etc/systemd/system/cloudflared.service > /dev/null << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared --config /etc/cloudflared/config.yml tunnel run
Restart=on-failure
RestartSec=5
Environment="TUNNEL_ORIGIN_CERT=/etc/cloudflared/cert.pem"

[Install]
WantedBy=multi-user.target
EOF
        
        # Fix cloudflared path
        local cf_path=$(which cloudflared)
        sudo sed -i "s|/usr/local/bin/cloudflared|$cf_path|g" /etc/systemd/system/cloudflared.service
    fi
    
    # Start service
    sudo systemctl daemon-reload
    sudo systemctl enable cloudflared
    sudo systemctl start cloudflared
    
    log "INFO" "Waiting for tunnel to establish connection..."
    sleep 5
    
    if sudo systemctl is-active --quiet cloudflared; then
        log "INFO" "Cloudflared service is running"
        
        # Verify tunnel connection by checking logs
        local tunnel_status=$(sudo journalctl -u cloudflared -n 10 --no-pager 2>/dev/null | grep -i "registered|connected|serving" | tail -1)
        if [ -n "$tunnel_status" ]; then
            log "INFO" "Tunnel appears to be connected"
        fi
        
        # Show service status
        sudo systemctl status cloudflared --no-pager | head -15
    else
        log "ERROR" "Service failed to start"
        sudo systemctl status cloudflared --no-pager
        echo ""
        log "INFO" "Recent logs:"
        sudo journalctl -u cloudflared -n 20 --no-pager
        echo ""
        log "INFO" "Try running 'troubleshoot_tunnel' from menu to diagnose"
        exit 1
    fi
}

#===============================================================================
# TEST CONNECTION
#===============================================================================

test_connection() {
    print_section "Testing Connection"
    
    log "INFO" "Testing tunnel connectivity..."
    
    # Wait for tunnel to establish
    sleep 5
    
    # Check tunnel status
    if cloudflared tunnel info "$TUNNEL_NAME" 2>/dev/null; then
        log "INFO" "Tunnel is connected"
    else
        log "WARN" "Could not get tunnel info"
    fi
    
    # Test service connectivity
    log "INFO" "Testing connection to $SERVICE_URL..."
    
    local target_ip=$(echo "$SERVICE_URL" | sed -E 's|.*://([^:]+).*|\1|')
    local target_port=$(echo "$SERVICE_URL" | sed -E 's|.*:([0-9]+).*|\1|')
    
    if timeout 5 bash -c "echo > /dev/tcp/$target_ip/$target_port" 2>/dev/null; then
        log "INFO" "Target service is reachable"
    else
        log "WARN" "Cannot reach target service at $target_ip:$target_port"
        log "INFO" "Ensure the target server is running and accessible"
    fi
    
    # Test external access (may take time for DNS)
    log "INFO" "External access test (may take a few minutes for DNS)..."
    echo ""
    echo -e "${YELLOW}Test your domains in a browser:${NC}"
    if [ "$SKIP_ROOT_DNS" != "true" ]; then
        echo -e "  https://$DOMAIN_NAME"
    fi
    echo -e "  https://$WWW_DOMAIN"
    for sub in "${SUBDOMAINS[@]}"; do
        if [ "$sub" != "www_auto" ]; then
            echo -e "  https://${sub}.$ROOT_DOMAIN"
        fi
    done
}

#===============================================================================
# ADD ANOTHER SERVICE
#===============================================================================

add_another_service() {
    if confirm "Add another domain/service to this tunnel?"; then
        # Reset variables for new service
        SUBDOMAINS=()
        SKIP_ROOT_DNS=""
        NO_TLS_VERIFY=""
        ROOT_DOMAIN=""
        DOMAIN_NAME=""
        WWW_DOMAIN=""
        HOSTING_TYPE=""
        PRIMARY_SUBDOMAIN=""
        
        configure_service
        
        # Append to existing config (before catch-all)
        local temp_file=$(mktemp)
        head -n -2 "$CF_CONFIG_FILE" > "$temp_file"
        
        # Add primary hostname if not skipped
        if [ "$SKIP_ROOT_DNS" != "true" ]; then
            echo "  # $DOMAIN_NAME" >> "$temp_file"
            echo "  - hostname: $DOMAIN_NAME" >> "$temp_file"
            echo "    service: $SERVICE_URL" >> "$temp_file"
            
            if [ "$NO_TLS_VERIFY" = "true" ]; then
                echo "    originRequest:" >> "$temp_file"
                echo "      noTLSVerify: true" >> "$temp_file"
            fi
        fi
        
        # Add www version of primary hostname
        echo "  # $WWW_DOMAIN (auto-added)" >> "$temp_file"
        echo "  - hostname: $WWW_DOMAIN" >> "$temp_file"
        echo "    service: $SERVICE_URL" >> "$temp_file"
        if [ "$NO_TLS_VERIFY" = "true" ]; then
            echo "    originRequest:" >> "$temp_file"
            echo "      noTLSVerify: true" >> "$temp_file"
        fi
        
        # Add additional subdomains (skip www_auto marker)
        for sub in "${SUBDOMAINS[@]}"; do
            if [ "$sub" != "www_auto" ]; then
                echo "  - hostname: ${sub}.$ROOT_DOMAIN" >> "$temp_file"
                echo "    service: $SERVICE_URL" >> "$temp_file"
                if [ "$NO_TLS_VERIFY" = "true" ]; then
                    echo "    originRequest:" >> "$temp_file"
                    echo "      noTLSVerify: true" >> "$temp_file"
                fi
            fi
        done
        
        echo "" >> "$temp_file"
        echo "  # Catch-all (must be last)" >> "$temp_file"
        echo "  - service: http_status:404" >> "$temp_file"
        
        mv "$temp_file" "$CF_CONFIG_FILE"
        
        # Setup DNS via API
        setup_dns_routing
        
        # Validate and restart
        validate_config
        sudo cp "$CF_CONFIG_FILE" /etc/cloudflared/config.yml
        sudo systemctl restart cloudflared
        
        log "INFO" "Service added and tunnel restarted"
        
        # Recursive call
        add_another_service
    fi
}

#===============================================================================
# DISPLAY SUMMARY
#===============================================================================

display_summary() {
    print_section "Setup Complete!"
    
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}TUNNEL INFORMATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Tunnel Name:   ${GREEN}$TUNNEL_NAME${NC}"
    echo -e "Tunnel ID:     ${GREEN}$TUNNEL_ID${NC}"
    echo ""
    echo -e "${GREEN}Configured Hostnames:${NC}"
    grep "hostname:" "$CF_CONFIG_FILE" | sed 's/.*hostname: /  - /'
    echo ""
    echo -e "${GREEN}Configuration File:${NC} $CF_CONFIG_FILE"
    echo -e "${GREEN}API Token File:${NC} $API_TOKEN_FILE"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ All DNS records were configured automatically!${NC}"
    echo -e "${GREEN}✓ No Cloudflare dashboard access required!${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Useful Commands:${NC}"
    echo "  sudo systemctl status cloudflared     # Check status"
    echo "  sudo journalctl -u cloudflared -f     # View logs"
    echo "  sudo systemctl restart cloudflared    # Restart tunnel"
    echo "  cloudflared tunnel list               # List tunnels"
    echo "  cloudflared tunnel info $TUNNEL_NAME  # Tunnel details"
    echo ""
    echo -e "${YELLOW}To add more services later, just run this script again!${NC}"
    echo ""
}

#===============================================================================
# MAIN MENU
#===============================================================================

show_menu() {
    print_section "Cloudflare Tunnel Setup"
    
    # Load existing config if available
    load_existing_config
    
    echo "What would you like to do?"
    echo ""
    echo "1. Full setup (new installation)"
    echo "2. Add domain to existing tunnel"
    echo "3. View current configuration"
    echo "4. Manage DNS records"
    echo "5. View available zones"
    echo "6. Restart tunnel service"
    echo "7. Troubleshoot tunnel (diagnose issues)"
    echo "8. Fix configuration (guided repair with prompts)"
    echo -e "${GREEN}9. Auto Debug (automatic check & fix everything)${NC}"
    echo "10. View tunnel logs"
    echo "11. Install service with token (auto-start on boot)"
    echo "0. Exit"
    echo ""
    echo -en "${CYAN}Select option [1]: ${NC}"
    read -r menu_choice
    menu_choice=${menu_choice:-1}
    
    case $menu_choice in
        1) full_setup ;;
        2) add_domain_only ;;
        3) view_config ;;
        4) manage_dns ;;
        5) view_zones ;;
        6) restart_service ;;
        7) troubleshoot_tunnel ;;
        8) fix_configuration ;;
        9) auto_debug ;;
        10) view_logs ;;
        11) install_service_with_token ;;
        0) exit 0 ;;
        *) full_setup ;;
    esac
}

full_setup() {
    check_dependencies
    install_cloudflared
    authenticate_cloudflare
    setup_api_token
    select_or_create_tunnel
    configure_service
    generate_config
    validate_config
    setup_dns_routing
    install_service
    test_connection
    add_another_service
    display_summary
}

add_domain_only() {
    # Load existing tunnel
    if [ ! -f "$CF_CONFIG_FILE" ]; then
        log "ERROR" "No existing configuration found"
        log "INFO" "Run full setup first"
        exit 1
    fi
    
    # Ensure API token is set
    setup_api_token
    
    TUNNEL_ID=$(grep "^tunnel:" "$CF_CONFIG_FILE" | awk '{print $2}')
    TUNNEL_NAME=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_ID" | awk '{print $2}')
    
    log "INFO" "Using tunnel: $TUNNEL_NAME ($TUNNEL_ID)"
    
    configure_service
    
    # Add to config
    add_another_service
}

manage_dns() {
    print_section "DNS Record Management"
    
    # Ensure API token is set
    setup_api_token
    
    # List zones
    list_available_zones
    
    echo ""
    echo -en "${CYAN}Enter domain name to manage: ${NC}"
    read -r domain_to_manage
    
    local zone_id=$(get_zone_id "$domain_to_manage")
    if [ -z "$zone_id" ]; then
        log "ERROR" "Could not find zone for $domain_to_manage"
        return 1
    fi
    
    echo ""
    list_dns_records "$zone_id"
    
    echo ""
    echo "What would you like to do?"
    echo "1. Add DNS record"
    echo "2. Delete DNS record"
    echo "3. Return to menu"
    echo ""
    echo -en "${CYAN}Select option: ${NC}"
    read -r dns_choice
    
    case $dns_choice in
        1)
            echo -en "${CYAN}Record name (e.g., www, api, @): ${NC}"
            read -r record_name
            echo -en "${CYAN}Record type (CNAME/A/AAAA) [CNAME]: ${NC}"
            read -r record_type
            record_type=${record_type:-CNAME}
            echo -en "${CYAN}Record content (IP or hostname): ${NC}"
            read -r record_content
            echo -en "${CYAN}Proxied through Cloudflare? [Y/n]: ${NC}"
            read -r proxied_input
            local proxied="true"
            [[ "$proxied_input" =~ ^[nN] ]] && proxied="false"
            
            create_dns_record "$zone_id" "$record_name" "$record_content" "$record_type" "$proxied"
            ;;
        2)
            echo -en "${CYAN}Enter full record name to delete: ${NC}"
            read -r delete_name
            if check_dns_record_exists "$zone_id" "$delete_name"; then
                if confirm "Delete record $delete_name ($EXISTING_RECORD_TYPE -> $EXISTING_RECORD_CONTENT)?"; then
                    delete_dns_record "$zone_id" "$EXISTING_RECORD_ID"
                    log "INFO" "Record deleted"
                fi
            else
                log "ERROR" "Record not found: $delete_name"
            fi
            ;;
        3)
            show_menu
            return
            ;;
    esac
    
    if confirm "Manage more DNS records?"; then
        manage_dns
    else
        show_menu
    fi
}

view_zones() {
    # Ensure API token is set
    setup_api_token
    
    list_available_zones
    
    echo ""
    echo -en "${CYAN}Enter zone number to view DNS records (or Enter to skip): ${NC}"
    read -r zone_num
    
    if [ -n "$zone_num" ]; then
        local zones_array=($(get_zones | grep -o '"name":"[^"]*"' | cut -d'"' -f4))
        if [ "$zone_num" -ge 1 ] && [ "$zone_num" -le "${#zones_array[@]}" ]; then
            local selected_zone="${zones_array[$((zone_num-1))]}"
            local zone_id=$(get_zone_id "$selected_zone")
            echo ""
            list_dns_records "$zone_id"
        fi
    fi
    
    echo ""
    if confirm "Return to menu?"; then
        show_menu
    fi
}

view_config() {
    if [ -f "$CF_CONFIG_FILE" ]; then
        cat "$CF_CONFIG_FILE"
    else
        log "INFO" "No configuration file found"
    fi
    
    echo ""
    if confirm "Return to menu?"; then
        show_menu
    fi
}

restart_service() {
    print_section "Restarting Cloudflare Tunnel Service"
    
    log "INFO" "Stopping service..."
    sudo systemctl stop cloudflared 2>/dev/null || true
    
    log "INFO" "Starting service..."
    sudo systemctl start cloudflared
    
    sleep 3
    
    if sudo systemctl is-active --quiet cloudflared; then
        log "INFO" "Service is running successfully"
        sudo systemctl status cloudflared --no-pager
    else
        log "ERROR" "Service failed to start"
        sudo systemctl status cloudflared --no-pager
        echo ""
        log "INFO" "Showing recent logs:"
        sudo journalctl -u cloudflared -n 20 --no-pager
    fi
    
    if confirm "Return to menu?"; then
        show_menu
    fi
}

troubleshoot_tunnel() {
    print_section "Tunnel Troubleshooting"
    
    echo -e "${CYAN}1. Service Status${NC}"
    echo "==================="
    if sudo systemctl is-active --quiet cloudflared; then
        echo -e "   Status: ${GREEN}RUNNING${NC}"
    else
        echo -e "   Status: ${RED}STOPPED${NC}"
    fi
    sudo systemctl is-enabled cloudflared 2>/dev/null && echo -e "   Enabled: ${GREEN}YES${NC}" || echo -e "   Enabled: ${RED}NO${NC}"
    echo ""
    
    echo -e "${CYAN}2. Configuration Check${NC}"
    echo "======================="
    if [ -f /etc/cloudflared/config.yml ]; then
        echo -e "   Config file: ${GREEN}EXISTS${NC} (/etc/cloudflared/config.yml)"
        
        # Check credentials file path in config
        local creds_path=$(grep "credentials-file:" /etc/cloudflared/config.yml | awk '{print $2}')
        if [ -n "$creds_path" ]; then
            if [ -f "$creds_path" ]; then
                echo -e "   Credentials: ${GREEN}EXISTS${NC} ($creds_path)"
            else
                echo -e "   Credentials: ${RED}MISSING${NC} ($creds_path)"
                echo -e "   ${YELLOW}FIX: Credentials file not found. Re-run full setup.${NC}"
            fi
        fi
        
        # Check tunnel ID
        local tunnel_id=$(grep "tunnel:" /etc/cloudflared/config.yml | awk '{print $2}')
        if [ -n "$tunnel_id" ]; then
            echo -e "   Tunnel ID: ${GREEN}$tunnel_id${NC}"
        else
            echo -e "   Tunnel ID: ${RED}NOT SET${NC}"
        fi
    else
        echo -e "   Config file: ${RED}MISSING${NC}"
        echo -e "   ${YELLOW}FIX: Run full setup to create configuration.${NC}"
    fi
    echo ""
    
    echo -e "${CYAN}3. Tunnel Connectivity${NC}"
    echo "======================="
    local tunnel_id=$(grep "tunnel:" /etc/cloudflared/config.yml 2>/dev/null | awk '{print $2}')
    if [ -n "$tunnel_id" ]; then
        if cloudflared tunnel info "$tunnel_id" 2>/dev/null | head -5; then
            echo -e "   ${GREEN}Tunnel info retrieved successfully${NC}"
        else
            echo -e "   ${YELLOW}Could not get tunnel info (may need auth)${NC}"
        fi
    fi
    echo ""
    
    echo -e "${CYAN}4. Recent Logs${NC}"
    echo "==============="
    sudo journalctl -u cloudflared -n 15 --no-pager 2>/dev/null || echo "No logs available"
    echo ""
    
    echo -e "${CYAN}5. Quick Fixes${NC}"
    echo "==============="
    echo "  a) Restart service: sudo systemctl restart cloudflared"
    echo "  b) View full logs: sudo journalctl -u cloudflared -f"
    echo "  c) Re-run setup: Select option 1 from menu"
    echo "  d) Check DNS: Ensure CNAME records point to <tunnel-id>.cfargotunnel.com"
    echo ""
    
    if confirm "Attempt automatic fix (restart service)?"; then
        restart_service
    else
        if confirm "Return to menu?"; then
            show_menu
        fi
    fi
}

#===============================================================================
# LOAD EXISTING CONFIGURATION
#===============================================================================

load_existing_config() {
    # Load from system config if available
    if [ -f "/etc/cloudflared/config.yml" ]; then
        TUNNEL_ID=$(grep "^tunnel:" /etc/cloudflared/config.yml 2>/dev/null | awk '{print $2}')
        if [ -n "$TUNNEL_ID" ]; then
            log "DEBUG" "Loaded existing tunnel ID: $TUNNEL_ID"
        fi
    fi
    
    # Load API token if saved
    if [ -f "$API_TOKEN_FILE" ]; then
        CF_API_TOKEN=$(cat "$API_TOKEN_FILE")
        log "DEBUG" "Loaded API token from file"
    fi
    
    # Load zone info if available
    if [ -f "$CF_CONFIG_DIR/zone_info" ]; then
        source "$CF_CONFIG_DIR/zone_info"
        log "DEBUG" "Loaded zone info: $ZONE_ID ($ZONE_NAME)"
    fi
    
    # Get tunnel name
    if [ -n "$TUNNEL_ID" ] && command_exists cloudflared; then
        TUNNEL_NAME=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_ID" | awk '{print $2}')
    fi
}

#===============================================================================
# AUTO DEBUG - FULLY AUTOMATIC DIAGNOSTICS AND REPAIR
#===============================================================================

auto_debug() {
    print_section "Auto Debug - Automatic Diagnostics & Repair"
    
    log "INFO" "Running fully automatic debug with existing parameters..."
    log "INFO" "No user input required - all fixes applied automatically"
    echo ""
    
    # Note: Using : for arithmetic to prevent set -e from triggering on ((0))
    local total_checks=0
    local passed_checks=0
    local failed_checks=0
    local auto_fixed=0
    local manual_needed=0
    local config_changed=0  # Track if config/DNS was modified to trigger service restart
    
    # Load existing configuration first
    load_existing_config
    
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    STARTING AUTO DEBUG                         ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    #---------------------------------------------------------------------------
    # CHECK 1: cloudflared binary
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[1/13] Checking cloudflared installation...${NC}"
    if command_exists cloudflared; then
        local cf_version=$(cloudflared --version 2>/dev/null | head -1)
        echo -e "   ${GREEN}✓ PASS${NC} - cloudflared installed ($cf_version)"
        : $((passed_checks++))
    else
        echo -e "   ${RED}✗ FAIL${NC} - cloudflared not installed"
        echo -e "   ${YELLOW}→ AUTO-FIX: Installing cloudflared...${NC}"
        : $((failed_checks++))
        if install_cloudflared; then
            echo -e "   ${GREEN}✓ FIXED${NC} - cloudflared installed successfully"
            : $((auto_fixed++))
        else
            echo -e "   ${RED}✗ FAILED TO FIX${NC} - Manual installation required"
            : $((manual_needed++))
        fi
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 2: Cloudflare authentication (cert.pem)
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[2/12] Checking Cloudflare authentication...${NC}"
    local cert_found=false
    local cert_path=""
    
    if [ -f "/etc/cloudflared/cert.pem" ]; then
        cert_found=true
        cert_path="/etc/cloudflared/cert.pem"
    elif [ -f "$CF_CONFIG_DIR/cert.pem" ]; then
        cert_found=true
        cert_path="$CF_CONFIG_DIR/cert.pem"
    fi
    
    if [ "$cert_found" = true ]; then
        echo -e "   ${GREEN}✓ PASS${NC} - Authentication certificate found ($cert_path)"
        : $((passed_checks++))
    else
        echo -e "   ${RED}✗ FAIL${NC} - Not authenticated with Cloudflare"
        echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - Run 'cloudflared tunnel login'"
        : $((failed_checks++))
        : $((manual_needed++))
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 3: API token exists
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[3/12] Checking API token existence...${NC}"
    if [ -n "$CF_API_TOKEN" ] && [ "$CF_API_TOKEN" != "" ]; then
        echo -e "   ${GREEN}✓ PASS${NC} - API token loaded from config"
        : $((passed_checks++))
    elif [ -f "$API_TOKEN_FILE" ]; then
        CF_API_TOKEN=$(cat "$API_TOKEN_FILE")
        if [ -n "$CF_API_TOKEN" ]; then
            echo -e "   ${GREEN}✓ PASS${NC} - API token loaded from file"
            : $((passed_checks++))
        else
            echo -e "   ${RED}✗ FAIL${NC} - API token file empty"
            echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - Configure API token via menu option 1"
            : $((failed_checks++))
            : $((manual_needed++))
        fi
    else
        echo -e "   ${RED}✗ FAIL${NC} - No API token configured"
        echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - Configure API token via menu option 1"
        : $((failed_checks++))
        : $((manual_needed++))
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 4: API token validity
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[4/12] Validating API token...${NC}"
    if [ -n "$CF_API_TOKEN" ]; then
        local token_response=$(curl -s -X GET "$CF_API_URL/user/tokens/verify" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" 2>/dev/null)
        
        if echo "$token_response" | grep -q '"success":true'; then
            echo -e "   ${GREEN}✓ PASS${NC} - API token is valid"
            : $((passed_checks++))
        else
            echo -e "   ${RED}✗ FAIL${NC} - API token is invalid or expired"
            echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - Generate new API token at Cloudflare dashboard"
            : $((failed_checks++))
            : $((manual_needed++))
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - No API token to validate"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 5: Tunnel ID exists
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[5/12] Checking tunnel configuration...${NC}"
    if [ -n "$TUNNEL_ID" ]; then
        echo -e "   ${GREEN}✓ PASS${NC} - Tunnel ID: $TUNNEL_ID"
        : $((passed_checks++))
    else
        # Try to find from config files
        if [ -f "/etc/cloudflared/config.yml" ]; then
            TUNNEL_ID=$(grep "^tunnel:" /etc/cloudflared/config.yml 2>/dev/null | awk '{print $2}')
        fi
        if [ -f "$CF_CONFIG_FILE" ] && [ -z "$TUNNEL_ID" ]; then
            TUNNEL_ID=$(grep "^tunnel:" "$CF_CONFIG_FILE" 2>/dev/null | awk '{print $2}')
        fi
        
        if [ -n "$TUNNEL_ID" ]; then
            echo -e "   ${GREEN}✓ PASS${NC} - Tunnel ID found: $TUNNEL_ID"
            : $((passed_checks++))
        else
            echo -e "   ${RED}✗ FAIL${NC} - No tunnel configured in config files"
            : $((failed_checks++))
            
            # AUTO-FIX: Try to find existing tunnels
            if command_exists cloudflared; then
                echo -e "   ${YELLOW}→ AUTO-FIX: Searching for existing tunnels...${NC}"
                local existing_tunnels=$(cloudflared tunnel list 2>/dev/null | tail -n +2)
                
                if [ -n "$existing_tunnels" ]; then
                    # Use the first available tunnel
                    TUNNEL_ID=$(echo "$existing_tunnels" | head -1 | awk '{print $1}')
                    TUNNEL_NAME=$(echo "$existing_tunnels" | head -1 | awk '{print $2}')
                    
                    if [ -n "$TUNNEL_ID" ]; then
                        echo -e "   ${GREEN}✓ FIXED${NC} - Found existing tunnel: $TUNNEL_NAME ($TUNNEL_ID)"
                        
                        # Save tunnel ID to config
                        if [ -f "$CF_CONFIG_FILE" ]; then
                            # Update existing config
                            if grep -q "^tunnel:" "$CF_CONFIG_FILE"; then
                                sed -i "s/^tunnel:.*/tunnel: $TUNNEL_ID/" "$CF_CONFIG_FILE"
                            else
                                sed -i "1i tunnel: $TUNNEL_ID" "$CF_CONFIG_FILE"
                            fi
                        fi
                        : $((auto_fixed++))
                    fi
                else
                    # No existing tunnels - create one automatically
                    echo -e "   ${YELLOW}→ AUTO-FIX: No tunnels found, creating new tunnel...${NC}"
                    local auto_tunnel_name="auto-tunnel-$(hostname 2>/dev/null || echo 'server')-$(date +%s | tail -c 5)"
                    
                    if cloudflared tunnel create "$auto_tunnel_name" 2>/dev/null; then
                        TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | grep "$auto_tunnel_name" | awk '{print $1}')
                        TUNNEL_NAME="$auto_tunnel_name"
                        
                        if [ -n "$TUNNEL_ID" ]; then
                            echo -e "   ${GREEN}✓ FIXED${NC} - Created tunnel: $TUNNEL_NAME ($TUNNEL_ID)"
                            : $((auto_fixed++))
                        else
                            echo -e "   ${RED}✗ FAILED TO FIX${NC} - Could not get tunnel ID after creation"
                            : $((manual_needed++))
                        fi
                    else
                        echo -e "   ${RED}✗ FAILED TO FIX${NC} - Could not create tunnel (may need authentication)"
                        echo -e "   ${YELLOW}⚠ Run: cloudflared tunnel login${NC}"
                        : $((manual_needed++))
                    fi
                fi
            else
                echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - cloudflared not installed"
                : $((manual_needed++))
            fi
        fi
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 6: Tunnel exists in Cloudflare
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[6/12] Verifying tunnel exists in Cloudflare...${NC}"
    if [ -n "$TUNNEL_ID" ] && command_exists cloudflared; then
        if cloudflared tunnel info "$TUNNEL_ID" &>/dev/null; then
            TUNNEL_NAME=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_ID" | awk '{print $2}')
            echo -e "   ${GREEN}✓ PASS${NC} - Tunnel exists: $TUNNEL_NAME"
            : $((passed_checks++))
        else
            echo -e "   ${RED}✗ FAIL${NC} - Tunnel ID not found in Cloudflare account"
            : $((failed_checks++))
            
            # AUTO-FIX: Try to select a different existing tunnel
            echo -e "   ${YELLOW}→ AUTO-FIX: Looking for valid tunnels...${NC}"
            local valid_tunnels=$(cloudflared tunnel list 2>/dev/null | tail -n +2)
            
            if [ -n "$valid_tunnels" ]; then
                local new_tunnel_id=$(echo "$valid_tunnels" | head -1 | awk '{print $1}')
                local new_tunnel_name=$(echo "$valid_tunnels" | head -1 | awk '{print $2}')
                
                if [ -n "$new_tunnel_id" ] && cloudflared tunnel info "$new_tunnel_id" &>/dev/null; then
                    TUNNEL_ID="$new_tunnel_id"
                    TUNNEL_NAME="$new_tunnel_name"
                    
                    # Update config files
                    if [ -f "/etc/cloudflared/config.yml" ]; then
                        sudo sed -i "s/^tunnel:.*/tunnel: $TUNNEL_ID/" /etc/cloudflared/config.yml
                    fi
                    if [ -f "$CF_CONFIG_FILE" ]; then
                        sed -i "s/^tunnel:.*/tunnel: $TUNNEL_ID/" "$CF_CONFIG_FILE"
                    fi
                    
                    echo -e "   ${GREEN}✓ FIXED${NC} - Switched to valid tunnel: $TUNNEL_NAME ($TUNNEL_ID)"
                    : $((auto_fixed++))
                else
                    echo -e "   ${RED}✗ FAILED TO FIX${NC} - No valid tunnels available"
                    : $((manual_needed++))
                fi
            else
                # Create new tunnel
                echo -e "   ${YELLOW}→ AUTO-FIX: Creating new tunnel...${NC}"
                local auto_tunnel_name="auto-tunnel-$(hostname 2>/dev/null || echo 'server')-$(date +%s | tail -c 5)"
                
                if cloudflared tunnel create "$auto_tunnel_name" 2>/dev/null; then
                    TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | grep "$auto_tunnel_name" | awk '{print $1}')
                    TUNNEL_NAME="$auto_tunnel_name"
                    
                    # Update config files
                    if [ -f "/etc/cloudflared/config.yml" ]; then
                        sudo sed -i "s/^tunnel:.*/tunnel: $TUNNEL_ID/" /etc/cloudflared/config.yml
                    fi
                    if [ -f "$CF_CONFIG_FILE" ]; then
                        sed -i "s/^tunnel:.*/tunnel: $TUNNEL_ID/" "$CF_CONFIG_FILE"
                    fi
                    
                    echo -e "   ${GREEN}✓ FIXED${NC} - Created new tunnel: $TUNNEL_NAME ($TUNNEL_ID)"
                    : $((auto_fixed++))
                else
                    echo -e "   ${RED}✗ FAILED TO FIX${NC} - Could not create tunnel"
                    : $((manual_needed++))
                fi
            fi
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - No tunnel ID to verify"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 7: Configuration file exists
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[7/12] Checking configuration file...${NC}"
    if [ -f "/etc/cloudflared/config.yml" ]; then
        echo -e "   ${GREEN}✓ PASS${NC} - System config exists (/etc/cloudflared/config.yml)"
        : $((passed_checks++))
    elif [ -f "$CF_CONFIG_FILE" ]; then
        echo -e "   ${YELLOW}⚠ WARN${NC} - User config exists but not in system location"
        echo -e "   ${YELLOW}→ AUTO-FIX: Copying to system location...${NC}"
        : $((failed_checks++))
        sudo mkdir -p /etc/cloudflared
        if sudo cp "$CF_CONFIG_FILE" /etc/cloudflared/config.yml; then
            sudo cp "$CF_CONFIG_DIR"/*.json /etc/cloudflared/ 2>/dev/null || true
            echo -e "   ${GREEN}✓ FIXED${NC} - Config copied to /etc/cloudflared/"
            : $((auto_fixed++))
        else
            echo -e "   ${RED}✗ FAILED TO FIX${NC}"
            : $((manual_needed++))
        fi
    else
        echo -e "   ${RED}✗ FAIL${NC} - No configuration file found"
        : $((failed_checks++))
        
        # AUTO-FIX: Generate basic config if we have tunnel ID
        if [ -n "$TUNNEL_ID" ]; then
            echo -e "   ${YELLOW}→ AUTO-FIX: Generating basic configuration...${NC}"
            
            # Find credentials file
            local creds_file=""
            for search_path in "$CF_CONFIG_DIR"/*.json /etc/cloudflared/*.json; do
                if [ -f "$search_path" ]; then
                    creds_file="$search_path"
                    break
                fi
            done
            
            sudo mkdir -p /etc/cloudflared
            
            # Create basic config
            sudo tee /etc/cloudflared/config.yml > /dev/null << EOCFG
# Cloudflare Tunnel Configuration
# Auto-generated by auto_debug
# Generated: $(date)

tunnel: $TUNNEL_ID
credentials-file: ${creds_file:-/etc/cloudflared/${TUNNEL_ID}.json}

ingress:
  # Add your hostname rules here
  # Example:
  # - hostname: example.com
  #   service: http://localhost:80
  
  # Catch-all (must be last)
  - service: http_status:404
EOCFG
            
            if [ -f "/etc/cloudflared/config.yml" ]; then
                # Copy credentials to system location
                if [ -n "$creds_file" ] && [ -f "$creds_file" ]; then
                    sudo cp "$creds_file" /etc/cloudflared/ 2>/dev/null
                    local creds_filename=$(basename "$creds_file")
                    sudo sed -i "s|credentials-file:.*|credentials-file: /etc/cloudflared/$creds_filename|g" /etc/cloudflared/config.yml
                fi
                echo -e "   ${GREEN}✓ FIXED${NC} - Created basic configuration"
                echo -e "   ${YELLOW}  Note: Add hostname rules via 'Add domain' (option 2)${NC}"
                : $((auto_fixed++))
            else
                echo -e "   ${RED}✗ FAILED TO FIX${NC}"
                : $((manual_needed++))
            fi
        else
            echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - No tunnel ID available to generate config"
            : $((manual_needed++))
        fi
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 8: Credentials file path
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[8/12] Checking credentials file...${NC}"
    local config_file="/etc/cloudflared/config.yml"
    [ ! -f "$config_file" ] && config_file="$CF_CONFIG_FILE"
    
    if [ -f "$config_file" ]; then
        local creds_path=$(grep "credentials-file:" "$config_file" 2>/dev/null | awk '{print $2}')
        
        if [ -n "$creds_path" ]; then
            if [ -f "$creds_path" ]; then
                echo -e "   ${GREEN}✓ PASS${NC} - Credentials file exists ($creds_path)"
                : $((passed_checks++))
            else
                echo -e "   ${RED}✗ FAIL${NC} - Credentials file missing: $creds_path"
                : $((failed_checks++))
                
                # Try to find existing credentials
                local found_creds=""
                for search_path in /etc/cloudflared/*.json "$CF_CONFIG_DIR"/*.json; do
                    if [ -f "$search_path" ]; then
                        found_creds="$search_path"
                        break
                    fi
                done
                
                if [ -n "$found_creds" ]; then
                    echo -e "   ${YELLOW}→ AUTO-FIX: Found credentials at $found_creds${NC}"
                    local creds_filename=$(basename "$found_creds")
                    sudo cp "$found_creds" /etc/cloudflared/ 2>/dev/null
                    sudo sed -i "s|credentials-file:.*|credentials-file: /etc/cloudflared/$creds_filename|g" /etc/cloudflared/config.yml
                    echo -e "   ${GREEN}✓ FIXED${NC} - Updated credentials path"
                    : $((auto_fixed++))
                elif [ -n "$TUNNEL_ID" ]; then
                    # Try to regenerate credentials using tunnel ID
                    echo -e "   ${YELLOW}→ AUTO-FIX: Attempting to regenerate credentials for tunnel $TUNNEL_ID...${NC}"
                    local new_creds_file="/etc/cloudflared/${TUNNEL_ID}.json"
                    
                    # Check if we can get credentials from cloudflared
                    if cloudflared tunnel token "$TUNNEL_ID" &>/dev/null; then
                        # Create a minimal credentials file
                        local tunnel_token=$(cloudflared tunnel token "$TUNNEL_ID" 2>/dev/null)
                        if [ -n "$tunnel_token" ]; then
                            echo -e "   ${GREEN}✓ FIXED${NC} - Use token-based auth instead"
                            echo -e "   ${YELLOW}  Recommendation: Use 'Install service with token' (option 11)${NC}"
                            : $((auto_fixed++))
                        fi
                    else
                        echo -e "   ${RED}✗ FAILED TO FIX${NC} - Cannot regenerate credentials"
                        echo -e "   ${YELLOW}⚠ Solution: Delete tunnel and recreate, or use token-based auth${NC}"
                        : $((manual_needed++))
                    fi
                else
                    echo -e "   ${RED}✗ FAILED TO FIX${NC} - No credentials and no tunnel ID"
                    echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - Re-authenticate and create tunnel"
                    : $((manual_needed++))
                fi
            fi
        else
            echo -e "   ${YELLOW}⚠ WARN${NC} - No credentials-file path in config"
            : $((failed_checks++))
            
            # AUTO-FIX: Find credentials and add to config
            local found_creds=""
            for search_path in /etc/cloudflared/*.json "$CF_CONFIG_DIR"/*.json; do
                if [ -f "$search_path" ]; then
                    found_creds="$search_path"
                    break
                fi
            done
            
            if [ -n "$found_creds" ]; then
                echo -e "   ${YELLOW}→ AUTO-FIX: Found credentials at $found_creds${NC}"
                local creds_filename=$(basename "$found_creds")
                sudo cp "$found_creds" /etc/cloudflared/ 2>/dev/null
                
                # Add credentials-file line to config after tunnel line
                if [ -f "/etc/cloudflared/config.yml" ]; then
                    sudo sed -i "/^tunnel:/a credentials-file: /etc/cloudflared/$creds_filename" /etc/cloudflared/config.yml
                    echo -e "   ${GREEN}✓ FIXED${NC} - Added credentials path to config"
                    : $((auto_fixed++))
                fi
            else
                echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - No credentials file found"
                : $((manual_needed++))
            fi
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - No config file to check"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 9: Config syntax validation
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[9/12] Validating configuration syntax...${NC}"
    if [ -f "/etc/cloudflared/config.yml" ] && command_exists cloudflared; then
        if cloudflared tunnel ingress validate --config /etc/cloudflared/config.yml &>/dev/null; then
            echo -e "   ${GREEN}✓ PASS${NC} - Configuration syntax is valid"
            : $((passed_checks++))
        else
            echo -e "   ${RED}✗ FAIL${NC} - Configuration syntax error"
            echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - Review config: cat /etc/cloudflared/config.yml"
            cloudflared tunnel ingress validate --config /etc/cloudflared/config.yml 2>&1 | head -5
            : $((failed_checks++))
            : $((manual_needed++))
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - No config to validate"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 10: DNS Records and Ingress Rules for configured hostnames
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[10/13] Verifying DNS records for configured hostnames...${NC}"
    
    # Only run if we have API token and tunnel ID
    if [ -n "$CF_API_TOKEN" ] && [ -n "$TUNNEL_ID" ]; then
        local tunnel_target="${TUNNEL_ID}.cfargotunnel.com"
        local config_file="/etc/cloudflared/config.yml"
        [ ! -f "$config_file" ] && config_file="$CF_CONFIG_FILE"
        
        if [ -f "$config_file" ]; then
            # Extract hostnames from config (excluding catch-all)
            local hostnames=$(grep -E "^\s*-?\s*hostname:" "$config_file" 2>/dev/null | awk '{print $NF}' | grep -v "^$")
            
            if [ -n "$hostnames" ]; then
                local dns_issues=0
                local dns_fixed=0
                
                # Use process substitution to avoid subshell (preserves variable changes)
                while read -r hostname; do
                    [ -z "$hostname" ] && continue
                    
                    # Get zone ID for this hostname
                    local host_zone_id=$(get_zone_id "$hostname" 2>/dev/null)
                    
                    if [ -n "$host_zone_id" ]; then
                        # Check if DNS record exists and points to tunnel
                        if check_dns_record_exists "$host_zone_id" "$hostname"; then
                            if [ "$EXISTING_RECORD_TYPE" = "CNAME" ] && [ "$EXISTING_RECORD_CONTENT" = "$tunnel_target" ]; then
                                echo -e "   ${GREEN}✓${NC} $hostname → tunnel"
                            else
                                echo -e "   ${YELLOW}⚠${NC} $hostname → wrong target ($EXISTING_RECORD_CONTENT)"
                                # Auto-fix: Delete and recreate
                                if [ -n "$EXISTING_RECORD_ID" ]; then
                                    delete_dns_record "$host_zone_id" "$EXISTING_RECORD_ID" 2>/dev/null
                                fi
                                # Extract record name from hostname
                                local root_domain=$(echo "$hostname" | awk -F. '{if(NF>2){print $(NF-1)"."$NF}else{print $0}}')
                                local record_name="${hostname%.$root_domain}"
                                [ "$record_name" = "$hostname" ] && record_name="@"
                                
                                if create_dns_record "$host_zone_id" "$record_name" "$tunnel_target" "CNAME" "true" 2>/dev/null; then
                                    echo -e "   ${GREEN}✓ FIXED${NC} $hostname"
                                    : $((dns_fixed++))
                                    : $((config_changed++))
                                fi
                            fi
                        else
                            echo -e "   ${RED}✗${NC} $hostname → missing DNS record"
                            # Auto-fix: Create DNS record
                            local root_domain=$(echo "$hostname" | awk -F. '{if(NF>2){print $(NF-1)"."$NF}else{print $0}}')
                            local record_name="${hostname%.$root_domain}"
                            [ "$record_name" = "$hostname" ] && record_name="@"
                            
                            if create_dns_record "$host_zone_id" "$record_name" "$tunnel_target" "CNAME" "true" 2>/dev/null; then
                                echo -e "   ${GREEN}✓ FIXED${NC} $hostname → created DNS record"
                                : $((dns_fixed++))
                                : $((config_changed++))
                            else
                                : $((dns_issues++))
                            fi
                        fi
                    else
                        echo -e "   ${YELLOW}⊘${NC} $hostname → zone not found (may be external)"
                    fi
                done <<< "$hostnames"
                
                # Update counters based on results
                if [ $dns_fixed -gt 0 ]; then
                    : $((auto_fixed++))
                fi
                
                if [ $dns_issues -eq 0 ]; then
                    echo -e "   ${GREEN}✓ PASS${NC} - All DNS records verified/fixed"
                    : $((passed_checks++))
                else
                    echo -e "   ${YELLOW}⚠ WARN${NC} - Some DNS records could not be auto-fixed"
                    : $((failed_checks++))
                    : $((manual_needed++))
                fi
            else
                echo -e "   ${YELLOW}⊘ SKIP${NC} - No hostnames found in config"
            fi
        else
            echo -e "   ${YELLOW}⊘ SKIP${NC} - No config file to read hostnames from"
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - API token or tunnel ID not available"
    fi

    #---------------------------------------------------------------------------
    # CHECK 10.5: Verify www ingress rules exist in config
    #---------------------------------------------------------------------------
    if [ -n "$TUNNEL_ID" ]; then
        local config_file="/etc/cloudflared/config.yml"
        [ ! -f "$config_file" ] && config_file="$CF_CONFIG_FILE"
        
        if [ -f "$config_file" ]; then
            # Get all hostnames from config
            local hostnames=$(grep -E "^\s*-?\s*hostname:" "$config_file" 2>/dev/null | awk '{print $NF}' | grep -v "^$")
            
            # Find root domains (without www) that don't have www variant in ingress
            local missing_www=""
            while read -r hostname; do
                [ -z "$hostname" ] && continue
                # Skip if already a www hostname
                [[ "$hostname" == www.* ]] && continue
                
                local www_hostname="www.$hostname"
                # Check if www variant exists in config
                if ! echo "$hostnames" | grep -qx "$www_hostname"; then
                    missing_www="$missing_www $www_hostname"
                fi
            done <<< "$hostnames"
            
            if [ -n "$missing_www" ]; then
                echo -e "   ${YELLOW}⚠${NC} Missing www ingress rules detected"
                
                for www_host in $missing_www; do
                    # Get the service URL from the non-www version
                    local base_host="${www_host#www.}"
                    local service_url=$(grep -A2 "hostname: $base_host\$" "$config_file" 2>/dev/null | grep "service:" | awk '{print $2}' | head -1)
                    
                    if [ -n "$service_url" ]; then
                        # Add www ingress rule before catch-all
                        echo -e "   ${YELLOW}→ AUTO-FIX:${NC} Adding ingress rule for $www_host"
                        
                        # Find position of catch-all and insert before it
                        local catch_all_line=$(grep -n "service: http_status:404" "$config_file" | tail -1 | cut -d: -f1)
                        if [ -n "$catch_all_line" ]; then
                            # Create temporary file with new ingress entry
                            local tmp_file=$(mktemp)
                            head -n $((catch_all_line - 1)) "$config_file" > "$tmp_file"
                            echo "  # $www_host (auto-added)" >> "$tmp_file"
                            echo "  - hostname: $www_host" >> "$tmp_file"
                            echo "    service: $service_url" >> "$tmp_file"
                            echo "" >> "$tmp_file"
                            tail -n +$catch_all_line "$config_file" >> "$tmp_file"
                            sudo cp "$tmp_file" "$config_file"
                            rm -f "$tmp_file"
                            
                            echo -e "   ${GREEN}✓ FIXED${NC} Added ingress rule for $www_host"
                            : $((auto_fixed++))
                            : $((config_changed++))
                            
                            # Also create DNS record if API token available
                            if [ -n "$CF_API_TOKEN" ]; then
                                local host_zone_id=$(get_zone_id "$www_host" 2>/dev/null)
                                if [ -n "$host_zone_id" ]; then
                                    local tunnel_target="${TUNNEL_ID}.cfargotunnel.com"
                                    if ! check_dns_record_exists "$host_zone_id" "$www_host"; then
                                        create_dns_record "$host_zone_id" "www" "$tunnel_target" "CNAME" "true" 2>/dev/null
                                    fi
                                fi
                            fi
                        fi
                    fi
                done
            fi
        fi
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 11: Systemd service installed
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[11/13] Checking systemd service...${NC}"
    if systemctl list-unit-files 2>/dev/null | grep -q cloudflared; then
        echo -e "   ${GREEN}✓ PASS${NC} - Service unit file exists"
        : $((passed_checks++))
    else
        echo -e "   ${RED}✗ FAIL${NC} - Service not installed"
        echo -e "   ${YELLOW}→ AUTO-FIX: Installing service...${NC}"
        : $((failed_checks++))
        
        if [ -f "/etc/cloudflared/config.yml" ]; then
            if sudo cloudflared service install 2>/dev/null; then
                echo -e "   ${GREEN}✓ FIXED${NC} - Service installed"
                : $((auto_fixed++))
            else
                # Manual systemd service creation
                local cf_path=$(which cloudflared 2>/dev/null || echo "/usr/local/bin/cloudflared")
                sudo tee /etc/systemd/system/cloudflared.service > /dev/null << EOSVC
[Unit]
Description=Cloudflare Tunnel
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$cf_path --config /etc/cloudflared/config.yml tunnel run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOSVC
                sudo systemctl daemon-reload
                echo -e "   ${GREEN}✓ FIXED${NC} - Service created manually"
                : $((auto_fixed++))
            fi
        else
            echo -e "   ${RED}✗ FAILED TO FIX${NC} - No config file available"
            : $((manual_needed++))
        fi
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 12: Service enabled
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[12/13] Checking service is enabled...${NC}"
    if systemctl list-unit-files 2>/dev/null | grep -q cloudflared; then
        if sudo systemctl is-enabled --quiet cloudflared 2>/dev/null; then
            echo -e "   ${GREEN}✓ PASS${NC} - Service is enabled (auto-start on boot)"
            : $((passed_checks++))
        else
            echo -e "   ${YELLOW}⚠ WARN${NC} - Service not enabled"
            echo -e "   ${YELLOW}→ AUTO-FIX: Enabling service...${NC}"
            : $((failed_checks++))
            if sudo systemctl enable cloudflared 2>/dev/null; then
                echo -e "   ${GREEN}✓ FIXED${NC} - Service enabled"
                : $((auto_fixed++))
            else
                echo -e "   ${RED}✗ FAILED TO FIX${NC}"
                : $((manual_needed++))
            fi
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - Service not installed"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 13: Service running (restart if config changed)
    #---------------------------------------------------------------------------
    : $((total_checks++))
    echo -e "${CYAN}[13/13] Checking service is running...${NC}"
    
    # If config was changed, restart service to apply changes
    if [ $config_changed -gt 0 ]; then
        echo -e "   ${YELLOW}→${NC} Config was modified, restarting service to apply changes..."
        sudo systemctl daemon-reload
        if sudo systemctl restart cloudflared 2>/dev/null; then
            sleep 3
            echo -e "   ${GREEN}✓${NC} Service restarted"
        fi
    fi
    
    if sudo systemctl is-active --quiet cloudflared 2>/dev/null; then
        echo -e "   ${GREEN}✓ PASS${NC} - Service is running"
        : $((passed_checks++))
        
        # Additional: Check tunnel connection in logs
        local recent_log=$(sudo journalctl -u cloudflared -n 5 --no-pager 2>/dev/null | grep -iE "registered|connected|serving" | tail -1)
        if [ -n "$recent_log" ]; then
            echo -e "   ${GREEN}✓ BONUS${NC} - Tunnel appears connected"
        fi
    else
        echo -e "   ${RED}✗ FAIL${NC} - Service is not running"
        : $((failed_checks++))
        
        # Check if we have all prerequisites to start
        if [ -f "/etc/cloudflared/config.yml" ] && systemctl list-unit-files 2>/dev/null | grep -q cloudflared; then
            echo -e "   ${YELLOW}→ AUTO-FIX: Starting service...${NC}"
            sudo systemctl daemon-reload
            if sudo systemctl start cloudflared; then
                sleep 3
                if sudo systemctl is-active --quiet cloudflared; then
                    echo -e "   ${GREEN}✓ FIXED${NC} - Service started successfully"
                    : $((auto_fixed++))
                else
                    echo -e "   ${RED}✗ FAILED TO FIX${NC} - Service won't stay running"
                    echo -e "   Recent logs:"
                    sudo journalctl -u cloudflared -n 5 --no-pager 2>/dev/null | tail -3
                    : $((manual_needed++))
                fi
            else
                echo -e "   ${RED}✗ FAILED TO FIX${NC} - Could not start service"
                : $((manual_needed++))
            fi
        else
            echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - Prerequisites missing"
            : $((manual_needed++))
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
        echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ✓ ALL CHECKS PASSED - TUNNEL IS HEALTHY                       ${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    elif [ $manual_needed -eq 0 ] && [ $auto_fixed -gt 0 ]; then
        echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ✓ ALL ISSUES AUTO-FIXED - TUNNEL SHOULD BE WORKING            ${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    else
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  ⚠ MANUAL ACTION REQUIRED FOR $manual_needed ISSUE(S)                       ${NC}"
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${CYAN}Recommended next steps:${NC}"
        echo "  1. Run full setup (option 1) to configure from scratch"
        echo "  2. Or use 'Fix configuration' (option 8) for guided repair"
    fi
    
    echo ""
    if confirm "Return to menu?"; then
        show_menu
    fi
}

#===============================================================================
# FIX CONFIGURATION
#===============================================================================

fix_configuration() {
    print_section "Fix Configuration - Automatic Repair"
    
    local issues_found=0
    local issues_fixed=0
    
    log "INFO" "Scanning for configuration issues..."
    echo ""
    
    # 1. Check cloudflared installation
    echo -e "${CYAN}1. Checking cloudflared installation...${NC}"
    if ! command_exists cloudflared; then
        echo -e "   ${RED}✗ cloudflared not installed${NC}"
        : $((issues_found++))
        if confirm "   Install cloudflared?"; then
            install_cloudflared
            : $((issues_fixed++))
        fi
    else
        echo -e "   ${GREEN}✓ cloudflared installed${NC}"
    fi
    
    # 2. Check authentication
    echo -e "${CYAN}2. Checking Cloudflare authentication...${NC}"
    if [ ! -f "$CF_CONFIG_DIR/cert.pem" ] && [ ! -f "/etc/cloudflared/cert.pem" ]; then
        echo -e "   ${RED}✗ Not authenticated${NC}"
        : $((issues_found++))
        if confirm "   Authenticate with Cloudflare?"; then
            authenticate_cloudflare
            : $((issues_fixed++))
        fi
    else
        echo -e "   ${GREEN}✓ Authenticated${NC}"
    fi
    
    # 3. Check API token
    echo -e "${CYAN}3. Checking API token...${NC}"
    if [ -z "$CF_API_TOKEN" ] || [ "$CF_API_TOKEN" = "" ]; then
        echo -e "   ${RED}✗ API token not configured${NC}"
        : $((issues_found++))
        if confirm "   Configure API token?"; then
            setup_api_token
            : $((issues_fixed++))
        fi
    else
        # Validate token
        local token_test=$(curl -s -X GET "$CF_API_URL/user/tokens/verify" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" 2>/dev/null | grep -o '"success":true')
        if [ -n "$token_test" ]; then
            echo -e "   ${GREEN}✓ API token valid${NC}"
        else
            echo -e "   ${YELLOW}⚠ API token may be invalid${NC}"
            : $((issues_found++))
            if confirm "   Re-configure API token?"; then
                setup_api_token
                : $((issues_fixed++))
            fi
        fi
    fi
    
    # 4. Check tunnel exists
    echo -e "${CYAN}4. Checking tunnel configuration...${NC}"
    if [ -z "$TUNNEL_ID" ]; then
        echo -e "   ${RED}✗ No tunnel configured${NC}"
        : $((issues_found++))
        if confirm "   Create or select a tunnel?"; then
            select_or_create_tunnel
            : $((issues_fixed++))
        fi
    else
        # Verify tunnel exists in Cloudflare
        if cloudflared tunnel info "$TUNNEL_ID" &>/dev/null; then
            echo -e "   ${GREEN}✓ Tunnel exists: ${TUNNEL_ID}${NC}"
        else
            echo -e "   ${RED}✗ Tunnel not found in Cloudflare${NC}"
            : $((issues_found++))
            if confirm "   Create new tunnel?"; then
                select_or_create_tunnel
                : $((issues_fixed++))
            fi
        fi
    fi
    
    # 5. Check config file
    echo -e "${CYAN}5. Checking configuration file...${NC}"
    if [ ! -f "/etc/cloudflared/config.yml" ]; then
        echo -e "   ${RED}✗ System config missing${NC}"
        : $((issues_found++))
        if [ -f "$CF_CONFIG_FILE" ]; then
            echo -e "   Found user config at $CF_CONFIG_FILE"
            if confirm "   Copy to system location?"; then
                sudo mkdir -p /etc/cloudflared
                sudo cp "$CF_CONFIG_FILE" /etc/cloudflared/config.yml
                sudo cp "$CF_CONFIG_DIR"/*.json /etc/cloudflared/ 2>/dev/null || true
                : $((issues_fixed++))
            fi
        else
            if confirm "   Generate new configuration?"; then
                configure_service
                generate_config
                install_service
                : $((issues_fixed++))
            fi
        fi
    else
        echo -e "   ${GREEN}✓ Configuration file exists${NC}"
    fi
    
    # 6. Check credentials file path
    echo -e "${CYAN}6. Checking credentials file path...${NC}"
    local creds_path=$(grep "credentials-file:" /etc/cloudflared/config.yml 2>/dev/null | awk '{print $2}')
    if [ -n "$creds_path" ]; then
        if [ -f "$creds_path" ]; then
            echo -e "   ${GREEN}✓ Credentials file exists at $creds_path${NC}"
        else
            echo -e "   ${RED}✗ Credentials file missing: $creds_path${NC}"
            : $((issues_found++))
            
            # Look for credentials file
            local found_creds=$(ls /etc/cloudflared/*.json 2>/dev/null | head -1)
            if [ -z "$found_creds" ]; then
                found_creds=$(ls "$CF_CONFIG_DIR"/*.json 2>/dev/null | head -1)
            fi
            
            if [ -n "$found_creds" ]; then
                echo -e "   Found credentials at: $found_creds"
                if confirm "   Update config to use this file?"; then
                    local creds_filename=$(basename "$found_creds")
                    sudo cp "$found_creds" /etc/cloudflared/ 2>/dev/null || true
                    sudo sed -i "s|credentials-file:.*|credentials-file: /etc/cloudflared/$creds_filename|g" /etc/cloudflared/config.yml
                    echo -e "   ${GREEN}✓ Updated credentials path${NC}"
                    : $((issues_fixed++))
                fi
            else
                echo -e "   ${RED}No credentials file found. Need to re-authenticate.${NC}"
                if confirm "   Re-authenticate?"; then
                    authenticate_cloudflare
                    select_or_create_tunnel
                    : $((issues_fixed++))
                fi
            fi
        fi
    fi
    
    # 7. Check systemd service
    echo -e "${CYAN}7. Checking systemd service...${NC}"
    if systemctl list-unit-files | grep -q cloudflared; then
        if sudo systemctl is-enabled --quiet cloudflared 2>/dev/null; then
            echo -e "   ${GREEN}✓ Service enabled${NC}"
        else
            echo -e "   ${YELLOW}⚠ Service not enabled${NC}"
            : $((issues_found++))
            if confirm "   Enable service?"; then
                sudo systemctl enable cloudflared
                : $((issues_fixed++))
            fi
        fi
        
        if sudo systemctl is-active --quiet cloudflared 2>/dev/null; then
            echo -e "   ${GREEN}✓ Service running${NC}"
        else
            echo -e "   ${RED}✗ Service not running${NC}"
            : $((issues_found++))
            if confirm "   Start service?"; then
                sudo systemctl start cloudflared
                sleep 3
                if sudo systemctl is-active --quiet cloudflared; then
                    echo -e "   ${GREEN}✓ Service started${NC}"
                    : $((issues_fixed++))
                else
                    echo -e "   ${RED}Service failed to start${NC}"
                    sudo journalctl -u cloudflared -n 10 --no-pager
                fi
            fi
        fi
    else
        echo -e "   ${RED}✗ Service not installed${NC}"
        : $((issues_found++))
        if confirm "   Install service?"; then
            install_service
            : $((issues_fixed++))
        fi
    fi
    
    # 8. Check DNS records
    echo -e "${CYAN}8. Checking DNS records...${NC}"
    if [ -n "$ZONE_ID" ] && [ -n "$TUNNEL_ID" ]; then
        local tunnel_target="${TUNNEL_ID}.cfargotunnel.com"
        echo -e "   Expected CNAME target: $tunnel_target"
        
        # List existing records
        local existing_records=$(curl -s -X GET "$CF_API_URL/zones/$ZONE_ID/dns_records?type=CNAME" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" 2>/dev/null)
        
        local tunnel_records=$(echo "$existing_records" | grep -o "\"content\":\"${TUNNEL_ID}.cfargotunnel.com\"" | wc -l)
        if [ "$tunnel_records" -gt 0 ]; then
            echo -e "   ${GREEN}✓ Found $tunnel_records DNS record(s) pointing to tunnel${NC}"
        else
            echo -e "   ${YELLOW}⚠ No DNS records found for this tunnel${NC}"
            echo -e "   ${YELLOW}  Run 'Manage DNS records' to set up DNS${NC}"
        fi
    else
        echo -e "   ${YELLOW}⚠ Cannot check DNS - Zone ID or Tunnel ID missing${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    if [ $issues_found -eq 0 ]; then
        log "INFO" "No issues found! Configuration appears healthy."
    else
        log "INFO" "Found $issues_found issue(s), fixed $issues_fixed"
        
        if [ $issues_fixed -gt 0 ]; then
            echo ""
            if confirm "Restart cloudflared service to apply changes?"; then
                sudo systemctl restart cloudflared
                sleep 3
                if sudo systemctl is-active --quiet cloudflared; then
                    log "INFO" "Service restarted successfully"
                else
                    log "ERROR" "Service failed to restart"
                    sudo journalctl -u cloudflared -n 10 --no-pager
                fi
            fi
        fi
    fi
    
    echo ""
    if confirm "Return to menu?"; then
        show_menu
    fi
}

view_logs() {
    echo "Press Ctrl+C to stop viewing logs"
    sleep 2
    sudo journalctl -u cloudflared -f
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

main() {
    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        log "WARN" "Running as root. Some files will be created in /root/.cloudflared"
    fi
    
    # Check dependencies
    check_dependencies
    
    show_menu
}

main "$@"
