#!/usr/bin/env bash
# =============================================================================
# 06_containers.sh - Create directories and deploy all Docker containers
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/config.sh"

STEP_NAME="06_containers"

if is_done "$STEP_NAME"; then
    log "Docker containers already deployed. Skipping."
    exit 0
fi

DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/home/dietpi/Docker}"
COMPOSE_DIR="${DOCKER_CONFIG_DIR}"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

# -------------------------------------------------------------------------
# Validate prerequisites
# -------------------------------------------------------------------------

if [[ "$DRY_RUN" != "true" ]]; then
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed. Run step 04 first."
        exit 1
    fi

    if ! docker compose version &>/dev/null 2>&1; then
        log_error "Docker Compose plugin is not installed. Run step 04 first."
        exit 1
    fi

    if [[ ! -e "/media" ]]; then
        log_error "/media does not exist. Step 03 (set_data_drive) must complete first."
        log_error "Re-run: sudo ./setup.sh --from 03"
        exit 1
    fi
fi

# -------------------------------------------------------------------------
# Create required directories
# -------------------------------------------------------------------------

log_step "Creating directory structure..."

DIRS=(
    "${DOCKER_CONFIG_DIR}/Transmission"
    "${DOCKER_CONFIG_DIR}/Transmission/watch"
    "${DOCKER_CONFIG_DIR}/Prowlarr"
    "${DOCKER_CONFIG_DIR}/Sonarr"
    "${DOCKER_CONFIG_DIR}/Radarr"
    "${DOCKER_CONFIG_DIR}/Jellyfin"
    "/media/torrents"
    "/media/media/tv"
    "/media/media/movies"
    # Note: Byparr is stateless; no config directory needed
)

for dir in "${DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        log "  Directory exists: ${dir}"
    else
        log "  Creating: ${dir}"
        run mkdir -p "$dir"
    fi
done

# Set ownership so containers (PUID:PGID) can write
run chown -R "${PUID}:${PGID}" "${DOCKER_CONFIG_DIR}" || true
run chown -R "${PUID}:${PGID}" /media/torrents /media/media || true

# -------------------------------------------------------------------------
# Generate docker-compose.yml from template
# -------------------------------------------------------------------------

log_step "Generating docker-compose.yml..."

TEMPLATE="${SCRIPT_DIR}/templates/docker-compose.yml.tpl"

if [[ ! -f "$TEMPLATE" ]]; then
    log_error "Template not found: ${TEMPLATE}"
    exit 1
fi

if [[ "$DRY_RUN" != "true" ]]; then
    # Substitute variables in the template (envsubst is not installed on DietPi)
    sed -e "s|\${PUID}|${PUID}|g" \
        -e "s|\${PGID}|${PGID}|g" \
        -e "s|\${TZ}|${TZ}|g" \
        -e "s|\${DOCKER_CONFIG_DIR}|${DOCKER_CONFIG_DIR}|g" \
        "$TEMPLATE" > "$COMPOSE_FILE"
    log "Generated: ${COMPOSE_FILE}"
else
    log "[DRY RUN] Would generate ${COMPOSE_FILE} from template"
    log "[DRY RUN] With TZ=${TZ}, PUID=${PUID}, PGID=${PGID}"
fi

# -------------------------------------------------------------------------
# Deploy containers
# -------------------------------------------------------------------------

log_step "Deploying containers with docker compose..."

if [[ "$DRY_RUN" != "true" ]]; then
    docker compose -f "$COMPOSE_FILE" up -d

    # Retry logic for container startup
    MAX_RETRIES=3
    RETRY_DELAY=10
    retry_count=0
    all_running=false

    while [[ $retry_count -lt $MAX_RETRIES && "$all_running" == "false" ]]; do
        echo ""
        if [[ $retry_count -eq 0 ]]; then
            log "Waiting for containers to start..."
        else
            log "Retry ${retry_count}/${MAX_RETRIES}: Waiting for containers to start..."
        fi
        sleep $RETRY_DELAY

        # Verify all containers are running
        EXPECTED_CONTAINERS=("Transmission" "Prowlarr" "Sonarr" "Radarr" "Jellyfin" "Byparr")
        all_running=true

        for cname in "${EXPECTED_CONTAINERS[@]}"; do
            state="$(docker inspect --format='{{.State.Status}}' "$cname" 2>/dev/null || echo "missing")"
            if [[ "$state" == "running" ]]; then
                log "  ${cname}: running"
            else
                log_error "  ${cname}: ${state}"
                all_running=false
            fi
        done

        if [[ "$all_running" != "true" ]]; then
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $MAX_RETRIES ]]; then
                log "Some containers failed to start. Retrying in ${RETRY_DELAY} seconds..."
            fi
        fi
    done

    if [[ "$all_running" != "true" ]]; then
        log_error "Containers failed to start after ${MAX_RETRIES} retries."
        log_error "Check: docker ps -a"
        log_error "View logs with: docker logs <container-name>"
        exit 1
    fi
else
    log "[DRY RUN] Would run: docker compose -f ${COMPOSE_FILE} up -d"
fi

# -------------------------------------------------------------------------
# Print service URLs
# -------------------------------------------------------------------------

IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<HC4-IP>')"

echo ""
log "All containers deployed. Service URLs:"
echo "  Transmission: http://${IP}:9091"
echo "  Prowlarr:     http://${IP}:9696"
echo "  Sonarr:       http://${IP}:8989"
echo "  Radarr:       http://${IP}:7878"
echo "  Jellyfin:     http://${IP}:8096"
echo "  Byparr:       http://${IP}:8191"
echo ""

mark_done "$STEP_NAME"
log "Container deployment complete."
