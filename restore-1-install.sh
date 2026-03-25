#!/bin/bash
# =============================================================================
# restore-1-install.sh
# Step 1 (and Step 0 on arm64): Install Proxmox VE if needed, then install
# PBS, rclone, restic, resticprofile and prepare storage.
#
# Starting points:
#   x86_64:  Proxmox VE already installed from ISO. Run this script once.
#   aarch64: Fresh Debian Trixie on Raspberry Pi 5 (no PVE yet).
#            Run this script once → installs PVE → reboots.
#            Run it again after reboot → installs PBS + tools.
#
# Prerequisites:
#   - Run as root
#   - EDIT config.env BEFORE running this script!
#     cp config_x86_standard.env config.env   # or config_rpi5.env
#   - PBS_PARTITION must already exist (create and format before running):
#       parted /dev/sdX mkpart primary ext4 <start> <end>
#       mkfs.ext4 -m 0 /dev/sdXN
#   - aarch64: set PVE_HOSTNAME, PVE_IP, PVE_GATEWAY, PVE_IFACE in config.env
#
# After this script:
#   1. Run: rclone config  (see README for detailed instructions)
#   2. Save restic password to /etc/resticprofile/restic-password
#   3. Run restore-3-pve.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="$(uname -m)"

# Stop all background apt services and timers to prevent lock conflicts
systemctl stop apt-daily.timer apt-daily-upgrade.timer \
    apt-daily.service apt-daily-upgrade.service \
    unattended-upgrades 2>/dev/null || true
pkill -x apt-get 2>/dev/null || true
sleep 2
# Remove potentially corrupted binary cache files (left by killed apt-daily)
rm -f /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin

# Helper: kill any background apt and wait for lists lock before running apt-get
apt_get() {
    pkill -x apt-get 2>/dev/null || true
    for _i in $(seq 1 12); do
        flock -n /var/lib/apt/lists/lock true 2>/dev/null && break
        echo "  apt lists lock busy ($_i/12), waiting 5s..."
        sleep 5
    done
    apt-get -o DPkg::Lock::Timeout=300 "$@"
}

# Load configuration
if [ ! -f "${SCRIPT_DIR}/config.env" ]; then
    echo "ERROR: config.env not found in ${SCRIPT_DIR}"
    echo "Copy config_home.env or config_cabin.env to config.env and edit it first!"
    exit 1
fi
source "${SCRIPT_DIR}/config.env"

# =============================================================================
# Step 0 (aarch64 only): Install Proxmox VE if not already present
# =============================================================================
if [ "${ARCH}" = "aarch64" ] && ! command -v pvesh &>/dev/null; then
    echo "=== Step 0: Install Proxmox VE (arm64 / pxvirt) ==="
    echo "  pvesh not found — PVE not yet installed."
    echo ""

    # Validate required config vars
    for _var in PVE_HOSTNAME PVE_IP PVE_GATEWAY PVE_IFACE; do
        if [ -z "${!_var:-}" ]; then
            echo "ERROR: ${_var} is not set in config.env"
            echo "  Add PVE_HOSTNAME, PVE_IP, PVE_GATEWAY, PVE_DNS, PVE_IFACE to config.env"
            exit 1
        fi
    done
    PVE_DNS="${PVE_DNS:-8.8.8.8}"

    # Verify interface exists
    if ! ip link show "${PVE_IFACE}" &>/dev/null; then
        echo "ERROR: interface '${PVE_IFACE}' not found. Set PVE_IFACE in config.env."
        echo "Available interfaces:"
        ip -o link show | awk '{print "  " $2}' | sed 's/://'
        exit 1
    fi

    echo "  Hostname:  ${PVE_HOSTNAME}"
    echo "  IP:        ${PVE_IP}"
    echo "  Gateway:   ${PVE_GATEWAY}"
    echo "  Interface: ${PVE_IFACE}"
    echo ""
    if [ "${CI:-}" = "true" ]; then
        echo "  CI mode: skipping confirmation, continuing automatically."
    else
        read -p "Press Enter to install Proxmox VE or Ctrl+C to abort..."
    fi

    export DEBIAN_FRONTEND=noninteractive

    # Set hostname
    hostnamectl set-hostname "${PVE_HOSTNAME}"
    sed -i '/^127\.0\.1\.1/d' /etc/hosts
    echo "127.0.1.1 ${PVE_HOSTNAME}.local ${PVE_HOSTNAME}" >> /etc/hosts

    # Disable cloud-init network management (common on Pi images)
    if [ -d /etc/cloud ]; then
        echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    fi

    # Update package lists before installing anything
    apt_get update

    # Configure vmbr0 bridge
    apt_get install -y ifupdown2 gpg curl
    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

iface ${PVE_IFACE} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${PVE_IP}
    gateway ${PVE_GATEWAY}
    dns-nameservers ${PVE_DNS}
    bridge-ports ${PVE_IFACE}
    bridge-stp off
    bridge-fd 0
