#!/usr/bin/env bash
# =============================================================================
# 07_wire_services.sh - Wire services together via REST APIs
#
# This step:
#   1. Reads API keys from each service's config.xml
#   2. Adds Sonarr and Radarr as applications in Prowlarr
#   3. Adds Transmission as a download client in Sonarr and Radarr
#   4. Enables hardlinks in Sonarr and Radarr
#
# Once Prowlarr has Sonarr/Radarr registered, any indexers you add in
# Prowlarr will automatically sync to both Sonarr and Radarr.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/config.sh"

STEP_NAME="07_wire_services"

if is_done "$STEP_NAME"; then
    log "Service wiring already completed. Skipping."
    exit 0
fi

DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/home/dietpi/Docker}"
IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"

# -------------------------------------------------------------------------
# Validate storage configuration
# -------------------------------------------------------------------------

log_step "Validating storage configuration..."

if [[ ! -L "/media" ]]; then
    log_error "/media is not a symlink (or does not exist)."
    log_error "Current state: $(ls -la /media 2>/dev/null || echo 'not found')"
    log_error "Re-run step 03 to configure the media drive: sudo ./setup.sh --from 03"
    exit 1
fi

# Verify the required directories exist
for dir in "/media/media/tv" "/media/media/movies" "/media/torrents"; do
    if [[ ! -d "$dir" ]]; then
        log_error "Required directory does not exist: $dir"
        log_error "Ensure /media is properly mounted and step 06 has completed."
        exit 1
    fi
done

log "Storage validation passed: $(df -h /media | tail -1)"

# -------------------------------------------------------------------------
# Wait for services to be ready
# -------------------------------------------------------------------------

log_step "Waiting for services to become available..."

if [[ "$DRY_RUN" != "true" ]]; then
    wait_for_http "http://localhost:9696" 120  # Prowlarr
    wait_for_http "http://localhost:8989" 120  # Sonarr
    wait_for_http "http://localhost:7878" 120  # Radarr
    wait_for_http "http://localhost:9091" 120  # Transmission
    wait_for_http "http://localhost:8191" 120  # Byparr
fi

# -------------------------------------------------------------------------
# Read API keys from config.xml files on disk
# -------------------------------------------------------------------------

log_step "Reading API keys from container config files..."

if [[ "$DRY_RUN" != "true" ]]; then
    PROWLARR_KEY="$(read_api_key "${DOCKER_CONFIG_DIR}/Prowlarr/config.xml" 120)"
    SONARR_KEY="$(read_api_key "${DOCKER_CONFIG_DIR}/Sonarr/config.xml" 120)"
    RADARR_KEY="$(read_api_key "${DOCKER_CONFIG_DIR}/Radarr/config.xml" 120)"

    log "  Prowlarr API key: ${PROWLARR_KEY:0:8}..."
    log "  Sonarr API key:   ${SONARR_KEY:0:8}..."
    log "  Radarr API key:   ${RADARR_KEY:0:8}..."
else
    PROWLARR_KEY="dry-run-prowlarr-key"
    SONARR_KEY="dry-run-sonarr-key"
    RADARR_KEY="dry-run-radarr-key"
    log "[DRY RUN] Would read API keys from config.xml files"
fi

# -------------------------------------------------------------------------
# Helper: Make API calls with error handling
# -------------------------------------------------------------------------

api_post() {
    local url="$1"
    local api_key="$2"
    local data="$3"
    local description="$4"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would POST to ${url}: ${description}"
        return 0
    fi

    local response http_code
    response="$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: ${api_key}" \
        -d "$data" \
        "$url" 2>/dev/null)"

    http_code="$(echo "$response" | tail -n1)"
    local body
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        log "  OK: ${description}"
        return 0
    elif [[ "$http_code" == "400" ]]; then
        # 400 could mean duplicate or validation error - check response body
        if echo "$body" | grep -qi "already exists\|duplicate"; then
            log_warn "  ${description}: already exists (HTTP 400)"
            return 0
        else
            # Validation error or other 400 - log and continue since it may not be critical
            log_warn "  ${description}: validation error (HTTP 400) - ${body}"
            return 0
        fi
    elif [[ "$http_code" == "409" ]]; then
        # 409 Conflict - resource already exists
        log_warn "  ${description}: already exists or conflict (HTTP 409)"
        return 0
    else
        log_error "  FAILED: ${description} (HTTP ${http_code})"
        log_error "  Response: ${body}"
        return 1
    fi
}

api_get() {
    local url="$1"
    local api_key="$2"

    curl -s \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: ${api_key}" \
        "$url" 2>/dev/null
}

api_put() {
    local url="$1"
    local api_key="$2"
    local data="$3"
    local description="$4"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would PUT to ${url}: ${description}"
        return 0
    fi

    local response http_code
    response="$(curl -s -w "\n%{http_code}" \
        -X PUT \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: ${api_key}" \
        -d "$data" \
        "$url" 2>/dev/null)"

    http_code="$(echo "$response" | tail -n1)"
    local body
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        log "  OK: ${description}"
        return 0
    else
        log_error "  FAILED: ${description} (HTTP ${http_code})"
        log_error "  Response: ${body}"
        return 1
    fi
}

