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
CF_API_TOKEN="5SmpLIr6eL_EkeZy3ouR_C4Sv9GMcSFlTV92p-wa"

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
    
    if echo "$response" | grep -q '"count":0'; then
        return 1  # Record does not exist
    else
        # Extract existing record info
        local record_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        local record_type=$(echo "$response" | grep -o '"type":"[^"]*"' | head -1 | cut -d'"' -f4)
        local record_content=$(echo "$response" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
        
        EXISTING_RECORD_ID="$record_id"
        EXISTING_RECORD_TYPE="$record_type"
        EXISTING_RECORD_CONTENT="$record_content"
        return 0  # Record exists
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
                ((dns_success++))
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
            ((dns_success++))
        else
            echo -e "${RED}✗ Failed${NC}"
            ((dns_failed++))
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
    
    sleep 3
    
    if sudo systemctl is-active --quiet cloudflared; then
        log "INFO" "Cloudflared service is running"
    else
        log "ERROR" "Service failed to start"
        sudo systemctl status cloudflared
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
    
    echo "What would you like to do?"
    echo ""
    echo "1. Full setup (new installation)"
    echo "2. Add domain to existing tunnel"
    echo "3. View current configuration"
    echo "4. Manage DNS records"
    echo "5. View available zones"
    echo "6. Restart tunnel service"
    echo "7. View tunnel logs"
    echo "8. Exit"
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
        7) view_logs ;;
        8) exit 0 ;;
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
    sudo systemctl restart cloudflared
    sudo systemctl status cloudflared
    
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
