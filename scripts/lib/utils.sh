#!/usr/bin/env bash
# =============================================================================
# utils.sh - Shared utilities for ODROID-HC4 Media Center setup scripts
# =============================================================================

set -euo pipefail

# State directory for tracking completed steps
STATE_DIR="/var/lib/odroid-setup"
BACKUP_DIR="/var/lib/odroid-setup/backups"
LOG_FILE="/var/log/odroid-setup.log"

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m' # No Color
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# DRY_RUN is inherited from the orchestrator; default to false
DRY_RUN="${DRY_RUN:-false}"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

_log() {
    local level="$1" color="$2"
    shift 2
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${color}[${level}]${NC} ${msg}"
    echo "[${timestamp}] [${level}] ${msg}" >> "$LOG_FILE" 2>/dev/null || true
}

log()      { _log "INFO"  "$GREEN"  "$@"; }
log_warn() { _log "WARN"  "$YELLOW" "$@"; }
log_error(){ _log "ERROR" "$RED"    "$@"; }
log_step() { _log "STEP"  "$BLUE"   "$@"; }

# Print a section header
log_header() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  [Media Center Setup] $*${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""
}

# -----------------------------------------------------------------------------
# State tracking (flag files)
# -----------------------------------------------------------------------------

# Ensure the state directory exists
init_state_dir() {
    mkdir -p "$STATE_DIR" "$BACKUP_DIR"
}

# Check if a step has been completed
is_done() {
    local step="$1"
    [[ -f "${STATE_DIR}/${step}.done" ]]
}

# Mark a step as completed
mark_done() {
    local step="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would mark step '${step}' as done"
        return 0
    fi
    date '+%Y-%m-%d %H:%M:%S' > "${STATE_DIR}/${step}.done"
    log "Step '${step}' completed and recorded"
}

# Reset a step (remove its flag)
reset_step() {
    local step="$1"
    rm -f "${STATE_DIR}/${step}.done"
    log "Step '${step}' has been reset"
}

# List all completed steps
list_completed() {
    if [[ -d "$STATE_DIR" ]]; then
        for f in "${STATE_DIR}"/*.done; do
            [[ -f "$f" ]] || continue
            local step
            step="$(basename "$f" .done)"
            local when
            when="$(cat "$f")"
            echo "  ${step} (completed: ${when})"
        done
    fi
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Backup helpers
# -----------------------------------------------------------------------------

# Backup a file before modifying it
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup_name
        backup_name="$(basename "$file").$(date '+%Y%m%d_%H%M%S').bak"
        cp "$file" "${BACKUP_DIR}/${backup_name}"
        log "Backed up ${file} -> ${BACKUP_DIR}/${backup_name}"
    fi
}

# -----------------------------------------------------------------------------
# Network helpers
# -----------------------------------------------------------------------------

# Wait for an HTTP endpoint to return a 2xx status code
# Usage: wait_for_http "http://localhost:8989" 120
wait_for_http() {
    local url="$1"
    local timeout="${2:-120}"
    local interval=5
    local elapsed=0

    log "Waiting for ${url} to become available (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        local http_code
        http_code="$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")"
        if [[ "$http_code" =~ ^2 ]] || [[ "$http_code" =~ ^3 ]]; then
            log "${url} is up (HTTP ${http_code})"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Timed out waiting for ${url} after ${timeout}s"
    return 1
}

# Wait for a Docker container to be running and healthy
# Usage: wait_for_container "Sonarr" 60
wait_for_container() {
    local name="$1"
    local timeout="${2:-60}"
    local interval=3
    local elapsed=0

    log "Waiting for container '${name}' to be running (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        local state
        state="$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")"
        if [[ "$state" == "running" ]]; then
            log "Container '${name}' is running"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Timed out waiting for container '${name}' after ${timeout}s"
    return 1
}

# Detect the local subnet (e.g. 192.168.0.0/24)
detect_subnet() {
    local iface subnet
    # Get the default route interface
    iface="$(ip route show default | awk '/default/ {print $5}' | head -n1)"
    if [[ -z "$iface" ]]; then
        log_error "Could not detect default network interface"
        return 1
    fi
    # Get the subnet in CIDR notation
    subnet="$(ip -o -f inet addr show "$iface" | awk '{print $4}')"
    if [[ -z "$subnet" ]]; then
        log_error "Could not detect subnet for interface ${iface}"
        return 1
    fi
    # Convert host address to network address (e.g. 192.168.0.84/24 -> 192.168.0.0/24)
    local ip_part mask_part
    ip_part="$(echo "$subnet" | cut -d/ -f1)"
    mask_part="$(echo "$subnet" | cut -d/ -f2)"
    local IFS='.'
    read -r a b c _d <<< "$ip_part"
    # For /24, zero out the last octet; for /16, zero out last two, etc.
    if [[ "$mask_part" -ge 24 ]]; then
        echo "${a}.${b}.${c}.0/${mask_part}"
    elif [[ "$mask_part" -ge 16 ]]; then
        echo "${a}.${b}.0.0/${mask_part}"
    else
        echo "${a}.0.0.0/${mask_part}"
    fi
}

# -----------------------------------------------------------------------------
# Dry run wrapper
# -----------------------------------------------------------------------------

# Run a command, or just print it if in dry-run mode
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY RUN]${NC} $*"
        return 0
    fi
    "$@"
}

# Same as run() but for commands piped from stdin (e.g. curl | bash)
run_pipe() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY RUN]${NC} (piped command) $*"
        return 0
    fi
    # shellcheck disable=SC2294  # eval is intentional for piped commands (e.g. curl | bash)
    eval "$@"
}

# -----------------------------------------------------------------------------
# XML/config helpers
# -----------------------------------------------------------------------------

# Read an API key from a *arr config.xml file
# Usage: read_api_key "/home/dietpi/Docker/Sonarr/config.xml"
read_api_key() {
    local config_file="$1"
    local timeout="${2:-120}"
    local interval=5
    local elapsed=0

    # The config.xml might not exist immediately after container start
    while [[ $elapsed -lt $timeout ]]; do
        if [[ -f "$config_file" ]]; then
            local key
            key="$(grep -oP '<ApiKey>\K[^<]+' "$config_file" 2>/dev/null || echo "")"
            if [[ -n "$key" ]]; then
                echo "$key"
                return 0
            fi
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Could not read API key from ${config_file} after ${timeout}s"
    return 1
}

# -----------------------------------------------------------------------------
# User interaction
# -----------------------------------------------------------------------------

# Pause and wait for user to press Enter (for manual steps)
pause_for_manual_step() {
    local msg="${1:-Press Enter to continue after completing the manual step above...}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY RUN]${NC} Would pause here: ${msg}"
        return 0
    fi
    echo ""
    echo -e "${BOLD}${YELLOW}>>> MANUAL STEP REQUIRED <<<${NC}"
    echo ""
    read -r -p "$msg"
    echo ""
}
