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
# Prunes config tarballs to match restic snapshot dates — so every kept
# tarball has a corresponding restic snapshot to restore from.
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
ENCRYPTED="${TARBALL}.enc"

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

# Encrypt tarball before upload
openssl enc -aes-256-cbc -pbkdf2 \
    -in "${TARBALL}" -out "${ENCRYPTED}" \
    -pass file:"${CONFIG_ENCRYPT_PASSWORD_FILE}"
rm -f "${TARBALL}"
echo "    Encrypted: pve-config-${TIMESTAMP}.tar.gz.enc"

# Upload to Google Drive
rclone copy "${ENCRYPTED}" "${GDRIVE_CONFIG_PATH}/"
echo "    Uploaded: pve-config-${TIMESTAMP}.tar.gz.enc"
rm -f "${ENCRYPTED}"

# Prune config tarballs: keep only dates that match a live restic snapshot.
# restic forget has already run before this script (04:30 vs 05:00), so the
# snapshot list reflects the final retention policy.
# Always keep today's tarball even if the restic query fails or today's
# snapshot hasn't landed yet.
echo "    Pruning config tarballs to match restic snapshot dates..."

RESTIC_DATES=$(restic \
    --repo "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
    --password-file "${RESTIC_PASSWORD_FILE}" \
    --no-lock \
    snapshots --json 2>/dev/null \
  | python3 -c "
import sys, json
try:
    snapshots = json.load(sys.stdin)
    dates = {s['time'][:10] for s in snapshots}
    print('\n'.join(sorted(dates)))
except Exception:
    pass" 2>/dev/null || true)

if [ -z "${RESTIC_DATES}" ]; then
    echo "    WARNING: could not query restic snapshots — skipping tarball prune"
else
    KEEP_DATES="${RESTIC_DATES}"$'\n'"${TIMESTAMP}"

    rclone lsf "${GDRIVE_CONFIG_PATH}/" --include "pve-config-*.tar.gz.enc" \
        | while read -r fname; do
            fdate="${fname#pve-config-}"
            fdate="${fdate%.tar.gz.enc}"
            if ! printf '%s\n' ${KEEP_DATES} | grep -qx "${fdate}"; then
                echo "    Removing: ${fname} (no matching restic snapshot)"
                rclone delete "${GDRIVE_CONFIG_PATH}/${fname}"
            fi
        done
fi

echo "=== Proxmox config backup complete ==="
