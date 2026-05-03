#!/usr/bin/env bash
# =============================================================================
# 08_nginx_reverse_proxy.sh - Configure nginx reverse proxy with path-based routing
#
# This step:
#   1. Reconfigures OpenMediaVault to listen on port 8080
#   2. Installs and configures nginx on port 80
#   3. Sets up path-based routing for all services
#   4. Configures base URLs for each service (Jellyfin, Sonarr, Radarr, etc.)
#   5. Restarts services to apply changes
#
# After this step, services are accessible via:
#   /omv         -> OpenMediaVault (port 8080)
#   /jellyfin    -> Jellyfin (port 8096)
#   /sonarr      -> Sonarr (port 8989)
#   /radarr      -> Radarr (port 7878)
#   /prowlarr    -> Prowlarr (port 9696)
#   /transmission -> Transmission (port 9091)
#
# Note: FlareSolverr (port 8191) is API-only and accessed directly by Prowlarr
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/config.sh"

STEP_NAME="08_nginx_reverse_proxy"

if is_done "$STEP_NAME"; then
    log "Nginx reverse proxy already configured. Skipping."
    exit 0
fi

DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/home/dietpi/Docker}"
NGINX_CONFIG="/etc/nginx/sites-available/media-center"
NGINX_ENABLED="/etc/nginx/sites-enabled/media-center"

# Track configuration successes and failures
declare -A SERVICE_STATUS
SERVICES=("sonarr" "radarr" "prowlarr" "jellyfin" "transmission")

# -------------------------------------------------------------------------
# Helper Functions for Service Configuration
# -------------------------------------------------------------------------