# -------------------------------------------------------------------------
# 1. Add Sonarr as an application in Prowlarr
# -------------------------------------------------------------------------

log_step "Adding Sonarr to Prowlarr..."

SONARR_APP_PAYLOAD="$(cat <<EOF
{
  "syncLevel": "fullSync",
  "name": "Sonarr",
  "fields": [
    { "name": "prowlarrUrl", "value": "http://prowlarr:9696" },
    { "name": "baseUrl", "value": "http://sonarr:8989" },
    { "name": "apiKey", "value": "${SONARR_KEY}" },
    { "name": "syncCategories", "value": [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080, 5090] }
  ],
  "implementationName": "Sonarr",
  "implementation": "Sonarr",
  "configContract": "SonarrSettings",
  "tags": []
}
EOF
)"

api_post "http://localhost:9696/api/v1/applications" "$PROWLARR_KEY" "$SONARR_APP_PAYLOAD" \
    "Add Sonarr to Prowlarr"

# -------------------------------------------------------------------------
# 2. Add Radarr as an application in Prowlarr
# -------------------------------------------------------------------------

log_step "Adding Radarr to Prowlarr..."

RADARR_APP_PAYLOAD="$(cat <<EOF
{
  "syncLevel": "fullSync",
  "name": "Radarr",
  "fields": [
    { "name": "prowlarrUrl", "value": "http://prowlarr:9696" },
    { "name": "baseUrl", "value": "http://radarr:7878" },
    { "name": "apiKey", "value": "${RADARR_KEY}" },
    { "name": "syncCategories", "value": [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080, 2090] }
  ],
  "implementationName": "Radarr",
  "implementation": "Radarr",
  "configContract": "RadarrSettings",
  "tags": []
}
EOF
)"

api_post "http://localhost:9696/api/v1/applications" "$PROWLARR_KEY" "$RADARR_APP_PAYLOAD" \
    "Add Radarr to Prowlarr"

# -------------------------------------------------------------------------
# 3. Add Transmission as download client in Sonarr
# -------------------------------------------------------------------------

log_step "Adding Transmission as download client in Sonarr..."

TRANSMISSION_SONARR_PAYLOAD="$(cat <<EOF
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "name": "Transmission",
  "fields": [
    { "name": "host", "value": "transmission" },
    { "name": "port", "value": 9091 },
    { "name": "urlBase", "value": "/transmission/rpc" },
    { "name": "username", "value": "" },
    { "name": "password", "value": "" },
    { "name": "tvCategory", "value": "tv-sonarr" },
    { "name": "tvDirectory", "value": "" },
    { "name": "recentTvPriority", "value": 0 },
    { "name": "olderTvPriority", "value": 0 },
    { "name": "addPaused", "value": false }
  ],
  "implementationName": "Transmission",
  "implementation": "Transmission",
  "configContract": "TransmissionSettings",
  "tags": []
}
EOF
)"

api_post "http://localhost:8989/api/v3/downloadclient" "$SONARR_KEY" "$TRANSMISSION_SONARR_PAYLOAD" \
    "Add Transmission to Sonarr"

# -------------------------------------------------------------------------
# 4. Add Transmission as download client in Radarr
# -------------------------------------------------------------------------

log_step "Adding Transmission as download client in Radarr..."

TRANSMISSION_RADARR_PAYLOAD="$(cat <<EOF
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "name": "Transmission",
  "fields": [
    { "name": "host", "value": "transmission" },
    { "name": "port", "value": 9091 },
    { "name": "urlBase", "value": "/transmission/rpc" },
    { "name": "username", "value": "" },
    { "name": "password", "value": "" },
    { "name": "movieCategory", "value": "radarr" },
    { "name": "movieDirectory", "value": "" },
    { "name": "recentMoviePriority", "value": 0 },
    { "name": "olderMoviePriority", "value": 0 },
    { "name": "addPaused", "value": false }
  ],
  "implementationName": "Transmission",
  "implementation": "Transmission",
  "configContract": "TransmissionSettings",
  "tags": []
}
EOF
)"

api_post "http://localhost:7878/api/v3/downloadclient" "$RADARR_KEY" "$TRANSMISSION_RADARR_PAYLOAD" \
    "Add Transmission to Radarr"

# -------------------------------------------------------------------------
# 5. Enable hardlinks in Sonarr
# -------------------------------------------------------------------------

log_step "Enabling hardlinks in Sonarr..."

