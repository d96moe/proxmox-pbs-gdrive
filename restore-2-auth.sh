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
rclone lsd ${RESTICPROFILE_GDRIVE_REMOTE}:bu
echo "rclone OK"

echo "=== Step 2: Download and restore PVE host config ==="
GDRIVE_CONFIG_PATH="${RESTICPROFILE_GDRIVE_REMOTE}:bu/${GDRIVE_CONFIG_FOLDER}"
echo "Looking for latest config backup in ${GDRIVE_CONFIG_PATH}..."

LATEST_CONFIG=$(rclone lsf "${GDRIVE_CONFIG_PATH}/" --include "pve-config-*.tar.gz" 2>/dev/null | sort -r | head -1) || LATEST_CONFIG=""
if [ -z "${LATEST_CONFIG}" ]; then
    if [ "${CI:-}" = "true" ]; then
        echo "ERROR: CI mode — expected a config backup in ${GDRIVE_CONFIG_PATH} but none found."
        echo "Ensure Scenario A (restore-test pipeline) has run at least once first."
        exit 1
    fi
    echo "WARNING: No config backup found in ${GDRIVE_CONFIG_PATH}"
    echo "Continuing without config restore — you will need to configure rclone and restic manually"
else
    echo "Found: ${LATEST_CONFIG}"
    rclone copy "${GDRIVE_CONFIG_PATH}/${LATEST_CONFIG}" /tmp/
    echo "Extracting config..."
    tar -xzf "/tmp/${LATEST_CONFIG}" -C /
    rm -f "/tmp/${LATEST_CONFIG}"
    echo "Config restored! rclone auth, restic password and PVE config are now in place."
fi

echo "=== Step 4: Verify restic password file exists ==="
if [ ! -f "${RESTIC_PASSWORD_FILE}" ]; then
    echo "ERROR: ${RESTIC_PASSWORD_FILE} not found!"
    echo "Run: echo 'YOUR-PASSWORD' > ${RESTIC_PASSWORD_FILE} && chmod 600 ${RESTIC_PASSWORD_FILE}"
    exit 1
fi
echo "Password file OK"

echo "=== Step 5: List available restic snapshots ==="
resticprofile -c /etc/resticprofile/profiles.yaml -n pbs-backup snapshots

echo ""
echo "=== The above shows available snapshots in Google Drive ==="
echo "=== Identify the snapshot ID you want to restore (usually 'latest') ==="
echo ""
if [ "${CI:-}" = "true" ]; then
    echo "CI mode: skipping restore confirmation prompt, continuing automatically."
else
    read -p "Press Enter to restore LATEST snapshot, or Ctrl+C to abort..."
fi

echo "=== Step 6: Stop PBS before restore ==="
systemctl stop proxmox-backup proxmox-backup-proxy || true

echo "=== Step 7: Clear existing PBS datastore ==="
if [ "${CI:-}" = "true" ]; then
    echo "CI mode: auto-confirming deletion of ${PBS_DATASTORE_PATH}."
else
    read -p "WARNING: This will DELETE all data in ${PBS_DATASTORE_PATH}. Type 'yes' to continue: " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi
rm -rf ${PBS_DATASTORE_PATH}/*

echo "=== Step 8: Restore from Google Drive ==="
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