# Configure Jellyfin base URL via API (with config file fallback)
configure_jellyfin_base_url() {
    local api_attempt=false
    local config_attempt=false
    
    log_step "Configuring Jellyfin base URL..."
    
    # Attempt 1: Try API approach
    local jellyfin_config
    jellyfin_config=$(curl -s -X GET "http://localhost:8096/System/Configuration" 2>/dev/null || echo "{}")
    
    if [[ "$jellyfin_config" != "{}" ]] && [[ -n "$jellyfin_config" ]]; then
        # API returned something, try to update
        local updated_config
        updated_config=$(echo "$jellyfin_config" | jq '. + {"BaseUrl": "/jellyfin"}' 2>/dev/null || echo "")
        
        if [[ -n "$updated_config" ]]; then
            local response
            response=$(curl -s -w "\n%{http_code}" -X POST "http://localhost:8096/System/Configuration" \
                -H "Content-Type: application/json" \
                -d "$updated_config" 2>/dev/null || echo "")
            
            local http_code
            http_code=$(echo "$response" | tail -1)
            if [[ "$http_code" =~ ^[2] ]]; then
                log "Jellyfin base URL configured via API"
                api_attempt=true
            fi
        fi
    fi
    
    # Attempt 2: Fallback to config file approach
    if [[ "$api_attempt" != "true" ]]; then
        local network_xml="${DOCKER_CONFIG_DIR}/Jellyfin/network.xml"
        if [[ -f "$network_xml" ]]; then
            log "API approach failed, using config file fallback..."
            backup_file "$network_xml"
            
            # Update network.xml with BaseUrl
            if sed -i 's|<BaseUrl />|<BaseUrl>/jellyfin</BaseUrl>|' "$network_xml" && \
               grep -q '<BaseUrl>/jellyfin</BaseUrl>' "$network_xml"; then
                log "Jellyfin network.xml updated with base URL"
                config_attempt=true
                
                # Restart Jellyfin to apply changes
                log "Restarting Jellyfin to apply base URL..."
                cd "${DOCKER_CONFIG_DIR}" && docker compose restart jellyfin 2>/dev/null || \
                    log_warn "Could not restart Jellyfin"
            fi
        fi
    fi
    
    if [[ "$api_attempt" == "true" ]] || [[ "$config_attempt" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# Configure Transmission RPC URL
configure_transmission_rpc_url() {
    log_step "Configuring Transmission RPC URL..."
    
    local transmission_config="${DOCKER_CONFIG_DIR}/Transmission/settings.json"
    
    if [[ ! -f "$transmission_config" ]]; then
        log_warn "Transmission config not found at ${transmission_config}"
        return 1
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log_warn "jq is not installed, skipping Transmission config"
        return 1
    fi
    
    # Verify JSON is valid
    if ! jq empty "$transmission_config" 2>/dev/null; then
        log_warn "Transmission config is not valid JSON"
        return 1
    fi
    
    # Check if RPC URL is already configured
    if grep -q '"rpc-url": "/transmission/"' "$transmission_config"; then
        log "Transmission RPC URL already configured"
        return 0
    fi
    
    log "Stopping Transmission container..."
    cd "${DOCKER_CONFIG_DIR}" && docker compose stop transmission 2>/dev/null || \
        log_warn "Could not stop Transmission"
    
    # Backup and update config
    backup_file "$transmission_config"
    
    local tmp_config
    tmp_config=$(mktemp)
    
    if jq '.["rpc-url"] = "/transmission/"' "$transmission_config" > "$tmp_config"; then
        mv "$tmp_config" "$transmission_config"
        log "Transmission RPC URL configured"
        
        # Restart Transmission
        log "Starting Transmission container..."
        cd "${DOCKER_CONFIG_DIR}" && docker compose start transmission 2>/dev/null || \
            log_warn "Could not start Transmission"
        
        # Wait for it to be ready
        if wait_for_http "http://localhost:9091/transmission/web/" 60; then
            log "Transmission is available on RPC URL path"
            return 0
        else
            log_warn "Transmission restarted but may not be accessible yet"
            return 1
        fi
    else
        rm -f "$tmp_config"
        log_warn "Failed to update Transmission config via jq"
        return 1
    fi
}

# -------------------------------------------------------------------------
# Phase 1: Reconfigure OpenMediaVault to port 8080
# -------------------------------------------------------------------------

log_header "Phase 1: Reconfigure OpenMediaVault"

if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would reconfigure OMV to port 8080"
else
    log_step "Checking if OpenMediaVault is installed..."
    if [[ ! -d "/etc/openmediavault" ]]; then
        log_warn "OpenMediaVault not found. Skipping OMV reconfiguration."
    else
        # Check if OMV is already on port 8080
        if grep -q "listen.*8080" /etc/nginx/sites-available/openmediavault-webgui 2>/dev/null; then
            log "OpenMediaVault is already configured on port 8080"
        else
            log_step "Reconfiguring OMV to listen on port 8080..."
            backup_file "/etc/openmediavault/config.xml"
            backup_file "/etc/nginx/sites-available/openmediavault-webgui"
            
            # Try to set OMV nginx port to 8080 via environment
            omv-env set OMV_NGINX_SITE_WEBGUI_PORT 8080 || log_warn "omv-env set failed, will use manual approach"
            
            # Apply the configuration (note: salt-minion may revert changes, so we'll manually fix)
            log "Deploying OMV nginx configuration..."
            omv-salt deploy run nginx || log_warn "omv-salt deploy failed, will manually configure"
            
            # Manually ensure OMV is on port 8080 (backup from salt-minion reversions)
            log_step "Verifying and manually fixing OMV nginx configuration..."
            if [[ -f "/etc/nginx/sites-available/openmediavault-webgui" ]]; then
                # Ensure port 8080
                sed -i 's/listen \*:80;/listen *:8080;/g' /etc/nginx/sites-available/openmediavault-webgui
                sed -i 's/listen \[::\]:80;/listen [::]:8080;/g' /etc/nginx/sites-available/openmediavault-webgui
                
                # Remove default_server if present (to avoid conflict with our nginx)
                sed -i 's/ default_server//g' /etc/nginx/sites-available/openmediavault-webgui
                
                log "OMV nginx configuration manually updated"
            fi
        fi
        
        log_step "Waiting for OMV to be available on port 8080..."
        if wait_for_http "http://localhost:8080" 60; then
            log "OMV is available on port 8080"
        else
            log_warn "OMV did not respond on port 8080, but continuing (may need manual restart)"
        fi
    fi
fi

# -------------------------------------------------------------------------
# Phase 2: Install and configure nginx
# -------------------------------------------------------------------------

log_header "Phase 2: Install and Configure Nginx"

if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would install nginx and create configuration"
else
    log_step "Handling APT repository issues..."
    # Disable OMV APT repository if it exists and is causing issues
    if [[ -f "/etc/apt/sources.list.d/openmediavault.list" ]]; then
        log "Disabling OMV APT repository (may be stale)..."
        mv /etc/apt/sources.list.d/openmediavault.list /etc/apt/sources.list.d/openmediavault.list.disabled || \
            log_warn "Could not disable OMV APT repo"
    fi
    
    log_step "Installing nginx..."
    # Try to update and install, but continue if APT fails (nginx may already be installed)
    if ! apt-get update -qq 2>/dev/null; then
        log_warn "APT update failed, attempting nginx install anyway..."
    fi
    
    if apt-get install -y nginx 2>/dev/null; then
        log "Nginx installed successfully"
    elif command -v nginx &> /dev/null; then
        log "Nginx is already installed on the system"
    else
        log_error "Failed to install nginx and it's not already installed"
        exit 1
    fi
    
    log_step "Creating nginx configuration for media center proxy..."
    
    # Create nginx pages directory and copy landing page
    NGINX_PAGES_DIR="/var/www/media-center"
    mkdir -p "$NGINX_PAGES_DIR"
    
    # Copy landing page HTML
    if [[ -f "${SCRIPT_DIR}/../nginx-pages/index.html" ]]; then
        cp "${SCRIPT_DIR}/../nginx-pages/index.html" "$NGINX_PAGES_DIR/index.html"
        chmod 644 "$NGINX_PAGES_DIR/index.html"
        log "Landing page HTML copied to ${NGINX_PAGES_DIR}"
    else
        log_warn "Landing page HTML not found at ${SCRIPT_DIR}/../nginx-pages/index.html"
        log "Creating basic landing page..."
        
        # Fallback: create a minimal HTML landing page
        cat > "$NGINX_PAGES_DIR/index.html" << 'HTML_FALLBACK'
<!DOCTYPE html>
<html>
<head><title>Media Center</title><style>body{font-family:Arial,sans-serif;margin:50px;}</style></head>
<body><h1>Media Center Proxy Active</h1><p>Available Services:</p><ul>
<li><a href="/omv">OpenMediaVault</a></li>
<li><a href="/jellyfin">Jellyfin Media Server</a></li>
<li><a href="/sonarr">TV Shows Manager</a></li>
<li><a href="/radarr">Movies Manager</a></li>
<li><a href="/prowlarr">Indexer Manager</a></li>
<li><a href="/transmission">Download Client</a></li>
</ul></body></html>
HTML_FALLBACK
        chmod 644 "$NGINX_PAGES_DIR/index.html"
        log "Basic fallback landing page created"
    fi
    
    # Copy service icons
    if [[ -d "${SCRIPT_DIR}/../images" ]]; then
        mkdir -p "$NGINX_PAGES_DIR/images"
        chmod 755 "$NGINX_PAGES_DIR/images"
        cp "${SCRIPT_DIR}/../images"/*.png "$NGINX_PAGES_DIR/images/"
        chmod 644 "$NGINX_PAGES_DIR/images"/*.png
        log "Service icons copied to ${NGINX_PAGES_DIR}/images"
    else
        log_warn "Images directory not found at ${SCRIPT_DIR}/../images"
    fi
    
    # Create the nginx site configuration
    cat > "$NGINX_CONFIG" << 'NGINX_EOF'
# Media Center Reverse Proxy Configuration
# Generated by ODROID-HC4 Media Center Setup

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # Increase body size for large file uploads
    client_max_body_size 100M;

    # Root - serve landing page with dynamic URL detection
    root /var/www/media-center;
    
    location = / {
        try_files /index.html =404;
        add_header Content-Type text/html;
    }

    # OpenMediaVault
    location /omv/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        
        # Remove /omv prefix when proxying
        proxy_redirect http://127.0.0.1:8080/ /omv/;
    }

    # Jellyfin Media Server
    location /jellyfin {
        proxy_pass http://127.0.0.1:8096;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Protocol $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        
        # WebSocket support for Jellyfin
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $http_connection;
        
        # Disable buffering for streaming
        proxy_buffering off;
        proxy_request_buffering off;
    }

    # Sonarr - TV Shows
    location /sonarr {
        proxy_pass http://127.0.0.1:8989;
        proxy_set_header Host localhost;
        proxy_set_header X-Real-IP 127.0.0.1;
        proxy_set_header X-Forwarded-For 127.0.0.1;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $http_connection;
    }

    # Radarr - Movies
    location /radarr {
        proxy_pass http://127.0.0.1:7878;
        proxy_set_header Host localhost;
        proxy_set_header X-Real-IP 127.0.0.1;
        proxy_set_header X-Forwarded-For 127.0.0.1;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $http_connection;
    }

    # Prowlarr - Indexer Manager
    location /prowlarr {
        proxy_pass http://127.0.0.1:9696;
        proxy_set_header Host localhost;
        proxy_set_header X-Real-IP 127.0.0.1;
        proxy_set_header X-Forwarded-For 127.0.0.1;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $http_connection;
    }

    # Transmission - Download Client
    location /transmission {
        proxy_pass http://127.0.0.1:9091;
        proxy_pass_header X-Transmission-Session-Id;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support for real-time updates
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $http_connection;
    }
}

# WebSocket upgrade map
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

# Use the connection_upgrade variable
map $http_upgrade $http_connection {
    default upgrade;
    '' close;
}
NGINX_EOF

    log "Nginx configuration created at ${NGINX_CONFIG}"
    
    # Enable the site
    log_step "Enabling media-center site..."
    ln -sf "$NGINX_CONFIG" "$NGINX_ENABLED"
    
    # Disable default site if it exists
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        log "Disabling default nginx site..."
        rm -f /etc/nginx/sites-enabled/default
    fi
    
    # Test nginx configuration
    log_step "Testing nginx configuration..."
    if nginx -t; then
        log "Nginx configuration is valid"
    else
        log_error "Nginx configuration test failed!"
        exit 1
    fi
    
    # Start/restart nginx
    log_step "Starting nginx service..."
    systemctl enable nginx
    systemctl restart nginx
    
    log "Nginx is now running on port 80"
fi

# -------------------------------------------------------------------------
# Phase 3: Configure service base URLs
# -------------------------------------------------------------------------

log_header "Phase 3: Configure Service Base URLs"

if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would configure base URLs for all services"
else
    # Read API keys
    log_step "Reading API keys..."
    SONARR_KEY="$(read_api_key "${DOCKER_CONFIG_DIR}/Sonarr/config.xml" 30 || echo "")"
    RADARR_KEY="$(read_api_key "${DOCKER_CONFIG_DIR}/Radarr/config.xml" 30 || echo "")"
    PROWLARR_KEY="$(read_api_key "${DOCKER_CONFIG_DIR}/Prowlarr/config.xml" 30 || echo "")"
    
    # -------------------------------------------------------------------------
    # Configure Sonarr
    # -------------------------------------------------------------------------
    
    log_step "Configuring Sonarr base URL..."
    if [[ -z "$SONARR_KEY" ]]; then
        log_warn "Could not read Sonarr API key. Skipping Sonarr configuration."
        SERVICE_STATUS[sonarr]="FAILED (no API key)"
    else
        # Get current config
        SONARR_CONFIG=$(curl -s -X GET "http://localhost:8989/api/v3/config/host" \
            -H "X-Api-Key: ${SONARR_KEY}" || echo "{}")
        
        if [[ "$SONARR_CONFIG" == "{}" ]]; then
            log_warn "Could not fetch Sonarr config. Service may not be ready."
            SERVICE_STATUS[sonarr]="FAILED (API error)"
        else
            # Check if already configured
            if echo "$SONARR_CONFIG" | jq -e '.urlBase == "/sonarr"' &>/dev/null; then
                log "Sonarr base URL already configured as /sonarr"
                SERVICE_STATUS[sonarr]="SUCCESS (already configured)"
            else
                # Update with urlBase
                UPDATED_CONFIG=$(echo "$SONARR_CONFIG" | jq '. + {"urlBase": "/sonarr"}')
                
                RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "http://localhost:8989/api/v3/config/host" \
                    -H "Content-Type: application/json" \
                    -H "X-Api-Key: ${SONARR_KEY}" \
                    -d "$UPDATED_CONFIG")
                
                HTTP_CODE=$(echo "$RESPONSE" | tail -1)
                if [[ "$HTTP_CODE" =~ ^2 ]]; then
                    log "Sonarr base URL configured successfully"
                    SERVICE_STATUS[sonarr]="SUCCESS"
                else
                    log_warn "Failed to configure Sonarr base URL (HTTP ${HTTP_CODE})"
                    SERVICE_STATUS[sonarr]="FAILED (HTTP ${HTTP_CODE})"
                fi
            fi
        fi
    fi
    
    # -------------------------------------------------------------------------
    # Configure Radarr
    # -------------------------------------------------------------------------
    
    log_step "Configuring Radarr base URL..."
    if [[ -z "$RADARR_KEY" ]]; then
        log_warn "Could not read Radarr API key. Skipping Radarr configuration."
        SERVICE_STATUS[radarr]="FAILED (no API key)"
    else
        RADARR_CONFIG=$(curl -s -X GET "http://localhost:7878/api/v3/config/host" \
            -H "X-Api-Key: ${RADARR_KEY}" || echo "{}")
        
        if [[ "$RADARR_CONFIG" == "{}" ]]; then
            log_warn "Could not fetch Radarr config. Service may not be ready."
            SERVICE_STATUS[radarr]="FAILED (API error)"
        else
            # Check if already configured
            if echo "$RADARR_CONFIG" | jq -e '.urlBase == "/radarr"' &>/dev/null; then
                log "Radarr base URL already configured as /radarr"
                SERVICE_STATUS[radarr]="SUCCESS (already configured)"
            else
                UPDATED_CONFIG=$(echo "$RADARR_CONFIG" | jq '. + {"urlBase": "/radarr"}')
                
                RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "http://localhost:7878/api/v3/config/host" \
                    -H "Content-Type: application/json" \
                    -H "X-Api-Key: ${RADARR_KEY}" \
                    -d "$UPDATED_CONFIG")
                
                HTTP_CODE=$(echo "$RESPONSE" | tail -1)
                if [[ "$HTTP_CODE" =~ ^2 ]]; then
                    log "Radarr base URL configured successfully"
                    SERVICE_STATUS[radarr]="SUCCESS"
                else
                    log_warn "Failed to configure Radarr base URL (HTTP ${HTTP_CODE})"
                    SERVICE_STATUS[radarr]="FAILED (HTTP ${HTTP_CODE})"
                fi
            fi
        fi
    fi
    
    # -------------------------------------------------------------------------
    # Configure Prowlarr
    # -------------------------------------------------------------------------
    
    log_step "Configuring Prowlarr base URL..."
    if [[ -z "$PROWLARR_KEY" ]]; then
        log_warn "Could not read Prowlarr API key. Skipping Prowlarr configuration."
        SERVICE_STATUS[prowlarr]="FAILED (no API key)"
    else
        PROWLARR_CONFIG=$(curl -s -X GET "http://localhost:9696/api/v1/config/host" \
            -H "X-Api-Key: ${PROWLARR_KEY}" || echo "{}")
        
        if [[ "$PROWLARR_CONFIG" == "{}" ]]; then
            log_warn "Could not fetch Prowlarr config. Service may not be ready."
            SERVICE_STATUS[prowlarr]="FAILED (API error)"
        else
            # Check if already configured
            if echo "$PROWLARR_CONFIG" | jq -e '.urlBase == "/prowlarr"' &>/dev/null; then
                log "Prowlarr base URL already configured as /prowlarr"
                SERVICE_STATUS[prowlarr]="SUCCESS (already configured)"
            else
                UPDATED_CONFIG=$(echo "$PROWLARR_CONFIG" | jq '. + {"urlBase": "/prowlarr"}')
                
                RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "http://localhost:9696/api/v1/config/host" \
                    -H "Content-Type: application/json" \
                    -H "X-Api-Key: ${PROWLARR_KEY}" \
                    -d "$UPDATED_CONFIG")
                
                HTTP_CODE=$(echo "$RESPONSE" | tail -1)
                if [[ "$HTTP_CODE" =~ ^2 ]]; then
                    log "Prowlarr base URL configured successfully"
                    SERVICE_STATUS[prowlarr]="SUCCESS"
                else
                    log_warn "Failed to configure Prowlarr base URL (HTTP ${HTTP_CODE})"
                    SERVICE_STATUS[prowlarr]="FAILED (HTTP ${HTTP_CODE})"
                fi
            fi
        fi
    fi
    
    # -------------------------------------------------------------------------
    # Configure Jellyfin
    # -------------------------------------------------------------------------
    
    if configure_jellyfin_base_url; then
        SERVICE_STATUS[jellyfin]="SUCCESS"
    else
        log_warn "Failed to configure Jellyfin base URL via API or config file"
        SERVICE_STATUS[jellyfin]="FAILED (both API and config methods failed)"
    fi
    
    # -------------------------------------------------------------------------
    # Configure Transmission
    # -------------------------------------------------------------------------
    
    if configure_transmission_rpc_url; then
        SERVICE_STATUS[transmission]="SUCCESS"
    else
        SERVICE_STATUS[transmission]="FAILED (could not configure RPC URL)"
    fi
fi

# -------------------------------------------------------------------------
# Phase 4: Restart containers and verify
# -------------------------------------------------------------------------

log_header "Phase 4: Restart Services and Verify"

if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would restart Docker containers and verify endpoints"
else
    log_step "Restarting Docker containers to apply base URL changes..."
    
    cd "${DOCKER_CONFIG_DIR}"
    
    # Restart Sonarr, Radarr, Prowlarr, Jellyfin (not Transmission - already restarted)
    for service in sonarr radarr prowlarr jellyfin; do
        log "Restarting ${service}..."
        docker compose restart "$service" || log_warn "Failed to restart ${service}"
    done
    
    log_step "Waiting for services to become available..."
    sleep 10
    
    # Verify endpoints through nginx
    log_step "Verifying proxy endpoints..."
    
    declare -A ENDPOINTS=(
        [omv]="http://localhost/omv/"
        [jellyfin]="http://localhost/jellyfin"
        [sonarr]="http://localhost/sonarr"
        [radarr]="http://localhost/radarr"
        [prowlarr]="http://localhost/prowlarr"
        [transmission]="http://localhost/transmission/web/"
    )
    
    FAILED_CHECKS=0
    for service in "${!ENDPOINTS[@]}"; do
        url="${ENDPOINTS[$service]}"
        http_code=$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")
        
        if [[ "$http_code" =~ ^[23] ]]; then
            log "  ✓ ${service}: ${url} (HTTP ${http_code})"
        else
            log_warn "  ✗ ${service}: ${url} (HTTP ${http_code})"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
        fi
    done
    
     # Note: FlareSolverr is API-only and accessed directly by Prowlarr on port 8191
     log "  ℹ FlareSolverr: http://localhost:8191 (API-only, accessed directly by Prowlarr)"
    
    echo ""
    if [[ $FAILED_CHECKS -eq 0 ]]; then
        log "All proxy endpoints verified successfully!"
    else
        log_warn "${FAILED_CHECKS} endpoint(s) failed verification. Check logs above."
    fi
fi

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------

log_header "Configuration Summary"

echo "Service Base URL Configuration Results:"
echo "========================================"
for service in "${SERVICES[@]}"; do
    status="${SERVICE_STATUS[$service]:-NOT CONFIGURED}"
    if [[ "$status" == "SUCCESS" ]]; then
        echo "  ✓ ${service}: ${status}"
    else
        echo "  ✗ ${service}: ${status}"
    fi
done
echo ""

log "Reverse proxy setup complete!"
echo ""
echo "==============================================="
echo "Access your services via:"
echo "==============================================="
echo ""
echo "Via Meshnet (NordVPN):"
echo "  http://<meshnet-hostname>/"
echo "  http://<meshnet-hostname>/omv"
echo "  http://<meshnet-hostname>/jellyfin"
echo "  http://<meshnet-hostname>/sonarr"
echo "  http://<meshnet-hostname>/radarr"
echo "  http://<meshnet-hostname>/prowlarr"
echo "  http://<meshnet-hostname>/transmission"
echo ""
echo "Via Local IP (192.168.0.84):"
echo "  http://192.168.0.84/omv"
echo "  http://192.168.0.84/jellyfin"
echo "  http://192.168.0.84/sonarr"
echo "  http://192.168.0.84/radarr"
echo "  http://192.168.0.84/prowlarr"
echo "  http://192.168.0.84/transmission"
echo ""
echo "Direct port access still available at http://<ip>:<port>"
echo ""
echo "FlareSolverr: http://<ip>:8191 (API-only, accessed directly)"
echo ""

mark_done "$STEP_NAME"
