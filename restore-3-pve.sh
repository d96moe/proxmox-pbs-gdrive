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

echo "=== Step 2: Ensure PBS datastore is registered ==="
# restore-1-install.sh already created the datastore at PBS_DATASTORE_PATH.
# After restic restores data to that path, PBS finds the chunks automatically
# on restart. Only create the config entry if it is genuinely missing.
# Do NOT remove-then-create: 'datastore create' rejects non-empty paths.
if proxmox-backup-manager datastore list 2>/dev/null | grep -q "${PBS_DATASTORE_NAME}"; then
    echo "  Datastore ${PBS_DATASTORE_NAME} already registered — PBS will use restored data"
else
    proxmox-backup-manager datastore create ${PBS_DATASTORE_NAME} ${PBS_DATASTORE_PATH}
fi

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

echo "=== Step 6: Set PBS prune and GC schedules ==="
# prune is a separate prune-job, NOT a datastore-level setting
proxmox-backup-manager prune-job create nightly-prune \
    --store ${PBS_DATASTORE_NAME} \
    --schedule "${PBS_PRUNE_SCHEDULE}" \
    --keep-last 3 2>/dev/null || \
proxmox-backup-manager prune-job update nightly-prune \
    --schedule "${PBS_PRUNE_SCHEDULE}"
proxmox-backup-manager datastore update ${PBS_DATASTORE_NAME} \
    --gc-schedule "${PBS_GC_SCHEDULE}"

echo "=== Step 7: Install restic backup script + systemd timer ==="
# Order: PBS BU (02:00) → PBS Prune (03:00) → PBS GC (03:30) → restic backup+forget (RESTIC_BACKUP_SCHEDULE)
# The script stops PBS, snapshots the clean post-prune datastore (tagged per VM/LXC),
# runs forget/prune for Google Drive retention, then restarts PBS.

install -m 750 "${SCRIPT_DIR}/backup-restic-vms.sh" /usr/local/bin/backup-restic-vms.sh

# systemd service
cat > /etc/systemd/system/restic-backup.service << SVCEOF
[Unit]
Description=restic backup of PBS datastore to Google Drive
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/usr/local/bin/backup-restic-vms.sh
TimeoutStartSec=8h
StandardOutput=journal
StandardError=journal
SVCEOF

# systemd timer
cat > /etc/systemd/system/restic-backup.timer << TIMEREOF
[Unit]
Description=Run restic backup nightly after PBS prune

[Timer]
OnCalendar=${RESTIC_BACKUP_SCHEDULE}
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

systemctl daemon-reload
systemctl enable --now restic-backup.timer

echo "=== Step 9: Verify snapshots visible in PBS ==="
proxmox-backup-client snapshots \
    --repository ${PBS_USER}@${PVE_PBS_SERVER}:${PBS_DATASTORE_NAME}

echo ""
echo "=== restore-3-pve.sh COMPLETE ==="
echo ""
echo "All PBS snapshots should now be visible in Proxmox GUI:"
echo "  1. Go to Datacenter -> Storage -> ${PVE_PBS_STORAGE_ID} -> Content"
echo "  2. Select snapshot and click Restore"
echo ""
echo "Verify schedules:"
echo "  proxmox-backup-manager prune-job list"
echo "  proxmox-backup-manager datastore show ${PBS_DATASTORE_NAME}"
echo "  systemctl list-timers | grep restic"
echo "  systemctl status restic-backup.timer"
echo ""
echo "Manual restic backup run:"
echo "  systemctl start restic-backup.service"
echo "  journalctl -u restic-backup -f"
