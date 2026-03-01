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
    
    # Project directory
    echo ""
    echo -e "${YELLOW}Project Directory Setup${NC}"
    echo -e "Enter the full path where your project is located or will be cloned."
    echo -e "Examples: /home/user/my-app, /var/www/project, /opt/myproject"
    echo ""
    echo -en "${CYAN}Enter project directory [${PARENT_DIR}]: ${NC}"
    read -r APP_DIR
    APP_DIR=${APP_DIR:-$PARENT_DIR}
    
    # Expand ~ to home directory if used
    APP_DIR="${APP_DIR/#\~/$HOME}"
    
    # Create directory if it doesn't exist
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${YELLOW}Directory does not exist: $APP_DIR${NC}"
        if confirm "Create this directory?"; then
            mkdir -p "$APP_DIR"
            log "INFO" "Created directory: $APP_DIR"
        else
            log "ERROR" "Directory is required. Exiting."
            exit 1
        fi
    fi
    
    log "INFO" "Project directory: $APP_DIR"
    
    # App name (derive from directory name by default)
    local default_app_name
    default_app_name=$(basename "$APP_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    echo -en "${CYAN}Enter application name [${default_app_name}]: ${NC}"
    read -r APP_NAME
    APP_NAME=${APP_NAME:-$default_app_name}
    
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
# MULTI-BACKEND DEPLOYMENT SYSTEM
#===============================================================================

# Supported backend types
declare -A BACKEND_TYPES=(
    [1]="nodejs"
    [2]="python-docker"
    [3]="python-systemd"
    [4]="java"
    [5]="rust"
    [6]="go"
    [7]="php"
    [8]="ruby"
    [9]="dotnet"
)

# Default versions
PYTHON_VERSION="3.11"
JAVA_VERSION="17"
DOTNET_VERSION="8.0"
GO_VERSION="1.22.0"
RUST_VERSION="stable"
RUBY_VERSION="3.2"
PHP_VERSION="8.3"

#===============================================================================
# BACKEND TYPE SELECTION
#===============================================================================

select_backend_type() {
    print_section "Select Backend Type"
    
    echo -e "${CYAN}Available backend types:${NC}"
    echo ""
    echo "  1) Node.js with PM2"
    echo "  2) Python with Docker (Flask/Django/FastAPI)"
    echo "  3) Python with systemd (uvicorn/gunicorn)"
    echo "  4) Java (Spring Boot with JAR)"
    echo "  5) Rust (compiled binary)"
    echo "  6) Go (compiled binary)"
    echo "  7) PHP (PHP-FPM)"
    echo "  8) Ruby on Rails (Puma)"
    echo "  9) .NET Core (ASP.NET Core)"
    echo ""
    
    local selection
    while true; do
        echo -en "${CYAN}Enter selection [1-9]: ${NC}"
        read -r selection
        
        if [[ "$selection" =~ ^[1-9]$ ]]; then
            BACKEND_TYPE="${BACKEND_TYPES[$selection]}"
            log "INFO" "Selected backend type: $BACKEND_TYPE"
            break
        else
            echo -e "${RED}Invalid selection. Please enter a number between 1 and 9.${NC}"
        fi
    done
    
    # Backend-specific configuration
    case "$BACKEND_TYPE" in
        "python-docker"|"python-systemd")
            echo -en "${CYAN}Enter Python framework (flask/django/fastapi) [fastapi]: ${NC}"
            read -r PYTHON_FRAMEWORK
            PYTHON_FRAMEWORK=${PYTHON_FRAMEWORK:-fastapi}
            ;;
        "java")
            echo -en "${CYAN}Enter JAR file name [app.jar]: ${NC}"
            read -r JAR_FILE
            JAR_FILE=${JAR_FILE:-app.jar}
            ;;
    esac
}

#===============================================================================
# RUNTIME INSTALLATION WITH FALLBACKS
#===============================================================================

install_runtime() {
    local runtime_type="${1:-$BACKEND_TYPE}"
    
    case "$runtime_type" in
        "nodejs")
            install_nodejs_runtime
            ;;
        "python-docker"|"python-systemd")
            install_python_runtime
            ;;
        "java")
            install_java_runtime
            ;;
        "rust")
            install_rust_runtime
            ;;
        "go")
            install_go_runtime
            ;;
        "php")
            install_php_runtime
            ;;
        "ruby")
            install_ruby_runtime
            ;;
        "dotnet")
            install_dotnet_runtime
            ;;
        *)
            log "ERROR" "Unknown backend type: $runtime_type"
            return 1
            ;;
    esac
}

#-------------------------------------------------------------------------------
# Node.js Runtime (Enhanced)
#-------------------------------------------------------------------------------

install_nodejs_runtime() {
    print_section "Installing Node.js ${NODE_VERSION}.x"
    
    if command_exists node; then
        local current_version=$(node -v 2>/dev/null | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$current_version" -ge "$NODE_VERSION" ]; then
            log "INFO" "Node.js v$(node -v) already installed"
            install_nodejs_tools
            return 0
        fi
        log "INFO" "Upgrading Node.js from v$current_version to v$NODE_VERSION"
    fi
    
    local install_success=false
    
    # Method 1: NodeSource repository
    log "INFO" "Method 1: Installing via NodeSource repository..."
    if curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x -o /tmp/nodesource_setup.sh 2>/dev/null; then
        if sudo -E bash /tmp/nodesource_setup.sh 2>/dev/null; then
            if sudo apt-get install -y nodejs 2>/dev/null; then
                log "INFO" "Node.js installed via NodeSource"
                install_success=true
            fi
        fi
    fi
    
    # Method 2: NVM (Node Version Manager)
    if [ "$install_success" = false ]; then
        log "WARN" "NodeSource failed, trying NVM..."
        
        export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
        
        if [ ! -s "$NVM_DIR/nvm.sh" ]; then
            log "INFO" "Installing NVM..."
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash 2>/dev/null || \
            wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash 2>/dev/null
        fi
        
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        
        if command_exists nvm; then
            if nvm install $NODE_VERSION && nvm use $NODE_VERSION && nvm alias default $NODE_VERSION; then
                # Create system-wide symlinks
                local node_bin="$NVM_DIR/versions/node/$(nvm current)/bin"
                sudo ln -sf "$node_bin/node" /usr/local/bin/node 2>/dev/null || true
                sudo ln -sf "$node_bin/npm" /usr/local/bin/npm 2>/dev/null || true
                sudo ln -sf "$node_bin/npx" /usr/local/bin/npx 2>/dev/null || true
                log "INFO" "Node.js installed via NVM"
                install_success=true
            fi
        fi
    fi
    
    # Method 3: Snap package
    if [ "$install_success" = false ]; then
        log "WARN" "NVM failed, trying Snap..."
        if command_exists snap || sudo apt-get install -y snapd 2>/dev/null; then
            if sudo snap install node --classic --channel=${NODE_VERSION} 2>/dev/null; then
                log "INFO" "Node.js installed via Snap"
                install_success=true
            fi
        fi
    fi
    
    # Method 4: Build from source
    if [ "$install_success" = false ]; then
        log "WARN" "Snap failed, building from source..."
        local node_url="https://nodejs.org/dist/v${NODE_VERSION}.0.0/node-v${NODE_VERSION}.0.0.tar.gz"
        
        sudo apt-get install -y build-essential python3 g++ make 2>/dev/null
        
        cd /tmp
        if curl -fsSL "$node_url" -o node.tar.gz 2>/dev/null || wget -q "$node_url" -O node.tar.gz 2>/dev/null; then
            tar -xzf node.tar.gz
            cd node-v${NODE_VERSION}.0.0
            ./configure && make -j$(nproc) && sudo make install
            log "INFO" "Node.js built from source"
            install_success=true
        fi
        cd - > /dev/null
    fi
    
    if [ "$install_success" = false ]; then
        log "ERROR" "All Node.js installation methods failed"
        return 1
    fi
    
    install_nodejs_tools
    verify_runtime "node" "node --version"
}

install_nodejs_tools() {
    log "INFO" "Installing Node.js tools..."
    
    # PM2
    if ! command_exists pm2; then
        sudo npm install -g pm2 --unsafe-perm 2>/dev/null || \
        npm install -g pm2 2>/dev/null || \
        npx pm2 --version > /dev/null 2>&1
    fi
    
    # Yarn (optional)
    if ! command_exists yarn; then
        sudo npm install -g yarn 2>/dev/null || true
    fi
}

#-------------------------------------------------------------------------------
# Python Runtime
#-------------------------------------------------------------------------------

install_python_runtime() {
    print_section "Installing Python ${PYTHON_VERSION}"
    
    if command_exists python${PYTHON_VERSION}; then
        log "INFO" "Python ${PYTHON_VERSION} already installed"
        install_python_tools
        return 0
    fi
    
    local install_success=false
    
    # Method 1: Deadsnakes PPA (Ubuntu)
    log "INFO" "Method 1: Installing via Deadsnakes PPA..."
    if sudo add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null; then
        sudo apt-get update -y
        if sudo apt-get install -y python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev 2>/dev/null; then
            log "INFO" "Python installed via Deadsnakes PPA"
            install_success=true
        fi
    fi
    
    # Method 2: System package manager
    if [ "$install_success" = false ]; then
        log "WARN" "Deadsnakes failed, trying system package manager..."
        if sudo apt-get install -y python3 python3-venv python3-dev python3-pip 2>/dev/null; then
            log "INFO" "Python installed via apt"
            install_success=true
            PYTHON_VERSION=$(python3 --version | cut -d' ' -f2 | cut -d'.' -f1-2)
        fi
    fi
    
    # Method 3: pyenv
    if [ "$install_success" = false ]; then
        log "WARN" "System packages failed, trying pyenv..."
        
        # Install pyenv dependencies
        sudo apt-get install -y make build-essential libssl-dev zlib1g-dev \
            libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
            libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
            libffi-dev liblzma-dev 2>/dev/null || true
        
        export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
        
        if [ ! -d "$PYENV_ROOT" ]; then
            curl https://pyenv.run | bash 2>/dev/null || \
            git clone https://github.com/pyenv/pyenv.git "$PYENV_ROOT" 2>/dev/null
        fi
        
        export PATH="$PYENV_ROOT/bin:$PATH"
        eval "$(pyenv init -)" 2>/dev/null || true
        
        if pyenv install $PYTHON_VERSION 2>/dev/null && pyenv global $PYTHON_VERSION; then
            log "INFO" "Python installed via pyenv"
            install_success=true
        fi
    fi
    
    # Method 4: Build from source
    if [ "$install_success" = false ]; then
        log "WARN" "pyenv failed, building from source..."
        
        local python_url="https://www.python.org/ftp/python/${PYTHON_VERSION}.0/Python-${PYTHON_VERSION}.0.tgz"
        
        cd /tmp
        if curl -fsSL "$python_url" -o python.tgz 2>/dev/null || wget -q "$python_url" -O python.tgz 2>/dev/null; then
            tar -xzf python.tgz
            cd Python-${PYTHON_VERSION}.0
            ./configure --enable-optimizations --prefix=/usr/local
            make -j$(nproc)
            sudo make altinstall
            log "INFO" "Python built from source"
            install_success=true
        fi
        cd - > /dev/null
    fi
    
    if [ "$install_success" = false ]; then
        log "ERROR" "All Python installation methods failed"
        return 1
    fi
    
    install_python_tools
    verify_runtime "python" "python${PYTHON_VERSION} --version || python3 --version"
}

install_python_tools() {
    log "INFO" "Installing Python tools..."
    
    # Ensure pip
    python${PYTHON_VERSION} -m ensurepip --upgrade 2>/dev/null || \
    python3 -m ensurepip --upgrade 2>/dev/null || \
    sudo apt-get install -y python3-pip 2>/dev/null || true
    
    # pipx for isolated tool installations
    python3 -m pip install --user pipx 2>/dev/null || true
    python3 -m pipx ensurepath 2>/dev/null || true
    
    # Poetry (optional)
    curl -sSL https://install.python-poetry.org | python3 - 2>/dev/null || true
    
    # Install uvicorn/gunicorn
    pip3 install --user uvicorn gunicorn 2>/dev/null || \
    python3 -m pip install uvicorn gunicorn 2>/dev/null || true
    
    # Docker for python-docker backend
    if [ "$BACKEND_TYPE" = "python-docker" ]; then
        install_docker
    fi
}

install_docker() {
    if command_exists docker; then
        log "INFO" "Docker already installed"
        return 0
    fi
    
    log "INFO" "Installing Docker..."
    
    # Method 1: Official Docker script
    if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
        if sudo sh /tmp/get-docker.sh 2>/dev/null; then
            sudo usermod -aG docker $USER
            log "INFO" "Docker installed via official script"
            return 0
        fi
    fi
    
    # Method 2: apt repository
    log "WARN" "Official script failed, trying apt repository..."
    sudo apt-get install -y ca-certificates curl gnupg lsb-release 2>/dev/null
    
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    sudo apt-get update -y
    if sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null; then
        sudo usermod -aG docker $USER
        log "INFO" "Docker installed via apt repository"
        return 0
    fi
    
    # Method 3: Snap
    log "WARN" "apt repository failed, trying Snap..."
    if sudo snap install docker 2>/dev/null; then
        log "INFO" "Docker installed via Snap"
        return 0
    fi
    
    log "ERROR" "Docker installation failed"
    return 1
}

#-------------------------------------------------------------------------------
# Java Runtime (Spring Boot)
#-------------------------------------------------------------------------------

install_java_runtime() {
    print_section "Installing Java ${JAVA_VERSION} (OpenJDK)"
    
    if command_exists java; then
        local current_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)
        if [ "$current_version" -ge "$JAVA_VERSION" ]; then
            log "INFO" "Java $current_version already installed"
            install_java_tools
            return 0
        fi
    fi
    
    local install_success=false
    
    # Method 1: apt-get OpenJDK
    log "INFO" "Method 1: Installing via apt-get..."
    if sudo apt-get install -y openjdk-${JAVA_VERSION}-jdk openjdk-${JAVA_VERSION}-jre 2>/dev/null; then
        log "INFO" "Java installed via apt"
        install_success=true
    fi
    
    # Method 2: Adoptium/Eclipse Temurin
    if [ "$install_success" = false ]; then
        log "WARN" "apt failed, trying Adoptium..."
        
        sudo apt-get install -y wget apt-transport-https 2>/dev/null
        
        wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | \
            sudo gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg 2>/dev/null
        
        echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] \
            https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | \
            sudo tee /etc/apt/sources.list.d/adoptium.list > /dev/null
        
        sudo apt-get update -y
        if sudo apt-get install -y temurin-${JAVA_VERSION}-jdk 2>/dev/null; then
            log "INFO" "Java installed via Adoptium"
            install_success=true
        fi
    fi
    
    # Method 3: SDKMAN
    if [ "$install_success" = false ]; then
        log "WARN" "Adoptium failed, trying SDKMAN..."
        
        if [ ! -d "$HOME/.sdkman" ]; then
            curl -s "https://get.sdkman.io" | bash 2>/dev/null
        fi
        
        source "$HOME/.sdkman/bin/sdkman-init.sh" 2>/dev/null || true
        
        if command_exists sdk; then
            if sdk install java ${JAVA_VERSION}-open 2>/dev/null; then
                log "INFO" "Java installed via SDKMAN"
                install_success=true
            fi
        fi
    fi
    
    # Method 4: Manual tarball
    if [ "$install_success" = false ]; then
        log "WARN" "SDKMAN failed, downloading tarball..."
        
        local jdk_url="https://download.java.net/java/GA/jdk${JAVA_VERSION}/latest/GPL/openjdk-${JAVA_VERSION}_linux-x64_bin.tar.gz"
        
        cd /tmp
        if curl -fsSL "$jdk_url" -o openjdk.tar.gz 2>/dev/null || wget -q "$jdk_url" -O openjdk.tar.gz 2>/dev/null; then
            sudo mkdir -p /usr/lib/jvm
            sudo tar -xzf openjdk.tar.gz -C /usr/lib/jvm
            
            local jdk_dir=$(tar -tzf openjdk.tar.gz | head -1 | cut -d'/' -f1)
            sudo update-alternatives --install /usr/bin/java java /usr/lib/jvm/${jdk_dir}/bin/java 1
            sudo update-alternatives --install /usr/bin/javac javac /usr/lib/jvm/${jdk_dir}/bin/javac 1
            
            log "INFO" "Java installed from tarball"
            install_success=true
        fi
        cd - > /dev/null
    fi
    
    if [ "$install_success" = false ]; then
        log "ERROR" "All Java installation methods failed"
        return 1
    fi
    
    # Set JAVA_HOME
    export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
    echo "export JAVA_HOME=$JAVA_HOME" >> ~/.bashrc
    
    install_java_tools
    verify_runtime "java" "java -version"
}

