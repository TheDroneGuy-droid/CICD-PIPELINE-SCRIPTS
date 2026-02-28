#!/bin/bash
#===============================================================================
# MAIN SERVER SETUP SCRIPT
# Purpose: Node.js, PM2, Git credentials, CI/CD auto-deploy pipeline
# Usage: Run on your frontend/application VM
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

# Default values
APP_PORT=3000
WEBHOOK_PORT=9000
NODE_VERSION="20"

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
# INPUT COLLECTION
#===============================================================================

collect_inputs() {
    print_section "Configuration Setup"
    
    # App name
    local default_app_name
    default_app_name=$(basename "$PARENT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    echo -en "${CYAN}Enter application name [${default_app_name}]: ${NC}"
    read -r APP_NAME
    APP_NAME=${APP_NAME:-$default_app_name}
    
    # App directory
    APP_DIR="$PARENT_DIR"
    log "INFO" "Application directory: $APP_DIR"
    
    # GitHub credentials
    echo ""
    echo -e "${YELLOW}GitHub credentials for private repository access${NC}"
    echo -e "${YELLOW}Create PAT at: https://github.com/settings/tokens${NC}"
    echo ""
    
    echo -en "${CYAN}Enter GitHub username: ${NC}"
    read -r GITHUB_USERNAME
    while [ -z "$GITHUB_USERNAME" ]; do
        echo -e "${RED}GitHub username is required!${NC}"
        echo -en "${CYAN}Enter GitHub username: ${NC}"
        read -r GITHUB_USERNAME
    done
    
    echo -en "${CYAN}Enter GitHub Personal Access Token: ${NC}"
    read -rs GITHUB_TOKEN
    echo ""
    while [ -z "$GITHUB_TOKEN" ]; do
        echo -e "${RED}GitHub token is required!${NC}"
        echo -en "${CYAN}Enter GitHub Personal Access Token: ${NC}"
        read -rs GITHUB_TOKEN
        echo ""
    done
    
    # Repository URL
    if [ -d "$APP_DIR/.git" ]; then
        GITHUB_REPO_URL=$(git -C "$APP_DIR" remote get-url origin 2>/dev/null || echo "")
    fi
    
    if [ -z "$GITHUB_REPO_URL" ]; then
        echo -en "${CYAN}Enter GitHub repository URL: ${NC}"
        read -r GITHUB_REPO_URL
    else
        log "INFO" "Detected repository: $GITHUB_REPO_URL"
    fi
    
    # Application port
    echo -en "${CYAN}Enter application port [${APP_PORT}]: ${NC}"
    read -r input_port
    APP_PORT=${input_port:-$APP_PORT}
    
    # Generate webhook secret
    WEBHOOK_SECRET=$(openssl rand -hex 32)
    
    # Summary
    print_section "Configuration Summary"
    echo -e "  Application Name:    ${GREEN}$APP_NAME${NC}"
    echo -e "  Application Dir:     ${GREEN}$APP_DIR${NC}"
    echo -e "  GitHub User:         ${GREEN}$GITHUB_USERNAME${NC}"
    echo -e "  Repository:          ${GREEN}$GITHUB_REPO_URL${NC}"
    echo -e "  App Port:            ${GREEN}$APP_PORT${NC}"
    echo -e "  Webhook Port:        ${GREEN}$WEBHOOK_PORT${NC}"
    echo ""
    
    if ! confirm "Proceed with these settings?"; then
        log "INFO" "Setup cancelled by user"
        exit 0
    fi
}

#===============================================================================
# SYSTEM UPDATE
#===============================================================================

update_system() {
    print_section "Updating System Packages"
    
    if retry_command 3 5 "sudo apt-get update -y"; then
        log "INFO" "Package lists updated"
    else
        log "ERROR" "Failed to update package lists"
        log "INFO" "Trying alternative: sudo apt update"
        sudo apt update -y || {
            log "ERROR" "System update failed. Check internet connection."
            exit 1
        }
    fi
    
    # Install essential packages
    log "INFO" "Installing essential packages..."
    sudo apt-get install -y curl wget git build-essential software-properties-common || {
        log "WARN" "Some packages failed, trying individually..."
        for pkg in curl wget git build-essential; do
            sudo apt-get install -y $pkg 2>/dev/null || log "WARN" "Failed to install $pkg"
        done
    }
}

#===============================================================================
# NODE.JS INSTALLATION
#===============================================================================

install_nodejs() {
    print_section "Installing Node.js ${NODE_VERSION}.x"
    
    if command_exists node; then
        local current_version=$(node -v 2>/dev/null | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$current_version" -ge "$NODE_VERSION" ]; then
            log "INFO" "Node.js v$(node -v) already installed"
            return 0
        fi
        log "INFO" "Upgrading Node.js from v$current_version to v$NODE_VERSION"
    fi
    
    # Method 1: NodeSource
    log "INFO" "Installing via NodeSource..."
    if curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash -; then
        if sudo apt-get install -y nodejs; then
            log "INFO" "Node.js installed successfully via NodeSource"
            return 0
        fi
    fi
    
    # Method 2: NVM fallback
    log "WARN" "NodeSource failed, trying NVM..."
    if [ ! -d "$HOME/.nvm" ]; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    fi
    
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    if nvm install $NODE_VERSION && nvm use $NODE_VERSION && nvm alias default $NODE_VERSION; then
        log "INFO" "Node.js installed via NVM"
        # Link for system-wide access
        sudo ln -sf "$NVM_DIR/versions/node/$(nvm current)/bin/node" /usr/local/bin/node
        sudo ln -sf "$NVM_DIR/versions/node/$(nvm current)/bin/npm" /usr/local/bin/npm
        return 0
    fi
    
    log "ERROR" "Failed to install Node.js"
    exit 1
}

#===============================================================================
# GIT CREDENTIALS SETUP
#===============================================================================

setup_git_credentials() {
    print_section "Configuring Git Credentials"
    
    # Configure git credential storage
    git config --global credential.helper store
    
    # Extract repo host
    local repo_host=$(echo "$GITHUB_REPO_URL" | sed -E 's|https?://([^/]+).*|\1|')
    
    # Create credentials file
    local cred_file="$HOME/.git-credentials"
    local cred_entry="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@${repo_host}"
    
    # Check if entry exists
    if grep -q "$repo_host" "$cred_file" 2>/dev/null; then
        # Update existing
        sed -i "s|https://.*@${repo_host}|${cred_entry}|g" "$cred_file"
        log "INFO" "Updated Git credentials"
    else
        echo "$cred_entry" >> "$cred_file"
        log "INFO" "Added Git credentials"
    fi
    
    chmod 600 "$cred_file"
    
    # Test credentials
    log "INFO" "Testing Git credentials..."
    cd "$APP_DIR"
    if git fetch --dry-run 2>/dev/null; then
        log "INFO" "Git credentials working"
    else
        log "WARN" "Git fetch test failed - credentials may not be valid"
    fi
}

#===============================================================================
# PM2 SETUP
#===============================================================================

setup_pm2() {
    print_section "Setting Up PM2"
    
    # Install PM2
    if ! command_exists pm2; then
        log "INFO" "Installing PM2..."
        if ! sudo npm install -g pm2; then
            log "WARN" "Global install failed, trying with --unsafe-perm"
            sudo npm install -g pm2 --unsafe-perm || {
                log "ERROR" "PM2 installation failed"
                exit 1
            }
        fi
    else
        log "INFO" "PM2 already installed"
    fi
    
    # Install serve for static files
    if ! command_exists serve; then
        log "INFO" "Installing serve..."
        sudo npm install -g serve || log "WARN" "serve install failed, will use npx"
    fi
    
    # Create ecosystem config
    log "INFO" "Creating PM2 ecosystem config..."
    cat > "$APP_DIR/ecosystem.config.cjs" << EOF
module.exports = {
  apps: [{
    name: '${APP_NAME}',
    script: 'npx',
    args: 'serve -s dist -l ${APP_PORT}',
    cwd: '${APP_DIR}',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '500M',
    env: {
      NODE_ENV: 'production',
      PORT: ${APP_PORT}
    },
    error_file: '/var/log/${APP_NAME}-error.log',
    out_file: '/var/log/${APP_NAME}-out.log',
    log_file: '/var/log/${APP_NAME}-combined.log',
    time: true
  }]
};
EOF
    
    # Create log files
    sudo touch /var/log/${APP_NAME}-error.log /var/log/${APP_NAME}-out.log /var/log/${APP_NAME}-combined.log
    sudo chown $USER:$USER /var/log/${APP_NAME}-*.log
    
    log "INFO" "PM2 ecosystem config created"
}

#===============================================================================
# BUILD APPLICATION
#===============================================================================

build_application() {
    print_section "Building Application"
    
    cd "$APP_DIR"
    
    # Install dependencies
    log "INFO" "Installing dependencies..."
    if [ -f "package-lock.json" ]; then
        npm ci || npm install
    else
        npm install
    fi
    
    # Build
    log "INFO" "Building application..."
    npm run build || {
        log "ERROR" "Build failed"
        exit 1
    }
    
    # Verify dist folder
    if [ ! -d "dist" ]; then
        log "ERROR" "dist folder not found after build"
        exit 1
    fi
    
    log "INFO" "Build completed successfully"
}

#===============================================================================
# START PM2
#===============================================================================

start_pm2() {
    print_section "Starting Application with PM2"
    
    cd "$APP_DIR"
    
    # Stop existing if running
    pm2 delete "$APP_NAME" 2>/dev/null || true
    
    # Start application
    if pm2 start ecosystem.config.cjs; then
        log "INFO" "Application started"
    else
        log "ERROR" "Failed to start application"
        exit 1
    fi
    
    # Save PM2 process list
    pm2 save
    
    # Setup startup script
    log "INFO" "Setting up PM2 startup..."
    pm2 startup systemd -u $USER --hp $HOME 2>/dev/null || {
        log "WARN" "Auto startup setup failed, trying alternative..."
        sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u $USER --hp $HOME
    }
    pm2 save
    
    # Verify
    sleep 3
    if pm2 list | grep -q "$APP_NAME"; then
        local status=$(pm2 jlist | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ "$status" = "online" ]; then
            log "INFO" "Application is running"
        else
            log "WARN" "Application status: $status"
            log "INFO" "Check logs: pm2 logs $APP_NAME"
        fi
    fi
}

#===============================================================================
# CI/CD WEBHOOK SETUP
#===============================================================================

setup_cicd_webhook() {
    print_section "Setting Up CI/CD Auto-Deploy Pipeline"
    
    # Install webhook
    if ! command_exists webhook; then
        log "INFO" "Installing webhook..."
        sudo apt-get install -y webhook || {
            log "WARN" "apt install failed, trying Go install..."
            if command_exists go; then
                go install github.com/adnanh/webhook@latest
                sudo cp ~/go/bin/webhook /usr/local/bin/
            else
                log "INFO" "Installing Go first..."
                sudo apt-get install -y golang-go
                go install github.com/adnanh/webhook@latest
                sudo cp ~/go/bin/webhook /usr/local/bin/
            fi
        }
    fi
    
    # Create deploy script
    log "INFO" "Creating deploy script..."
    cat > "$APP_DIR/deploy.sh" << 'DEPLOY_SCRIPT'
#!/bin/bash
#===============================================================================
# AUTO-DEPLOY SCRIPT
# Triggered by GitHub webhook on push
#===============================================================================

set -e

# Configuration
APP_DIR="__APP_DIR__"
APP_NAME="__APP_NAME__"
LOG_FILE="/var/log/__APP_NAME__-deploy.log"
MAX_RETRIES=3
RETRY_DELAY=5

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Error handler
handle_error() {
    log "ERROR: Deployment failed at line $1"
    log "Attempting rollback..."
    cd "$APP_DIR"
    git checkout HEAD~1 2>/dev/null || true
    npm install 2>/dev/null || true
    npm run build 2>/dev/null || true
    pm2 restart "$APP_NAME" 2>/dev/null || true
    exit 1
}

trap 'handle_error $LINENO' ERR

# Retry function
retry() {
    local attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        log "Attempt $attempt: $@"
        if "$@"; then
            return 0
        fi
        log "Failed, retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
        ((attempt++))
    done
    return 1
}

# Main deployment
log "=========================================="
log "Deployment started"
log "=========================================="

cd "$APP_DIR"

# Stash local changes
log "Stashing local changes..."
git stash --include-untracked 2>/dev/null || true

# Pull latest changes
log "Pulling latest changes..."
retry git pull origin main || retry git pull origin master || {
    log "Pull failed, trying reset..."
    git fetch origin
    git reset --hard origin/main 2>/dev/null || git reset --hard origin/master
}

# Install dependencies
log "Installing dependencies..."
if [ -f "package-lock.json" ]; then
    retry npm ci || retry npm install
else
    retry npm install
fi

# Build
log "Building application..."
npm run build || {
    log "Build failed, checking for errors..."
    exit 1
}

# Restart PM2
log "Restarting application..."
pm2 restart "$APP_NAME" || pm2 start ecosystem.config.cjs

# Verify
sleep 3
if curl -s -o /dev/null -w "%{http_code}" http://localhost:__APP_PORT__ | grep -q "200"; then
    log "Deployment successful - App responding"
else
    log "Warning: App may not be responding correctly"
fi

log "=========================================="
log "Deployment completed"
log "=========================================="
DEPLOY_SCRIPT

    # Replace placeholders
    sed -i "s|__APP_DIR__|$APP_DIR|g" "$APP_DIR/deploy.sh"
    sed -i "s|__APP_NAME__|$APP_NAME|g" "$APP_DIR/deploy.sh"
    sed -i "s|__APP_PORT__|$APP_PORT|g" "$APP_DIR/deploy.sh"
    
    chmod +x "$APP_DIR/deploy.sh"
    
    # Create webhook config directory
    sudo mkdir -p /etc/webhook
    
    # Create hooks.json
    log "INFO" "Creating webhook configuration..."
    sudo tee /etc/webhook/hooks.json > /dev/null << EOF
[
  {
    "id": "${APP_NAME}-deploy",
    "execute-command": "${APP_DIR}/deploy.sh",
    "command-working-directory": "${APP_DIR}",
    "response-message": "Deployment started",
    "trigger-rule": {
      "and": [
        {
          "match": {
            "type": "payload-hmac-sha256",
            "secret": "${WEBHOOK_SECRET}",
            "parameter": {
              "source": "header",
              "name": "X-Hub-Signature-256"
            }
          }
        },
        {
          "match": {
            "type": "value",
            "value": "refs/heads/main",
            "parameter": {
              "source": "payload",
              "name": "ref"
            }
          }
        }
      ]
    }
  }
]
EOF
    
    # Create systemd service
    log "INFO" "Creating webhook service..."
    sudo tee /etc/systemd/system/webhook.service > /dev/null << EOF
[Unit]
Description=Webhook Server for ${APP_NAME}
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=/usr/bin/webhook -hooks /etc/webhook/hooks.json -port ${WEBHOOK_PORT} -verbose
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # Fix webhook path if needed
    local webhook_path=$(which webhook 2>/dev/null || echo "/usr/local/bin/webhook")
    sudo sed -i "s|/usr/bin/webhook|$webhook_path|g" /etc/systemd/system/webhook.service
    
    # Start webhook service
    sudo systemctl daemon-reload
    sudo systemctl enable webhook
    sudo systemctl start webhook
    
    sleep 2
    if sudo systemctl is-active --quiet webhook; then
        log "INFO" "Webhook service running on port $WEBHOOK_PORT"
    else
        log "WARN" "Webhook service may not be running"
        log "INFO" "Check status: sudo systemctl status webhook"
    fi
    
    # Create deploy log
    sudo touch /var/log/${APP_NAME}-deploy.log
    sudo chown $USER:$USER /var/log/${APP_NAME}-deploy.log
}

#===============================================================================
# DISPLAY SUMMARY
#===============================================================================

display_summary() {
    print_section "Setup Complete!"
    
    echo -e "${GREEN}Application Status:${NC}"
    pm2 status
    echo ""
    
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}IMPORTANT INFORMATION - SAVE THIS!${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Application URL (local): ${GREEN}http://localhost:${APP_PORT}${NC}"
    echo -e "Webhook URL:             ${GREEN}http://YOUR_SERVER_IP:${WEBHOOK_PORT}/hooks/${APP_NAME}-deploy${NC}"
    echo ""
    echo -e "${YELLOW}GitHub Webhook Secret:${NC}"
    echo -e "${GREEN}${WEBHOOK_SECRET}${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo "1. Run nginx-ssl-setup.sh to configure Nginx reverse proxy"
    echo "2. Run cloudflare-tunnel-setup.sh on your tunnel VM"
    echo "3. Configure GitHub webhook at: https://github.com/YOUR_USERNAME/YOUR_REPO/settings/hooks"
    echo "   - Payload URL: http://YOUR_SERVER_IP:${WEBHOOK_PORT}/hooks/${APP_NAME}-deploy"
    echo "   - Content type: application/json"
    echo "   - Secret: (the secret shown above)"
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  pm2 status              # Check app status"
    echo "  pm2 logs $APP_NAME      # View logs"
    echo "  pm2 restart $APP_NAME   # Restart app"
    echo "  sudo systemctl status webhook  # Check webhook status"
    echo ""
    
    # Save config for other scripts
    cat > "$APP_DIR/.deploy-config" << EOF
APP_NAME=$APP_NAME
APP_DIR=$APP_DIR
APP_PORT=$APP_PORT
WEBHOOK_PORT=$WEBHOOK_PORT
WEBHOOK_SECRET=$WEBHOOK_SECRET
EOF
    chmod 600 "$APP_DIR/.deploy-config"
    log "INFO" "Config saved to $APP_DIR/.deploy-config"
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

main() {
    print_section "Main Server Setup Script"
    echo "This script will set up:"
    echo "  - Node.js ${NODE_VERSION}.x"
    echo "  - PM2 process manager"
    echo "  - Git credentials"
    echo "  - CI/CD auto-deploy pipeline"
    echo ""
    
    if ! confirm "Continue with setup?"; then
        exit 0
    fi
    
    collect_inputs
    update_system
    install_nodejs
    setup_git_credentials
    setup_pm2
    build_application
    start_pm2
    setup_cicd_webhook
    display_summary
}

main "$@"
