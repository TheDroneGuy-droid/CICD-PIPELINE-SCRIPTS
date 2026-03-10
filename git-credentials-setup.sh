#!/bin/bash
#===============================================================================
# GIT CREDENTIALS SETUP SCRIPT
# Purpose: Configure global Git credentials using PAT from github_token.txt
# Usage: Run this script and enter your GitHub username when prompted
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
TOKEN_FILE="$SCRIPT_DIR/github_token.txt"

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

print_header() {
    echo -e "\n${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

#===============================================================================
# MAIN SCRIPT
#===============================================================================

print_header "Git Credentials Setup"

# Check if token file exists
if [ ! -f "$TOKEN_FILE" ]; then
    print_error "Token file not found: $TOKEN_FILE"
    echo -e "${YELLOW}Please create github_token.txt with your Personal Access Token${NC}"
    exit 1
fi

# Read the PAT from file
GITHUB_TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')

if [ -z "$GITHUB_TOKEN" ]; then
    print_error "Token file is empty"
    exit 1
fi

print_success "Token file found and loaded"

# Prompt for username
echo -e "${YELLOW}Enter your GitHub username:${NC}"
read -r GITHUB_USERNAME

if [ -z "$GITHUB_USERNAME" ]; then
    print_error "Username cannot be empty"
    exit 1
fi

print_info "Configuring Git credentials for user: $GITHUB_USERNAME"

# Set global Git configuration
git config --global user.name "$GITHUB_USERNAME"
print_success "Set global user.name"

# Prompt for email (optional but recommended)
echo -e "${YELLOW}Enter your GitHub email (press Enter to skip):${NC}"
read -r GITHUB_EMAIL

if [ -n "$GITHUB_EMAIL" ]; then
    git config --global user.email "$GITHUB_EMAIL"
    print_success "Set global user.email"
fi

# Configure credential helper to store credentials
git config --global credential.helper store
print_success "Configured credential helper (store)"

# Create/update the credentials file
CREDENTIALS_FILE="$HOME/.git-credentials"
# Remove existing GitHub entries
if [ -f "$CREDENTIALS_FILE" ]; then
    grep -v "github.com" "$CREDENTIALS_FILE" > "$CREDENTIALS_FILE.tmp" 2>/dev/null || true
    mv "$CREDENTIALS_FILE.tmp" "$CREDENTIALS_FILE"
fi

# Add new GitHub credentials
echo "https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com" >> "$CREDENTIALS_FILE"
chmod 600 "$CREDENTIALS_FILE"
print_success "Stored GitHub credentials in ~/.git-credentials"

# Verify configuration
print_header "Configuration Summary"
echo -e "Username:    ${GREEN}$GITHUB_USERNAME${NC}"
if [ -n "$GITHUB_EMAIL" ]; then
    echo -e "Email:       ${GREEN}$GITHUB_EMAIL${NC}"
fi
echo -e "Token:       ${GREEN}****${GITHUB_TOKEN: -4}${NC} (last 4 chars)"
echo -e "Credentials: ${GREEN}$CREDENTIALS_FILE${NC}"

print_header "Setup Complete!"
echo -e "${GREEN}You can now clone, pull, and push to GitHub repositories without entering credentials.${NC}"
echo ""
echo -e "${YELLOW}Test with:${NC} git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git"
