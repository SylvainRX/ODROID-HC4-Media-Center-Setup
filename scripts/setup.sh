#!/usr/bin/env bash
# =============================================================================
# setup.sh - Main orchestrator for ODROID-HC4 Media Center setup
# =============================================================================
#
# Usage:
#   sudo ./setup.sh              # Run the full setup
#   sudo ./setup.sh --dry-run    # Preview what will be done (no changes)
#   sudo ./setup.sh --status     # Show which steps are completed
#   sudo ./setup.sh --reset      # Reset all steps (start fresh)
#   sudo ./setup.sh --reset 03   # Reset a single step
#   sudo ./setup.sh --from 04    # Start from step 04 (skip earlier steps)
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
export DRY_RUN="false"
START_FROM=""
ACTION="run"    # run | status | reset
RESET_STEP=""

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            export DRY_RUN="true"
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --reset)
            ACTION="reset"
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                RESET_STEP="$2"
                shift
            fi
            shift
            ;;
        --from)
            START_FROM="${2:-}"
            if [[ -z "$START_FROM" ]]; then
                echo "Error: --from requires a step number (e.g. --from 04)"
                exit 1
            fi
            shift 2
            ;;
        -h|--help)
            head -n 13 "$0" | tail -n 10
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage"
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Load config and utilities
# -----------------------------------------------------------------------------

# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/lib/utils.sh"

if [[ ! -f "${SCRIPT_DIR}/config.sh" ]]; then
    log_error "config.sh not found in ${SCRIPT_DIR}"
    log_error "Copy config.sh.example to config.sh and fill in your values"
    exit 1
fi

# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

# Allow config.sh to override STATE_DIR
export STATE_DIR="${STATE_DIR:-/var/lib/odroid-setup}"

require_root
init_state_dir

# -----------------------------------------------------------------------------
# Handle --status
# -----------------------------------------------------------------------------

if [[ "$ACTION" == "status" ]]; then
    log_header "Setup Status"
    echo "Completed steps:"
    list_completed
    echo ""
    echo "State directory: ${STATE_DIR}"
    exit 0
fi

# -----------------------------------------------------------------------------
# Handle --reset
# -----------------------------------------------------------------------------

if [[ "$ACTION" == "reset" ]]; then
    if [[ -n "$RESET_STEP" ]]; then
        # Find the matching step file to get the full step name
        for step_file in "${SCRIPT_DIR}"/steps/"${RESET_STEP}"_*.sh; do
            if [[ -f "$step_file" ]]; then
                step_name="$(basename "$step_file" .sh)"
                reset_step "$step_name"
            fi
        done
    else
        log_warn "This will reset ALL completed steps. You will need to re-run the full setup."
        read -r -p "Are you sure? (y/N) " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "${STATE_DIR}"/*.done
            log "All steps have been reset"
        else
            log "Aborted"
        fi
    fi
    exit 0
fi

# -----------------------------------------------------------------------------
# Validate required config
# -----------------------------------------------------------------------------

validate_config() {
    local errors=0

    if [[ -z "${NORDVPN_TOKEN:-}" ]]; then
        log_warn "NORDVPN_TOKEN is not set. Step 04 (NordVPN) will be skipped."
    fi

    return $errors
}

# -----------------------------------------------------------------------------
# Step definitions
# Each step is a script in steps/ that:
# 1. Sources utils.sh
# 2. Checks is_done and skips if completed
# 3. Does its work
# 4. Calls mark_done on success
# -----------------------------------------------------------------------------

# Ordered list of step scripts
STEPS=(
    "01_fan_control"
    "02_omv_install"
    "03_set_data_drive"
    "04_nordvpn"
    "05_docker_install"
    "06_containers"
    "07_wire_services"
)

run_step() {
    local step_name="$1"
    local step_file="${SCRIPT_DIR}/steps/${step_name}.sh"

    if [[ ! -f "$step_file" ]]; then
        log_error "Step file not found: ${step_file}"
        return 1
    fi

    # Check if already completed
    if is_done "$step_name"; then
        log "Step '${step_name}' already completed. Skipping."
        return 0
    fi

    log_header "Running: ${step_name}"

    # Run the step script in the current shell so it inherits all variables
    # Each step is responsible for its own error handling
    if bash -e "$step_file"; then
        return 0
    else
        local exit_code=$?
        log_error "Step '${step_name}' failed with exit code ${exit_code}"
        log_error "Fix the issue and re-run: sudo ./setup.sh"
        log_error "Or skip ahead with: sudo ./setup.sh --from <next_step_number>"
        return $exit_code
    fi
}

# -----------------------------------------------------------------------------
# Main execution
# -----------------------------------------------------------------------------

log_header "ODROID-HC4 Media Center Setup"

if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY RUN MODE - No changes will be made"
    echo ""
fi

validate_config

# Show what's already done
completed_count=0
for step in "${STEPS[@]}"; do
    if is_done "$step"; then
        completed_count=$((completed_count + 1))
    fi
done
if [[ $completed_count -gt 0 ]]; then
    log "Resuming setup (${completed_count}/${#STEPS[@]} steps already completed)"
fi

# Export variables so step scripts can access them
export SCRIPT_DIR DRY_RUN TZ PUID PGID
export DATA_DRIVE DOCKER_CONFIG_DIR NORDVPN_TOKEN
export FAN_MIN_TEMP FAN_MAX_TEMP STATE_DIR
# DATA_DRIVE may be empty — step 03 handles interactive selection if so

should_skip=false
if [[ -n "$START_FROM" ]]; then
    should_skip=true
fi

for step in "${STEPS[@]}"; do
    # Handle --from flag
    if [[ "$should_skip" == "true" ]]; then
        step_num="${step%%_*}"  # Extract the number prefix
        if [[ "$step_num" == "$START_FROM" ]]; then
            should_skip=false
        else
            log "Skipping step '${step}' (--from ${START_FROM})"
            continue
        fi
    fi

    run_step "$step" || exit $?
done

log_header "Setup Complete!"
echo "All automated steps have been completed."
echo ""
echo "Remaining manual steps:"
echo "  1. Add indexers in Prowlarr: http://<HC4-IP>:9696"
echo "  2. Create Jellyfin account: http://<HC4-IP>:8096"
echo "  3. (Optional) Configure push notifications"
echo "  4. (Optional) Enable NordVPN Meshnet for remote access:"
echo "     nordvpn set meshnet on"
echo ""
