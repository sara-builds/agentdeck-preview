#!/bin/bash
# AgentPen VPS Install Script
# Usage: curl -fsSL https://agentpen.io/install.sh | bash
#
# What this does:
# 1. Installs Docker if not present
# 2. Installs Node.js 22 if not present  
# 3. Installs OpenClaw globally
# 4. Creates agent workspace structure
# 5. Starts AgentPen backend container

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() { echo -e "${CYAN}[AgentPen]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "Please run as root (use sudo)"
fi

log "Starting AgentPen installation..."

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    error "Cannot detect OS. Only Ubuntu/Debian supported."
fi

log "Detected OS: $OS $VERSION"

# ============ Docker Installation ============
install_docker() {
    if command -v docker &> /dev/null; then
        success "Docker already installed: $(docker --version)"
        return
    fi
    
    log "Installing Docker..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    # Update and install prerequisites
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    
    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $(. /etc/os-release && echo $VERSION_CODENAME) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Enable and start Docker
    systemctl enable docker
    systemctl start docker
    
    success "Docker installed successfully"
}

# ============ Node.js Installation ============
install_nodejs() {
    if command -v node &> /dev/null; then
        NODE_VERSION=$(node --version)
        success "Node.js already installed: $NODE_VERSION"
        return
    fi
    
    log "Installing Node.js 22..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    # Install Node.js 22 via NodeSource
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs
    
    success "Node.js installed: $(node --version)"
}

# ============ OpenClaw Installation ============
install_openclaw() {
    if command -v openclaw &> /dev/null; then
        success "OpenClaw already installed"
        return
    fi
    
    log "Installing OpenClaw..."
    
    npm install -g openclaw
    
    success "OpenClaw installed"
}

# ============ Directory Setup ============
setup_directories() {
    log "Setting up directories..."
    
    mkdir -p /opt/agentpen/agents
    mkdir -p /opt/agentpen/data
    
    success "Directories created"
}

# ============ Docker Compose Setup ============
setup_backend() {
    log "Setting up AgentPen backend..."
    
    cd /opt/agentpen
    
    # Create docker-compose.yml
    cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  backend:
    image: ghcr.io/sara-builds/agent-deck-backend:latest
    container_name: agentpen-api
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /opt/agentpen/agents:/opt/agentpen/agents
      - /opt/agentpen/data:/app/data
    environment:
      - SPRING_PROFILES_ACTIVE=prod
      - AGENTPEN_AGENTS_PATH=/opt/agentpen/agents
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/api/health"]
      interval: 30s
      timeout: 3s
      retries: 3
EOF

    # Pull and start
    docker compose pull
    docker compose up -d
    
    success "Backend started"
}

# ============ Create Default Agent ============
create_default_agent() {
    local agent_name="${1:-my-agent}"
    
    log "Creating agent: $agent_name"
    
    mkdir -p "/opt/agentpen/agents/$agent_name/memory"
    cd "/opt/agentpen/agents/$agent_name"
    
    # Create workspace files
    cat > SOUL.md << 'EOF'
# SOUL.md - Who You Are

You are a helpful AI assistant.
EOF

    cat > MEMORY.md << 'EOF'
# MEMORY.md - Long-Term Memory

*Your memories will be stored here.*
EOF

    cat > AGENTS.md << 'EOF'
# AGENTS.md - Workspace Guidelines

Follow the patterns established in this workspace.
EOF

    touch TOOLS.md
    
    # Initialize OpenClaw if available
    if command -v openclaw &> /dev/null; then
        openclaw init . --name "$agent_name" 2>/dev/null || true
    fi
    
    success "Agent workspace created: $agent_name"
}

# ============ Configure Telegram ============
configure_telegram() {
    local agent_name="$1"
    local bot_token="$2"
    
    if [ -z "$bot_token" ]; then
        warn "No Telegram token provided, skipping Telegram setup"
        return
    fi
    
    log "Configuring Telegram for $agent_name..."
    
    cd "/opt/agentpen/agents/$agent_name"
    
    cat > gateway.yml << EOF
agent: $agent_name
channels:
  telegram:
    enabled: true
    token: $bot_token
model:
  provider: anthropic
  model: claude-sonnet-4-20250514
EOF

    success "Telegram configured"
}

# ============ Start Agent ============
start_agent() {
    local agent_name="$1"
    
    log "Starting agent: $agent_name"
    
    cd "/opt/agentpen/agents/$agent_name"
    
    # Start OpenClaw gateway as systemd service or background process
    if command -v openclaw &> /dev/null; then
        nohup openclaw gateway start > /var/log/openclaw-$agent_name.log 2>&1 &
        success "Agent started (PID: $!)"
    else
        warn "OpenClaw not found, agent not started"
    fi
}

# ============ Main ============
main() {
    local agent_name="${AGENT_NAME:-my-agent}"
    local telegram_token="${TELEGRAM_TOKEN:-}"
    
    echo ""
    echo "╔═══════════════════════════════════════╗"
    echo "║        AgentPen VPS Installer         ║"
    echo "╚═══════════════════════════════════════╝"
    echo ""
    
    install_docker
    install_nodejs
    install_openclaw
    setup_directories
    setup_backend
    create_default_agent "$agent_name"
    
    if [ -n "$telegram_token" ]; then
        configure_telegram "$agent_name" "$telegram_token"
        start_agent "$agent_name"
    fi
    
    echo ""
    echo "╔═══════════════════════════════════════╗"
    echo "║      Installation Complete! 🎉        ║"
    echo "╚═══════════════════════════════════════╝"
    echo ""
    echo "Backend running at: http://$(hostname -I | awk '{print $1}'):8080"
    echo "Agent workspace:    /opt/agentpen/agents/$agent_name"
    echo ""
    
    if [ -z "$telegram_token" ]; then
        echo "To connect Telegram, edit:"
        echo "  /opt/agentpen/agents/$agent_name/gateway.yml"
        echo ""
    fi
}

main "$@"