install_java_tools() {
    log "INFO" "Installing Java build tools..."
    
    # Maven
    if ! command_exists mvn; then
        sudo apt-get install -y maven 2>/dev/null || {
            log "INFO" "Installing Maven manually..."
            local mvn_version="3.9.6"
            cd /tmp
            wget -q "https://dlcdn.apache.org/maven/maven-3/${mvn_version}/binaries/apache-maven-${mvn_version}-bin.tar.gz" -O maven.tar.gz 2>/dev/null
            sudo tar -xzf maven.tar.gz -C /opt
            sudo ln -sf /opt/apache-maven-${mvn_version}/bin/mvn /usr/local/bin/mvn
            cd - > /dev/null
        }
    fi
    
    # Gradle (optional)
    if ! command_exists gradle; then
        sudo apt-get install -y gradle 2>/dev/null || true
    fi
}

#-------------------------------------------------------------------------------
# Rust Runtime
#-------------------------------------------------------------------------------

install_rust_runtime() {
    print_section "Installing Rust (${RUST_VERSION})"
    
    if command_exists rustc && command_exists cargo; then
        log "INFO" "Rust $(rustc --version | cut -d' ' -f2) already installed"
        return 0
    fi
    
    local install_success=false
    
    # Method 1: rustup (official)
    log "INFO" "Method 1: Installing via rustup..."
    if curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${RUST_VERSION} 2>/dev/null; then
        source "$HOME/.cargo/env"
        log "INFO" "Rust installed via rustup"
        install_success=true
    fi
    
    # Method 2: System package manager
    if [ "$install_success" = false ]; then
        log "WARN" "rustup failed, trying apt..."
        if sudo apt-get install -y rustc cargo 2>/dev/null; then
            log "INFO" "Rust installed via apt"
            install_success=true
        fi
    fi
    
    # Method 3: Snap
    if [ "$install_success" = false ]; then
        log "WARN" "apt failed, trying Snap..."
        if sudo snap install rustup --classic 2>/dev/null; then
            rustup default stable
            log "INFO" "Rust installed via Snap"
            install_success=true
        fi
    fi
    
    if [ "$install_success" = false ]; then
        log "ERROR" "All Rust installation methods failed"
        return 1
    fi
    
    # Ensure cargo is in PATH
    [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
    
    verify_runtime "rust" "rustc --version && cargo --version"
}

#-------------------------------------------------------------------------------
# Go Runtime
#-------------------------------------------------------------------------------

install_go_runtime() {
    print_section "Installing Go ${GO_VERSION}"
    
    if command_exists go; then
        local current_version=$(go version | cut -d' ' -f3 | sed 's/go//')
        log "INFO" "Go ${current_version} already installed"
        return 0
    fi
    
    local install_success=false
    
    # Method 1: Official tarball
    log "INFO" "Method 1: Installing from official tarball..."
    local go_url="https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    
    cd /tmp
    if curl -fsSL "$go_url" -o go.tar.gz 2>/dev/null || wget -q "$go_url" -O go.tar.gz 2>/dev/null; then
        sudo rm -rf /usr/local/go
        sudo tar -C /usr/local -xzf go.tar.gz
        
        export PATH=$PATH:/usr/local/go/bin
        export GOPATH=$HOME/go
        export PATH=$PATH:$GOPATH/bin
        
        # Persist PATH
        cat >> ~/.bashrc << 'EOF'
export PATH=$PATH:/usr/local/go/bin
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin
EOF
        
        log "INFO" "Go installed from official tarball"
        install_success=true
    fi
    cd - > /dev/null
    
    # Method 2: apt
    if [ "$install_success" = false ]; then
        log "WARN" "Official tarball failed, trying apt..."
        if sudo apt-get install -y golang-go 2>/dev/null; then
            log "INFO" "Go installed via apt"
            install_success=true
        fi
    fi
    
    # Method 3: Snap
    if [ "$install_success" = false ]; then
        log "WARN" "apt failed, trying Snap..."
        if sudo snap install go --classic 2>/dev/null; then
            log "INFO" "Go installed via Snap"
            install_success=true
        fi
    fi
    
    if [ "$install_success" = false ]; then
        log "ERROR" "All Go installation methods failed"
        return 1
    fi
    
    verify_runtime "go" "go version"
}

#-------------------------------------------------------------------------------
# PHP Runtime (PHP-FPM)
#-------------------------------------------------------------------------------

install_php_runtime() {
    print_section "Installing PHP ${PHP_VERSION} with PHP-FPM"
    
    if command_exists php; then
        local current_version=$(php -v | head -1 | cut -d' ' -f2 | cut -d'.' -f1-2)
        log "INFO" "PHP ${current_version} already installed"
        install_php_tools
        return 0
    fi
    
    local install_success=false
    
    # Method 1: Ondrej PPA (recommended for Ubuntu)
    log "INFO" "Method 1: Installing via Ondrej PPA..."
    if sudo add-apt-repository -y ppa:ondrej/php 2>/dev/null; then
        sudo apt-get update -y
        if sudo apt-get install -y php${PHP_VERSION} php${PHP_VERSION}-fpm php${PHP_VERSION}-cli \
            php${PHP_VERSION}-common php${PHP_VERSION}-mysql php${PHP_VERSION}-pgsql \
            php${PHP_VERSION}-redis php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml \
            php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-gd \
            php${PHP_VERSION}-intl php${PHP_VERSION}-bcmath 2>/dev/null; then
            log "INFO" "PHP installed via Ondrej PPA"
            install_success=true
        fi
    fi
    
    # Method 2: System packages
    if [ "$install_success" = false ]; then
        log "WARN" "Ondrej PPA failed, trying system packages..."
        if sudo apt-get install -y php php-fpm php-cli php-common php-mysql \
            php-mbstring php-xml php-curl php-zip php-gd 2>/dev/null; then
            log "INFO" "PHP installed via apt"
            install_success=true
            PHP_VERSION=$(php -v | head -1 | cut -d' ' -f2 | cut -d'.' -f1-2)
        fi
    fi
    
    # Method 3: Build from source
    if [ "$install_success" = false ]; then
        log "WARN" "System packages failed, building from source..."
        
        sudo apt-get install -y build-essential autoconf bison re2c libxml2-dev \
            libsqlite3-dev libssl-dev libcurl4-openssl-dev libpng-dev \
            libonig-dev libzip-dev 2>/dev/null
        
        local php_url="https://www.php.net/distributions/php-${PHP_VERSION}.0.tar.gz"
        
        cd /tmp
        if curl -fsSL "$php_url" -o php.tar.gz 2>/dev/null || wget -q "$php_url" -O php.tar.gz 2>/dev/null; then
            tar -xzf php.tar.gz
            cd php-${PHP_VERSION}.0
            ./configure --prefix=/usr/local/php --enable-fpm --with-fpm-user=www-data \
                --with-fpm-group=www-data --enable-mbstring --with-curl --with-openssl \
                --with-zlib --enable-zip --with-mysqli --with-pdo-mysql
            make -j$(nproc)
            sudo make install
            log "INFO" "PHP built from source"
            install_success=true
        fi
        cd - > /dev/null
    fi
    
    if [ "$install_success" = false ]; then
        log "ERROR" "All PHP installation methods failed"
        return 1
    fi
    
    install_php_tools
    verify_runtime "php" "php -v"
}

install_php_tools() {
    log "INFO" "Installing PHP tools..."
    
    # Composer
    if ! command_exists composer; then
        log "INFO" "Installing Composer..."
        cd /tmp
        curl -sS https://getcomposer.org/installer -o composer-setup.php 2>/dev/null || \
        wget -q https://getcomposer.org/installer -O composer-setup.php 2>/dev/null
        
        if [ -f composer-setup.php ]; then
            php composer-setup.php --install-dir=/tmp --filename=composer
            sudo mv /tmp/composer /usr/local/bin/composer
            sudo chmod +x /usr/local/bin/composer
        fi
        cd - > /dev/null
    fi
    
    # Enable and start PHP-FPM
    local php_fpm_service="php${PHP_VERSION}-fpm"
    sudo systemctl enable ${php_fpm_service} 2>/dev/null || true
    sudo systemctl start ${php_fpm_service} 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# Ruby Runtime (Ruby on Rails with Puma)
#-------------------------------------------------------------------------------

install_ruby_runtime() {
    print_section "Installing Ruby ${RUBY_VERSION}"
    
    if command_exists ruby; then
        local current_version=$(ruby -v | cut -d' ' -f2 | cut -d'p' -f1)
        log "INFO" "Ruby ${current_version} already installed"
        install_ruby_tools
        return 0
    fi
    
    local install_success=false
    
    # Install dependencies
    sudo apt-get install -y autoconf bison build-essential libssl-dev libyaml-dev \
        libreadline-dev zlib1g-dev libncurses5-dev libffi-dev libgdbm-dev \
        libgdbm6 libdb-dev 2>/dev/null || true
    
    # Method 1: rbenv
    log "INFO" "Method 1: Installing via rbenv..."
    
    export RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
    
    if [ ! -d "$RBENV_ROOT" ]; then
        git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT" 2>/dev/null
        git clone https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build" 2>/dev/null
    fi
    
    export PATH="$RBENV_ROOT/bin:$PATH"
    eval "$(rbenv init -)" 2>/dev/null || true
    
    if command_exists rbenv; then
        if rbenv install $RUBY_VERSION 2>/dev/null && rbenv global $RUBY_VERSION; then
            log "INFO" "Ruby installed via rbenv"
            install_success=true
            
            # Persist PATH
            cat >> ~/.bashrc << 'EOF'
export RBENV_ROOT="$HOME/.rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"
EOF
        fi
    fi
    
    # Method 2: RVM
    if [ "$install_success" = false ]; then
        log "WARN" "rbenv failed, trying RVM..."
        
        gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys \
            409B6B1796C275462A1703113804BB82D39DC0E3 \
            7D2BAF1CF37B13E2069D6956105BD0E739499BDB 2>/dev/null || true
        
        curl -sSL https://get.rvm.io | bash -s stable --ruby=${RUBY_VERSION} 2>/dev/null
        
        source "$HOME/.rvm/scripts/rvm" 2>/dev/null || true
        
        if command_exists rvm; then
            log "INFO" "Ruby installed via RVM"
            install_success=true
        fi
    fi
    
    # Method 3: System packages
    if [ "$install_success" = false ]; then
        log "WARN" "RVM failed, trying apt..."
        if sudo apt-get install -y ruby-full 2>/dev/null; then
            log "INFO" "Ruby installed via apt"
            install_success=true
        fi
    fi
    
    if [ "$install_success" = false ]; then
        log "ERROR" "All Ruby installation methods failed"
        return 1
    fi
    
    install_ruby_tools
    verify_runtime "ruby" "ruby -v"
}

install_ruby_tools() {
    log "INFO" "Installing Ruby tools..."
    
    # Bundler
    gem install bundler 2>/dev/null || sudo gem install bundler 2>/dev/null || true
    
    # Rails (if using Rails)
    gem install rails 2>/dev/null || sudo gem install rails 2>/dev/null || true
    
    # Puma
    gem install puma 2>/dev/null || sudo gem install puma 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# .NET Core Runtime
#-------------------------------------------------------------------------------

install_dotnet_runtime() {
    print_section "Installing .NET ${DOTNET_VERSION}"
    
    if command_exists dotnet; then
        local current_version=$(dotnet --version | cut -d'.' -f1-2)
        log "INFO" ".NET ${current_version} already installed"
        return 0
    fi
    
    local install_success=false
    
    # Method 1: Microsoft packages
    log "INFO" "Method 1: Installing via Microsoft packages..."
    
    local ubuntu_version=$(lsb_release -rs 2>/dev/null || echo "22.04")
    local packages_url="https://packages.microsoft.com/config/ubuntu/${ubuntu_version}/packages-microsoft-prod.deb"
    
    cd /tmp
    if curl -fsSL "$packages_url" -o packages-microsoft-prod.deb 2>/dev/null || \
       wget -q "$packages_url" -O packages-microsoft-prod.deb 2>/dev/null; then
        sudo dpkg -i packages-microsoft-prod.deb 2>/dev/null
        sudo apt-get update -y
        if sudo apt-get install -y dotnet-sdk-${DOTNET_VERSION} 2>/dev/null; then
            log "INFO" ".NET installed via Microsoft packages"
            install_success=true
        fi
    fi
    cd - > /dev/null
    
    # Method 2: Install script
    if [ "$install_success" = false ]; then
        log "WARN" "Microsoft packages failed, trying install script..."
        
        cd /tmp
        if curl -fsSL https://dot.net/v1/dotnet-install.sh -o dotnet-install.sh 2>/dev/null || \
           wget -q https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh 2>/dev/null; then
            chmod +x dotnet-install.sh
            ./dotnet-install.sh --channel ${DOTNET_VERSION} --install-dir /usr/local/dotnet
            
            export DOTNET_ROOT=/usr/local/dotnet
            export PATH=$PATH:$DOTNET_ROOT
            
            # Persist PATH
            cat >> ~/.bashrc << 'EOF'
export DOTNET_ROOT=/usr/local/dotnet
export PATH=$PATH:$DOTNET_ROOT
EOF
            
            sudo ln -sf /usr/local/dotnet/dotnet /usr/local/bin/dotnet 2>/dev/null || true
            log "INFO" ".NET installed via install script"
            install_success=true
        fi
        cd - > /dev/null
    fi
    
    # Method 3: Snap
    if [ "$install_success" = false ]; then
        log "WARN" "Install script failed, trying Snap..."
        if sudo snap install dotnet-sdk --classic --channel=${DOTNET_VERSION}/stable 2>/dev/null; then
            log "INFO" ".NET installed via Snap"
            install_success=true
        fi
    fi
    
    if [ "$install_success" = false ]; then
        log "ERROR" "All .NET installation methods failed"
        return 1
    fi
    
    verify_runtime "dotnet" "dotnet --version"
}

#===============================================================================
# RUNTIME VERIFICATION
#===============================================================================

verify_runtime() {
    local runtime_name="$1"
    local verify_cmd="$2"
    
    log "INFO" "Verifying ${runtime_name} installation..."
    
    if eval "$verify_cmd" &>/dev/null; then
        log "INFO" "${runtime_name} verified successfully"
        return 0
    else
        log "ERROR" "${runtime_name} verification failed"
        return 1
    fi
}

#===============================================================================
# BACKEND SERVICE SETUP
#===============================================================================

setup_backend_service() {
    print_section "Setting Up Backend Service"
    
    case "$BACKEND_TYPE" in
        "nodejs")
            setup_nodejs_service
            ;;
        "python-docker")
            setup_python_docker_service
            ;;
        "python-systemd")
            setup_python_systemd_service
            ;;
        "java")
            setup_java_service
            ;;
        "rust")
            setup_rust_service
            ;;
        "go")
            setup_go_service
            ;;
        "php")
            setup_php_service
            ;;
        "ruby")
            setup_ruby_service
            ;;
        "dotnet")
            setup_dotnet_service
            ;;
        *)
            log "ERROR" "Unknown backend type: $BACKEND_TYPE"
            return 1
            ;;
    esac
}

