#!/bin/bash
# =============================================================================
# restore-3-pve.sh
# Step 3: Configure PBS and PVE after datastore has been restored
#
# Prerequisites:
#   - restore-2-auth.sh completed (datastore restored to PBS_DATASTORE_PATH)
#
# After this script: restore VMs/LXCs via Proxmox GUI (including LXC 199 for the monitoring GUI)
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
# The config restore may have already written pbs-ci into /etc/pve/storage.cfg
# with a stale fingerprint from Scenario A. Update fingerprint if it exists,
# create it from scratch if it doesn't.
if pvesh get /storage/${PVE_PBS_STORAGE_ID} >/dev/null 2>&1; then
    echo "  Storage ${PVE_PBS_STORAGE_ID} already exists — updating fingerprint"
    pvesh set /storage/${PVE_PBS_STORAGE_ID} --fingerprint "${FINGERPRINT}"
else
    pvesh create /storage \
        --storage ${PVE_PBS_STORAGE_ID} \
        --type pbs \
        --server 127.0.0.1 \
        --datastore ${PBS_DATASTORE_NAME} \
        --username ${PBS_USER} \
        --password "${PBS_USER_PASSWORD}" \
        --fingerprint "${FINGERPRINT}" \
        --content backup \
        --prune-backups "${PBS_RETENTION_LOCAL}"
fi

echo "=== Step 6: Set PBS backup, prune and GC schedules ==="
mkdir -p /var/lock/pve-manager
# PBS backup job (vzdump of all VMs/LXCs) — create or update
EXISTING_JOB="$(pvesh get /cluster/backup --output-format json 2>/dev/null \
    | python3 -c "
import sys,json
jobs=json.load(sys.stdin)
for j in jobs:
    if j.get('storage')=='${PVE_PBS_STORAGE_ID}':
        print(j['id']); break
" 2>/dev/null || true)"

if [ -n "${EXISTING_JOB}" ]; then
    echo "  Backup job ${EXISTING_JOB} already exists — updating schedule to ${PBS_BACKUP_SCHEDULE}"
    pvesh set /cluster/backup/${EXISTING_JOB} --schedule "${PBS_BACKUP_SCHEDULE}"
else
    pvesh create /cluster/backup \
        --all 1 \
        --storage ${PVE_PBS_STORAGE_ID} \
        --mode snapshot \
        --compress zstd \
        --schedule "${PBS_BACKUP_SCHEDULE}"
    echo "  Created backup job — schedule: ${PBS_BACKUP_SCHEDULE}"
fi

# PBS prune job — convert "keep-last=3,keep-daily=3" → --keep-last 3 --keep-daily 3
read -ra PRUNE_FLAGS <<< "$(echo "${PBS_RETENTION_LOCAL}" | sed 's/,/ --/g; s/=/ /g; s/^/--/')"
proxmox-backup-manager prune-job create nightly-prune \
    --store ${PBS_DATASTORE_NAME} \
    --schedule "${PBS_PRUNE_SCHEDULE}" \
    "${PRUNE_FLAGS[@]}" 2>/dev/null || \
proxmox-backup-manager prune-job update nightly-prune \
    --schedule "${PBS_PRUNE_SCHEDULE}" \
    "${PRUNE_FLAGS[@]}"

# PBS garbage collection
proxmox-backup-manager datastore update ${PBS_DATASTORE_NAME} \
    --gc-schedule "${PBS_GC_SCHEDULE}"

echo "=== Step 7: Install restic backup script + systemd timer ==="
# Order: PBS backup → PBS prune → PBS GC → restic backup+forget
# The script stops PBS, snapshots the clean post-prune datastore (tagged per VM/LXC),
# runs forget/prune for Google Drive retention, then restarts PBS.

install -m 750 "${SCRIPT_DIR}/scripts/backup-restic-vms.sh" /usr/local/bin/backup-restic-vms.sh

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

echo "=== Step 8: Restore pve-agent (monitoring) ==="
# config backup captures /etc/pve-agent/, /opt/pve-agent/*.py, and the
# systemd unit — restore-2-auth.sh already extracted them.
# The venv is excluded from backup (recreatable); recreate it here.
if [ -f /opt/pve-agent/pve_agent.py ]; then
    echo "  Agent source found — recreating venv..."
    python3 -m venv /opt/pve-agent/.venv
    /opt/pve-agent/.venv/bin/pip install -q \
        "flask>=3.0" "flask-sock>=0.7" "requests>=2.31" "paho-mqtt>=1.6" "urllib3>=2.0"
    systemctl daemon-reload
    systemctl enable --now pve-agent
    echo "  pve-agent running: $(systemctl is-active pve-agent)"
else
    echo "  Agent source not found in config backup — reinstall manually:"
    echo "    git clone https://github.com/d96moe/proxmox-backup-gui.git /tmp/gui"
    echo "    bash /tmp/gui/setup-agent.sh"
fi

echo "=== Step 9: Verify snapshots visible in PBS ==="
PBS_PASSWORD="${PBS_USER_PASSWORD}" PBS_FINGERPRINT="${FINGERPRINT}" \
    proxmox-backup-client snapshots \
    --repository ${PBS_USER}@127.0.0.1:${PBS_DATASTORE_NAME}

