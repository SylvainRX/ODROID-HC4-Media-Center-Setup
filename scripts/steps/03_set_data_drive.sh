#!/usr/bin/env bash
# =============================================================================
# 03_set_data_drive.sh - Select the media drive and create /media symlink
#
# This step creates a /media symlink pointing to the OMV-managed mount point
# for your hard drive or RAID array. All Docker containers use /media as their
# storage root.
#
# Behaviour:
#   - If DATA_DRIVE is set in config.sh, it is used directly (skips menu).
#   - Otherwise, this step scans /srv/dev-disk-* for OMV-mounted drives and
#     presents an interactive selection menu.
#
# NOTE: /media is a standard Linux system directory used for removable media
# auto-mount. On a headless OMV/DietPi server udisks auto-mount is not active,
# so it is safe to replace the empty /media directory with a symlink. If /media
# is non-empty (unexpected), this step will error rather than risk data loss.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/config.sh"

STEP_NAME="03_set_data_drive"
MOUNT_POINT="/media"

if is_done "$STEP_NAME"; then
    current="$(readlink "${MOUNT_POINT}" 2>/dev/null || echo '?')"
    log "Media drive already configured (${MOUNT_POINT} -> ${current}). Skipping."
    exit 0
fi

# -------------------------------------------------------------------------
# Determine the target mount path
# -------------------------------------------------------------------------

TARGET=""

if [[ -n "${DATA_DRIVE:-}" ]]; then
    # DATA_DRIVE pre-set in config.sh — use it directly, no menu
    log_step "DATA_DRIVE is set in config.sh: ${DATA_DRIVE}"

    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ ! -d "${DATA_DRIVE}" ]]; then
            log_error "DATA_DRIVE='${DATA_DRIVE}' does not exist or is not a directory."
            log_error "Possible fixes:"
            log_error "  - Complete the OMV web UI setup so the drive is mounted under /srv/"
            log_error "  - Or clear DATA_DRIVE in config.sh to use the interactive drive selection"
            exit 1
        fi
        if [[ ! -r "${DATA_DRIVE}" ]]; then
            log_error "DATA_DRIVE='${DATA_DRIVE}' exists but is not readable. Check permissions."
            exit 1
        fi
    fi

    TARGET="${DATA_DRIVE}"

else
    # Interactive mode: scan /srv/ for OMV-mounted drives
    log_step "Scanning for OMV-mounted drives in /srv/..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would scan /srv/dev-disk-* and present a drive selection menu"
        log "[DRY RUN] Would create symlink: ${MOUNT_POINT} -> /srv/dev-disk-by-uuid-XXXX"
        mark_done "$STEP_NAME"
        exit 0
    fi

    # Collect OMV-managed mount points
    declare -a MOUNTS=()
    for mount in /srv/dev-disk-*; do
        [[ -d "$mount" ]] && MOUNTS+=("$mount")
    done

    if [[ ${#MOUNTS[@]} -eq 0 ]]; then
        log_error "No OMV-mounted drives found in /srv/."
        log_error ""
        log_error "You must complete the OMV web UI setup first:"
        log_error "  1. Open OMV at http://$(hostname -I | awk '{print $1}')"
        log_error "  2. Go to Storage > File Systems, mount your drive, and save"
        log_error "  3. Re-run: sudo ./setup.sh --from 03"
        exit 1
    fi

    # Build menu entries with filesystem details
    declare -a MENU_ENTRIES=()
    for mount in "${MOUNTS[@]}"; do
        # df -hT: columns are Filesystem, Type, Size, Used, Avail, Use%, Mountpoint
        info="$(df -hT "$mount" 2>/dev/null | awk 'NR==2 {printf "%s, %s total, %s free", $2, $3, $5}')" \
            || info="unknown"
        MENU_ENTRIES+=("${mount}  [${info}]")
    done

    echo ""
    echo "The following drives are mounted by OMV:"
    echo ""

    PS3="Select your media drive: "
    select entry in "${MENU_ENTRIES[@]}" "Quit"; do
        if [[ -z "$entry" ]]; then
            echo "Invalid selection. Please enter a number from the list."
            continue
        fi
        if [[ "$entry" == "Quit" ]]; then
            log_error "Drive selection cancelled."
            log_error "Re-run the setup when ready: sudo ./setup.sh --from 03"
            exit 1
        fi
        # REPLY is 1-indexed; MOUNTS is 0-indexed
        TARGET="${MOUNTS[$((REPLY - 1))]}"
        break
    done

    echo ""
    log "Selected: ${TARGET}"
fi

# -------------------------------------------------------------------------
# Create /media symlink
# -------------------------------------------------------------------------

log_step "Setting up ${MOUNT_POINT} -> ${TARGET}"

if [[ "$DRY_RUN" != "true" ]]; then

    if [[ -L "${MOUNT_POINT}" ]]; then
        # Already a symlink
        current_target="$(readlink "${MOUNT_POINT}")"
        if [[ "$current_target" == "$TARGET" ]]; then
            log "${MOUNT_POINT} already points to ${TARGET}."
        else
            log_warn "${MOUNT_POINT} points to '${current_target}' — updating to '${TARGET}'..."
            rm "${MOUNT_POINT}"
            ln -s "${TARGET}" "${MOUNT_POINT}"
            log "Updated: ${MOUNT_POINT} -> ${TARGET}"
        fi

    elif [[ -d "${MOUNT_POINT}" ]]; then
        # Real directory — only safe to replace if empty
        if [[ -z "$(ls -A "${MOUNT_POINT}" 2>/dev/null)" ]]; then
            log_warn "${MOUNT_POINT} is an empty directory (likely a system default). Replacing with symlink..."
            rmdir "${MOUNT_POINT}"
            ln -s "${TARGET}" "${MOUNT_POINT}"
            log "Created: ${MOUNT_POINT} -> ${TARGET}"
        else
            log_error "${MOUNT_POINT} is a non-empty directory — refusing to replace it."
            log_error "Contents: $(ls "${MOUNT_POINT}" | head -5)"
            log_error "Manually move or remove ${MOUNT_POINT}, then re-run: sudo ./setup.sh --from 03"
            exit 1
        fi

    elif [[ -e "${MOUNT_POINT}" ]]; then
        log_error "${MOUNT_POINT} exists but is not a directory or symlink (type: $(stat -c '%F' "${MOUNT_POINT}"))."
        log_error "Manually remove it, then re-run: sudo ./setup.sh --from 03"
        exit 1

    else
        ln -s "${TARGET}" "${MOUNT_POINT}"
        log "Created: ${MOUNT_POINT} -> ${TARGET}"
    fi

    # Final sanity check
    if [[ ! -r "${MOUNT_POINT}" ]]; then
        log_error "${MOUNT_POINT} symlink was created but the target is not readable."
        log_error "Verify the drive is properly mounted under OMV."
        exit 1
    fi

    echo ""
    log "Storage:"
    df -h "${MOUNT_POINT}" | awk 'NR==2 {printf "  Size:  %s\n  Used:  %s (%s)\n  Free:  %s\n", $2, $3, $5, $4}'
    echo ""
fi

mark_done "$STEP_NAME"
log "Media drive configured: ${MOUNT_POINT} -> ${TARGET}"
