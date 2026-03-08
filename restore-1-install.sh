#!/bin/bash
# =============================================================================
# restore-1-install.sh
# Step 1: Install PBS, rclone, restic, resticprofile and prepare storage
#
# Prerequisites:
#   - Fresh Proxmox VE installed and network configured
#   - Run as root on PVE host
#   - EDIT config.env BEFORE running this script!
#
# Supports:
#   - x86_64: standard Proxmox VE install with LVM thin-pool
#   - aarch64: Proxmox on Debian (e.g. Raspberry Pi 5), dir-based storage
#              Uses community ARM64 PBS build (pipbs)
#
# After this script:
#   1. Run: rclone config  (see README for detailed instructions)
#   2. Save restic password to /etc/resticprofile/restic-password
#   3. Run restore-2-auth.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="$(uname -m)"

# Load configuration
if [ ! -f "${SCRIPT_DIR}/config.env" ]; then
    echo "ERROR: config.env not found in ${SCRIPT_DIR}"
    echo "Copy config.env to the same directory as this script and edit it first!"
    exit 1
fi
source "${SCRIPT_DIR}/config.env"

echo "=== Configuration loaded ==="
echo "  Architecture:     ${ARCH}"
echo "  Storage type:     ${STORAGE_TYPE}"
echo "  PBS datastore:    ${PBS_DATASTORE_PATH}"
if [ "${STORAGE_TYPE}" = "lvm-thin" ]; then
    echo "  LVM:              ${PBS_LVM_VG}/${PBS_LVM_THIN_POOL} -> ${PBS_LVM_VOL_NAME} (${PBS_DATASTORE_SIZE})"
fi
echo "  Google Drive:     ${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}"
echo ""
read -p "Does this look correct? Press Enter to continue or Ctrl+C to abort..."

# -----------------------------------------------------------------------------
# ARM64 (Raspberry Pi): check 4k page-size — required for PBS
# -----------------------------------------------------------------------------
if [ "${ARCH}" = "aarch64" ]; then
    PAGE_SIZE="$(getconf PAGE_SIZE)"
    if [ "${PAGE_SIZE}" != "4096" ]; then
        echo ""
        echo "=== ⚠️  ARM64: Wrong kernel page-size detected! ==="
        echo "  Current page size: ${PAGE_SIZE} (need 4096)"
        echo "  PBS requires a 4k page-size kernel."
        echo "  Raspberry Pi 5 ships with a 16k kernel by default."
        echo ""
        echo "  Fix: Add 'kernel=kernel8.img' to /boot/firmware/config.txt"
        echo "  Then reboot and run this script again."
        echo ""
        read -p "Add kernel=kernel8.img and reboot now? (y/N) " confirm
        if [ "${confirm}" = "y" ] || [ "${confirm}" = "Y" ]; then
            echo "kernel=kernel8.img" >> /boot/firmware/config.txt
            echo "Rebooting in 5 seconds... Run this script again after reboot."
            sleep 5
            reboot
        else
            echo "Aborting. Fix page-size manually and re-run."
            exit 1
        fi
    fi
    echo "  Page size: ${PAGE_SIZE} ✓"
fi

echo "=== Step 1: Install Proxmox Backup Server ==="
if [ "${ARCH}" = "aarch64" ]; then
    echo "  ARM64 detected — using community pipbs repository..."
    apt-get install -y ca-certificates curl gnupg
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://dexogen.github.io/pipbs/gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/pipbs.gpg
    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/pipbs.gpg] https://dexogen.github.io/pipbs/ trixie main" \
        > /etc/apt/sources.list.d/pipbs.list
else
    echo "  x86_64 detected — using official Proxmox repository..."
    echo "deb http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription" \
        > /etc/apt/sources.list.d/pbs.list
fi
apt-get update
apt-get install -y proxmox-backup-server

echo "=== Step 2: Install rclone ==="
curl https://rclone.org/install.sh | bash

echo "=== Step 3: Install restic ==="
apt-get install -y restic

echo "=== Step 4: Install resticprofile ==="
curl -sfL https://raw.githubusercontent.com/creativeprojects/resticprofile/master/install.sh | sh
mv bin/resticprofile /usr/local/bin/
resticprofile version

echo "=== Step 5: Prepare PBS datastore storage ==="
if [ "${STORAGE_TYPE}" = "lvm-thin" ]; then
    echo "  Creating LVM thin volume ${PBS_LVM_VOL_NAME} (${PBS_DATASTORE_SIZE})..."
    lvcreate -V${PBS_DATASTORE_SIZE} -T ${PBS_LVM_VG}/${PBS_LVM_THIN_POOL} -n ${PBS_LVM_VOL_NAME}
    mkfs.ext4 -m 0 /dev/${PBS_LVM_VG}/${PBS_LVM_VOL_NAME}
    mkdir -p ${PBS_DATASTORE_PATH}
    echo "/dev/${PBS_LVM_VG}/${PBS_LVM_VOL_NAME} ${PBS_DATASTORE_PATH} ext4 defaults,noatime 0 0" \
        >> /etc/fstab
    systemctl daemon-reload
    mount ${PBS_DATASTORE_PATH}
    echo "  LVM volume created and mounted at ${PBS_DATASTORE_PATH}"