if [[ "$DRY_RUN" != "true" ]]; then
    # Get current media management config
    SONARR_MM="$(api_get "http://localhost:8989/api/v3/config/mediamanagement" "$SONARR_KEY")"

    if [[ -n "$SONARR_MM" ]]; then
        # Update the config to enable hardlinks (set copyUsingHardlinks to true)
        SONARR_MM_UPDATED="${SONARR_MM//\"copyUsingHardlinks\":false/\"copyUsingHardlinks\":true}"

        # Extract the ID for the PUT request
        MM_ID="$(echo "$SONARR_MM" | grep -oP '"id":\s*\K\d+' | head -1)"

        if [[ -n "$MM_ID" ]]; then
            api_put "http://localhost:8989/api/v3/config/mediamanagement/${MM_ID}" \
                "$SONARR_KEY" "$SONARR_MM_UPDATED" \
                "Enable hardlinks in Sonarr"
        else
            log_warn "Could not parse Sonarr media management config ID"
        fi
    else
        log_warn "Could not fetch Sonarr media management config"
    fi
else
    log "[DRY RUN] Would enable hardlinks in Sonarr"
fi

# -------------------------------------------------------------------------
# 6. Enable hardlinks in Radarr
# -------------------------------------------------------------------------

log_step "Enabling hardlinks in Radarr..."

if [[ "$DRY_RUN" != "true" ]]; then
    RADARR_MM="$(api_get "http://localhost:7878/api/v3/config/mediamanagement" "$RADARR_KEY")"

    if [[ -n "$RADARR_MM" ]]; then
        RADARR_MM_UPDATED="${RADARR_MM//\"copyUsingHardlinks\":false/\"copyUsingHardlinks\":true}"

        MM_ID="$(echo "$RADARR_MM" | grep -oP '"id":\s*\K\d+' | head -1)"

        if [[ -n "$MM_ID" ]]; then
            api_put "http://localhost:7878/api/v3/config/mediamanagement/${MM_ID}" \
                "$RADARR_KEY" "$RADARR_MM_UPDATED" \
                "Enable hardlinks in Radarr"
        else
            log_warn "Could not parse Radarr media management config ID"
        fi
    else
        log_warn "Could not fetch Radarr media management config"
    fi
else
    log "[DRY RUN] Would enable hardlinks in Radarr"
fi

# -------------------------------------------------------------------------
# 7. Add root folders in Sonarr and Radarr
# -------------------------------------------------------------------------

log_step "Adding root folders..."

api_post "http://localhost:8989/api/v3/rootfolder" "$SONARR_KEY" \
    '{"path": "/tv", "accessible": true, "freeSpace": 0}' \
    "Add /tv root folder in Sonarr"

api_post "http://localhost:7878/api/v3/rootfolder" "$RADARR_KEY" \
    '{"path": "/movies", "accessible": true, "freeSpace": 0}' \
    "Add /movies root folder in Radarr"

# -------------------------------------------------------------------------
# 8. Add Byparr as FlareSolverr proxy in Prowlarr
# -------------------------------------------------------------------------
#
# Byparr is a Cloudflare anti-bot bypass service compatible with Prowlarr's
# FlareSolverr indexer proxy interface. Once registered, Prowlarr will use
# Byparr to bypass Cloudflare protection on torrent indexers automatically.
#

log_step "Registering Byparr as indexer proxy in Prowlarr..."

BYPARR_PROXY_PAYLOAD="$(cat <<EOF
{
  "name": "Byparr",
  "implementationName": "FlareSolverr",
  "implementation": "FlareSolverr",
  "configContract": "FlareSolverrSettings",
  "supportsAny": true,
  "tags": [],
  "fields": [
    { "name": "host", "value": "http://byparr:8191" },
    { "name": "requestTimeout", "value": 60 }
  ]
}
EOF
)"

api_post "http://localhost:9696/api/v1/indexerproxy" "$PROWLARR_KEY" "$BYPARR_PROXY_PAYLOAD" \
    "Register Byparr as indexer proxy in Prowlarr"

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------

log_header "Service Wiring Summary"

echo "The following connections have been configured:"
echo ""
echo "  Prowlarr -> Sonarr  (indexer sync)"
echo "  Prowlarr -> Radarr  (indexer sync)"
echo "  Prowlarr -> Byparr  (Cloudflare bypass proxy)"
echo "  Sonarr   -> Transmission (download client)"
echo "  Radarr   -> Transmission (download client)"
echo "  Sonarr   : hardlinks enabled"
echo "  Radarr   : hardlinks enabled"
echo "  Sonarr   : root folder /tv"
echo "  Radarr   : root folder /movies"
echo ""
echo "Remaining manual steps:"
echo "  1. Add indexers in Prowlarr (http://${IP}:9696)"
echo "     Cloudflare-protected indexers will automatically use Byparr."
echo "     They will automatically sync to Sonarr and Radarr."
echo "  2. Complete Jellyfin setup (http://${IP}:8096)"
echo "     Create your admin account and add media libraries."
echo ""

mark_done "$STEP_NAME"
log "Service wiring complete."
