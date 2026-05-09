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
#   0. Wait for any running PBS backup to complete
#   1. Run PBS prune (so restic only sees snapshots that will be kept)
#   2. Wait for prune to complete
#   3. Stop PBS (so restic sees a consistent on-disk state)
#   4. Discover all PBS snapshot tags from the datastore
#   5. Run restic backup
#   6. Run restic forget/prune (cloud retention)
#   7. Start PBS again
#   8. Empty Google Drive trash
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
PBS_PRUNE_JOB_ID="${PBS_PRUNE_JOB_ID:-nightly-prune}"

# ── helpers ───────────────────────────────────────────────────────────────────

_pbs_running_task_count() {
    # Count running PBS tasks whose worker-type contains $1.
    # Avoid a pipeline so pipefail doesn't propagate a non-zero exit from
    # proxmox-backup-manager (which can fail when PBS is busy with a backup).
    local pattern="$1"
    local json
    json=$(proxmox-backup-manager task list --output-format json 2>/dev/null) || json="[]"
    echo "${json}" | python3 -c "
import json, sys
pattern = sys.argv[1]
try:
    tasks = json.load(sys.stdin)
    print(sum(1 for t in tasks if not t.get('endtime') and pattern in t.get('worker-type', '')))
except Exception:
    print(0)
" "${pattern}"
}

wait_for_pbs_tasks() {
    local pattern="$1"
    local label="$2"
    local max_wait="${3:-14400}"
    local interval=30
    local elapsed=0
    while [ "$(_pbs_running_task_count "${pattern}")" != "0" ]; do
        echo "--- ${label} still running (${elapsed}s elapsed), waiting ${interval}s..."
        sleep "${interval}"
        elapsed=$((elapsed + interval))
        if [ "${elapsed}" -ge "${max_wait}" ]; then
            echo "ERROR: ${label} did not complete within ${max_wait}s — aborting"
            exit 1
        fi
    done
    if [ "${elapsed}" -gt 0 ]; then
        echo "--- ${label} done (waited ${elapsed}s)"
    fi
}

echo "=== restic VM backup started: $(date) ==="

# ── 0. Wait for PBS backup ────────────────────────────────────────────────────
echo "--- Checking for running PBS backup tasks..."
wait_for_pbs_tasks "backup" "PBS backup" 14400

# ── 1-2. PBS prune ────────────────────────────────────────────────────────────
echo "--- Running PBS prune job: ${PBS_PRUNE_JOB_ID}"
if proxmox-backup-manager prune-job run "${PBS_PRUNE_JOB_ID}" 2>&1; then
    wait_for_pbs_tasks "prune" "PBS prune" 3600
else
    echo "WARNING: prune-job run failed — continuing without prune"
fi

# ── 3. Stop PBS ───────────────────────────────────────────────────────────────
echo "--- Stopping PBS..."
systemctl stop proxmox-backup proxmox-backup-proxy || true
sync

trap 'echo "--- Restarting PBS..."; systemctl start proxmox-backup proxmox-backup-proxy || true' EXIT

# ── 4. Discover VM/LXC IDs from datastore ────────────────────────────────────
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

# ── 5. Run restic backup ──────────────────────────────────────────────────────
echo "--- Running restic backup (timeout 6h)..."
timeout 6h restic backup --retry-lock 30m "${PBS_DATASTORE_PATH}" \
    --password-file "${RESTIC_PASSWORD_FILE}" \
    --repo "${RESTIC_REPO}" \
    --exclude "${PBS_DATASTORE_PATH}/.lock" \
    "${TAG_ARGS[@]}" || { echo "ERROR: restic backup failed or timed out (exit $?)"; exit 1; }

# ── 6. Forget / prune ────────────────────────────────────────────────────────
# Build retention flags — only include a flag if the env var is set and non-zero.
FORGET_ARGS=()
[ "${RESTIC_RETENTION_KEEP_LAST:-0}" != "0" ]    && FORGET_ARGS+=("--keep-last"    "${RESTIC_RETENTION_KEEP_LAST}")
[ "${RESTIC_RETENTION_KEEP_DAILY:-0}" != "0" ]   && FORGET_ARGS+=("--keep-daily"   "${RESTIC_RETENTION_KEEP_DAILY}")
[ "${RESTIC_RETENTION_KEEP_WEEKLY:-0}" != "0" ]  && FORGET_ARGS+=("--keep-weekly"  "${RESTIC_RETENTION_KEEP_WEEKLY}")
[ "${RESTIC_RETENTION_KEEP_MONTHLY:-0}" != "0" ] && FORGET_ARGS+=("--keep-monthly" "${RESTIC_RETENTION_KEEP_MONTHLY}")
[ "${RESTIC_RETENTION_KEEP_YEARLY:-0}" != "0" ]  && FORGET_ARGS+=("--keep-yearly"  "${RESTIC_RETENTION_KEEP_YEARLY}")

if [ ${#FORGET_ARGS[@]} -eq 0 ]; then
    echo "WARNING: No retention policy configured — skipping forget/prune"
else
    echo "--- Running restic forget (timeout 7h): ${FORGET_ARGS[*]}..."
    timeout 7h restic forget --retry-lock 30m \
        --password-file "${RESTIC_PASSWORD_FILE}" \
        --repo "${RESTIC_REPO}" \
        "${FORGET_ARGS[@]}" \
        --max-repack-size 100G \
        --prune || { echo "ERROR: restic forget failed or timed out (exit $?)"; exit 1; }
fi

# ── 7. Empty Google Drive trash ───────────────────────────────────────────────
echo "--- Emptying Google Drive trash..."
rclone cleanup "${RESTICPROFILE_GDRIVE_REMOTE}:" || true

echo "=== restic VM backup complete: $(date) ==="
