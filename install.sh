#!/usr/bin/env bash
##############################################################################
# Anyrest — One-Command Installer
#
# Installs the Anyrest server stack (signaling + relay + web UI) and
# optionally the desktop agent on the local machine.
#
# Usage:
#   curl -fsSL https://<your-server>/install.sh | bash
#   ./install.sh [options]
#
# Options:
#   --server-only      Install server stack only (default if no flag)
#   --agent-only       Install desktop agent only
#   --full             Install both server and agent
#   --signal-url URL   Signaling server URL for the agent
#                      (default: wss://localhost/ws)
#   --relay-secret S   Shared HMAC secret (auto-generated if omitted)
#   --no-cert-install  Skip installing CA into the system trust store
#   --dir DIR          Installation directory (default: /opt/anyrest)
#   --uninstall        Remove Anyrest from this machine
##############################################################################
set -euo pipefail

##############################################################################
# Colour helpers
##############################################################################
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[anyrest]${RESET} $*"; }
success() { echo -e "${GREEN}[anyrest]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[anyrest]${RESET} $*"; }
die()     { echo -e "${RED}[anyrest] ERROR:${RESET} $*" >&2; exit 1; }
hr()      { echo -e "${BOLD}──────────────────────────────────────────────────${RESET}"; }

##############################################################################
# Defaults
##############################################################################
MODE="server"          # server | agent | full
SIGNAL_URL="wss://localhost/ws"
RELAY_SECRET=""
INSTALL_CERTS=true
INSTALL_DIR="/opt/anyrest"
REPO_URL="https://github.com/mintfary-oss/Anyrest.git"
UNINSTALL=false

##############################################################################
# Argument parsing
##############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-only)      MODE="server";             shift ;;
    --agent-only)       MODE="agent";              shift ;;
    --full)             MODE="full";               shift ;;
    --signal-url)       SIGNAL_URL="$2";           shift 2 ;;
    --relay-secret)     RELAY_SECRET="$2";         shift 2 ;;
    --no-cert-install)  INSTALL_CERTS=false;        shift ;;
    --dir)              INSTALL_DIR="$2";           shift 2 ;;
    --uninstall)        UNINSTALL=true;             shift ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!' | sed 's/^# *//' | head -25
      exit 0
      ;;
    *)
      die "Unknown option: $1  (use --help for usage)"
      ;;
  esac
done

##############################################################################
# OS detection
##############################################################################
detect_os() {
  case "$(uname -s)" in
    Linux)
      if   [[ -f /etc/debian_version ]]; then DISTRO="debian"
      elif [[ -f /etc/redhat-release ]]; then DISTRO="rhel"
      elif [[ -f /etc/alpine-release ]]; then DISTRO="alpine"
      else                                    DISTRO="linux"
      fi
      OS="linux"
      ;;
    Darwin) OS="macos"; DISTRO="macos" ;;
    MINGW*|CYGWIN*|MSYS*) OS="windows"; DISTRO="windows" ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
  info "Detected OS: $OS ($DISTRO)"
}

##############################################################################
# Privilege check
##############################################################################
require_sudo() {
  if [[ "$EUID" -ne 0 ]]; then
    if command -v sudo &>/dev/null; then
      SUDO="sudo"
    else
      die "This step requires root. Run as root or install sudo."
    fi
  else
    SUDO=""
  fi
}

##############################################################################
# Docker installation
##############################################################################
install_docker() {
  if command -v docker &>/dev/null; then
    info "Docker $(docker --version | awk '{print $3}' | tr -d ',') already installed."
    return
  fi
  info "Installing Docker..."
  case "$DISTRO" in
    debian)
      $SUDO apt-get update -qq
      $SUDO apt-get install -y -qq ca-certificates curl gnupg lsb-release
      $SUDO install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
      $SUDO apt-get update -qq
      $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
      ;;
    rhel)
      $SUDO yum install -y -q yum-utils
      $SUDO yum-config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo
      $SUDO yum install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
      $SUDO systemctl enable --now docker
      ;;
    alpine)
      $SUDO apk add --no-cache docker docker-compose
      $SUDO rc-update add docker default
      $SUDO service docker start
      ;;
    macos)
      if command -v brew &>/dev/null; then
        brew install --cask docker
      else
        die "Install Docker Desktop manually from https://docs.docker.com/desktop/mac/install/"
      fi
      ;;
    *)
      # Generic: use Docker's get.docker.com convenience script
      curl -fsSL https://get.docker.com | $SUDO bash
      ;;
  esac
  success "Docker installed."
}

