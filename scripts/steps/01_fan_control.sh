#!/usr/bin/env bash
# =============================================================================
# 01_fan_control.sh - Install and configure fancontrol for the ODROID-HC4
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/config.sh"

STEP_NAME="01_fan_control"

if is_done "$STEP_NAME"; then
    log "Fan control already configured. Skipping."
    exit 0
fi

log_step "Installing fancontrol..."
run apt-get update -qq
run apt-get install -y -qq fancontrol

log_step "Writing fan configuration to /etc/fancontrol..."

FAN_MIN_TEMP="${FAN_MIN_TEMP:-35}"
FAN_MAX_TEMP="${FAN_MAX_TEMP:-70}"

if [[ "$DRY_RUN" != "true" ]]; then
    backup_file "/etc/fancontrol"

    cat > /etc/fancontrol <<EOF
INTERVAL=10
DEVPATH=hwmon0=devices/virtual/thermal/thermal_zone0 hwmon2=devices/platform/pwm-fan
DEVNAME=hwmon0=cpu_thermal hwmon2=pwmfan
FCTEMPS= hwmon2/pwm1=hwmon0/temp1_input
FCFANS= hwmon2/pwm1=hwmon2/fan1_input
MINTEMP= hwmon2/pwm1=${FAN_MIN_TEMP}
MAXTEMP= hwmon2/pwm1=${FAN_MAX_TEMP}
MINSTART= hwmon2/pwm1=10
MINSTOP= hwmon2/pwm1=10
MINPWM= hwmon2/pwm1=10
EOF
else
    log "[DRY RUN] Would write fancontrol config (MINTEMP=${FAN_MIN_TEMP}, MAXTEMP=${FAN_MAX_TEMP})"
fi

log_step "Enabling fancontrol service..."
run systemctl enable --now fancontrol

mark_done "$STEP_NAME"
log "Fan control configured successfully."
