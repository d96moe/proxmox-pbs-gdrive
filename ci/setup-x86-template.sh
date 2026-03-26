#!/bin/bash
# =============================================================================
# ci/setup-x86-template.sh — One-time setup of x86_64 CI template VM
#
# Creates template VM 9001: Debian Bookworm x86_64 with Proxmox VE installed.
# No PBS — restore-1-install.sh installs it during CI.
#
# Run once directly on the PVE host:
#   bash ci/setup-x86-template.sh
#
# What it does:
#   1. Download Debian Bookworm x86_64 cloud image
#   2. Create VM 9001 with OS disk + PBS data disk + cloud-init
#   3. Boot VM, install Proxmox VE (official repo)
#   4. Shut down, convert to template
#
# Template is used by: proxmox-ci-backup, proxmox-ci-dr
# =============================================================================

set -euo pipefail

TEMPLATE_ID=9001
TEMPLATE_NAME="restore-test-ci"
VM_IP="192.168.0.251"
GATEWAY="192.168.0.1"
STORAGE="local-lvm"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -i /var/lib/jenkins/.ssh/id_ed25519"

# Debian Bookworm x86_64 cloud image
IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
IMAGE_PATH="/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2"

# Jenkins SSH pubkey — from Jenkins agent key on this host
JENKINS_PUBKEY_FILE="/var/lib/jenkins/.ssh/id_ed25519.pub"
[ -f "${JENKINS_PUBKEY_FILE}" ] || { echo "ERROR: Jenkins pubkey not found at ${JENKINS_PUBKEY_FILE}"; exit 1; }

# =============================================================================
echo "=== Step 1: Download Debian Bookworm x86_64 cloud image ==="
# =============================================================================
if [ -f "${IMAGE_PATH}" ]; then
    echo "Already downloaded: ${IMAGE_PATH}"
else
    wget --progress=dot:giga -O "${IMAGE_PATH}" "${IMAGE_URL}"
fi

# =============================================================================
echo "=== Step 2: Destroy existing VM ${TEMPLATE_ID} if present ==="
# =============================================================================
if qm status ${TEMPLATE_ID} &>/dev/null; then
    qm stop ${TEMPLATE_ID} 2>/dev/null || true
    sleep 3
    qm destroy ${TEMPLATE_ID} --purge 1
    echo "Removed existing VM ${TEMPLATE_ID}"
fi

# =============================================================================
echo "=== Step 3: Create x86_64 VM ==="
# =============================================================================
qm create ${TEMPLATE_ID} \
    --name "${TEMPLATE_NAME}" \
    --cpu host \
    --cores 2 \
    --memory 2048 \
    --net0 virtio,bridge=vmbr0 \
    --ostype l26 \
    --scsihw virtio-scsi-pci \
    --serial0 socket \
    --vga serial0

# =============================================================================
echo "=== Step 4: Import cloud image as OS disk ==="
# =============================================================================
qm importdisk ${TEMPLATE_ID} "${IMAGE_PATH}" ${STORAGE}

# =============================================================================
echo "=== Step 5: Attach disks ==="
# =============================================================================
qm set ${TEMPLATE_ID} \
    --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0,discard=on \
    --boot order=scsi0

# Resize OS disk to 16G
qm resize ${TEMPLATE_ID} scsi0 16G

# PBS data disk — formatted fresh each CI run by the pipeline
qm set ${TEMPLATE_ID} --scsi1 ${STORAGE}:4,format=raw

# Cloud-init disk (ide2 — standard for x86_64 SeaBIOS VMs)
qm set ${TEMPLATE_ID} --ide2 ${STORAGE}:cloudinit,media=cdrom

# =============================================================================
echo "=== Step 6: Configure cloud-init ==="
# =============================================================================
TMPKEY=$(mktemp)
cat "${JENKINS_PUBKEY_FILE}" > "${TMPKEY}"
qm set ${TEMPLATE_ID} \
    --ciuser root \
    --cipassword "ci-template-root" \
    --ipconfig0 ip=${VM_IP}/24,gw=${GATEWAY} \
    --nameserver 8.8.8.8 \
    --sshkeys "${TMPKEY}"
rm -f "${TMPKEY}"

# =============================================================================
echo "=== Step 7: Boot VM and install Proxmox VE ==="
# =============================================================================
qm start ${TEMPLATE_ID}
echo "Waiting for SSH at ${VM_IP} (max 120s)..."
for i in $(seq 1 24); do
    ssh ${SSH_OPTS} root@${VM_IP} true 2>/dev/null && echo "SSH ready" && break
    echo "  attempt $i/24..."
    sleep 5
    [ "$i" -eq 24 ] && { echo "ERROR: VM did not become reachable"; qm stop ${TEMPLATE_ID}; exit 1; }
done

echo "Installing Proxmox VE on template VM..."
ssh ${SSH_OPTS} root@${VM_IP} bash -s << 'ENDSSH'
set -euo pipefail

# Hostname — must resolve to itself for pve-cluster to start
HOSTNAME="restore-ci"
hostnamectl set-hostname "${HOSTNAME}"
grep -qF "192.168.0.251 ${HOSTNAME}" /etc/hosts || echo "192.168.0.251 ${HOSTNAME}.local ${HOSTNAME}" >> /etc/hosts

# Add Proxmox VE repo (no-subscription)
curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
    -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
echo "deb [arch=amd64] http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
    > /etc/apt/sources.list.d/pve-install-repo.list

# Remove enterprise repo (requires subscription, causes 401)
rm -f /etc/apt/sources.list.d/pve-enterprise.list

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-ve

# Remove enterprise PBS repo if installed
rm -f /etc/apt/sources.list.d/pbs-enterprise.list

echo "Proxmox VE installed OK"
pvesh get /version
ENDSSH

# =============================================================================
echo "=== Step 8: Shut down and convert to template ==="
# =============================================================================
qm shutdown ${TEMPLATE_ID}
echo "Waiting for VM to stop..."
for i in $(seq 1 30); do
    [ "$(qm status ${TEMPLATE_ID} | awk '{print $2}')" = "stopped" ] && break
    sleep 2
done

qm template ${TEMPLATE_ID}

echo ""
echo "=== x86_64 template ${TEMPLATE_ID} (${TEMPLATE_NAME}) created ==="
echo "    Base OS:      Debian Bookworm x86_64 (cloud image)"
echo "    PVE:          installed (pve-no-subscription repo)"
echo "    PBS:          NOT pre-installed (tested by restore-1-install.sh in CI)"
echo "    IP:           ${VM_IP}"
echo "    OS disk:      /dev/sda (16 GB)"
echo "    Data disk:    /dev/sdb (4 GB, formatted fresh each CI run by pipeline)"
echo "    Used by:      proxmox-ci-backup and proxmox-ci-dr"
