#!/bin/bash
# =============================================================================
# restore-3-pve.sh
# Step 3: Configure PBS and PVE after datastore has been restored
#
# Prerequisites:
#   - restore-2-auth.sh completed (datastore restored to /mnt/pbs)
#
# After this script: restore VMs/LXCs via Proxmox GUI
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION - must match restore-1-install.sh
# =============================================================================

PBS_DATASTORE_NAME="local-store"
PBS_DATASTORE_PATH="/mnt/pbs"
PBS_USER="backup@pbs"
PBS_USER_PASSWORD="changeme"       # Must match restore-1-install.sh
PBS_TOKEN_NAME="pve-token"

# PVE storage entry for PBS
PVE_PBS_STORAGE_ID="pbs-local"
PVE_PBS_SERVER="127.0.0.1"

# =============================================================================

echo "=== Step 1: Start PBS ==="
systemctl start proxmox-backup
systemctl start proxmox-backup-proxy
sleep 5

echo "=== Step 2: Re-create PBS datastore (points to restored data) ==="
# Remove if exists, then recreate
proxmox-backup-manager datastore remove ${PBS_DATASTORE_NAME} 2>/dev/null || true
proxmox-backup-manager datastore create ${PBS_DATASTORE_NAME} ${PBS_DATASTORE_PATH}

echo "=== Step 3: Set ACL for backup user ==="
proxmox-backup-manager acl update /datastore/${PBS_DATASTORE_NAME} DatastoreBackup \
    --auth-id ${PBS_USER}

echo "=== Step 4: Get PBS fingerprint ==="
FINGERPRINT=$(proxmox-backup-manager cert info 2>/dev/null | grep "Fingerprint" | awk '{print $2}')
echo "PBS Fingerprint: ${FINGERPRINT}"

echo "=== Step 5: Add PBS storage to PVE ==="
pvesh create /storage \
    --storage ${PVE_PBS_STORAGE_ID} \
    --type pbs \
    --server ${PVE_PBS_SERVER} \
    --datastore ${PBS_DATASTORE_NAME} \
    --username ${PBS_USER} \
    --password "${PBS_USER_PASSWORD}" \
    --fingerprint "${FINGERPRINT}" \
    --content backup \
    --prune-backups "keep-last=3,keep-daily=7,keep-weekly=4"

echo "=== Step 6: Register resticprofile schedules ==="
resticprofile -c /etc/resticprofile/profiles.yaml -n pbs-backup schedule

echo "=== Step 7: Verify snapshots visible in PBS ==="
proxmox-backup-client snapshots \
    --repository ${PBS_USER}@${PVE_PBS_SERVER}:${PBS_DATASTORE_NAME}

echo ""
echo "=== restore-3-pve.sh COMPLETE ==="
echo ""
echo "All PBS snapshots should now be visible in Proxmox GUI:"
echo "  1. Go to your VM/LXC → Backup tab"
echo "  2. Select storage '${PVE_PBS_STORAGE_ID}' in the dropdown"
echo "  3. Select snapshot and click Restore"
echo ""
echo "Don't forget to verify nightly backup schedule is active:"
echo "  systemctl list-timers | grep restic"