#-------------------------------------------------------------------------------
# Node.js Service (PM2)
#-------------------------------------------------------------------------------

setup_nodejs_service() {
    log "INFO" "Setting up Node.js service with PM2..."
    
    cd "$APP_DIR"
    
    # Install dependencies
    log "INFO" "Installing dependencies..."
    if [ -f "package-lock.json" ]; then
        npm ci || npm install
    elif [ -f "yarn.lock" ]; then
        yarn install --frozen-lockfile || yarn install
    else
        npm install
    fi
    
    # Build
    if grep -q '"build"' package.json 2>/dev/null; then
        log "INFO" "Building application..."
        npm run build || {
            log "ERROR" "Build failed"
            return 1
        }
    fi
    
    # Detect app entry point
    local entry_point
    if [ -f "dist/index.js" ]; then
        entry_point="dist/index.js"
    elif [ -f "build/index.js" ]; then
        entry_point="build/index.js"
    elif [ -f "dist/main.js" ]; then
        entry_point="dist/main.js"
    elif [ -f "server.js" ]; then
        entry_point="server.js"
    elif [ -f "app.js" ]; then
        entry_point="app.js"
    elif [ -f "index.js" ]; then
        entry_point="index.js"
    else
        # Check for static site (serve dist)
        if [ -d "dist" ] && [ -f "dist/index.html" ]; then
            entry_point="serve"
        else
            log "ERROR" "Could not detect entry point"
            return 1
        fi
    fi
    
    # Create PM2 ecosystem config
    log "INFO" "Creating PM2 ecosystem config..."
    
    if [ "$entry_point" = "serve" ]; then
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
    else
        cat > "$APP_DIR/ecosystem.config.cjs" << EOF
module.exports = {
  apps: [{
    name: '${APP_NAME}',
    script: '${entry_point}',
    cwd: '${APP_DIR}',
    instances: 'max',
    exec_mode: 'cluster',
    autorestart: true,
    watch: false,
    max_memory_restart: '1G',
    env: {
      NODE_ENV: 'production',
      PORT: ${APP_PORT}
    },
    error_file: '/var/log/${APP_NAME}-error.log',
    out_file: '/var/log/${APP_NAME}-out.log',
    log_file: '/var/log/${APP_NAME}-combined.log',
    time: true,
    merge_logs: true
  }]
};
EOF
    fi
    
    # Create log files
    sudo touch /var/log/${APP_NAME}-{error,out,combined}.log
    sudo chown $USER:$USER /var/log/${APP_NAME}-*.log
    
    # Start with PM2
    pm2 delete "$APP_NAME" 2>/dev/null || true
    pm2 start ecosystem.config.cjs
    pm2 save
    
    # Setup PM2 startup
    pm2 startup systemd -u $USER --hp $HOME 2>/dev/null || \
    sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u $USER --hp $HOME 2>/dev/null || true
    pm2 save
    
    # Health check
    perform_health_check
}

#-------------------------------------------------------------------------------
# Python Docker Service
#-------------------------------------------------------------------------------

setup_python_docker_service() {
    log "INFO" "Setting up Python Docker service..."
    
    cd "$APP_DIR"
    
    # Create Dockerfile if not exists
    if [ ! -f "Dockerfile" ]; then
        log "INFO" "Creating Dockerfile..."
        create_python_dockerfile
    fi
    
    # Create docker-compose.yml if not exists
    if [ ! -f "docker-compose.yml" ] && [ ! -f "docker-compose.yaml" ]; then
        log "INFO" "Creating docker-compose.yml..."
        create_docker_compose
    fi
    
    # Build and start containers
    log "INFO" "Building Docker image..."
    docker compose build || docker-compose build || {
        log "ERROR" "Docker build failed"
        return 1
    }
    
    log "INFO" "Starting Docker containers..."
    docker compose up -d || docker-compose up -d || {
        log "ERROR" "Docker compose up failed"
        return 1
    }
    
    # Create systemd service for docker-compose
    create_docker_systemd_service
    
    # Health check
    perform_health_check
}

create_python_dockerfile() {
    local wsgi_server
    local wsgi_command
    
    case "$PYTHON_FRAMEWORK" in
        "flask")
            wsgi_server="gunicorn"
            wsgi_command="gunicorn --bind 0.0.0.0:\${PORT:-${APP_PORT}} --workers 4 app:app"
            ;;
        "django")
            wsgi_server="gunicorn"
            wsgi_command="gunicorn --bind 0.0.0.0:\${PORT:-${APP_PORT}} --workers 4 config.wsgi:application"
            ;;
        "fastapi"|*)
            wsgi_server="uvicorn"
            wsgi_command="uvicorn main:app --host 0.0.0.0 --port \${PORT:-${APP_PORT}} --workers 4"
            ;;
    esac
    
    cat > "$APP_DIR/Dockerfile" << EOF
FROM python:${PYTHON_VERSION}-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \\
    gcc \\
    libpq-dev \\
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
RUN pip install --no-cache-dir ${wsgi_server}

# Copy application
COPY . .

# Create non-root user
RUN useradd --create-home --shell /bin/bash appuser
RUN chown -R appuser:appuser /app
USER appuser

# Environment
ENV PORT=${APP_PORT}
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

EXPOSE ${APP_PORT}

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \\
    CMD curl -f http://localhost:${APP_PORT}/health || exit 1

CMD ["/bin/sh", "-c", "${wsgi_command}"]
EOF
}

create_docker_compose() {
    cat > "$APP_DIR/docker-compose.yml" << EOF
version: '3.8'

services:
  ${APP_NAME}:
    build: .
    container_name: ${APP_NAME}
    restart: unless-stopped
    ports:
      - "${APP_PORT}:${APP_PORT}"
    environment:
      - PORT=${APP_PORT}
      - NODE_ENV=production
    volumes:
      - ./logs:/app/logs
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${APP_PORT}/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  default:
    name: ${APP_NAME}-network
EOF
}

create_docker_systemd_service() {
    log "INFO" "Creating Docker systemd service..."
    
    sudo tee /etc/systemd/system/${APP_NAME}-docker.service > /dev/null << EOF
[Unit]
Description=${APP_NAME} Docker Service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose restart
TimeoutStartSec=0
User=$USER
Group=docker

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable ${APP_NAME}-docker
}

#-------------------------------------------------------------------------------
# Python systemd Service (uvicorn/gunicorn)
#-------------------------------------------------------------------------------

setup_python_systemd_service() {
    log "INFO" "Setting up Python systemd service..."
    
    cd "$APP_DIR"
    
    # Create virtual environment
    log "INFO" "Creating virtual environment..."
    python${PYTHON_VERSION} -m venv venv 2>/dev/null || python3 -m venv venv
    
    # Activate and install dependencies
    source venv/bin/activate
    
    pip install --upgrade pip
    
    if [ -f "requirements.txt" ]; then
        pip install -r requirements.txt
    elif [ -f "pyproject.toml" ]; then
        pip install .
    fi
    
    # Install WSGI server
    case "$PYTHON_FRAMEWORK" in
        "flask"|"django")
            pip install gunicorn
            ;;
        "fastapi"|*)
            pip install uvicorn[standard]
            ;;
    esac
    
    deactivate
    
    # Create systemd service
    create_python_systemd_unit
    
    # Start service
    sudo systemctl daemon-reload
    sudo systemctl enable ${APP_NAME}
    sudo systemctl start ${APP_NAME}
    
    # Health check
    perform_health_check
}

create_python_systemd_unit() {
    local exec_start
    
    case "$PYTHON_FRAMEWORK" in
        "flask")
            exec_start="${APP_DIR}/venv/bin/gunicorn --bind 0.0.0.0:${APP_PORT} --workers 4 --threads 2 app:app"
            ;;
        "django")
            exec_start="${APP_DIR}/venv/bin/gunicorn --bind 0.0.0.0:${APP_PORT} --workers 4 --threads 2 config.wsgi:application"
            ;;
        "fastapi"|*)
            exec_start="${APP_DIR}/venv/bin/uvicorn main:app --host 0.0.0.0 --port ${APP_PORT} --workers 4"
            ;;
    esac
    
    sudo tee /etc/systemd/system/${APP_NAME}.service > /dev/null << EOF
[Unit]
Description=${APP_NAME} Python Service
After=network.target

[Service]
Type=notify
User=$USER
Group=$USER
WorkingDirectory=${APP_DIR}
Environment="PATH=${APP_DIR}/venv/bin:/usr/local/bin:/usr/bin"
Environment="PYTHONUNBUFFERED=1"
ExecStart=${exec_start}
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=30
PrivateTmp=true
NoNewPrivileges=true

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}

[Install]
WantedBy=multi-user.target
EOF
}

#-------------------------------------------------------------------------------
# Java Service (Spring Boot JAR)
#-------------------------------------------------------------------------------

