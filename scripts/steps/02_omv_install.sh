#!/usr/bin/env bash
# =============================================================================
# 02_omv_install.sh - Install OpenMediaVault
#
# NOTE: OMV web UI configuration (RAID, SMB shares, users) cannot be
# automated reliably. This step installs OMV and then pauses for the user
# to complete the web UI setup before continuing.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/config.sh"

STEP_NAME="02_omv_install"

if is_done "$STEP_NAME"; then
    log "OpenMediaVault already installed. Skipping."
    exit 0
fi

# -------------------------------------------------------------------------
# Install OMV (skip if already installed, e.g. system rebooted mid-run)
# -------------------------------------------------------------------------

if dpkg-query -W -f='${Status}' openmediavault 2>/dev/null | grep -q 'install ok installed'; then
    log_warn "OpenMediaVault is already installed, system likely rebooted mid-install. Proceeding..."
else
    log_step "Installing OpenMediaVault (this may take a while)..."
    run_pipe "wget -O - https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install | sudo bash"
fi

# -------------------------------------------------------------------------
# Install OMV RAID plugin (optional, but enables RAID management in web UI)
# -------------------------------------------------------------------------

if ! dpkg-query -W -f='${Status}' openmediavault-md 2>/dev/null | grep -q 'install ok installed'; then
    log_step "Installing OpenMediaVault RAID plugin..."
    run apt install -y openmediavault-md
else
    log "OpenMediaVault RAID plugin already installed."
fi

# -------------------------------------------------------------------------
# Install mdadm
# -------------------------------------------------------------------------

if ! dpkg-query -W -f='${Status}' mdadm 2>/dev/null | grep -q 'install ok installed'; then
    log_step "Installing mdadm (RAID management tool)..."
    run apt install -y mdadm
else
    log "mdadm already installed."
fi

# -------------------------------------------------------------------------
# Detect and reassemble existing RAID arrays
# -------------------------------------------------------------------------

log_step "Scanning for existing RAID arrays..."

if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would scan for existing RAID array metadata and reassemble if found"
else
    RAID_SCAN="$(mdadm --examine --scan 2>/dev/null || true)"

    if [[ -n "$RAID_SCAN" ]]; then
        log_warn "Detected existing RAID array metadata on your drives:"
        echo ""
        echo "$RAID_SCAN"
        echo ""

        log_step "Reassembling existing RAID array(s)..."
        mdadm --assemble --scan --verbose 2>&1 || true
        sleep 3

        # Check for degraded arrays: [U_] or [_U] etc. in /proc/mdstat bitmap
        if grep -Eq '\[U*_[U_]*\]' /proc/mdstat 2>/dev/null; then
            echo ""
            log_error "One or more RAID arrays are in a degraded state (a drive is missing or failed)."
            log_error "Continuing the setup on a degraded array risks data loss."
            log_error ""
            log_error "Please resolve the issue manually before continuing."
            log_error ""
            log_error "Useful commands:"
            log_error "  cat /proc/mdstat                            # View array status"
            log_error "  mdadm --detail /dev/mdX                     # Detailed info (replace mdX)"
            log_error "  mdadm --manage /dev/mdX --add /dev/sdX      # Add a replacement drive"
            log_error ""
            log_error "Once the array is healthy, re-run: sudo ./setup.sh --from 02"
            exit 1
        fi

        if grep -qE '^md[0-9]+ : active' /proc/mdstat 2>/dev/null; then
            log "RAID array(s) successfully assembled and healthy."
            echo ""
            grep -A3 '^md' /proc/mdstat || true
            echo ""
            log "These arrays will be visible in the OMV web UI under Storage > RAID Management."
        else
            log_warn "mdadm scan completed but no active arrays were detected in /proc/mdstat."
            log_warn "If you expected a RAID array, inspect your drives before continuing."
        fi
    else
        log "No existing RAID array metadata detected. You can create new arrays via the OMV web UI."
    fi
fi

# -------------------------------------------------------------------------
# Manual steps required
# -------------------------------------------------------------------------

log_header "Manual OMV Configuration Required"

echo "OpenMediaVault has been installed. You now need to configure it via the web UI."
echo ""
echo "  URL:      http://$(hostname -I | awk '{print $1}')"
echo "  Login:    admin"
echo "  Password: openmediavault"
echo ""
echo "Please complete the following steps in the OMV web UI:"
echo ""
echo "  1. Verify omv-extras is installed (System section)"
echo "  2. Check your storage under Storage > RAID Management:"
echo "     - If you had existing RAID arrays, they are already assembled —"
echo "       verify their status here before continuing"
echo "     - To create a NEW RAID array: Storage > Software RAID > +"
echo "       Select the RAID level and drives, then save"
echo "  3. Mount your filesystem under Storage > File Systems,"
echo "     select your drive or RAID array and click Mount"
echo "  4. Create shared folders:"
echo "     - Go to Storage > Shared Folders > +"
echo "     - Use your drive or RAID array"
echo "  5. Enable SMB/CIFS:"
echo "     - Go to Services > SMB/CIFS > Settings (enable and save)"
echo "     - Go to Services > SMB/CIFS > Shares > + (add your shared folder)"
echo "  6. Create a user:"
echo "     - Go to Users > Users > +"
echo ""
echo "After completing these steps, the next step (03_set_data_drive) will"
echo "scan /srv/ for your mounted drive and set up the /media symlink."
echo ""

pause_for_manual_step "Press Enter after completing the OMV web UI setup..."

mark_done "$STEP_NAME"
log "OpenMediaVault installation step complete."