##############################################################################
# Install required tools
##############################################################################
install_tools() {
  local missing=()
  command -v git     &>/dev/null || missing+=("git")
  command -v openssl &>/dev/null || missing+=("openssl")
  [[ ${#missing[@]} -eq 0 ]] && return

  info "Installing missing tools: ${missing[*]}"
  case "$DISTRO" in
    debian)  $SUDO apt-get install -y -qq "${missing[@]}" ;;
    rhel)    $SUDO yum install -y -q     "${missing[@]}" ;;
    alpine)  $SUDO apk add --no-cache    "${missing[@]}" ;;
    macos)   brew install                "${missing[@]}" ;;
    *) warn "Please install manually: ${missing[*]}" ;;
  esac
}

##############################################################################
# Clone or update the repository
##############################################################################
fetch_source() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing installation at $INSTALL_DIR..."
    git -C "$INSTALL_DIR" pull --ff-only
  elif [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    info "Using existing files at $INSTALL_DIR (no git clone)."
  else
    info "Cloning Anyrest into $INSTALL_DIR..."
    $SUDO mkdir -p "$INSTALL_DIR"
    $SUDO chown "$(id -u):$(id -g)" "$INSTALL_DIR" 2>/dev/null || true
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  fi
}

##############################################################################
# Generate certificates
##############################################################################
generate_certificates() {
  local cert_dir="$INSTALL_DIR/certs"
  mkdir -p "$cert_dir"

  if [[ -f "$cert_dir/server.crt" && -f "$cert_dir/server.key" ]]; then
    info "Certificates already exist — skipping generation."
    info "  (Delete $cert_dir/*.crt and *.key to regenerate)"
    return
  fi

  info "Generating TLS certificates with IP SANs..."
  bash "$INSTALL_DIR/certs/gen-certs.sh" \
    --out "$cert_dir" \
    ${INSTALL_CERTS:+--install} 2>&1 || true

  # The gen-certs.sh installs the CA as a side effect; trust store refresh
  if [[ "$INSTALL_CERTS" == "true" ]]; then
    refresh_trust_store
  else
    warn "CA certificate NOT installed into system trust store."
    warn "Add $cert_dir/ca.crt manually to trust Anyrest HTTPS."
  fi
}

##############################################################################
# Install CA into browser trust stores
##############################################################################
refresh_trust_store() {
  local cert_dir="$INSTALL_DIR/certs"
  [[ -f "$cert_dir/ca.crt" ]] || return

  # Chrome / Chromium on Linux use the NSS shared database
  if command -v certutil &>/dev/null; then
    for nssdb in \
        "$HOME/.pki/nssdb" \
        "${HOME}/.mozilla/firefox/"*; do
      if [[ -d "$nssdb" ]]; then
        certutil -A -d "sql:$nssdb" -n "Anyrest Root CA" -t "CT,," \
          -i "$cert_dir/ca.crt" 2>/dev/null && \
          info "CA installed into NSS: $nssdb"
      fi
    done
  fi

  # Refresh system store
  case "$DISTRO" in
    debian)
      [[ -f "$cert_dir/ca.crt" ]] && \
        $SUDO cp "$cert_dir/ca.crt" /usr/local/share/ca-certificates/anyrest-ca.crt
      $SUDO update-ca-certificates --fresh 2>/dev/null || true
      ;;
    rhel)
      [[ -f "$cert_dir/ca.crt" ]] && \
        $SUDO cp "$cert_dir/ca.crt" /etc/pki/ca-trust/source/anchors/anyrest-ca.crt
      $SUDO update-ca-trust extract 2>/dev/null || true
      ;;
    macos)
      $SUDO security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain "$cert_dir/ca.crt" 2>/dev/null || true
      ;;
  esac
  success "CA certificate installed — browsers will trust Anyrest HTTPS."
}

##############################################################################
# Write .env file
##############################################################################
write_env() {
  local env_file="$INSTALL_DIR/.env"
  [[ -f "$env_file" ]] && { info ".env already exists — not overwriting."; return; }

  if [[ -z "$RELAY_SECRET" ]]; then
    RELAY_SECRET="$(openssl rand -hex 32)"
  fi

  cat > "$env_file" <<EOF
# Anyrest environment — generated by install.sh on $(date)
RELAY_SECRET=${RELAY_SECRET}
ANYREST_SIGNAL_URL=${SIGNAL_URL}
EOF
  $SUDO chmod 600 "$env_file"
  success ".env written to $env_file"
}

##############################################################################
# Start the server stack
##############################################################################
start_server() {
  info "Starting Anyrest server stack..."
  cd "$INSTALL_DIR"

  docker compose build --quiet 2>&1
  docker compose up -d

  success "Server stack started."
  print_server_urls
}