setup_java_service() {
    log "INFO" "Setting up Java Spring Boot service..."
    
    cd "$APP_DIR"
    
    # Build the application
    if [ -f "pom.xml" ]; then
        log "INFO" "Building with Maven..."
        mvn clean package -DskipTests || {
            log "ERROR" "Maven build failed"
            return 1
        }
        
        # Find JAR file
        JAR_FILE=$(find target -name "*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" | head -1)
    elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
        log "INFO" "Building with Gradle..."
        ./gradlew clean build -x test 2>/dev/null || gradle clean build -x test || {
            log "ERROR" "Gradle build failed"
            return 1
        }
        
        # Find JAR file
        JAR_FILE=$(find build/libs -name "*.jar" -not -name "*-plain.jar" | head -1)
    fi
    
    if [ -z "$JAR_FILE" ] || [ ! -f "$JAR_FILE" ]; then
        log "ERROR" "Could not find JAR file"
        return 1
    fi
    
    log "INFO" "Found JAR: $JAR_FILE"
    
    # Copy JAR to standard location
    sudo mkdir -p /opt/${APP_NAME}
    sudo cp "$JAR_FILE" /opt/${APP_NAME}/app.jar
    sudo chown -R $USER:$USER /opt/${APP_NAME}
    
    # Create systemd service
    create_java_systemd_unit
    
    # Start service
    sudo systemctl daemon-reload
    sudo systemctl enable ${APP_NAME}
    sudo systemctl start ${APP_NAME}
    
    # Health check
    perform_health_check
}

create_java_systemd_unit() {
    sudo tee /etc/systemd/system/${APP_NAME}.service > /dev/null << EOF
[Unit]
Description=${APP_NAME} Spring Boot Service
After=network.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=/opt/${APP_NAME}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="SERVER_PORT=${APP_PORT}"
ExecStart=/usr/bin/java -Xms256m -Xmx512m -jar /opt/${APP_NAME}/app.jar --server.port=${APP_PORT}
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=always
RestartSec=10
SuccessExitStatus=143
TimeoutStopSec=30

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}

# Security
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/${APP_NAME}

[Install]
WantedBy=multi-user.target
EOF
}

#-------------------------------------------------------------------------------
# Rust Service (Binary)
#-------------------------------------------------------------------------------

setup_rust_service() {
    log "INFO" "Setting up Rust service..."
    
    cd "$APP_DIR"
    
    # Source cargo env
    [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
    
    # Build release binary
    log "INFO" "Building Rust release binary..."
    cargo build --release || {
        log "ERROR" "Cargo build failed"
        return 1
    }
    
    # Find binary name from Cargo.toml
    local binary_name
    binary_name=$(grep -m1 '^name' Cargo.toml | cut -d'"' -f2 || echo "$APP_NAME")
    
    local binary_path="target/release/${binary_name}"
    
    if [ ! -f "$binary_path" ]; then
        log "ERROR" "Binary not found at $binary_path"
        return 1
    fi
    
    # Copy binary to /opt
    sudo mkdir -p /opt/${APP_NAME}
    sudo cp "$binary_path" /opt/${APP_NAME}/${APP_NAME}
    sudo chmod +x /opt/${APP_NAME}/${APP_NAME}
    sudo chown -R $USER:$USER /opt/${APP_NAME}
    
    # Create systemd service
    create_rust_systemd_unit
    
    # Start service
    sudo systemctl daemon-reload
    sudo systemctl enable ${APP_NAME}
    sudo systemctl start ${APP_NAME}
    
    # Health check
    perform_health_check
}

create_rust_systemd_unit() {
    sudo tee /etc/systemd/system/${APP_NAME}.service > /dev/null << EOF
[Unit]
Description=${APP_NAME} Rust Service
After=network.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=/opt/${APP_NAME}
Environment="RUST_LOG=info"
Environment="PORT=${APP_PORT}"
ExecStart=/opt/${APP_NAME}/${APP_NAME}
Restart=always
RestartSec=5
TimeoutStopSec=30

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}

# Security
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/${APP_NAME}

# Resource limits
LimitNOFILE=65535
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF
}

#-------------------------------------------------------------------------------
# Go Service (Binary)
#-------------------------------------------------------------------------------

setup_go_service() {
    log "INFO" "Setting up Go service..."
    
    cd "$APP_DIR"
    
    # Ensure Go is in PATH
    export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
    
    # Download dependencies
    log "INFO" "Downloading Go dependencies..."
    go mod download 2>/dev/null || go mod tidy
    
    # Build binary
    log "INFO" "Building Go binary..."
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o ${APP_NAME} . || {
        log "ERROR" "Go build failed"
        return 1
    }
    
    # Copy binary to /opt
    sudo mkdir -p /opt/${APP_NAME}
    sudo cp ${APP_NAME} /opt/${APP_NAME}/${APP_NAME}
    sudo chmod +x /opt/${APP_NAME}/${APP_NAME}
    sudo chown -R $USER:$USER /opt/${APP_NAME}
    
    # Create systemd service
    create_go_systemd_unit
    
    # Start service
    sudo systemctl daemon-reload
    sudo systemctl enable ${APP_NAME}
    sudo systemctl start ${APP_NAME}
    
    # Health check
    perform_health_check
}

create_go_systemd_unit() {
    sudo tee /etc/systemd/system/${APP_NAME}.service > /dev/null << EOF
[Unit]
Description=${APP_NAME} Go Service
After=network.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=/opt/${APP_NAME}
Environment="PORT=${APP_PORT}"
Environment="GIN_MODE=release"
ExecStart=/opt/${APP_NAME}/${APP_NAME}
Restart=always
RestartSec=5
TimeoutStopSec=30

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}

# Security
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/${APP_NAME}

# Resource limits
LimitNOFILE=65535
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF
}

#-------------------------------------------------------------------------------
# PHP Service (PHP-FPM)
#-------------------------------------------------------------------------------

setup_php_service() {
    log "INFO" "Setting up PHP-FPM service..."
    
    cd "$APP_DIR"
    
    # Install Composer dependencies
    if [ -f "composer.json" ]; then
        log "INFO" "Installing Composer dependencies..."
        composer install --no-dev --optimize-autoloader 2>/dev/null || {
            log "WARN" "Composer install had issues, continuing..."
        }
    fi
    
    # Set ownership
    sudo chown -R www-data:www-data "$APP_DIR"
    sudo chmod -R 755 "$APP_DIR"
    
    # Create PHP-FPM pool config
    create_php_fpm_pool
    
    # Create Nginx config for PHP (if Nginx is installed)
    if command_exists nginx; then
        create_php_nginx_config
    fi
    
    # Restart PHP-FPM
    local php_fpm_service="php${PHP_VERSION}-fpm"
    sudo systemctl restart ${php_fpm_service} 2>/dev/null || \
    sudo systemctl restart php-fpm 2>/dev/null
    
    # Health check
    perform_health_check
}

create_php_fpm_pool() {
    local pool_config="/etc/php/${PHP_VERSION}/fpm/pool.d/${APP_NAME}.conf"
    
    sudo tee "$pool_config" > /dev/null << EOF
[${APP_NAME}]
user = www-data
group = www-data

listen = /run/php/${APP_NAME}.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
pm.max_requests = 500

; Environment
env[APP_ENV] = production
env[APP_DEBUG] = false

; Logging
php_admin_value[error_log] = /var/log/php-fpm/${APP_NAME}-error.log
php_admin_flag[log_errors] = on

; Security
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen
php_admin_value[open_basedir] = ${APP_DIR}:/tmp

; Limits
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 60
php_admin_value[upload_max_filesize] = 50M
php_admin_value[post_max_size] = 50M
EOF
    
    # Create log directory
    sudo mkdir -p /var/log/php-fpm
    sudo chown www-data:www-data /var/log/php-fpm
}

create_php_nginx_config() {
    sudo tee /etc/nginx/sites-available/${APP_NAME} > /dev/null << EOF
server {
    listen ${APP_PORT};
    server_name localhost;
    
    root ${APP_DIR}/public;
    index index.php index.html;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    
    location ~ \.php\$ {
        fastcgi_pass unix:/run/php/${APP_NAME}.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_busy_buffers_size 256k;
    }
    
    location ~ /\.ht {
        deny all;
    }
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    access_log /var/log/nginx/${APP_NAME}-access.log;
    error_log /var/log/nginx/${APP_NAME}-error.log;
}
EOF
    
    sudo ln -sf /etc/nginx/sites-available/${APP_NAME} /etc/nginx/sites-enabled/
    sudo nginx -t && sudo systemctl reload nginx
}

#-------------------------------------------------------------------------------
# Ruby on Rails Service (Puma)
#-------------------------------------------------------------------------------

setup_ruby_service() {
    log "INFO" "Setting up Ruby on Rails service with Puma..."
    
    cd "$APP_DIR"
    
    # Ensure Ruby is available
    [ -f "$HOME/.rbenv/bin/rbenv" ] && eval "$(~/.rbenv/bin/rbenv init -)" 2>/dev/null
    [ -f "$HOME/.rvm/scripts/rvm" ] && source "$HOME/.rvm/scripts/rvm" 2>/dev/null
    
    # Install dependencies
    log "INFO" "Installing Ruby dependencies..."
    bundle config set --local deployment 'true' 2>/dev/null || true
    bundle config set --local without 'development test' 2>/dev/null || true
    bundle install || {
        log "ERROR" "Bundle install failed"
        return 1
    }
    
    # Precompile assets (Rails)
    if [ -f "bin/rails" ]; then
        log "INFO" "Precompiling assets..."
        RAILS_ENV=production bundle exec rails assets:precompile 2>/dev/null || true
    fi
    
    # Create Puma config
    create_puma_config
    
    # Create systemd service
    create_ruby_systemd_unit
    
    # Start service
    sudo systemctl daemon-reload
    sudo systemctl enable ${APP_NAME}
    sudo systemctl start ${APP_NAME}
    
    # Health check
    perform_health_check
}

create_puma_config() {
    cat > "$APP_DIR/config/puma.rb" << EOF
# Puma configuration for ${APP_NAME}

# Port
port ENV.fetch("PORT") { ${APP_PORT} }

# Environment
environment ENV.fetch("RAILS_ENV") { "production" }

# Workers (set to 0 for single mode)
workers ENV.fetch("WEB_CONCURRENCY") { 2 }

# Threads
threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
threads threads_count, threads_count

# PID file
pidfile ENV.fetch("PIDFILE") { "tmp/pids/server.pid" }

# State file
state_path "tmp/pids/puma.state"

# Bind
bind "tcp://0.0.0.0:${APP_PORT}"

# Preload app for better memory usage with workers
preload_app!

# Allow puma to be restarted by `bin/rails restart`
plugin :tmp_restart

# Logging
stdout_redirect "/var/log/${APP_NAME}/puma.stdout.log", "/var/log/${APP_NAME}/puma.stderr.log", true

# Before/After fork hooks
before_fork do
  ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord)
end

on_worker_boot do
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
end
EOF
    
    # Create log directory
    sudo mkdir -p /var/log/${APP_NAME}
    sudo chown $USER:$USER /var/log/${APP_NAME}
    
    # Create tmp/pids directory
    mkdir -p tmp/pids
}

create_ruby_systemd_unit() {
    # Determine Ruby path
    local ruby_path
    if [ -f "$HOME/.rbenv/bin/rbenv" ]; then
        ruby_path="$HOME/.rbenv/shims"
    elif [ -f "$HOME/.rvm/scripts/rvm" ]; then
        ruby_path="$HOME/.rvm/rubies/default/bin"
    else
        ruby_path="/usr/bin"
    fi
    
    sudo tee /etc/systemd/system/${APP_NAME}.service > /dev/null << EOF
[Unit]
Description=${APP_NAME} Rails/Puma Service
After=network.target

[Service]
Type=notify
User=$USER
Group=$USER
WorkingDirectory=${APP_DIR}
Environment="RAILS_ENV=production"
Environment="PORT=${APP_PORT}"
Environment="PATH=${ruby_path}:/usr/local/bin:/usr/bin:/bin"
ExecStart=${ruby_path}/bundle exec puma -C config/puma.rb
ExecReload=/bin/kill -s USR2 \$MAINPID
Restart=always
RestartSec=5
TimeoutStopSec=30

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}

# Security
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

#-------------------------------------------------------------------------------
# .NET Core Service
#-------------------------------------------------------------------------------

