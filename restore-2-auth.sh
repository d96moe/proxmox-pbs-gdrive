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
# Then (Step 4) the config and the restic snapshot are paired BY DATE: the
# newest day that has both is restored, however old it is. With Path A the
# tarball you put in /tmp decides the date. RESTORE_DATE=YYYY-MM-DD forces a day.
# No pair → CI fails; interactively you must type 'mismatch' to go on.
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

# shellcheck source=lib/restore-pair.sh
. "${SCRIPT_DIR}/lib/restore-pair.sh"

# Optional environment:
#   RESTORE_DATE=YYYY-MM-DD   force one day (tarball AND snapshot from that date).
#                             Without it: the newest date that has BOTH, however old.
#   RESTORE_CONFIG_FOLDER=x   read config tarballs from bu/x instead of
#                             GDRIVE_CONFIG_FOLDER (e.g. another host's folder).
#   RESTORE_PLAN_ONLY=1       run steps 1-4 for real (download, decrypt, extract,
#                             pair) and stop before PBS is touched; prints a
#                             'RESTORE_PLAN ...' line. Used by the CI pairing tests.
RESTORE_DATE="${RESTORE_DATE:-}"
GDRIVE_CONFIG_PATH="${RESTICPROFILE_GDRIVE_REMOTE}:bu/${RESTORE_CONFIG_FOLDER:-${GDRIVE_CONFIG_FOLDER}}"
RESTIC_REPO="rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}"

# decrypt_config_tar <path> — prints the path of the plain .tar.gz
decrypt_config_tar() {
    local in="$1" out
    if [[ "${in}" != *.enc ]]; then echo "${in}"; return 0; fi
    out="${in%.enc}"
    echo "Decrypting $(basename "${in}")..." >&2
    # Called inside $(...), where set -e does not apply: check openssl explicitly
    # and keep the encrypted file if it fails (wrong password → try again).
    local rc=0
    if [ -f "${CONFIG_ENCRYPT_PASSWORD_FILE:-}" ]; then
        openssl enc -d -aes-256-cbc -pbkdf2 -in "${in}" -out "${out}" \
            -pass file:"${CONFIG_ENCRYPT_PASSWORD_FILE}" || rc=$?
    else
        local _enc_pass
        read -r -s -p "Config tarball encryption password: " _enc_pass || true
        echo >&2
        printf '%s' "${_enc_pass}" | openssl enc -d -aes-256-cbc -pbkdf2 \
            -in "${in}" -out "${out}" -pass stdin || rc=$?
        unset _enc_pass
    fi
    if [ "${rc}" -ne 0 ]; then
        rm -f "${out}"
        echo "ERROR: could not decrypt $(basename "${in}") (wrong password?)" >&2
        return 1
    fi
    rm -f "${in}"
    echo "${out}"
}

# extract_config_tar <plain tar.gz> [keep-creds]
# keep-creds: re-extracting an OLDER tarball to match the snapshot date — keep the
# rclone token and restic password that are already in place (from the newest
# tarball), so a later credential change can't lock us out of the repo.
extract_config_tar() {
    local tar_file="$1" keep="${2:-}"
    local excl=(--exclude='./etc/pve' --exclude='etc/pve')
    if [ "${keep}" = "keep-creds" ]; then
        excl+=(--exclude='root/.config/rclone' --exclude='./root/.config/rclone'
               --exclude='etc/resticprofile'   --exclude='./etc/resticprofile')
    fi
    # The pairing goes by the date in the FILE NAME (stamped by backup-pve-config.sh
    # when it made the tarball). Cross-check it against config.db's own mtime
    # inside the archive and warn on a mismatch, e.g. a renamed file.
    local name_date db_date diff_days
    name_date="$(tarball_date "${tar_file}")"
    db_date="$(tar -tvzf "${tar_file}" var/lib/pve-cluster/config.db 2>/dev/null | awk 'NR==1 {print $4}' || true)"
    if [ -n "${db_date}" ] && [ -n "${name_date}" ]; then
        diff_days=$(( ( $(date -d "${name_date}" +%s) - $(date -d "${db_date}" +%s) ) / 86400 ))
        if [ "${diff_days#-}" -gt 1 ]; then
            echo "WARNING: $(basename "${tar_file}") is named ${name_date}, but its config.db is from ${db_date}."
            echo "         The pairing uses the name; make sure this is the tarball you meant."
        fi
    fi
    echo "Extracting config ($(basename "${tar_file}"))..."
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
    tar -xzf "${tar_file}" -C / "${excl[@]}"
    echo "Restarting pve-cluster with restored config.db..."
    systemctl start pve-cluster
    sleep 5
    systemctl is-active pve-cluster && echo "pve-cluster: OK" || \
        { journalctl -u pve-cluster -n 10 --no-pager; exit 1; }
}