##############################################################################
# Install and start the agent
##############################################################################
install_agent_binary() {
  info "Building Anyrest agent..."
  cd "$INSTALL_DIR"

  docker compose -f docker-compose.agent.yml build --quiet 2>&1

  if [[ "$OS" == "linux" ]] && command -v systemctl &>/dev/null; then
    install_agent_systemd
  else
    info "Starting agent via Docker..."
    ANYREST_SIGNAL_URL="$SIGNAL_URL" \
      docker compose -f docker-compose.agent.yml up -d
    success "Agent started. It will reconnect automatically on reboot."
  fi
}

install_agent_systemd() {
  local unit=/etc/systemd/system/anyrest-agent.service
  info "Installing anyrest-agent as a systemd service..."

  $SUDO tee "$unit" > /dev/null <<UNIT
[Unit]
Description=Anyrest Desktop Agent
After=network-online.target graphical.target
Wants=network-online.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5
Environment="DISPLAY=:0"
Environment="ANYREST_SIGNAL_URL=${SIGNAL_URL}"
ExecStart=/usr/bin/docker compose \\
  -f ${INSTALL_DIR}/docker-compose.agent.yml \\
  up --no-recreate
ExecStop=/usr/bin/docker compose \\
  -f ${INSTALL_DIR}/docker-compose.agent.yml \\
  down
WorkingDirectory=${INSTALL_DIR}

[Install]
WantedBy=graphical.target
UNIT

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now anyrest-agent.service
  success "Agent systemd service installed and started."
}

##############################################################################
# Uninstall
##############################################################################
uninstall() {
  warn "Uninstalling Anyrest..."
  cd "$INSTALL_DIR" 2>/dev/null || true

  # Stop containers
  docker compose down --volumes 2>/dev/null || true
  docker compose -f docker-compose.agent.yml down 2>/dev/null || true

  # Remove systemd service
  if [[ "$OS" == "linux" ]] && command -v systemctl &>/dev/null; then
    $SUDO systemctl disable --now anyrest-agent.service 2>/dev/null || true
    $SUDO rm -f /etc/systemd/system/anyrest-agent.service
    $SUDO systemctl daemon-reload
  fi

  # Remove CA certificate
  $SUDO rm -f /usr/local/share/ca-certificates/anyrest-ca.crt
  $SUDO rm -f /etc/pki/ca-trust/source/anchors/anyrest-ca.crt
  $SUDO update-ca-certificates 2>/dev/null || true
  $SUDO update-ca-trust 2>/dev/null || true

  # Remove Docker images
  docker image rm anyrest-signal anyrest-relay anyrest-web anyrest-agent 2>/dev/null || true

  # Remove install directory (ask first)
  read -rp "Remove $INSTALL_DIR? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    $SUDO rm -rf "$INSTALL_DIR"
    success "Anyrest removed from $INSTALL_DIR"
  fi
  success "Uninstall complete."
}

##############################################################################
# Print access URLs
##############################################################################
print_server_urls() {
  local host
  host=$(hostname -I 2>/dev/null | awk '{print $1}') || host="localhost"

  hr
  success "Anyrest is running!"
  echo ""
  echo -e "  Web UI:     ${BOLD}https://${host}${RESET}"
  echo -e "  Web UI:     ${BOLD}https://localhost${RESET}"
  echo ""
  echo -e "  Relay:      ${BOLD}${host}:8081${RESET} (for agent P2P fallback)"
  echo ""
  echo -e "  Agent cmd:"
  echo -e "  ${CYAN}./install.sh --agent-only --signal-url wss://${host}/ws${RESET}"
  echo ""
  warn "First-time setup: import certs/ca.crt into your browser to trust HTTPS."
  warn "  Chrome: Settings → Privacy → Manage Certs → Authorities → Import"
  warn "  Firefox: Settings → Privacy → View Certs → Authorities → Import"
  hr
}

##############################################################################
# Main
##############################################################################
main() {
  hr
  echo -e "${BOLD}  Anyrest Installer — self-hosted remote desktop${RESET}"
  hr

  if [[ "$UNINSTALL" == "true" ]]; then
    require_sudo
    detect_os
    uninstall
    exit 0
  fi

  detect_os
  require_sudo
  install_tools
  install_docker

  case "$MODE" in
    server)
      fetch_source
      generate_certificates
      write_env
      start_server
      ;;
    agent)
      fetch_source
      write_env
      install_agent_binary
      ;;
    full)
      fetch_source
      generate_certificates
      write_env
      start_server
      install_agent_binary
      ;;
  esac

  success "Done!"
}

main
