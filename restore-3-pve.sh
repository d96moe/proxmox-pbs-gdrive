#!/bin/bash
# =============================================================================
# restore-3-pve.sh
# Step 3: Configure PBS and PVE after datastore has been restored
#
# Prerequisites:
#   - restore-2-auth.sh completed (datastore restored to PBS_DATASTORE_PATH)
#
# After this script: restore VMs/LXCs via Proxmox GUI
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "${SCRIPT_DIR}/config.env" ]; then
    echo "ERROR: config.env not found in ${SCRIPT_DIR}"
    exit 1
fi
source "${SCRIPT_DIR}/config.env"

echo "=== Step 1: Start PBS ==="
systemctl start proxmox-backup
systemctl start proxmox-backup-proxy
sleep 5

echo "=== Step 2: Re-create PBS datastore (points to restored data) ==="
proxmox-backup-manager datastore remove ${PBS_DATASTORE_NAME} 2>/dev/null || true
proxmox-backup-manager datastore create ${PBS_DATASTORE_NAME} ${PBS_DATASTORE_PATH}

echo "=== Step 3: Set ACL for backup user ==="
proxmox-backup-manager acl update /datastore/${PBS_DATASTORE_NAME} DatastoreAdmin \
    --auth-id ${PBS_USER}

echo "=== Step 4: Get PBS fingerprint ==="
FINGERPRINT=$(proxmox-backup-manager cert info 2>/dev/null | grep "Fingerprint (sha256):" | awk '{print $NF}')
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
    --prune-backups "${PBS_RETENTION_LOCAL}"

echo "=== Step 6: Register resticprofile schedules ==="
resticprofile -c /etc/resticprofile/profiles.yaml -n pbs-backup schedule

echo "=== Step 7: Verify snapshots visible in PBS ==="
proxmox-backup-client snapshots \
    --repository ${PBS_USER}@${PVE_PBS_SERVER}:${PBS_DATASTORE_NAME}

echo ""
echo "=== restore-3-pve.sh COMPLETE ==="
echo ""
echo "All PBS snapshots should now be visible in Proxmox GUI:"
echo "  1. Go to Datacenter -> Storage -> ${PVE_PBS_STORAGE_ID} -> Content"
echo "  2. Select snapshot and click Restore"
echo ""
echo "Verify nightly backup schedule:"
echo "  systemctl list-timers | grep restic"
