#!/bin/bash
# =============================================================================
# restore-2-auth.sh
# Step 2: Verify rclone auth and restore PBS datastore from Google Drive
#
# Prerequisites:
#   - restore-1-install.sh completed
#   - rclone configured manually (rclone config - see README)
#   - Restic password saved to /etc/resticprofile/restic-password
#
# After this script: run restore-3-pve.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "${SCRIPT_DIR}/config.env" ]; then
    echo "ERROR: config.env not found in ${SCRIPT_DIR}"
    exit 1
fi
source "${SCRIPT_DIR}/config.env"

echo "=== Step 1: Verify rclone access to Google Drive ==="
rclone lsd ${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}
echo "rclone OK"

echo "=== Step 2: Verify restic password file exists ==="
if [ ! -f "${RESTIC_PASSWORD_FILE}" ]; then
    echo "ERROR: ${RESTIC_PASSWORD_FILE} not found!"
    echo "Run: echo 'YOUR-PASSWORD' > ${RESTIC_PASSWORD_FILE} && chmod 600 ${RESTIC_PASSWORD_FILE}"
    exit 1
fi
echo "Password file OK"

echo "=== Step 3: List available restic snapshots ==="
resticprofile -c /etc/resticprofile/profiles.yaml -n pbs-backup snapshots

echo ""
echo "=== The above shows available snapshots in Google Drive ==="
echo "=== Identify the snapshot ID you want to restore (usually 'latest') ==="
echo ""
read -p "Press Enter to restore LATEST snapshot, or Ctrl+C to abort..."

echo "=== Step 4: Stop PBS before restore ==="
systemctl stop proxmox-backup proxmox-backup-proxy || true

echo "=== Step 5: Clear existing PBS datastore ==="
read -p "WARNING: This will DELETE all data in ${PBS_DATASTORE_PATH}. Type 'yes' to continue: " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi
rm -rf ${PBS_DATASTORE_PATH}/*

echo "=== Step 6: Restore from Google Drive ==="
echo "This will take several hours depending on data size and network speed..."
restic \
    -r rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH} \
    --password-file ${RESTIC_PASSWORD_FILE} \
    restore latest \
    --target /

echo ""
echo "=== restore-2-auth.sh COMPLETE ==="
echo ""
echo "PBS datastore restored to ${PBS_DATASTORE_PATH}"
echo "Next step: ./restore-3-pve.sh"
