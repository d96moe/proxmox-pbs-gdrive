#!/bin/bash
# =============================================================================
# backup-restic-vms.sh
# Nightly restic backup of PBS datastore to Google Drive
#
# Backs up the full PBS datastore as one restic snapshot, but tags it with
# every VM/LXC ID present so the backup GUI can identify per-VM cloud coverage.
#
# Tags added: vm-100, vm-101, ct-104, ct-105, ...
#
# Flow:
#   1. Stop PBS (so restic sees a consistent on-disk state)
#   2. Discover all VM/LXC IDs from the datastore directory
#   3. Run restic backup with --tag per VM/LXC
#   4. Run restic forget (prune Google Drive retention)
#   5. Start PBS again
#
# Called by systemd timer: restic-backup.timer
# =============================================================================

set -euo pipefail

CONFIG_FILE="/etc/proxmox-backup-restore/config.env"
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "ERROR: ${CONFIG_FILE} not found"
    exit 1
fi
source "${CONFIG_FILE}"

RESTIC_REPO="rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}"

echo "=== restic VM backup started: $(date) ==="

# ── 1. Stop PBS ──────────────────────────────────────────────────────────────
echo "--- Stopping PBS..."
systemctl stop proxmox-backup proxmox-backup-proxy || true
sync

# Ensure PBS restarts on exit (including error)
trap 'echo "--- Restarting PBS..."; systemctl start proxmox-backup proxmox-backup-proxy || true' EXIT

# ── 2. Discover VM/LXC IDs from datastore ────────────────────────────────────
echo "--- Scanning PBS datastore: ${PBS_DATASTORE_PATH}"
TAG_ARGS=()
for backup_type in vm ct; do
    type_dir="${PBS_DATASTORE_PATH}/${backup_type}"
    if [ ! -d "${type_dir}" ]; then
        continue
    fi
    for id_dir in "${type_dir}"/*/; do
        id=$(basename "${id_dir}")
        # Only numeric IDs
        [[ "${id}" =~ ^[0-9]+$ ]] || continue
        # Tag once per PBS snapshot with exact backup timestamp: ct-301-1775554738
        # This allows the GUI to match cloud entries back to exact PBS snapshots.
        for snap_dir in "${id_dir}"*/; do
            snap=$(basename "${snap_dir}")
            ts=$(date -d "${snap}" +%s 2>/dev/null) || continue
            TAG_ARGS+=("--tag" "${backup_type}-${id}-${ts}")
            echo "    Found: ${backup_type}-${id} @ ${snap} (ts=${ts})"
        done
    done
done

if [ ${#TAG_ARGS[@]} -eq 0 ]; then
    echo "WARNING: No VMs or containers found in datastore — backing up untagged"
fi

# ── 3. Run restic backup ──────────────────────────────────────────────────────
echo "--- Running restic backup (timeout 6h)..."
timeout 6h restic backup "${PBS_DATASTORE_PATH}" \
    --password-file "${RESTIC_PASSWORD_FILE}" \
    --repo "${RESTIC_REPO}" \
    --exclude "${PBS_DATASTORE_PATH}/.lock" \
    "${TAG_ARGS[@]}" || { echo "ERROR: restic backup failed or timed out (exit $?)"; exit 1; }

# ── 4. Forget / prune ────────────────────────────────────────────────────────
echo "--- Running restic forget (timeout 3h)..."
timeout 3h restic forget \
    --password-file "${RESTIC_PASSWORD_FILE}" \
    --repo "${RESTIC_REPO}" \
    --keep-last    "${RESTIC_RETENTION_KEEP_LAST}" \
    --keep-daily   "${RESTIC_RETENTION_KEEP_DAILY}" \
    --keep-weekly  "${RESTIC_RETENTION_KEEP_WEEKLY}" \
    --keep-monthly "${RESTIC_RETENTION_KEEP_MONTHLY}" \
    --prune || { echo "ERROR: restic forget failed or timed out (exit $?)"; exit 1; }

# ── 5. Empty Google Drive trash ──────────────────────────────────────────────
# Deleted packs end up in GDrive trash and count against quota until emptied.
echo "--- Emptying Google Drive trash..."
rclone cleanup "${RESTICPROFILE_GDRIVE_REMOTE}:" || true

echo "=== restic VM backup complete: $(date) ==="
