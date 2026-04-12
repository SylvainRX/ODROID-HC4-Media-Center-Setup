#!/usr/bin/env bash
# =============================================================================
# 04_nordvpn.sh - Install and configure NordVPN
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/config.sh"

STEP_NAME="04_nordvpn"

if is_done "$STEP_NAME"; then
    log "NordVPN already configured. Skipping."
    exit 0
fi

# Sub-steps for granular control
SUBSTEP_INSTALL="${STEP_NAME}_install"
SUBSTEP_LOGIN="${STEP_NAME}_login"
SUBSTEP_WHITELIST="${STEP_NAME}_whitelist"
SUBSTEP_CONNECT="${STEP_NAME}_connect"
SUBSTEP_AUTOCONNECT="${STEP_NAME}_autoconnect"
SUBSTEP_DNS="${STEP_NAME}_dns"

# Skip entirely if no token is provided
if [[ -z "${NORDVPN_TOKEN:-}" ]]; then
    log_warn "NORDVPN_TOKEN not set in config.sh. Skipping NordVPN setup."
    log_warn "You can set it later and re-run: sudo ./setup.sh --reset 03 && sudo ./setup.sh --from 03"
    mark_done "$STEP_NAME"
    exit 0
fi

# -------------------------------------------------------------------------
# Install NordVPN
# -------------------------------------------------------------------------

if ! is_done "$SUBSTEP_INSTALL"; then
    log_step "Installing NordVPN..."
    
    if command -v nordvpn &>/dev/null; then
        log "NordVPN is already installed. Skipping installation."
    else
        # Clean up APT cache to avoid "Read error - read (21: Is a directory)" errors
        # This is a known issue with OpenMediaVault's local APT cache
        log "Cleaning APT cache before installation..."
        if [[ "$DRY_RUN" != "true" ]]; then
            apt-get clean 2>/dev/null || true
            rm -rf /var/cache/openmediavault/archives/Packages 2>/dev/null || true
        fi
        
        run_pipe "sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)"
    fi
    
    mark_done "$SUBSTEP_INSTALL"
else
    log "NordVPN installation already complete. Skipping."
fi

# -------------------------------------------------------------------------
# Login
# -------------------------------------------------------------------------

if ! is_done "$SUBSTEP_LOGIN"; then
    log_step "Logging in to NordVPN..."
    
    # Check if already logged in
    if nordvpn account &>/dev/null 2>&1; then
        log "Already logged in to NordVPN."
    else
        run nordvpn login --token "$NORDVPN_TOKEN"
    fi
    
    mark_done "$SUBSTEP_LOGIN"
else
    log "NordVPN login already complete. Skipping."
fi

# -------------------------------------------------------------------------
# Whitelist local subnet
# -------------------------------------------------------------------------

if ! is_done "$SUBSTEP_WHITELIST"; then
    log_step "Detecting local subnet and whitelisting it..."
    
    SUBNET="$(detect_subnet)"
    if [[ -n "$SUBNET" ]]; then
        log "Detected subnet: ${SUBNET}"
        
        # Check if subnet is already whitelisted
        if nordvpn whitelist list 2>/dev/null | grep -q "$SUBNET"; then
            log "Subnet ${SUBNET} is already whitelisted."
        else
            run nordvpn whitelist add subnet "$SUBNET"
        fi
    else
        log_error "Could not detect subnet. You may need to add it manually:"
        log_error "  nordvpn whitelist add subnet <your-subnet>"
    fi
    
    mark_done "$SUBSTEP_WHITELIST"
else
    log "NordVPN whitelist already configured. Skipping."
fi

# -------------------------------------------------------------------------
# Connect to P2P server
# -------------------------------------------------------------------------

if ! is_done "$SUBSTEP_CONNECT"; then
    log_step "Connecting to P2P server..."
    
    run nordvpn connect P2P
    
    # Verify connection
    if [[ "$DRY_RUN" != "true" ]]; then
        sleep 3
        if nordvpn status | grep -q "Connected"; then
            log "Successfully connected to NordVPN P2P server."
        else
            log_warn "NordVPN does not appear to be connected. Check 'nordvpn status'."
        fi
    fi
    
    mark_done "$SUBSTEP_CONNECT"