setup_dotnet_service() {
    log "INFO" "Setting up .NET Core service..."
    
    cd "$APP_DIR"
    
    # Ensure dotnet is in PATH
    export PATH=$PATH:/usr/local/dotnet:$HOME/.dotnet
    
    # Restore and publish
    log "INFO" "Restoring .NET dependencies..."
    dotnet restore || {
        log "ERROR" "Dotnet restore failed"
        return 1
    }
    
    log "INFO" "Publishing .NET application..."
    dotnet publish -c Release -o publish || {
        log "ERROR" "Dotnet publish failed"
        return 1
    }
    
    # Find DLL
    local dll_file
    dll_file=$(find publish -maxdepth 1 -name "*.dll" -type f | grep -v ".Views.dll" | head -1)
    
    if [ -z "$dll_file" ]; then
        log "ERROR" "Could not find published DLL"
        return 1
    fi
    
    local dll_name=$(basename "$dll_file")
    
    # Copy to /opt
    sudo mkdir -p /opt/${APP_NAME}
    sudo cp -r publish/* /opt/${APP_NAME}/
    sudo chown -R $USER:$USER /opt/${APP_NAME}
    
    # Create systemd service
    create_dotnet_systemd_unit "$dll_name"
    
    # Start service
    sudo systemctl daemon-reload
    sudo systemctl enable ${APP_NAME}
    sudo systemctl start ${APP_NAME}
    
    # Health check
    perform_health_check
}

create_dotnet_systemd_unit() {
    local dll_name="$1"
    local dotnet_path
    
    # Find dotnet executable
    if [ -f "/usr/local/dotnet/dotnet" ]; then
        dotnet_path="/usr/local/dotnet/dotnet"
    elif [ -f "/usr/bin/dotnet" ]; then
        dotnet_path="/usr/bin/dotnet"
    elif [ -f "/snap/bin/dotnet" ]; then
        dotnet_path="/snap/bin/dotnet"
    else
        dotnet_path=$(which dotnet)
    fi
    
    sudo tee /etc/systemd/system/${APP_NAME}.service > /dev/null << EOF
[Unit]
Description=${APP_NAME} .NET Core Service
After=network.target

[Service]
Type=notify
User=$USER
Group=$USER
WorkingDirectory=/opt/${APP_NAME}
Environment="ASPNETCORE_ENVIRONMENT=Production"
Environment="ASPNETCORE_URLS=http://0.0.0.0:${APP_PORT}"
Environment="DOTNET_ROOT=/usr/local/dotnet"
ExecStart=${dotnet_path} /opt/${APP_NAME}/${dll_name}
Restart=always
RestartSec=10
TimeoutStopSec=30
KillSignal=SIGINT
SyslogIdentifier=${APP_NAME}

# Logging
StandardOutput=journal
StandardError=journal

# Security
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/${APP_NAME}

[Install]
WantedBy=multi-user.target
EOF
}

#===============================================================================
# HEALTH CHECK
#===============================================================================

perform_health_check() {
    log "INFO" "Performing health check..."
    
    local max_attempts=10
    local attempt=1
    local health_endpoint="http://localhost:${APP_PORT}"
    
    # Common health endpoints
    local endpoints=(
        "${health_endpoint}/health"
        "${health_endpoint}/healthz"
        "${health_endpoint}/api/health"
        "${health_endpoint}/"
    )
    
    sleep 3  # Initial wait for service to start
    
    while [ $attempt -le $max_attempts ]; do
        for endpoint in "${endpoints[@]}"; do
            local status_code
            status_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$endpoint" 2>/dev/null)
            
            if [[ "$status_code" =~ ^(200|201|204|301|302)$ ]]; then
                log "INFO" "Health check passed: $endpoint (HTTP $status_code)"
                return 0
            fi
        done
        
        log "WARN" "Health check attempt $attempt/$max_attempts failed, retrying..."
        sleep 2
        ((attempt++))
    done
    
    log "WARN" "Health check failed after $max_attempts attempts"
    log "INFO" "Service may still be starting. Check status manually."
    return 1
}

#===============================================================================
# DEPLOY SCRIPT GENERATION
#===============================================================================

create_deploy_script() {
    print_section "Creating Deploy Script"
    
    log "INFO" "Generating deploy script for ${BACKEND_TYPE}..."
    
    cat > "$APP_DIR/deploy.sh" << 'DEPLOY_HEADER'
#!/bin/bash
#===============================================================================
# AUTO-DEPLOY SCRIPT
# Backend Type: __BACKEND_TYPE__
# Generated: __TIMESTAMP__
#===============================================================================

set -e

# Configuration
APP_NAME="__APP_NAME__"
APP_DIR="__APP_DIR__"
APP_PORT="__APP_PORT__"
BACKEND_TYPE="__BACKEND_TYPE__"
LOG_FILE="/var/log/${APP_NAME}-deploy.log"
MAX_RETRIES=3
RETRY_DELAY=5
DEPLOY_LOCK="/tmp/${APP_NAME}-deploy.lock"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[${timestamp}] [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

#-------------------------------------------------------------------------------
# Locking
#-------------------------------------------------------------------------------

acquire_lock() {
    if [ -f "$DEPLOY_LOCK" ]; then
        local lock_pid=$(cat "$DEPLOY_LOCK" 2>/dev/null)
        if kill -0 "$lock_pid" 2>/dev/null; then
            log_error "Another deployment is in progress (PID: $lock_pid)"
            exit 1
        fi
        rm -f "$DEPLOY_LOCK"
    fi
    echo $$ > "$DEPLOY_LOCK"
    trap 'rm -f "$DEPLOY_LOCK"' EXIT
}

#-------------------------------------------------------------------------------
# Retry Logic
#-------------------------------------------------------------------------------

retry() {
    local max_attempts=${1:-$MAX_RETRIES}
    local delay=${2:-$RETRY_DELAY}
    shift 2
    local cmd="$@"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log_info "Attempt $attempt/$max_attempts: $cmd"
        if eval "$cmd"; then
            return 0
        fi
        log_warn "Failed, retrying in ${delay}s..."
        sleep $delay
        ((attempt++))
    done
    
    log_error "Command failed after $max_attempts attempts: $cmd"
    return 1
}

#-------------------------------------------------------------------------------
# Error Handler with Rollback
#-------------------------------------------------------------------------------

ROLLBACK_COMMIT=""

handle_error() {
    local line_number=$1
    log_error "Deployment failed at line $line_number"
    
    if [ -n "$ROLLBACK_COMMIT" ] && [ "$ROLLBACK_COMMIT" != "none" ]; then
        log_warn "Attempting rollback to commit: $ROLLBACK_COMMIT"
        
        cd "$APP_DIR"
        git checkout "$ROLLBACK_COMMIT" 2>/dev/null || true
        
        # Attempt to restore previous state
        case "$BACKEND_TYPE" in
            "nodejs")
                npm install 2>/dev/null || true
                npm run build 2>/dev/null || true
                pm2 restart "$APP_NAME" 2>/dev/null || true
                ;;
            "python-docker")
                docker compose up -d --build 2>/dev/null || docker-compose up -d --build 2>/dev/null || true
                ;;
            "python-systemd"|"java"|"rust"|"go"|"dotnet")
                sudo systemctl restart "$APP_NAME" 2>/dev/null || true
                ;;
            "php")
                sudo systemctl restart php*-fpm 2>/dev/null || true
                ;;
            "ruby")
                sudo systemctl restart "$APP_NAME" 2>/dev/null || true
                ;;
        esac
        
        log_info "Rollback attempted"
    fi
    
    exit 1
}

trap 'handle_error $LINENO' ERR

#-------------------------------------------------------------------------------
# Health Check
#-------------------------------------------------------------------------------

health_check() {
    local max_attempts=${1:-10}
    local delay=${2:-3}
    local attempt=1
    
    local endpoints=(
        "http://localhost:${APP_PORT}/health"
        "http://localhost:${APP_PORT}/healthz"
        "http://localhost:${APP_PORT}/api/health"
        "http://localhost:${APP_PORT}/"
    )
    
    while [ $attempt -le $max_attempts ]; do
        for endpoint in "${endpoints[@]}"; do
            local status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$endpoint" 2>/dev/null)
            if [[ "$status" =~ ^(200|201|204|301|302)$ ]]; then
                log_info "Health check passed: $endpoint (HTTP $status)"
                return 0
            fi
        done
        
        log_warn "Health check attempt $attempt/$max_attempts..."
        sleep $delay
        ((attempt++))
    done
    
    log_error "Health check failed"
    return 1
}

#-------------------------------------------------------------------------------
# Pre-deployment
#-------------------------------------------------------------------------------

pre_deploy() {
    log_info "=========================================="
    log_info "Deployment started for: $APP_NAME"
    log_info "Backend type: $BACKEND_TYPE"
    log_info "=========================================="
    
    acquire_lock
    
    cd "$APP_DIR"
    
    # Save current commit for rollback
    ROLLBACK_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "none")
    log_info "Current commit (for rollback): $ROLLBACK_COMMIT"
    
    # Stash local changes
    git stash --include-untracked 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# Git Pull
#-------------------------------------------------------------------------------

git_pull() {
    log_info "Pulling latest changes..."
    
    retry 3 5 "git fetch origin" || {
        log_error "Git fetch failed"
        return 1
    }
    
    # Try main, then master
    if git rev-parse --verify origin/main &>/dev/null; then
        git reset --hard origin/main
    elif git rev-parse --verify origin/master &>/dev/null; then
        git reset --hard origin/master
    else
        local branch=$(git symbolic-ref --short HEAD)
        git reset --hard origin/$branch
    fi
    
    log_info "Git pull completed"
}

DEPLOY_HEADER

    # Add backend-specific deploy functions
    case "$BACKEND_TYPE" in
        "nodejs")
            append_nodejs_deploy_functions
            ;;
        "python-docker")
            append_python_docker_deploy_functions
            ;;
        "python-systemd")
            append_python_systemd_deploy_functions
            ;;
        "java")
            append_java_deploy_functions
            ;;
        "rust")
            append_rust_deploy_functions
            ;;
        "go")
            append_go_deploy_functions
            ;;
        "php")
            append_php_deploy_functions
            ;;
        "ruby")
            append_ruby_deploy_functions
            ;;
        "dotnet")
            append_dotnet_deploy_functions
            ;;
    esac

    # Add main execution
    cat >> "$APP_DIR/deploy.sh" << 'DEPLOY_FOOTER'

#-------------------------------------------------------------------------------
# Post-deployment
#-------------------------------------------------------------------------------

post_deploy() {
    log_info "Running post-deployment tasks..."
    
    # Health check
    if health_check 10 3; then
        log_info "Application is healthy"
    else
        log_warn "Application may not be responding correctly"
    fi
    
    log_info "=========================================="
    log_info "Deployment completed successfully"
    log_info "=========================================="
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------

main() {
    pre_deploy
    git_pull
    deploy
    post_deploy
}

main "$@"
DEPLOY_FOOTER

    # Replace placeholders
    sed -i "s|__APP_NAME__|$APP_NAME|g" "$APP_DIR/deploy.sh"
    sed -i "s|__APP_DIR__|$APP_DIR|g" "$APP_DIR/deploy.sh"
    sed -i "s|__APP_PORT__|$APP_PORT|g" "$APP_DIR/deploy.sh"
    sed -i "s|__BACKEND_TYPE__|$BACKEND_TYPE|g" "$APP_DIR/deploy.sh"
    sed -i "s|__TIMESTAMP__|$(date '+%Y-%m-%d %H:%M:%S')|g" "$APP_DIR/deploy.sh"
    
    chmod +x "$APP_DIR/deploy.sh"
    
    # Create deploy log
    sudo touch /var/log/${APP_NAME}-deploy.log
    sudo chown $USER:$USER /var/log/${APP_NAME}-deploy.log
    
    log "INFO" "Deploy script created: $APP_DIR/deploy.sh"
}

#-------------------------------------------------------------------------------
# Backend-specific deploy function generators
#-------------------------------------------------------------------------------

append_nodejs_deploy_functions() {
    cat >> "$APP_DIR/deploy.sh" << 'EOF'

#-------------------------------------------------------------------------------
# Node.js Deployment
#-------------------------------------------------------------------------------

deploy() {
    log_info "Deploying Node.js application..."
    
    cd "$APP_DIR"
    
    # Install dependencies
    log_info "Installing dependencies..."
    if [ -f "package-lock.json" ]; then
        retry 3 5 "npm ci" || retry 3 5 "npm install"
    elif [ -f "yarn.lock" ]; then
        retry 3 5 "yarn install --frozen-lockfile" || retry 3 5 "yarn install"
    else
        retry 3 5 "npm install"
    fi
    
    # Build
    if grep -q '"build"' package.json 2>/dev/null; then
        log_info "Building application..."
        npm run build || {
            log_error "Build failed"
            return 1
        }
    fi
    
    # Restart PM2
    log_info "Restarting PM2 process..."
    pm2 reload ecosystem.config.cjs --update-env 2>/dev/null || \
    pm2 restart "$APP_NAME" 2>/dev/null || \
    pm2 start ecosystem.config.cjs
    
    pm2 save
}
EOF
}

append_python_docker_deploy_functions() {
    cat >> "$APP_DIR/deploy.sh" << 'EOF'

#-------------------------------------------------------------------------------
# Python Docker Deployment
#-------------------------------------------------------------------------------

deploy() {
    log_info "Deploying Python Docker application..."
    
    cd "$APP_DIR"
    
    # Build new image
    log_info "Building Docker image..."
    docker compose build --no-cache || docker-compose build --no-cache || {
        log_error "Docker build failed"
        return 1
    }
    
    # Stop old containers
    log_info "Stopping old containers..."
    docker compose down || docker-compose down || true
    
    # Start new containers
    log_info "Starting new containers..."
    docker compose up -d || docker-compose up -d || {
        log_error "Docker compose up failed"
        return 1
    }
    
    # Cleanup old images
    log_info "Cleaning up old images..."
    docker image prune -f 2>/dev/null || true
}
EOF
}

append_python_systemd_deploy_functions() {
    cat >> "$APP_DIR/deploy.sh" << 'EOF'

#-------------------------------------------------------------------------------
# Python systemd Deployment
#-------------------------------------------------------------------------------

deploy() {
    log_info "Deploying Python systemd application..."
    
    cd "$APP_DIR"
    
    # Activate virtual environment
    source venv/bin/activate
    
    # Install/update dependencies
    log_info "Updating dependencies..."
    pip install --upgrade pip
    if [ -f "requirements.txt" ]; then
        pip install -r requirements.txt
    elif [ -f "pyproject.toml" ]; then
        pip install .
    fi
    
    deactivate
    
    # Run migrations (if Django)
    if [ -f "manage.py" ]; then
        log_info "Running migrations..."
        source venv/bin/activate
        python manage.py migrate --noinput 2>/dev/null || true
        python manage.py collectstatic --noinput 2>/dev/null || true
        deactivate
    fi
    
    # Restart service
    log_info "Restarting service..."
    sudo systemctl restart "$APP_NAME"
}
EOF
}

append_java_deploy_functions() {
    cat >> "$APP_DIR/deploy.sh" << 'EOF'

#-------------------------------------------------------------------------------
# Java Spring Boot Deployment
#-------------------------------------------------------------------------------

deploy() {
    log_info "Deploying Java Spring Boot application..."
    
    cd "$APP_DIR"
    
    # Build with Maven or Gradle
    if [ -f "pom.xml" ]; then
        log_info "Building with Maven..."
        mvn clean package -DskipTests || {
            log_error "Maven build failed"
            return 1
        }
        JAR_FILE=$(find target -name "*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" | head -1)
    elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
        log_info "Building with Gradle..."
        ./gradlew clean build -x test 2>/dev/null || gradle clean build -x test || {
            log_error "Gradle build failed"
            return 1
        }
        JAR_FILE=$(find build/libs -name "*.jar" -not -name "*-plain.jar" | head -1)
    fi
    
    # Copy new JAR
    log_info "Deploying new JAR..."
    sudo cp "$JAR_FILE" /opt/${APP_NAME}/app.jar
    
    # Restart service
    log_info "Restarting service..."
    sudo systemctl restart "$APP_NAME"
}
EOF
}

append_rust_deploy_functions() {
    cat >> "$APP_DIR/deploy.sh" << 'EOF'

#-------------------------------------------------------------------------------
# Rust Deployment
#-------------------------------------------------------------------------------

deploy() {
    log_info "Deploying Rust application..."
    
    cd "$APP_DIR"
    
    # Source cargo environment
    [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
    
    # Build release
    log_info "Building Rust release binary..."
    cargo build --release || {
        log_error "Cargo build failed"
        return 1
    }
    
    # Get binary name
    local binary_name=$(grep -m1 '^name' Cargo.toml | cut -d'"' -f2 || echo "$APP_NAME")
    
    # Stop service before replacing binary
    sudo systemctl stop "$APP_NAME" 2>/dev/null || true
    
    # Copy new binary
    log_info "Deploying new binary..."
    sudo cp "target/release/${binary_name}" /opt/${APP_NAME}/${APP_NAME}
    sudo chmod +x /opt/${APP_NAME}/${APP_NAME}
    
    # Start service
    log_info "Starting service..."
    sudo systemctl start "$APP_NAME"
}
EOF
}

append_go_deploy_functions() {
    cat >> "$APP_DIR/deploy.sh" << 'EOF'

#-------------------------------------------------------------------------------
# Go Deployment
#-------------------------------------------------------------------------------

deploy() {
    log_info "Deploying Go application..."
    
    cd "$APP_DIR"
    
    # Ensure Go is in PATH
    export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
    
    # Update dependencies
    log_info "Updating Go dependencies..."
    go mod download 2>/dev/null || go mod tidy
    
    # Build binary
    log_info "Building Go binary..."
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o ${APP_NAME} . || {
        log_error "Go build failed"
        return 1
    }
    
    # Stop service before replacing binary
    sudo systemctl stop "$APP_NAME" 2>/dev/null || true
    
    # Copy new binary
    log_info "Deploying new binary..."
    sudo cp ${APP_NAME} /opt/${APP_NAME}/${APP_NAME}
    sudo chmod +x /opt/${APP_NAME}/${APP_NAME}
    
    # Start service
    log_info "Starting service..."
    sudo systemctl start "$APP_NAME"
}
EOF
}

append_php_deploy_functions() {
    cat >> "$APP_DIR/deploy.sh" << 'EOF'

#-------------------------------------------------------------------------------
# PHP Deployment
#-------------------------------------------------------------------------------

deploy() {
    log_info "Deploying PHP application..."
    
    cd "$APP_DIR"
    
    # Install Composer dependencies
    if [ -f "composer.json" ]; then
        log_info "Installing Composer dependencies..."
        composer install --no-dev --optimize-autoloader || {
            log_warn "Composer install had issues"
        }
    fi
    
    # Laravel-specific commands
    if [ -f "artisan" ]; then
        log_info "Running Laravel commands..."
        php artisan migrate --force 2>/dev/null || true
        php artisan config:cache 2>/dev/null || true
        php artisan route:cache 2>/dev/null || true
        php artisan view:cache 2>/dev/null || true
    fi
    
    # Fix permissions
    sudo chown -R www-data:www-data "$APP_DIR"
    sudo chmod -R 755 "$APP_DIR"
    
    # Restart PHP-FPM
    log_info "Restarting PHP-FPM..."
    sudo systemctl restart php*-fpm 2>/dev/null || \
    sudo systemctl restart php-fpm 2>/dev/null || true
    
    # Restart Nginx if present
    if command -v nginx &>/dev/null; then
        sudo systemctl reload nginx 2>/dev/null || true
    fi
}
EOF
}

append_ruby_deploy_functions() {
    cat >> "$APP_DIR/deploy.sh" << 'EOF'

#-------------------------------------------------------------------------------
# Ruby on Rails Deployment
#-------------------------------------------------------------------------------

deploy() {
    log_info "Deploying Ruby on Rails application..."
    
    cd "$APP_DIR"
    
    # Load Ruby environment
    [ -f "$HOME/.rbenv/bin/rbenv" ] && eval "$(~/.rbenv/bin/rbenv init -)" 2>/dev/null
    [ -f "$HOME/.rvm/scripts/rvm" ] && source "$HOME/.rvm/scripts/rvm" 2>/dev/null
    
    # Install dependencies
    log_info "Installing Ruby dependencies..."
    bundle config set --local deployment 'true' 2>/dev/null || true
    bundle config set --local without 'development test' 2>/dev/null || true
    bundle install || {
        log_error "Bundle install failed"
        return 1
    }
    
    # Rails-specific commands
    if [ -f "bin/rails" ]; then
        log_info "Running Rails commands..."
        RAILS_ENV=production bundle exec rails db:migrate 2>/dev/null || true
        RAILS_ENV=production bundle exec rails assets:precompile 2>/dev/null || true
    fi
    
    # Restart service (Puma)
    log_info "Restarting Puma..."
    sudo systemctl restart "$APP_NAME"
}
EOF
}

append_dotnet_deploy_functions() {
    cat >> "$APP_DIR/deploy.sh" << 'EOF'

#-------------------------------------------------------------------------------
# .NET Core Deployment
#-------------------------------------------------------------------------------

deploy() {
    log_info "Deploying .NET Core application..."
    
    cd "$APP_DIR"
    
    # Ensure dotnet is in PATH
    export PATH=$PATH:/usr/local/dotnet:$HOME/.dotnet
    
    # Restore packages
    log_info "Restoring .NET packages..."
    dotnet restore || {
        log_error "Dotnet restore failed"
        return 1
    }
    
    # Publish
    log_info "Publishing .NET application..."
    dotnet publish -c Release -o publish || {
        log_error "Dotnet publish failed"
        return 1
    }
    
    # Stop service
    sudo systemctl stop "$APP_NAME" 2>/dev/null || true
    
    # Copy new publish output
    log_info "Deploying new build..."
    sudo cp -r publish/* /opt/${APP_NAME}/
    
    # Start service
    log_info "Starting service..."
    sudo systemctl start "$APP_NAME"
}
EOF
}

#===============================================================================
# WEBHOOK SETUP (UNIVERSAL)
#===============================================================================

setup_universal_webhook() {
    print_section "Setting Up CI/CD Webhook"
    
    # Install webhook if not present
    if ! command_exists webhook; then
        log "INFO" "Installing webhook..."
        sudo apt-get install -y webhook 2>/dev/null || {
            log "INFO" "Installing webhook via Go..."
            if ! command_exists go; then
                sudo apt-get install -y golang-go 2>/dev/null || {
                    # Download pre-built binary
                    local webhook_url="https://github.com/adnanh/webhook/releases/download/2.8.1/webhook-linux-amd64.tar.gz"
                    cd /tmp
                    curl -fsSL "$webhook_url" -o webhook.tar.gz || wget -q "$webhook_url" -O webhook.tar.gz
                    tar -xzf webhook.tar.gz
                    sudo mv webhook-linux-amd64/webhook /usr/local/bin/webhook
                    sudo chmod +x /usr/local/bin/webhook
                    cd - > /dev/null
                }
            else
                go install github.com/adnanh/webhook@latest
                sudo cp ~/go/bin/webhook /usr/local/bin/webhook 2>/dev/null || true
            fi
        }
    fi
    
    # Generate webhook secret if not exists
    if [ -z "$WEBHOOK_SECRET" ]; then
        WEBHOOK_SECRET=$(openssl rand -hex 32)
    fi
    
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
    "response-message": "Deployment triggered for ${APP_NAME} (${BACKEND_TYPE})",
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
          "or": [
            {
              "match": {
                "type": "value",
                "value": "refs/heads/main",
                "parameter": {
                  "source": "payload",
                  "name": "ref"
                }
              }
            },
            {
              "match": {
                "type": "value",
                "value": "refs/heads/master",
                "parameter": {
                  "source": "payload",
                  "name": "ref"
                }
              }
            }
          ]
        }
      ]
    },
    "pass-arguments-to-command": [
      {
        "source": "payload",
        "name": "head_commit.id"
      },
      {
        "source": "payload",
        "name": "pusher.name"
      }
    ],
    "pass-environment-to-command": [
      {
        "source": "payload",
        "name": "head_commit.message",
        "envname": "COMMIT_MESSAGE"
      }
    ]
  }
]
EOF
    
    # Create systemd service for webhook
    local webhook_path=$(which webhook 2>/dev/null || echo "/usr/local/bin/webhook")
    
    sudo tee /etc/systemd/system/webhook.service > /dev/null << EOF
[Unit]
Description=Webhook Server for ${APP_NAME}
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=/etc/webhook
ExecStart=${webhook_path} -hooks /etc/webhook/hooks.json -port ${WEBHOOK_PORT} -verbose
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=webhook

[Install]
WantedBy=multi-user.target
EOF
    
    # Start webhook service
    sudo systemctl daemon-reload
    sudo systemctl enable webhook
    sudo systemctl restart webhook
    
    sleep 2
    if sudo systemctl is-active --quiet webhook; then
        log "INFO" "Webhook service running on port $WEBHOOK_PORT"
    else
        log "WARN" "Webhook service may not be running correctly"
        log "INFO" "Check: sudo systemctl status webhook"
    fi
}

#===============================================================================
# DISPLAY MULTI-BACKEND SUMMARY
#===============================================================================

display_multibackend_summary() {
    print_section "Setup Complete!"
    
    # Show service status based on backend type
    echo -e "${GREEN}Service Status:${NC}"
    case "$BACKEND_TYPE" in
        "nodejs")
            pm2 status
            ;;
        "python-docker")
            docker compose ps 2>/dev/null || docker-compose ps 2>/dev/null || docker ps --filter "name=${APP_NAME}"
            ;;
        *)
            sudo systemctl status ${APP_NAME} --no-pager -l 2>/dev/null | head -20 || true
            ;;
    esac
    echo ""
    
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}DEPLOYMENT INFORMATION - SAVE THIS!${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Application Name:    ${GREEN}${APP_NAME}${NC}"
    echo -e "  Backend Type:        ${GREEN}${BACKEND_TYPE}${NC}"
    echo -e "  Application URL:     ${GREEN}http://localhost:${APP_PORT}${NC}"
    echo -e "  Webhook URL:         ${GREEN}http://YOUR_SERVER_IP:${WEBHOOK_PORT}/hooks/${APP_NAME}-deploy${NC}"
    echo ""
    echo -e "${YELLOW}GitHub Webhook Secret:${NC}"
    echo -e "${GREEN}${WEBHOOK_SECRET}${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Useful Commands:${NC}"
    
    case "$BACKEND_TYPE" in
        "nodejs")
            echo "  pm2 status                    # Check app status"
            echo "  pm2 logs $APP_NAME            # View logs"
            echo "  pm2 restart $APP_NAME         # Restart app"
            ;;
        "python-docker")
            echo "  docker compose ps             # Check container status"
            echo "  docker compose logs -f        # View logs"
            echo "  docker compose restart        # Restart containers"
            ;;
        *)
            echo "  sudo systemctl status $APP_NAME   # Check service status"
            echo "  sudo journalctl -u $APP_NAME -f   # View logs"
            echo "  sudo systemctl restart $APP_NAME  # Restart service"
            ;;
    esac
    
    echo "  sudo systemctl status webhook     # Check webhook status"
    echo "  cat /var/log/${APP_NAME}-deploy.log  # View deploy logs"
    echo ""
    
    # Save config
    cat > "$APP_DIR/.deploy-config" << EOF
APP_NAME=$APP_NAME
APP_DIR=$APP_DIR
APP_PORT=$APP_PORT
BACKEND_TYPE=$BACKEND_TYPE
WEBHOOK_PORT=$WEBHOOK_PORT
WEBHOOK_SECRET=$WEBHOOK_SECRET
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    chmod 600 "$APP_DIR/.deploy-config"
    
    log "INFO" "Configuration saved to $APP_DIR/.deploy-config"
}

#===============================================================================
# MULTI-BACKEND MAIN FUNCTION
#===============================================================================

setup_multibackend() {
    print_section "Multi-Backend Deployment Setup"
    
    echo "This script supports multiple backend types:"
    echo "  - Node.js (PM2)"
    echo "  - Python (Docker or systemd)"
    echo "  - Java (Spring Boot)"
    echo "  - Rust (compiled binary)"
    echo "  - Go (compiled binary)"
    echo "  - PHP (PHP-FPM)"
    echo "  - Ruby on Rails (Puma)"
    echo "  - .NET Core"
    echo ""
    
    if ! confirm "Continue with multi-backend setup?"; then
        return 0
    fi
    
    # Collect basic inputs (reuse existing function)
    collect_inputs
    
    # Select backend type
    select_backend_type
    
    # Update system
    update_system
    
    # Install runtime
    install_runtime
    
    # Setup Git credentials
    setup_git_credentials
    
    # Setup backend service
    setup_backend_service
    
    # Create deploy script
    create_deploy_script
    
    # Setup webhook
    setup_universal_webhook
    
    # Display summary
    display_multibackend_summary
}

#===============================================================================
# LOAD EXISTING CONFIGURATION
#===============================================================================

load_existing_config() {
    # Load saved config
    if [ -f "$PARENT_DIR/.deploy-config" ]; then
        source "$PARENT_DIR/.deploy-config"
        log "DEBUG" "Loaded config: $APP_NAME on port $APP_PORT"
    fi
    
    # Detect backend type from running process
    if command_exists pm2 && pm2 jlist 2>/dev/null | grep -q '"name"'; then
        EXISTING_BACKEND="nodejs"
        EXISTING_APP_NAME=$(pm2 jlist 2>/dev/null | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
    elif systemctl list-units --type=service --state=running | grep -qE "uvicorn|gunicorn|flask|django"; then
        EXISTING_BACKEND="python-systemd"
    elif docker ps 2>/dev/null | grep -qE "python|flask|django|fastapi"; then
        EXISTING_BACKEND="python-docker"
    elif systemctl list-units --type=service --state=running | grep -q "spring"; then
        EXISTING_BACKEND="java"
    elif systemctl list-units --type=service --state=running | grep -qE "dotnet|aspnet"; then
        EXISTING_BACKEND="dotnet"
    fi
    
    # Get webhook status
    if systemctl is-active --quiet webhook 2>/dev/null; then
        WEBHOOK_STATUS="running"
    else
        WEBHOOK_STATUS="stopped"
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
    load_existing_config
    echo ""
    
    # 1. Check if application is running
    echo -e "${CYAN}1. Checking application status...${NC}"
    case "$EXISTING_BACKEND" in
        nodejs)
            if pm2 list 2>/dev/null | grep -q "$EXISTING_APP_NAME"; then
                local status=$(pm2 jlist 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
                if [ "$status" = "online" ]; then
                    echo -e "   ${GREEN}✓ Node.js app '$EXISTING_APP_NAME' is running${NC}"
                else
                    echo -e "   ${RED}✗ Node.js app '$EXISTING_APP_NAME' status: $status${NC}"
                    ((issues_found++))
                    if confirm "   Restart application?"; then
                        pm2 restart "$EXISTING_APP_NAME"
                        ((issues_fixed++))
                    fi
                fi
            else
                echo -e "   ${RED}✗ No PM2 application found${NC}"
                ((issues_found++))
                
                if [ -f "$APP_DIR/ecosystem.config.cjs" ]; then
                    if confirm "   Found ecosystem config. Start application?"; then
                        cd "$APP_DIR"
                        pm2 start ecosystem.config.cjs
                        pm2 save
                        ((issues_fixed++))
                    fi
                fi
            fi
            ;;
        python-docker)
            if docker ps | grep -q "$APP_NAME"; then
                echo -e "   ${GREEN}✓ Python Docker container running${NC}"
            else
                echo -e "   ${RED}✗ Python Docker container not running${NC}"
                ((issues_found++))
                if confirm "   Try to start container?"; then
                    cd "$APP_DIR"
                    docker-compose up -d || docker compose up -d
                    ((issues_fixed++))
                fi
            fi
            ;;
        python-systemd)
            if systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
                echo -e "   ${GREEN}✓ Python service running${NC}"
            else
                echo -e "   ${RED}✗ Python service not running${NC}"
                ((issues_found++))
                if confirm "   Start service?"; then
                    sudo systemctl start "$APP_NAME"
                    ((issues_fixed++))
                fi
            fi
            ;;
        java)
            if systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
                echo -e "   ${GREEN}✓ Java service running${NC}"
            else
                echo -e "   ${RED}✗ Java service not running${NC}"
                ((issues_found++))
                if confirm "   Start service?"; then
                    sudo systemctl start "$APP_NAME"
                    ((issues_fixed++))
                fi
            fi
            ;;
        *)
            echo -e "   ${YELLOW}⚠ Could not detect backend type${NC}"
            ;;
    esac
    
    # 2. Check webhook service
    echo -e "${CYAN}2. Checking webhook service...${NC}"
    if systemctl is-active --quiet webhook 2>/dev/null; then
        echo -e "   ${GREEN}✓ Webhook service running${NC}"
    else
        echo -e "   ${RED}✗ Webhook service not running${NC}"
        ((issues_found++))
        
        if systemctl list-unit-files | grep -q webhook; then
            if confirm "   Start webhook service?"; then
                sudo systemctl start webhook
                if systemctl is-active --quiet webhook; then
                    echo -e "   ${GREEN}✓ Webhook started${NC}"
                    ((issues_fixed++))
                else
                    echo -e "   ${RED}Webhook failed to start${NC}"
                    sudo journalctl -u webhook -n 10 --no-pager
                fi
            fi
        else
            echo -e "   ${YELLOW}   Webhook service not installed${NC}"
        fi
    fi
    
    # 3. Check Git credentials
    echo -e "${CYAN}3. Checking Git credentials...${NC}"
    if [ -f "$HOME/.git-credentials" ]; then
        echo -e "   ${GREEN}✓ Git credentials file exists${NC}"
        
        cd "$APP_DIR" 2>/dev/null || true
        if git fetch --dry-run 2>/dev/null; then
            echo -e "   ${GREEN}✓ Git fetch test passed${NC}"
        else
            echo -e "   ${YELLOW}⚠ Git fetch test failed${NC}"
            ((issues_found++))
        fi
    else
        echo -e "   ${RED}✗ Git credentials not configured${NC}"
        ((issues_found++))
    fi
    
    # 4. Check deploy script
    echo -e "${CYAN}4. Checking deploy script...${NC}"
    if [ -f "$APP_DIR/deploy.sh" ]; then
        if [ -x "$APP_DIR/deploy.sh" ]; then
            echo -e "   ${GREEN}✓ Deploy script exists and is executable${NC}"
        else
            echo -e "   ${YELLOW}⚠ Deploy script not executable${NC}"
            ((issues_found++))
            if confirm "   Make executable?"; then
                chmod +x "$APP_DIR/deploy.sh"
                ((issues_fixed++))
            fi
        fi
    else
        echo -e "   ${RED}✗ Deploy script not found${NC}"
        ((issues_found++))
    fi
    
    # 5. Check application port
    echo -e "${CYAN}5. Checking application port...${NC}"
    local test_port="${APP_PORT:-3000}"
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$test_port" 2>/dev/null | grep -qE "200|301|302"; then
        echo -e "   ${GREEN}✓ Application responding on port $test_port${NC}"
    else
        echo -e "   ${YELLOW}⚠ Application not responding on port $test_port${NC}"
        ((issues_found++))
    fi
    
    # 6. Check PM2 startup configuration
    if [ "$EXISTING_BACKEND" = "nodejs" ]; then
        echo -e "${CYAN}6. Checking PM2 startup configuration...${NC}"
        if pm2 startup 2>&1 | grep -q "already set"; then
            echo -e "   ${GREEN}✓ PM2 startup configured${NC}"
        else
            echo -e "   ${YELLOW}⚠ PM2 startup may not be configured${NC}"
            ((issues_found++))
            if confirm "   Configure PM2 startup?"; then
                pm2 startup systemd -u $USER --hp $HOME
                pm2 save
                ((issues_fixed++))
            fi
        fi
    fi
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    if [ $issues_found -eq 0 ]; then
        log "INFO" "No issues found! Configuration appears healthy."
    else
        log "INFO" "Found $issues_found issue(s), fixed $issues_fixed"
    fi
    
    echo ""
    if confirm "Return to menu?"; then
        show_menu
    fi
}

#===============================================================================
# VIEW STATUS
#===============================================================================

view_status() {
    print_section "Current Status"
    
    load_existing_config
    
    echo -e "${CYAN}Configuration:${NC}"
    echo -e "  App Name:    ${GREEN}${APP_NAME:-'Not set'}${NC}"
    echo -e "  App Dir:     ${GREEN}${APP_DIR:-$PARENT_DIR}${NC}"
    echo -e "  App Port:    ${GREEN}${APP_PORT:-'Not set'}${NC}"
    echo -e "  Backend:     ${GREEN}${EXISTING_BACKEND:-'Not detected'}${NC}"
    echo ""
    
    echo -e "${CYAN}Services:${NC}"
    
    # PM2 status
    if command_exists pm2; then
        echo -e "  ${CYAN}PM2 Applications:${NC}"
        pm2 list 2>/dev/null | head -15
        echo ""
    fi
    
    # Docker containers
    if command_exists docker; then
        local containers=$(docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | tail -n +2)
        if [ -n "$containers" ]; then
            echo -e "  ${CYAN}Docker Containers:${NC}"
            echo "$containers"
            echo ""
        fi
    fi
    
    # Webhook status
    echo -e "  ${CYAN}Webhook Service:${NC}"
    sudo systemctl status webhook --no-pager 2>/dev/null | head -5 || echo "  Not installed"
    echo ""
    
    if confirm "Return to menu?"; then
        show_menu
    fi
}

#===============================================================================
# RESTART SERVICES
#===============================================================================

restart_services() {
    print_section "Restart Services"
    
    load_existing_config
    
    echo "What would you like to restart?"
    echo ""
    echo "1. Application only"
    echo "2. Webhook service only"
    echo "3. Both application and webhook"
    echo "4. Cancel"
    echo ""
    echo -en "${CYAN}Select [3]: ${NC}"
    read -r restart_choice
    restart_choice=${restart_choice:-3}
    
    case $restart_choice in
        1)
            case "$EXISTING_BACKEND" in
                nodejs) pm2 restart all ;;
                python-docker) cd "$APP_DIR" && docker-compose restart ;;
                *) sudo systemctl restart "$APP_NAME" 2>/dev/null ;;
            esac
            ;;
        2)
            sudo systemctl restart webhook
            ;;
        3)
            case "$EXISTING_BACKEND" in
                nodejs) pm2 restart all ;;
                python-docker) cd "$APP_DIR" && docker-compose restart ;;
                *) sudo systemctl restart "$APP_NAME" 2>/dev/null ;;
            esac
            sudo systemctl restart webhook
            ;;
        4)
            ;;
    esac
    
    log "INFO" "Services restarted"
    
    if confirm "Return to menu?"; then
        show_menu
    fi
}

#===============================================================================
# VIEW LOGS
#===============================================================================

view_logs() {
    echo ""
    echo -e "${CYAN}Select log to view:${NC}"
    echo "1. Application logs (PM2)"
    echo "2. Webhook logs"
    echo "3. Deploy logs"
    echo "4. Docker logs"
    echo ""
    echo -en "${CYAN}Select [1]: ${NC}"
    read -r log_choice
    log_choice=${log_choice:-1}
    
    echo "Press Ctrl+C to stop viewing logs"
    sleep 2
    
    case $log_choice in
        1) pm2 logs --lines 50 ;;
        2) sudo journalctl -u webhook -f ;;
        3) tail -f /var/log/${APP_NAME:-app}-deploy.log 2>/dev/null || echo "Deploy log not found" ;;
        4) docker-compose logs -f 2>/dev/null || docker logs -f $(docker ps -q | head -1) 2>/dev/null ;;
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
    # CHECK 1: Detect backend type
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[1/12] Detecting backend type...${NC}"
    local detected_backend="$EXISTING_BACKEND"
    
    if [ -z "$detected_backend" ]; then
        # Auto-detect based on running processes and files
        if pm2 list 2>/dev/null | grep -q online; then
            detected_backend="nodejs"
        elif docker ps 2>/dev/null | grep -q .; then
            detected_backend="docker"
        elif systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
            detected_backend="systemd"
        elif [ -f "$APP_DIR/package.json" ]; then
            detected_backend="nodejs"
        elif [ -f "$APP_DIR/requirements.txt" ] || [ -f "$APP_DIR/pyproject.toml" ]; then
            detected_backend="python"
        elif [ -f "$APP_DIR/pom.xml" ] || [ -f "$APP_DIR/build.gradle" ]; then
            detected_backend="java"
        elif [ -f "$APP_DIR/go.mod" ]; then
            detected_backend="go"
        elif [ -f "$APP_DIR/Cargo.toml" ]; then
            detected_backend="rust"
        fi
    fi
    
    if [ -n "$detected_backend" ]; then
        echo -e "   ${GREEN}✓ PASS${NC} - Backend detected: $detected_backend"
        EXISTING_BACKEND="$detected_backend"
        ((passed_checks++))
    else
        echo -e "   ${YELLOW}⚠ WARN${NC} - Could not detect backend type"
        echo -e "   ${YELLOW}  Will check common services...${NC}"
        ((passed_checks++))
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 2: Node.js / PM2 (if applicable)
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[2/12] Checking Node.js/PM2 status...${NC}"
    if [ "$detected_backend" = "nodejs" ] || command_exists pm2; then
        if command_exists node; then
            local node_ver=$(node --version 2>/dev/null)
            echo -e "   ${GREEN}✓${NC} Node.js installed: $node_ver"
        else
            echo -e "   ${YELLOW}⚠ Node.js not installed${NC}"
        fi
        
        if command_exists pm2; then
            local pm2_apps=$(pm2 jlist 2>/dev/null | grep -c '"name"' || echo 0)
            local pm2_online=$(pm2 jlist 2>/dev/null | grep -c '"status":"online"' || echo 0)
            
            if [ "$pm2_online" -gt 0 ]; then
                echo -e "   ${GREEN}✓ PASS${NC} - PM2 running ($pm2_online/$pm2_apps apps online)"
                ((passed_checks++))
            elif [ "$pm2_apps" -gt 0 ]; then
                echo -e "   ${RED}✗ FAIL${NC} - PM2 apps exist but not running"
                ((failed_checks++))
                echo -e "   ${YELLOW}→ AUTO-FIX: Restarting all PM2 apps...${NC}"
                if pm2 restart all 2>/dev/null; then
                    sleep 2
                    local now_online=$(pm2 jlist 2>/dev/null | grep -c '"status":"online"' || echo 0)
                    if [ "$now_online" -gt 0 ]; then
                        echo -e "   ${GREEN}✓ FIXED${NC} - $now_online apps now online"
                        ((auto_fixed++))
                    else
                        echo -e "   ${RED}✗ FAILED TO FIX${NC} - Check pm2 logs"
                        ((manual_needed++))
                    fi
                else
                    ((manual_needed++))
                fi
            else
                echo -e "   ${YELLOW}⊘ SKIP${NC} - No PM2 apps configured"
            fi
        else
            echo -e "   ${YELLOW}⊘ SKIP${NC} - PM2 not installed"
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - Not a Node.js backend"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 3: Docker containers (if applicable)
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[3/12] Checking Docker status...${NC}"
    if command_exists docker; then
        local running_containers=$(docker ps -q 2>/dev/null | wc -l)
        local all_containers=$(docker ps -aq 2>/dev/null | wc -l)
        
        if [ "$running_containers" -gt 0 ]; then
            echo -e "   ${GREEN}✓ PASS${NC} - $running_containers container(s) running"
            ((passed_checks++))
        elif [ "$all_containers" -gt 0 ]; then
            echo -e "   ${RED}✗ FAIL${NC} - Containers exist but not running"
            ((failed_checks++))
            echo -e "   ${YELLOW}→ AUTO-FIX: Starting stopped containers...${NC}"
            
            # Try docker-compose first
            if [ -f "$APP_DIR/docker-compose.yml" ] || [ -f "$APP_DIR/docker-compose.yaml" ]; then
                cd "$APP_DIR"
                if docker-compose up -d 2>/dev/null || docker compose up -d 2>/dev/null; then
                    echo -e "   ${GREEN}✓ FIXED${NC} - Containers started via docker-compose"
                    ((auto_fixed++))
                else
                    echo -e "   ${RED}✗ FAILED TO FIX${NC}"
                    ((manual_needed++))
                fi
            else
                # Start individual containers
                docker start $(docker ps -aq) 2>/dev/null
                local now_running=$(docker ps -q 2>/dev/null | wc -l)
                if [ "$now_running" -gt 0 ]; then
                    echo -e "   ${GREEN}✓ FIXED${NC} - $now_running containers started"
                    ((auto_fixed++))
                else
                    ((manual_needed++))
                fi
            fi
        else
            echo -e "   ${YELLOW}⊘ SKIP${NC} - No Docker containers"
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - Docker not installed"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 4: Systemd services (for Python/Java/Go/Rust)
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[4/12] Checking systemd services...${NC}"
    local app_service="${APP_NAME:-myapp}"
    
    if systemctl list-unit-files 2>/dev/null | grep -q "$app_service"; then
        if sudo systemctl is-active --quiet "$app_service" 2>/dev/null; then
            echo -e "   ${GREEN}✓ PASS${NC} - Service '$app_service' is running"
            ((passed_checks++))
        else
            echo -e "   ${RED}✗ FAIL${NC} - Service '$app_service' not running"
            ((failed_checks++))
            echo -e "   ${YELLOW}→ AUTO-FIX: Starting service...${NC}"
            if sudo systemctl start "$app_service" 2>/dev/null; then
                sleep 2
                if sudo systemctl is-active --quiet "$app_service"; then
                    echo -e "   ${GREEN}✓ FIXED${NC} - Service started"
                    ((auto_fixed++))
                else
                    echo -e "   ${RED}✗ FAILED TO FIX${NC} - Check: journalctl -u $app_service"
                    ((manual_needed++))
                fi
            else
                ((manual_needed++))
            fi
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - No systemd service for '$app_service'"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 5: Webhook service
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[5/12] Checking webhook service...${NC}"
    if systemctl list-unit-files 2>/dev/null | grep -q webhook; then
        if sudo systemctl is-active --quiet webhook 2>/dev/null; then
            echo -e "   ${GREEN}✓ PASS${NC} - Webhook service running"
            ((passed_checks++))
        else
            echo -e "   ${RED}✗ FAIL${NC} - Webhook service not running"
            ((failed_checks++))
            echo -e "   ${YELLOW}→ AUTO-FIX: Starting webhook...${NC}"
            if sudo systemctl start webhook 2>/dev/null; then
                sleep 2
                if sudo systemctl is-active --quiet webhook; then
                    echo -e "   ${GREEN}✓ FIXED${NC} - Webhook started"
                    ((auto_fixed++))
                else
                    echo -e "   ${RED}✗ FAILED TO FIX${NC} - Check: journalctl -u webhook"
                    ((manual_needed++))
                fi
            else
                ((manual_needed++))
            fi
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - Webhook service not installed"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 6: Application port responding
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[6/12] Checking application port...${NC}"
    local test_port="${APP_PORT:-3000}"
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$test_port" --max-time 5 2>/dev/null || echo "000")
    
    if [[ "$http_code" =~ ^(200|301|302|304|404|401|403)$ ]]; then
        echo -e "   ${GREEN}✓ PASS${NC} - Application responding on port $test_port (HTTP $http_code)"
        ((passed_checks++))
    else
        echo -e "   ${RED}✗ FAIL${NC} - Application not responding on port $test_port (HTTP $http_code)"
        ((failed_checks++))
        echo -e "   ${YELLOW}⚠ MANUAL ACTION NEEDED${NC} - Start your application"
        ((manual_needed++))
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 7: Git credentials
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[7/12] Checking Git credentials...${NC}"
    if [ -f "$HOME/.git-credentials" ]; then
        echo -e "   ${GREEN}✓ PASS${NC} - Git credentials file exists"
        ((passed_checks++))
        
        # Test git fetch
        if [ -d "$APP_DIR/.git" ]; then
            cd "$APP_DIR" 2>/dev/null
            if git fetch --dry-run 2>/dev/null; then
                echo -e "   ${GREEN}✓${NC} Git fetch test passed"
            else
                echo -e "   ${YELLOW}⚠ WARN${NC} - Git fetch test failed (credentials may be expired)"
            fi
        fi
    else
        echo -e "   ${YELLOW}⚠ WARN${NC} - Git credentials not configured"
        echo -e "   ${YELLOW}  Run full setup to configure Git credentials${NC}"
        ((passed_checks++))
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 8: Deploy script
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[8/12] Checking deploy script...${NC}"
    if [ -f "$APP_DIR/deploy.sh" ]; then
        if [ -x "$APP_DIR/deploy.sh" ]; then
            echo -e "   ${GREEN}✓ PASS${NC} - Deploy script exists and executable"
            ((passed_checks++))
        else
            echo -e "   ${YELLOW}⚠ WARN${NC} - Deploy script not executable"
            ((failed_checks++))
            echo -e "   ${YELLOW}→ AUTO-FIX: Making executable...${NC}"
            chmod +x "$APP_DIR/deploy.sh"
            echo -e "   ${GREEN}✓ FIXED${NC}"
            ((auto_fixed++))
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - No deploy script found"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 9: PM2 startup configuration
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[9/12] Checking PM2 startup...${NC}"
    if command_exists pm2; then
        if pm2 startup 2>&1 | grep -q "already"; then
            echo -e "   ${GREEN}✓ PASS${NC} - PM2 startup configured"
            ((passed_checks++))
        else
            echo -e "   ${YELLOW}⚠ WARN${NC} - PM2 startup may not be configured"
            ((failed_checks++))
            echo -e "   ${YELLOW}→ AUTO-FIX: Configuring PM2 startup...${NC}"
            local startup_cmd=$(pm2 startup systemd -u $USER --hp $HOME 2>&1 | grep 'sudo' | head -1)
            if [ -n "$startup_cmd" ]; then
                eval "$startup_cmd" 2>/dev/null
            fi
            pm2 save 2>/dev/null
            echo -e "   ${GREEN}✓ FIXED${NC} - PM2 startup configured"
            ((auto_fixed++))
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - PM2 not installed"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 10: Webhook hooks.json
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[10/12] Checking webhook configuration...${NC}"
    if [ -f "/etc/webhook/hooks.json" ]; then
        if jq empty /etc/webhook/hooks.json 2>/dev/null; then
            echo -e "   ${GREEN}✓ PASS${NC} - Webhook hooks.json is valid JSON"
            ((passed_checks++))
        else
            echo -e "   ${RED}✗ FAIL${NC} - hooks.json has invalid JSON"
            ((failed_checks++))
            ((manual_needed++))
        fi
    elif [ -f "$HOME/hooks.json" ]; then
        echo -e "   ${GREEN}✓ PASS${NC} - Using ~/hooks.json"
        ((passed_checks++))
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - No webhook configuration"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 11: Application directory
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[11/12] Checking application directory...${NC}"
    if [ -d "$APP_DIR" ]; then
        local file_count=$(ls -A "$APP_DIR" 2>/dev/null | wc -l)
        if [ "$file_count" -gt 0 ]; then
            echo -e "   ${GREEN}✓ PASS${NC} - App directory exists: $APP_DIR ($file_count files)"
            ((passed_checks++))
        else
            echo -e "   ${YELLOW}⚠ WARN${NC} - App directory empty"
            ((passed_checks++))
        fi
    else
        echo -e "   ${YELLOW}⊘ SKIP${NC} - App directory not set or doesn't exist"
    fi
    
    #---------------------------------------------------------------------------
    # CHECK 12: Memory and disk space
    #---------------------------------------------------------------------------
    ((total_checks++))
    echo -e "${CYAN}[12/12] Checking system resources...${NC}"
    
    # Check memory
    local mem_free=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
    local mem_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    if [ -n "$mem_free" ] && [ "$mem_free" -gt 100 ]; then
        echo -e "   ${GREEN}✓${NC} Memory OK: ${mem_free}MB available of ${mem_total}MB"
    elif [ -n "$mem_free" ]; then
        echo -e "   ${YELLOW}⚠${NC} Low memory: ${mem_free}MB available"
    fi
    
    # Check disk
    local disk_use=$(df -h / 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
    if [ -n "$disk_use" ]; then
        if [ "$disk_use" -lt 90 ]; then
            echo -e "   ${GREEN}✓ PASS${NC} - Disk usage: ${disk_use}%"
            ((passed_checks++))
        else
            echo -e "   ${RED}✗ FAIL${NC} - Disk almost full: ${disk_use}%"
            ((failed_checks++))
            ((manual_needed++))
        fi
    else
        ((passed_checks++))
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
        echo -e "${GREEN}  ✓ ALL CHECKS PASSED - APPLICATION IS HEALTHY                 ${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    elif [ $manual_needed -eq 0 ] && [ $auto_fixed -gt 0 ]; then
        echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ✓ ALL ISSUES AUTO-FIXED - APP SHOULD BE WORKING              ${NC}"
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
    print_section "Main Server Setup"
    
    load_existing_config
    
    # Show current status
    if [ -n "$APP_NAME" ]; then
        echo -e "${GREEN}Detected configuration:${NC}"
        echo -e "  App: $APP_NAME (port ${APP_PORT:-3000})"
        echo -e "  Backend: ${EXISTING_BACKEND:-'Not detected'}"
        echo -e "  Webhook: $WEBHOOK_STATUS"
        echo ""
    fi
    
    echo "What would you like to do?"
    echo ""
    echo "1. Quick Setup (Node.js with PM2)"
    echo "2. Multi-Backend Setup (Python, Java, Go, Rust, etc.)"
    echo "3. View current status"
    echo "4. Fix configuration (guided repair with prompts)"
    echo -e "${GREEN}5. Auto Debug (automatic check & fix everything)${NC}"
    echo "6. Restart services"
    echo "7. View logs"
    echo "8. Exit"
    echo ""
    echo -en "${CYAN}Select option [1]: ${NC}"
    read -r menu_choice
    menu_choice=${menu_choice:-1}
    
    case $menu_choice in
        1) quick_setup ;;
        2) setup_multibackend ;;
        3) view_status ;;
        4) fix_configuration ;;
        5) auto_debug ;;
        6) restart_services ;;
        7) view_logs ;;
        8) exit 0 ;;
        *) quick_setup ;;
    esac
}

quick_setup() {
    echo ""
    echo "This script will set up:"
    echo "  - Node.js ${NODE_VERSION}.x"
    echo "  - PM2 process manager"
    echo "  - Git credentials"
    echo "  - CI/CD auto-deploy pipeline"
    echo ""
    
    if ! confirm "Continue with setup?"; then
        show_menu
        return
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

#===============================================================================
# MAIN EXECUTION
#===============================================================================

main() {
    print_section "Main Server Setup Script"
    
    show_menu
}

main "$@"