EOF

    # Add pxvirt repo (community PVE ARM64 port)
    curl -fsSL https://download.lierfang.com/pxcloud/pxvirt/pveport.gpg \
        | gpg --batch --no-tty --dearmor \
        > /etc/apt/trusted.gpg.d/pxvirt.gpg
    echo "deb https://download.lierfang.com/pxcloud/pxvirt trixie main" \
        > /etc/apt/sources.list.d/pxvirt.list
    apt_get update
    apt_get install -y proxmox-ve pve-qemu-kvm

    # Remove enterprise repos (require subscription, cause 401)
    rm -f /etc/apt/sources.list.d/*enterprise*
    apt_get update -qq

    # Switch to 4k page-size kernel — required for PBS on Pi5
    if [ "$(getconf PAGE_SIZE)" != "4096" ]; then
        if grep -q "^kernel=" /boot/firmware/config.txt 2>/dev/null; then
            sed -i 's/^kernel=.*/kernel=kernel8.img/' /boot/firmware/config.txt
        else
            echo "kernel=kernel8.img" >> /boot/firmware/config.txt
        fi
        echo "  4k kernel configured (kernel=kernel8.img)"
    fi

    # Disable systemd-networkd — Debian cloud images use it by default,
    # but PVE requires ifupdown2/networking.service to manage vmbr0.
    # Both running after reboot causes the bridge to fail silently.
    systemctl disable systemd-networkd systemd-networkd-wait-online 2>/dev/null || true
    systemctl mask systemd-networkd 2>/dev/null || true

    PVE_IP_ADDR="${PVE_IP%/*}"
    echo ""
    echo "=== Proxmox VE installed. Rebooting in 5 seconds... ==="
    echo "After reboot, run this script again: ./restore-1-install.sh"
    echo "Proxmox GUI will be at: https://${PVE_IP_ADDR}:8006"
    sleep 5
    reboot
    exit 0
fi

echo "=== Configuration loaded ==="
echo "  Architecture:     ${ARCH}"
echo "  PBS partition:    ${PBS_PARTITION}"
echo "  PBS datastore:    ${PBS_DATASTORE_PATH}"
echo "  PBS retention:    ${PBS_RETENTION_LOCAL}"
echo "  Google Drive:     ${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}"
echo ""

# -----------------------------------------------------------------------------
# Sanity check: PBS partition must be a dedicated block device
# -----------------------------------------------------------------------------
echo "=== Sanity check: PBS partition ==="

# Check partition exists as block device
if [ ! -b "${PBS_PARTITION}" ]; then
    echo "ERROR: ${PBS_PARTITION} is not a block device or does not exist."
    echo "  Create and format the partition first:"
    echo "    parted /dev/sdX mkpart primary ext4 <start> <end>"
    echo "    mkfs.ext4 -m 0 ${PBS_PARTITION}"
    exit 1
fi

# Check that PBS_PARTITION is not the root partition
ROOT_DEV="$(df / | awk 'NR==2 {print $1}')"
if [ "${PBS_PARTITION}" = "${ROOT_DEV}" ]; then
    echo "ERROR: ${PBS_PARTITION} is the root partition!"
    echo "  PBS must be on a dedicated partition, not the OS partition."
    exit 1
fi

# Check PBS_DATASTORE_PATH is not already mounted by something else
if mount | grep -q " on ${PBS_DATASTORE_PATH} "; then
    MOUNTED_DEV="$(mount | grep " on ${PBS_DATASTORE_PATH} " | awk '{print $1}')"
    if [ "${MOUNTED_DEV}" != "${PBS_PARTITION}" ]; then
        echo "ERROR: ${PBS_DATASTORE_PATH} is already mounted by ${MOUNTED_DEV}, not ${PBS_PARTITION}."
        echo "  Unmount it first or change PBS_DATASTORE_PATH in config.env"
        exit 1
    fi
fi

# Check PBS partition size is at least 15% of total disk
PBS_SIZE_BYTES="$(lsblk -bno SIZE "${PBS_PARTITION}" 2>/dev/null | head -1)"
PBS_SIZE_GB=$(( PBS_SIZE_BYTES / 1024 / 1024 / 1024 ))
PBS_DISK="$(lsblk -no pkname "${PBS_PARTITION}" 2>/dev/null | head -1)"
# If PBS_PARTITION is a whole disk (not a partition), pkname is empty — use the disk itself
[ -z "${PBS_DISK}" ] && PBS_DISK="$(basename "${PBS_PARTITION}")"
DISK_SIZE_BYTES="$(lsblk -bno SIZE "/dev/${PBS_DISK}" 2>/dev/null | head -1)"
DISK_SIZE_GB=$(( DISK_SIZE_BYTES / 1024 / 1024 / 1024 ))
REQUIRED_GB=$(( DISK_SIZE_GB * 15 / 100 ))

echo "  PBS partition:    ${PBS_PARTITION} (${PBS_SIZE_GB} GB)"
echo "  Total disk:       /dev/${PBS_DISK} (${DISK_SIZE_GB} GB)"
echo "  Minimum required: ${REQUIRED_GB} GB (15% of disk)"