else
    log "NordVPN P2P connection already established. Skipping."
fi

# -------------------------------------------------------------------------
# Set auto-connect
# -------------------------------------------------------------------------

if ! is_done "$SUBSTEP_AUTOCONNECT"; then
    log_step "Configuring auto-connect..."
    
    if [[ "$DRY_RUN" != "true" ]]; then
        # Extract server hostname from nordvpn status (e.g. "ca1628.nordvpn.com")
        SERVER_ID="$(nordvpn status | grep -oP '(?<=Hostname:\s)[\w.]+' || echo "")"
        # Fallback: try the server name field
        if [[ -z "$SERVER_ID" ]]; then
            SERVER_ID="$(nordvpn status | grep -i 'server' | head -1 | awk '{print $NF}' || echo "")"
        fi
    
        if [[ -n "$SERVER_ID" ]]; then
            # Extract just the server ID (e.g., "ca1887" from "ca1887.nordvpn.com")
            SERVER_ID="${SERVER_ID%.nordvpn.com}"
            log "Setting auto-connect to server: ${SERVER_ID}"
            nordvpn set autoconnect on "$SERVER_ID"
        else
            log_warn "Could not detect server ID. Setting generic P2P auto-connect."
            nordvpn set autoconnect on P2P
        fi
    else
        log "[DRY RUN] Would set auto-connect to current P2P server"
    fi
    
    mark_done "$SUBSTEP_AUTOCONNECT"
else
    log "NordVPN auto-connect already configured. Skipping."
fi

# -------------------------------------------------------------------------
# Configure DNS fallback for Docker and system-wide resolution
# -------------------------------------------------------------------------
#
# NordVPN's DNS servers (103.86.x.x) are only reliably accessible through
# the VPN tunnel. Docker's isolated networking can struggle to reach them.
# Adding public DNS servers as fallback ensures Docker containers (and the
# system) can resolve domains even if NordVPN's DNS has issues.
#

if ! is_done "$SUBSTEP_DNS"; then
    log_step "Configuring DNS fallback servers..."
    
    RESOLVED_CONF="/etc/systemd/resolved.conf"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        # Backup the original config
        backup_file "$RESOLVED_CONF"
        
        # Check if [Resolve] section exists
        if grep -q "^\[Resolve\]" "$RESOLVED_CONF"; then
            # Update existing [Resolve] section
            # First, comment out any existing DNS= or FallbackDNS= lines
            sed -i '/^\[Resolve\]/,/^\[/ {
                /^DNS=/s/^/#/
                /^FallbackDNS=/s/^/#/
            }' "$RESOLVED_CONF"
            
            # Add our DNS configuration right after [Resolve]
            sed -i '/^\[Resolve\]/a\
DNS=8.8.8.8 8.8.4.4\
FallbackDNS=1.1.1.1 1.0.0.1\
Domains=~.' "$RESOLVED_CONF"
        else
            # If no [Resolve] section, append it
            cat >> "$RESOLVED_CONF" << EOF

[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1 1.0.0.1
Domains=~.
EOF
        fi
        
        # Restart systemd-resolved to apply changes
        systemctl restart systemd-resolved
        sleep 2
        
        # Verify DNS resolution works
        if resolvectl query ghcr.io &>/dev/null; then
            log "DNS configuration successful. ghcr.io resolves correctly."
        else
            log_warn "DNS configuration completed but ghcr.io resolution failed. Check /var/log/odroid-setup.log"
        fi
    else
        log "[DRY RUN] Would configure DNS fallback in ${RESOLVED_CONF}"
    fi
    
    mark_done "$SUBSTEP_DNS"
else
    log "DNS fallback configuration already complete. Skipping."
fi

mark_done "$STEP_NAME"
log "NordVPN setup complete."
