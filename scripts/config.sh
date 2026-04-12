#!/usr/bin/env bash
# =============================================================================
# config.sh - User configuration for ODROID-HC4 Media Center setup
# =============================================================================
#
# Fill in the values below before running setup.sh.
# Lines marked [REQUIRED] must be set. Lines marked [OPTIONAL] have defaults.
#

# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------

# Timezone (https://w.wiki/4Jx)
# [OPTIONAL] Default: Canada/Eastern
TZ="Canada/Eastern"

# User/group IDs for Docker containers.
# Run `id dietpi` to verify. Default DietPi user is UID/GID 1000.
# [OPTIONAL]
PUID=1000
PGID=1000

# -----------------------------------------------------------------------------
# Storage
# -----------------------------------------------------------------------------

# Path where your drive (or RAID array) is mounted by OMV
# (e.g. /srv/dev-disk-by-uuid-XXXX).
# [OPTIONAL] If left empty, step 03 will scan /srv/ and present an interactive
# menu to select your drive. Only set this if you want to skip the interactive
# selection (e.g. for a fully automated/unattended install).
DATA_DRIVE=""

# Base directory for Docker container configs
# [OPTIONAL]
DOCKER_CONFIG_DIR="/home/dietpi/Docker"

# -----------------------------------------------------------------------------
# NordVPN
# -----------------------------------------------------------------------------

# Your NordVPN access token.
# Generate one at: https://my.nordaccount.com/dashboard/nordvpn/
# Leave empty to skip NordVPN setup entirely.
# [OPTIONAL]
NORDVPN_TOKEN=""

# -----------------------------------------------------------------------------
# Advanced
# -----------------------------------------------------------------------------

# Fan control temperature thresholds (Celsius)
# [OPTIONAL]
FAN_MIN_TEMP=35
FAN_MAX_TEMP=70

# State directory for tracking completed steps
# [OPTIONAL]
STATE_DIR="/var/lib/odroid-setup"