# gdrive_tarball_dates — dates of the encrypted tarballs on GDrive, one per line
gdrive_tarball_dates() {
    local f
    rclone lsf "${GDRIVE_CONFIG_PATH}/" --include "pve-config-*.tar.gz.enc" \
        | while read -r f; do tarball_date "${f}"; done
}

echo "=== Step 1: Restore PVE host config (and the credentials inside it) ==="
# The tarball holds the rclone token and the restic password, so it comes first.
# Step 4 then checks that a restic snapshot exists for the SAME date and, if
# not, switches to the newest date that has both.

# --- Path A: local tar already on disk (manual DR: downloaded via browser + scp) ---
LOCAL_TAR=$(ls /tmp/pve-config-*.tar.gz.enc /tmp/pve-config-*.tar.gz 2>/dev/null | sort -r | awk 'NR==1' || true)
CONFIG_SOURCE=""
CONFIG_TAR=""
TAR_DATE=""

if [ -n "${LOCAL_TAR}" ]; then
    echo "Found local config backup: ${LOCAL_TAR}"
    CONFIG_TAR="${LOCAL_TAR}"
    CONFIG_SOURCE="local"
else
    # --- Path B: download from Google Drive (rclone must already be configured) ---
    echo "No local tar found. Checking Google Drive (${GDRIVE_CONFIG_PATH})..."
    rclone lsd ${RESTICPROFILE_GDRIVE_REMOTE}:bu >/dev/null
    echo "rclone OK"
    if [ -n "${RESTORE_DATE}" ]; then
        WANT_DATE="${RESTORE_DATE}"
    else
        WANT_DATE="$(gdrive_tarball_dates | sort | sed -n '$p')"
    fi
    if [ -z "${WANT_DATE}" ]; then
        if [ "${CI:-}" = "true" ]; then
            echo "ERROR: CI mode — expected a config backup in ${GDRIVE_CONFIG_PATH} but none found."
            echo "Ensure Scenario A has run at least once first."
            exit 1
        fi
        echo "WARNING: No encrypted config backup found in ${GDRIVE_CONFIG_PATH}"
        echo "Continuing without config restore — configure rclone and restic manually before proceeding."
    else
        echo "Using from GDrive: pve-config-${WANT_DATE}.tar.gz.enc"
        rclone copy "${GDRIVE_CONFIG_PATH}/pve-config-${WANT_DATE}.tar.gz.enc" /tmp/
        CONFIG_TAR="/tmp/pve-config-${WANT_DATE}.tar.gz.enc"
        [ -f "${CONFIG_TAR}" ] || { echo "ERROR: pve-config-${WANT_DATE}.tar.gz.enc not found on GDrive"; exit 1; }
        CONFIG_SOURCE="gdrive"
    fi
fi

if [ -n "${CONFIG_TAR}" ]; then
    TAR_DATE="$(tarball_date "${CONFIG_TAR}")"
    if [ "${CONFIG_SOURCE}" = "local" ] && [ -n "${RESTORE_DATE}" ] && [ "${RESTORE_DATE}" != "${TAR_DATE}" ]; then
        echo "ERROR: RESTORE_DATE=${RESTORE_DATE} but the local tarball is from ${TAR_DATE} — remove one of them"
        exit 1
    fi
    CONFIG_TAR="$(decrypt_config_tar "${CONFIG_TAR}")"
    extract_config_tar "${CONFIG_TAR}"
    [ "${CONFIG_SOURCE}" = "gdrive" ] && rm -f "${CONFIG_TAR}"
    echo "Config restored (${TAR_DATE}): PVE config, rclone auth and restic password are now in place."
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

echo "=== Step 4: Pick a config + snapshot pair from the same date ==="
resticprofile -c /etc/resticprofile/profiles.yaml -n pbs-backup snapshots

# "YYYY-MM-DD <id>" per snapshot, oldest first. The date is the snapshot's own
# local date — the same rule backup-pve-config.sh uses to prune tarballs.
SNAP_LINES="$(restic -r "${RESTIC_REPO}" --password-file "${RESTIC_PASSWORD_FILE}" --no-lock \
    snapshots --json | python3 -c '
import json, sys
for s in sorted(json.load(sys.stdin), key=lambda s: s["time"]):
    print(s["time"][:10], s["short_id"])')"
