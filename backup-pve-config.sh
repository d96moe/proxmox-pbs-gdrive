#!/bin/bash
# =============================================================================
# backup-pve-config.sh
# Daily backup of Proxmox host configuration to Google Drive
#
# Backs up:
#   - /etc/pve/          Proxmox cluster config, VM configs, storage config
#   - /etc/network/      Network interfaces
#   - /etc/hosts, /etc/hostname, /etc/resolv.conf
#   - /etc/fstab         Mount points (incl /mnt/pbs)
#   - /root/.config/rclone/   rclone config + Google Drive OAuth token
#   - /etc/resticprofile/     restic profiles + password file
#   - /usr/local/bin/    Our custom scripts
#
# Keeps last 7 config backups on Google Drive.
# =============================================================================

set -euo pipefail

# Load config from same directory as this script, or /etc/proxmox-backup-restore/
CONFIG_FILE="/etc/proxmox-backup-restore/config.env"
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "ERROR: ${CONFIG_FILE} not found"
    exit 1
fi
source "${CONFIG_FILE}"

GDRIVE_CONFIG_PATH="${RESTICPROFILE_GDRIVE_REMOTE}:bu/${GDRIVE_CONFIG_FOLDER}"
TIMESTAMP=$(date +%Y-%m-%d)
TARBALL="/tmp/pve-config-${TIMESTAMP}.tar.gz"
KEEP_DAYS=7

echo "=== Backing up Proxmox host config to Google Drive ==="
echo "    Destination: ${GDRIVE_CONFIG_PATH}"

# Create tarball of critical config files
tar -czf "${TARBALL}" \
    /etc/pve/ \
    /etc/network/interfaces \
    /etc/hosts \
    /etc/hostname \
    /etc/resolv.conf \
    /etc/fstab \
    /root/.config/rclone/ \
    /etc/resticprofile/ \
    /usr/local/bin/stop-proxmox-backup.sh \
    /usr/local/bin/backup-pve-config.sh \
    /etc/proxmox-backup-restore/ \
    /boot/firmware/config.txt \
    2>/dev/null || true

echo "    Tarball size: $(du -sh ${TARBALL} | cut -f1)"

# Upload to Google Drive
rclone copy "${TARBALL}" "${GDRIVE_CONFIG_PATH}/"
echo "    Uploaded: pve-config-${TIMESTAMP}.tar.gz"

# Clean up local temp file
rm -f "${TARBALL}"

# Remove old backups from Google Drive (keep last KEEP_DAYS)
echo "    Pruning old backups (keeping last ${KEEP_DAYS})..."
rclone lsf "${GDRIVE_CONFIG_PATH}/" --include "pve-config-*.tar.gz" \
    | sort -r \
    | tail -n +$((KEEP_DAYS + 1)) \
    | while read -r old_file; do
        echo "    Removing old backup: ${old_file}"
        rclone delete "${GDRIVE_CONFIG_PATH}/${old_file}"
    done

echo "=== Proxmox config backup complete ==="
