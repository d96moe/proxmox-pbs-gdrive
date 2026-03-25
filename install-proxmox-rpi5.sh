#!/bin/bash
# =============================================================================
# install-proxmox-rpi5.sh
#
# This script is now a thin wrapper. Proxmox VE installation for Raspberry Pi 5
# is handled directly by restore-1-install.sh (Step 0).
#
# Just run restore-1-install.sh:
#   cp config_rpi5.env config.env
#   nano config.env    # set PVE_HOSTNAME, PVE_IP, PVE_IFACE, PBS_PARTITION, PBS_USER_PASSWORD
#   ./restore-1-install.sh
#
# restore-1-install.sh detects that PVE is not yet installed and handles:
#   - pxvirt repo + proxmox-ve install
#   - vmbr0 bridge configuration
#   - 4k kernel switch (required for PBS on Pi5)
#   - reboot
# After reboot, run restore-1-install.sh again to install PBS + tools.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/restore-1-install.sh" "$@"