[ -n "${SNAP_LINES}" ] || { echo "ERROR: no restic snapshots in ${RESTIC_REPO}"; exit 1; }
SNAP_DATES="$(awk '{print $1}' <<< "${SNAP_LINES}")"
NEWEST_SNAP_DATE="$(sed -n '$s/ .*//p' <<< "${SNAP_LINES}")"

PAIR_DATE=""
SWITCHED=0     # 1 = re-extracted an older tarball to match the snapshot date
MISMATCH=0     # 1 = no pair; the user typed 'mismatch' and goes on regardless
if [ -z "${CONFIG_TAR}" ]; then
    # No config tarball at all (credentials set up by hand): nothing to pair with.
    PAIR_DATE="${RESTORE_DATE:-${NEWEST_SNAP_DATE}}"
    echo "No config tarball was restored — using the snapshot from ${PAIR_DATE}"
else
    if [ "${CONFIG_SOURCE}" = "local" ]; then
        TAR_DATES="${TAR_DATE}"      # you chose this tarball; only its date can match
    else
        TAR_DATES="$(gdrive_tarball_dates)"
    fi
    if PAIR_DATE="$(pick_restore_date "${TAR_DATES}" "${SNAP_DATES}" "${RESTORE_DATE}")"; then
        if [ "${PAIR_DATE}" != "${TAR_DATE}" ]; then
            echo ""
            echo "NOTE: the newest config tarball (${TAR_DATE}) has no restic snapshot from that day."
            echo "      Switching to the newest date that has both: ${PAIR_DATE}."
            echo "      (Credentials stay from ${TAR_DATE}; only the PVE config is taken from ${PAIR_DATE}.)"
            rclone copy "${GDRIVE_CONFIG_PATH}/pve-config-${PAIR_DATE}.tar.gz.enc" /tmp/
            PAIR_TAR="$(decrypt_config_tar "/tmp/pve-config-${PAIR_DATE}.tar.gz.enc")"
            extract_config_tar "${PAIR_TAR}" keep-creds
            rm -f "${PAIR_TAR}"
            SWITCHED=1
        fi
    else
        echo ""
        echo "WARNING: no matching config + snapshot pair (see above)."
        echo "  Restoring anyway means config.db (${TAR_DATE}) and the PBS datastore"
        echo "  (newest snapshot: ${NEWEST_SNAP_DATE}) describe different days: some guests"
        echo "  may have no backup, or backups may exist for guests PVE doesn't know."
        if [ "${CI:-}" = "true" ]; then
            echo "ERROR: CI mode — refusing a mismatched restore"
            exit 1
        fi
        read -r -p "Type 'mismatch' to restore the newest snapshot anyway, anything else aborts: " ans
        [ "${ans}" = "mismatch" ] || { echo "Aborted."; exit 1; }
        PAIR_DATE="${NEWEST_SNAP_DATE}"
        MISMATCH=1
    fi
fi
SNAP_ID="$(snapshot_for_date "${SNAP_LINES}" "${PAIR_DATE}")"
[ -n "${SNAP_ID}" ] || { echo "ERROR: no restic snapshot dated ${PAIR_DATE}"; exit 1; }
echo ""
if [ -n "${CONFIG_TAR}" ]; then
    echo "=== Restore pair: config ${PAIR_DATE} + restic snapshot ${SNAP_ID} (${PAIR_DATE}) ==="
else
    echo "=== Restore: restic snapshot ${SNAP_ID} (${PAIR_DATE}), no config tarball ==="
fi
echo ""
if [ "${RESTORE_PLAN_ONLY:-}" = "1" ]; then
    echo "RESTORE_PLAN date=${PAIR_DATE} snapshot=${SNAP_ID} newest_tarball=${TAR_DATE:-none} switched=${SWITCHED} mismatch=${MISMATCH}"
    echo "RESTORE_PLAN_ONLY=1 — stopping before PBS is touched."
    exit 0
fi
if [ "${CI:-}" = "true" ]; then
    echo "CI mode: skipping restore confirmation prompt, continuing automatically."
else
    read -r -p "Press Enter to restore snapshot ${SNAP_ID}, or Ctrl+C to abort..."
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
    -r "${RESTIC_REPO}" \
    --password-file "${RESTIC_PASSWORD_FILE}" \
    restore "${SNAP_ID}" \
    --target /

echo ""
echo "=== restore-2-auth.sh COMPLETE ==="
echo ""
echo "PBS datastore restored to ${PBS_DATASTORE_PATH}"
echo "Next step: ./restore-3-pve.sh"