if [ "${PBS_SIZE_GB}" -lt "${REQUIRED_GB}" ]; then
    echo ""
    echo "WARNING: PBS partition (${PBS_SIZE_GB} GB) is smaller than 15% of total disk (${REQUIRED_GB} GB)."
    echo "  This may be too small for multiple backup snapshots."
    if [ "${CI:-}" = "true" ]; then
        echo "  CI mode: skipping size warning prompt, continuing automatically."
    else
        read -p "Continue anyway? (y/N) " confirm
        if [ "${confirm}" != "y" ] && [ "${confirm}" != "Y" ]; then
            echo "Aborted."
            exit 1
        fi
    fi
else
    echo "  Size check:       OK (${PBS_SIZE_GB} GB >= ${REQUIRED_GB} GB minimum)"
fi

echo ""
if [ "${CI:-}" = "true" ]; then
    echo "CI mode: skipping confirmation prompt, continuing automatically."
else
    read -p "Does this look correct? Press Enter to continue or Ctrl+C to abort..."
fi

# -----------------------------------------------------------------------------
# ARM64 (Raspberry Pi): check 4k page-size — required for PBS
# -----------------------------------------------------------------------------
if [ "${ARCH}" = "aarch64" ]; then
    PAGE_SIZE="$(getconf PAGE_SIZE)"
    if [ "${PAGE_SIZE}" != "4096" ]; then
        echo ""
        echo "=== WARNING: ARM64 wrong kernel page-size detected! ==="
        echo "  Current page size: ${PAGE_SIZE} (need 4096)"
        echo "  PBS requires a 4k page-size kernel."
        echo "  Raspberry Pi 5 ships with a 16k kernel by default."
        echo ""
        read -p "Add kernel=kernel8.img to /boot/firmware/config.txt and reboot? (y/N) " confirm
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
    echo "  Page size: ${PAGE_SIZE} OK"
fi

echo "=== Step 1: Install Proxmox Backup Server ==="
if [ "${ARCH}" = "aarch64" ]; then
    echo "  ARM64 detected — using community pipbs repository..."
    apt_get install -y ca-certificates curl gnupg unzip
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://dexogen.github.io/pipbs/gpg.key \
        | gpg --batch --no-tty --dearmor \
        > /etc/apt/keyrings/pipbs.gpg
    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/pipbs.gpg] https://dexogen.github.io/pipbs/ trixie main" \
        > /etc/apt/sources.list.d/pipbs.list
else
    echo "  x86_64 detected — using official Proxmox repository..."
    echo "deb http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription" \
        > /etc/apt/sources.list.d/pbs.list
fi
apt_get update
apt_get install -y proxmox-backup-server

# Remove enterprise repos that PBS installer adds automatically (require subscription, cause 401)
rm -f /etc/apt/sources.list.d/*enterprise*
apt_get update -qq

echo "=== Step 2: Install rclone ==="
curl https://rclone.org/install.sh | bash

echo "=== Step 3: Install restic ==="
apt_get install -y restic

echo "=== Step 4: Install resticprofile ==="
curl -sfL https://raw.githubusercontent.com/creativeprojects/resticprofile/master/install.sh | sh
mv bin/resticprofile /usr/local/bin/
resticprofile version

echo "=== Step 5: Mount PBS partition ==="
mkdir -p ${PBS_DATASTORE_PATH}

PBS_UUID="$(blkid -s UUID -o value ${PBS_PARTITION})"
if ! grep -q "${PBS_UUID}" /etc/fstab; then
    echo "UUID=${PBS_UUID} ${PBS_DATASTORE_PATH} ext4 defaults,noatime 0 0" >> /etc/fstab
    echo "  Added to /etc/fstab: UUID=${PBS_UUID} -> ${PBS_DATASTORE_PATH}"
fi

systemctl daemon-reload

if ! mount | grep -q " on ${PBS_DATASTORE_PATH} "; then
    mount ${PBS_DATASTORE_PATH}
fi
echo "  Mounted ${PBS_PARTITION} at ${PBS_DATASTORE_PATH}"
df -h ${PBS_DATASTORE_PATH}

# Ensure PBS daemon is running before datastore/user operations
systemctl start proxmox-backup proxmox-backup-proxy 2>/dev/null || true
sleep 5

echo "=== Step 6: Create PBS datastore ==="
proxmox-backup-manager datastore create ${PBS_DATASTORE_NAME} ${PBS_DATASTORE_PATH}

echo "=== Step 7: Create PBS user and ACL ==="
proxmox-backup-manager user create ${PBS_USER} --password "${PBS_USER_PASSWORD}"
proxmox-backup-manager user generate-token ${PBS_USER} ${PBS_TOKEN_NAME}
proxmox-backup-manager acl update /datastore/${PBS_DATASTORE_NAME} DatastoreAdmin \
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
    keep-last: ${RESTIC_RETENTION_KEEP_LAST}
    keep-daily: ${RESTIC_RETENTION_KEEP_DAILY}
    keep-weekly: ${RESTIC_RETENTION_KEEP_WEEKLY}
    keep-monthly: ${RESTIC_RETENTION_KEEP_MONTHLY}
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
