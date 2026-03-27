#!/bin/bash
# =============================================================================
# restore-2-auth.sh
# Step 2: Restore PVE config from backup, then restore PBS datastore from GDrive
#
# Prerequisites:
#   - restore-1-install.sh completed
#
# Config backup restore (Step 1) supports two paths:
#   A) Manual DR: copy pve-config-YYYY-MM-DD.tar.gz to /tmp/ before running.
#      The script finds it, extracts it (restoring rclone auth + restic password),
#      then uses rclone to restore the PBS datastore. No rclone setup needed first.
#   B) Automated / CI: if no local tar exists and rclone is already configured,
#      the latest config backup is downloaded from Google Drive automatically.
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

GDRIVE_CONFIG_PATH="${RESTICPROFILE_GDRIVE_REMOTE}:bu/${GDRIVE_CONFIG_FOLDER}"

echo "=== Step 1: Restore PVE host config ==="

# --- Path A: local tar already on disk (manual DR: downloaded via browser + scp) ---
LOCAL_TAR=$(ls /tmp/pve-config-*.tar.gz.enc /tmp/pve-config-*.tar.gz 2>/dev/null | sort -r | head -1 || true)

if [ -n "${LOCAL_TAR}" ]; then
    echo "Found local config backup: ${LOCAL_TAR}"
    CONFIG_TAR="${LOCAL_TAR}"
    DOWNLOADED=false
else
    # --- Path B: download from Google Drive (rclone must already be configured) ---
    echo "No local tar found. Checking Google Drive (${GDRIVE_CONFIG_PATH})..."
    rclone lsd ${RESTICPROFILE_GDRIVE_REMOTE}:bu
    echo "rclone OK"

    LATEST_CONFIG=$(rclone lsf "${GDRIVE_CONFIG_PATH}/" --include "pve-config-*.tar.gz.enc" 2>/dev/null | sort -r | head -1) || LATEST_CONFIG=""
    # Fall back to unencrypted for backward compatibility
    [ -z "${LATEST_CONFIG}" ] && LATEST_CONFIG=$(rclone lsf "${GDRIVE_CONFIG_PATH}/" --include "pve-config-*.tar.gz" 2>/dev/null | sort -r | head -1) || true
    if [ -z "${LATEST_CONFIG}" ]; then
        if [ "${CI:-}" = "true" ]; then
            echo "ERROR: CI mode — expected a config backup in ${GDRIVE_CONFIG_PATH} but none found."
            echo "Ensure Scenario A (restore-test pipeline) has run at least once first."
            exit 1
        fi
        echo "WARNING: No config backup found in ${GDRIVE_CONFIG_PATH}"
        echo "Continuing without config restore — configure rclone and restic manually before proceeding."
        CONFIG_TAR=""
    else
        echo "Found on GDrive: ${LATEST_CONFIG}"
        rclone copy "${GDRIVE_CONFIG_PATH}/${LATEST_CONFIG}" /tmp/
        CONFIG_TAR="/tmp/${LATEST_CONFIG}"
        DOWNLOADED=true
    fi
fi

if [ -n "${CONFIG_TAR}" ]; then
    # Decrypt if encrypted
    if [[ "${CONFIG_TAR}" == *.enc ]]; then
        DECRYPTED="${CONFIG_TAR%.enc}"
        echo "Decrypting config tarball..."
        if [ -f "${CONFIG_ENCRYPT_PASSWORD_FILE:-}" ]; then
            openssl enc -d -aes-256-cbc -pbkdf2 \
                -in "${CONFIG_TAR}" -out "${DECRYPTED}" \
                -pass file:"${CONFIG_ENCRYPT_PASSWORD_FILE}"
        else
            read -s -p "Config tarball encryption password: " _enc_pass
            echo
            printf '%s' "${_enc_pass}" | openssl enc -d -aes-256-cbc -pbkdf2 \
                -in "${CONFIG_TAR}" -out "${DECRYPTED}" -pass stdin
            unset _enc_pass
        fi
        rm -f "${CONFIG_TAR}"
        CONFIG_TAR="${DECRYPTED}"
    fi

    echo "Extracting config..."
    # /etc/pve is a pmxcfs FUSE filesystem — the authoritative data is
    # /var/lib/pve-cluster/config.db; pmxcfs regenerates /etc/pve from it
    # on startup. Stop pve-cluster so the FUSE mount is gone, restore config.db
    # (and all other files), then restart so pmxcfs rebuilds /etc/pve.
    systemctl stop pve-cluster 2>/dev/null || true
    sleep 2
    # Remove stale WAL files — if left over from the running cluster, they would
    # override the restored config.db when pve-cluster restarts.
    rm -f /var/lib/pve-cluster/config.db-wal \
          /var/lib/pve-cluster/config.db-shm 2>/dev/null || true
    tar -xzf "${CONFIG_TAR}" -C / \
        --exclude='./etc/pve' \
        --exclude='etc/pve'
    [ "${DOWNLOADED:-false}" = "true" ] && rm -f "${CONFIG_TAR}"
    echo "Restarting pve-cluster with restored config.db..."
    systemctl start pve-cluster
    sleep 5
    systemctl is-active pve-cluster && echo "pve-cluster: OK" || \
        { journalctl -u pve-cluster -n 10 --no-pager; exit 1; }
    echo "Config restored! PVE config, rclone auth and restic password are now in place."
fi

echo "=== Step 2: Verify rclone access to Google Drive ==="
rclone lsd ${RESTICPROFILE_GDRIVE_REMOTE}:bu
echo "rclone OK"

echo "=== Step 3: Verify restic password file exists ==="
if [ ! -f "${RESTIC_PASSWORD_FILE}" ]; then
    echo "ERROR: ${RESTIC_PASSWORD_FILE} not found!"
    echo "Run: echo 'YOUR-PASSWORD' > ${RESTIC_PASSWORD_FILE} && chmod 600 ${RESTIC_PASSWORD_FILE}"
    exit 1
fi
echo "Password file OK"

echo "=== Step 4: List available restic snapshots ==="
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

echo "=== Step 5: Stop PBS before restore ==="
systemctl stop proxmox-backup proxmox-backup-proxy || true

echo "=== Step 6: Clear existing PBS datastore ==="
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

echo "=== Step 7: Restore from Google Drive ==="
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
