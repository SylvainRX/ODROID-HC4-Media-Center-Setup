#!/usr/bin/env bash
# =============================================================================
# 05_docker_install.sh - Install Docker Engine (bypassing OMV web UI)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/config.sh"

STEP_NAME="05_docker_install"

if is_done "$STEP_NAME"; then
    log "Docker already installed. Skipping."
    exit 0
fi

# -------------------------------------------------------------------------
# Fix broken OMV apt repository cache (known issue on DietPi + OMV)
# -------------------------------------------------------------------------
# The OMV archive cache at /var/cache/openmediavault/archives/ may have
# broken or missing Packages files, causing apt-get update to fail silently
# and preventing Docker from installing.

log_step "Cleaning up apt cache (fixes OMV repo issues)..."
if [[ -d /var/cache/openmediavault/archives ]]; then
    # Ensure the Packages file exists (empty is valid if no local packages)
    if [[ ! -f /var/cache/openmediavault/archives/Packages ]]; then
        run touch /var/cache/openmediavault/archives/Packages
        log "Created missing /var/cache/openmediavault/archives/Packages"
    fi
fi

# Clean apt's partial downloads that may be broken
run rm -rf /var/lib/apt/lists/partial
run mkdir -p /var/lib/apt/lists/partial

# -------------------------------------------------------------------------
# Install apparmor workaround (prevents generic errors with Docker/Portainer)
# -------------------------------------------------------------------------

log_step "Installing apparmor packages (Docker prerequisite)..."
run apt-get update
run apt-get install -y apparmor apparmor-utils auditd

# -------------------------------------------------------------------------
# Install Docker
# -------------------------------------------------------------------------

if command -v docker &>/dev/null; then
    log "Docker is already installed: $(docker --version)"
else
    log_step "Installing Docker via official Docker APT repository..."

    # Install prerequisites
    run apt-get install -y ca-certificates curl gnupg

    # Add Docker's official GPG key
    run install -m 0755 -d /etc/apt/keyrings
    if [[ "$DRY_RUN" != "true" ]]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    else
        log "[DRY RUN] Would download Docker GPG key"
    fi

    # Detect architecture and codename
    local_arch="$(dpkg --print-architecture)"
    local_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    log "Detected architecture: ${local_arch}, codename: ${local_codename}"

    # Add Docker repository
    if [[ "$DRY_RUN" != "true" ]]; then
        echo "deb [arch=${local_arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${local_codename} stable" \
            > /etc/apt/sources.list.d/docker.list
    else
        log "[DRY RUN] Would add Docker repository"
    fi

    # Update apt cache with new repository
    log_step "Updating apt cache with Docker repository..."
    run apt-get update

    # Install Docker packages (with visible output so errors are seen)
    log_step "Installing Docker packages (this may take a few minutes)..."
    run apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    # Verify install actually worked
    if [[ "$DRY_RUN" != "true" ]]; then
        if ! command -v docker &>/dev/null; then
            log_error "Docker install reported success but 'docker' command is not available."
            log_error "Check /var/log/apt/ for errors."
            exit 1
        fi
        log "Docker installed: $(docker --version)"
    fi
fi

# -------------------------------------------------------------------------
# Verify Docker Compose plugin
# -------------------------------------------------------------------------

if [[ "$DRY_RUN" != "true" ]]; then
    if docker compose version &>/dev/null 2>&1; then
        log "Docker Compose plugin is available: $(docker compose version)"
    else
        log_warn "Docker Compose plugin not detected. Attempting to install..."
        run apt-get install -y docker-compose-plugin
        if ! docker compose version &>/dev/null 2>&1; then
            log_error "Docker Compose plugin installation failed."
            exit 1
        fi
        log "Docker Compose plugin installed: $(docker compose version)"
    fi
fi

# -------------------------------------------------------------------------
# Configure Docker daemon DNS (fallback for container registry access)
# -------------------------------------------------------------------------

log_step "Configuring Docker daemon DNS..."

if [[ "$DRY_RUN" != "true" ]]; then
    # Backup existing daemon.json if it exists
    if [[ -f /etc/docker/daemon.json ]]; then
        backup_file /etc/docker/daemon.json
    fi
    
    # Create /etc/docker/daemon.json with DNS configuration
    # This ensures Docker containers can resolve external registries
    # even when running behind a VPN or with restrictive network setups
    cat > /etc/docker/daemon.json << 'EOF'
{
  "dns": [
    "8.8.8.8",
    "8.8.4.4",
    "1.1.1.1",
    "1.0.0.1"
  ]
}
EOF
    log "Configured /etc/docker/daemon.json with public DNS servers"
else
    log "[DRY RUN] Would configure Docker daemon DNS in /etc/docker/daemon.json"
fi

# -------------------------------------------------------------------------
# Enable and start Docker service
# -------------------------------------------------------------------------

log_step "Enabling Docker service..."
if [[ "$DRY_RUN" != "true" ]]; then
    # Verify the unit file exists before enabling
    if ! systemctl list-unit-files docker.service &>/dev/null; then
        log_error "docker.service unit file not found. Docker package did not install correctly."
        log_error "Try: sudo apt-get install --reinstall docker-ce"
        exit 1
    fi

    systemctl enable --now docker.service

    # Give Docker a moment to start
    sleep 3

    if docker info &>/dev/null; then
        log "Docker is running: $(docker --version)"
    else
        log_error "Docker does not appear to be running. Check 'systemctl status docker'."
        exit 1
    fi
else
    log "[DRY RUN] Would enable and start docker.service"
fi

mark_done "$STEP_NAME"
log "Docker installation complete."