echo ""
echo "=== Step 10: Restore host extras (EXTRA_PACKAGES / EXTRA_CONFIG_PATHS / EXTRA_SERVICES) ==="
# Deliberately last: a failing extra (an apt conflict, a service that won't
# start) must not stop PBS/PVE/pve-agent from being restored. It fails loudly,
# and the step can be re-run on its own by re-running this script.
# The authoritative list is the one the backup was made with: restore-2 put the
# backed-up config.env back at /etc/proxmox-backup-restore/config.env. Only when
# that file is missing do the values from ${SCRIPT_DIR}/config.env apply.
RESTORED_ENV="/etc/proxmox-backup-restore/config.env"
if [ -f "${RESTORED_ENV}" ]; then
    eval "$(set +eu; source "${RESTORED_ENV}" >/dev/null 2>&1
            printf 'EXTRA_PACKAGES=%q\nEXTRA_CONFIG_PATHS=%q\nEXTRA_SERVICES=%q\n' \
                "${EXTRA_PACKAGES:-}" "${EXTRA_CONFIG_PATHS:-}" "${EXTRA_SERVICES:-}")"
    echo "  Using the extras list from the restored ${RESTORED_ENV}"
fi
read -ra X_PKGS  <<< "${EXTRA_PACKAGES:-}"
read -ra X_PATHS <<< "${EXTRA_CONFIG_PATHS:-}"
read -ra X_SVCS  <<< "${EXTRA_SERVICES:-}"

if [ ${#X_PKGS[@]} -eq 0 ] && [ ${#X_PATHS[@]} -eq 0 ] && [ ${#X_SVCS[@]} -eq 0 ]; then
    echo "  No extras configured"
else
    # 1. Snapshot the restored paths BEFORE any package is installed: a package's
    #    postinst may add defaults (nginx: sites-enabled/default with
    #    default_server, which would shadow the restored site on port 80).
    X_PRESENT=()
    for p in "${X_PATHS[@]}"; do
        # These paths are rm -rf'd and re-extracted below, so be strict:
        # absolute, at least two non-empty levels (/etc/nginx yes; /etc, /etc/ no),
        # no '.'/'..' components, no '//', no trailing slash.
        case "${p}" in
            *//*|*/|*/.|*/./*|*/..|*/../*)
                echo "ERROR: EXTRA_CONFIG_PATHS entry '${p}' has '.', '..', '//' or a trailing slash"; exit 1 ;;
            /?*/?*) ;;
            *)  echo "ERROR: EXTRA_CONFIG_PATHS entry '${p}' must be an absolute path at least two levels deep"; exit 1 ;;
        esac
        if [ -e "${p}" ] || [ -L "${p}" ]; then
            X_PRESENT+=("${p#/}")
        else
            echo "  WARNING: ${p} is listed but not in the restored config backup"
        fi
    done
    X_STAGE="$(mktemp -d /root/.restore-extras.XXXXXX)"
    if [ ${#X_PRESENT[@]} -gt 0 ]; then
        tar -C / -cpf "${X_STAGE}/extras.tar" "${X_PRESENT[@]}"
    fi

    # 2. Packages — simulate first and refuse if apt would remove anything
    #    (the same rule as everywhere else: never let an extra package take PVE/PBS down).
    if [ ${#X_PKGS[@]} -gt 0 ]; then
        echo "  Installing: ${X_PKGS[*]}"
        # iptables-persistent would otherwise offer to save the live (empty) ruleset
        echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections
        echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections
        apt-get update -qq
        X_SIM="$(DEBIAN_FRONTEND=noninteractive apt-get -s install -y "${X_PKGS[@]}")"
        X_REMOVALS="$(printf '%s\n' "${X_SIM}" | awk '/^Remv /{print $2}')"
        if [ -n "${X_REMOVALS}" ]; then
            echo "ERROR: installing the extras would remove: ${X_REMOVALS//$'\n'/ } — refusing"
            exit 1
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            "${X_PKGS[@]}"
    fi

    # 3. Put the restored paths back exactly as they were backed up
    if [ ${#X_PRESENT[@]} -gt 0 ]; then
        for p in "${X_PRESENT[@]}"; do rm -rf "/${p:?}"; done
        tar -C / -xpf "${X_STAGE}/extras.tar"
        echo "  Restored: ${X_PRESENT[*]/#//}"
    fi
    rm -rf "${X_STAGE}"

    # 4. Activate: units, sysctl drop-ins, services (restart so they read the restored config)
    systemctl daemon-reload
    sysctl --system >/dev/null || echo "  WARNING: sysctl --system reported errors"
    for s in "${X_SVCS[@]}"; do
        systemctl enable "${s}"
        systemctl restart "${s}"
    done
    sleep 2
    for s in "${X_SVCS[@]}"; do
        if systemctl is-active -q "${s}"; then
            echo "  ${s}: active"
        else
            echo "ERROR: ${s} is not active after restore"
            journalctl -u "${s}" -n 20 --no-pager || true
            exit 1
        fi
    done
fi

echo "=== restore-3-pve.sh COMPLETE ==="
echo ""
echo "All PBS snapshots should now be visible in Proxmox GUI:"
echo "  1. Go to Datacenter -> Storage -> ${PVE_PBS_STORAGE_ID} -> Content"
echo "  2. Select snapshot and click Restore"
echo "  3. Restore LXC 199 (proxmox-backup-gui) if it was backed up in PBS"
echo ""
echo "Verify schedules:"
echo "  proxmox-backup-manager prune-job list"
echo "  proxmox-backup-manager datastore show ${PBS_DATASTORE_NAME}"
echo "  systemctl list-timers | grep restic"
echo "  systemctl status restic-backup.timer"
echo ""
echo "Verify monitoring agent:"
echo "  journalctl -u pve-agent -f"
echo ""
echo "Manual restic backup run:"
echo "  systemctl start restic-backup.service"
echo "  journalctl -u restic-backup -f"
