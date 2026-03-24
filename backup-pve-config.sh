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
#   - /boot/firmware/config.txt  Pi5 kernel config (4k page-size setting)
#
# Keeps last CONFIG_KEEP_DAYS config backups on Google Drive.
# =============================================================================

set -euo pipefail

CONFIG_FILE="/etc/proxmox-backup-restore/config.env"
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "ERROR: ${CONFIG_FILE} not found"
    exit 1
fi
source "${CONFIG_FILE}"

GDRIVE_CONFIG_PATH="${RESTICPROFILE_GDRIVE_REMOTE}:bu/${GDRIVE_CONFIG_FOLDER}"
TIMESTAMP=$(date +%Y-%m-%d)
TARBALL="/tmp/pve-config-${TIMESTAMP}.tar.gz"

echo "=== Backing up Proxmox host config to Google Drive ==="
echo "    Destination: ${GDRIVE_CONFIG_PATH}"

# Checkpoint SQLite WAL into the main database before archiving.
# pmxcfs may have recent writes only in the WAL file; without this the
# backup captures a stale config.db that is missing recent changes.
sqlite3 /var/lib/pve-cluster/config.db "PRAGMA wal_checkpoint(FULL);" 2>/dev/null || true

# Create tarball of critical config files
# /boot/firmware/config.txt is Pi5-specific — harmless to include on x86 (will just be missing)
tar -czf "${TARBALL}" \
    /var/lib/pve-cluster/config.db \
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

# Remove old backups from Google Drive (keep last CONFIG_KEEP_DAYS)
echo "    Pruning old backups (keeping last ${CONFIG_KEEP_DAYS})..."
rclone lsf "${GDRIVE_CONFIG_PATH}/" --include "pve-config-*.tar.gz" \
    | sort -r \
    | tail -n +$(( CONFIG_KEEP_DAYS + 1 )) \
    | while read -r old_file; do
        echo "    Removing old backup: ${old_file}"
        rclone delete "${GDRIVE_CONFIG_PATH}/${old_file}"
    done

echo "=== Proxmox config backup complete ==="