elif [ "${STORAGE_TYPE}" = "dir" ]; then
    echo "  Creating plain directory at ${PBS_DATASTORE_PATH}..."
    mkdir -p ${PBS_DATASTORE_PATH}
    echo "  Directory created (no LVM, no fstab entry needed)"
else
    echo "ERROR: Unknown STORAGE_TYPE '${STORAGE_TYPE}' — must be 'lvm-thin' or 'dir'"
    exit 1
fi

echo "=== Step 6: Create PBS datastore ==="
proxmox-backup-manager datastore create ${PBS_DATASTORE_NAME} ${PBS_DATASTORE_PATH}

echo "=== Step 7: Create PBS user and ACL ==="
proxmox-backup-manager user create ${PBS_USER} --password "${PBS_USER_PASSWORD}"
proxmox-backup-manager user generate-token ${PBS_USER} ${PBS_TOKEN_NAME}
proxmox-backup-manager acl update /datastore/${PBS_DATASTORE_NAME} DatastoreBackup \
    --auth-id ${PBS_USER}

echo "=== Step 8: Create stop-proxmox-backup.sh ==="
cat > /usr/local/bin/stop-proxmox-backup.sh << 'EOF'
#!/bin/bash
echo "Waiting for PBS to finish any running tasks..."
for i in $(seq 1 60); do
    if ! proxmox-backup-manager task list --limit 100 2>/dev/null | grep -q "running"; then
        echo "PBS is idle, stopping..."
        systemctl stop proxmox-backup
        systemctl stop proxmox-backup-proxy
        echo "PBS stopped"
        exit 0
    fi
    echo "Still running tasks ($i/60), waiting 60s..."
    sleep 60
done
echo "ERROR: PBS still busy after 60 minutes, aborting"
exit 1
EOF
chmod +x /usr/local/bin/stop-proxmox-backup.sh

echo "=== Step 9: Create resticprofile config ==="
mkdir -p /etc/resticprofile
cat > /etc/resticprofile/profiles.yaml << YAML
version: "1"

global:
  default-command: snapshots

pbs-backup:
  repository: "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}"
  password-file: "${RESTIC_PASSWORD_FILE}"

  backup:
    source:
      - "${PBS_DATASTORE_PATH}"
    schedule: "${RESTIC_BACKUP_SCHEDULE}"
    schedule-permission: system
    run-before:
      - "/usr/local/bin/stop-proxmox-backup.sh"
    run-after:
      - "systemctl start proxmox-backup"
      - "systemctl start proxmox-backup-proxy"
    run-after-fail:
      - "systemctl start proxmox-backup"
      - "systemctl start proxmox-backup-proxy"

  forget:
    keep-last: 3
    keep-daily: 6
    keep-weekly: 3
    keep-monthly: 5
    prune: true
    schedule: "${RESTIC_FORGET_SCHEDULE}"
    schedule-permission: system
YAML

echo "=== Step 10: Install PVE config backup script ==="
mkdir -p /etc/proxmox-backup-restore
cp "${SCRIPT_DIR}/config.env" /etc/proxmox-backup-restore/config.env
cp "${SCRIPT_DIR}/backup-pve-config.sh" /usr/local/bin/backup-pve-config.sh
chmod +x /usr/local/bin/backup-pve-config.sh

cat > /etc/systemd/system/pve-config-backup.service << SERVICE
[Unit]
Description=Proxmox host config backup to Google Drive
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-pve-config.sh
StandardOutput=journal
StandardError=journal
SERVICE

cat > /etc/systemd/system/pve-config-backup.timer << TIMER
[Unit]
Description=Daily Proxmox config backup timer

[Timer]
OnCalendar=${CONFIG_BACKUP_SCHEDULE}
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now pve-config-backup.timer
echo "Config backup timer enabled (${CONFIG_BACKUP_SCHEDULE} daily)"

echo ""
echo "=== restore-1-install.sh COMPLETE ==="
echo ""
echo "Next steps:"
echo "  1. Run: rclone config   (see README - configure remote named '${RESTICPROFILE_GDRIVE_REMOTE}')"
echo "  2. echo 'YOUR-PASSWORD' > ${RESTIC_PASSWORD_FILE} && chmod 600 ${RESTIC_PASSWORD_FILE}"
echo "  3. ./restore-2-auth.sh"
