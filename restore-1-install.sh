#!/bin/bash
# =============================================================================
# restore-1-install.sh
# Step 1: Install PBS, rclone, restic, resticprofile and prepare storage
#
# Prerequisites:
#   - Fresh Proxmox VE installed
#   - Network configured
#   - Run as root on PVE host
#
# After this script: run restore-2-auth.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION - adjust these variables for your environment
# =============================================================================

PBS_DATASTORE_NAME="local-store"
PBS_DATASTORE_PATH="/mnt/pbs"
PBS_DATASTORE_SIZE="350G"          # Size of LVM thin volume for PBS
PBS_LVM_VG="pve"                   # LVM volume group (usually 'pve')
PBS_LVM_THIN_POOL="data"           # LVM thin pool name (usually 'data')
PBS_LVM_VOL_NAME="pbs-datastore"   # LVM volume name

PBS_USER="backup@pbs"
PBS_USER_PASSWORD="changeme"       # Change this!
PBS_TOKEN_NAME="pve-token"

RESTICPROFILE_GDRIVE_REMOTE="gdrive"
RESTICPROFILE_GDRIVE_PATH="bu/proxmox_home"
RESTIC_PASSWORD_FILE="/etc/resticprofile/restic-password"

# =============================================================================

echo "=== Step 1: Install Proxmox Backup Server ==="
echo "deb http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription" \
    > /etc/apt/sources.list.d/pbs.list
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

echo "=== Step 5: Create LVM thin volume for PBS datastore ==="
lvcreate -V${PBS_DATASTORE_SIZE} -T ${PBS_LVM_VG}/${PBS_LVM_THIN_POOL} -n ${PBS_LVM_VOL_NAME}
mkfs.ext4 -m 0 /dev/${PBS_LVM_VG}/${PBS_LVM_VOL_NAME}
mkdir -p ${PBS_DATASTORE_PATH}
echo "/dev/${PBS_LVM_VG}/${PBS_LVM_VOL_NAME} ${PBS_DATASTORE_PATH} ext4 defaults,noatime 0 0" \
    >> /etc/fstab
systemctl daemon-reload
mount ${PBS_DATASTORE_PATH}

echo "=== Step 6: Create PBS datastore ==="
proxmox-backup-manager datastore create ${PBS_DATASTORE_NAME} ${PBS_DATASTORE_PATH}

echo "=== Step 7: Create PBS user and token ==="
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
    schedule: "02:30"
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
    schedule: "03:30"
    schedule-permission: system
YAML

echo ""
echo "=== restore-1-install.sh COMPLETE ==="
echo ""
echo "Next steps:"
echo "  1. Run: rclone config   (configure Google Drive remote named '${RESTICPROFILE_GDRIVE_REMOTE}')"
echo "  2. Save restic password: echo 'YOUR-PASSWORD' > ${RESTIC_PASSWORD_FILE} && chmod 600 ${RESTIC_PASSWORD_FILE}"
echo "  3. Run: restore-2-auth.sh"
