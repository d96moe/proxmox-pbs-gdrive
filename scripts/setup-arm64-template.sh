#!/bin/bash
# =============================================================================
# scripts/setup-arm64-template.sh — One-time setup of arm64 CI template VM
#
# Creates template VM 9002 on the PVE host (192.168.0.200) for use by the
# proxmox-ci-backup-arm64 and proxmox-ci-dr-arm64 Jenkins pipelines.
#
# Run once directly on the PVE host:
#   bash scripts/setup-arm64-template.sh
#
# Prerequisites:
#   - Internet access from PVE host (to download cloud image)
#   - Jenkins SSH pubkey at /root/.ssh/authorized_keys on PVE host
# =============================================================================

set -euo pipefail

TEMPLATE_ID=9002
TEMPLATE_NAME="arm64-restore-ci"
VM_IP="192.168.0.252"
GATEWAY="192.168.0.1"
STORAGE="local-lvm"
IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.qcow2"
IMAGE_PATH="/var/lib/vz/template/iso/debian-12-generic-arm64.qcow2"

# Jenkins SSH pubkey — same key used for template 9001
JENKINS_PUBKEY=$(cat /var/lib/jenkins/.ssh/id_ed25519.pub 2>/dev/null \
    || grep -r 'ssh-ed25519' /root/.ssh/authorized_keys 2>/dev/null | head -1 \
    || { echo "ERROR: cannot find Jenkins pubkey"; exit 1; })

echo "=== Step 1: Install arm64 UEFI firmware ==="
apt-get install -y qemu-efi-aarch64

# PVE looks for AAVMF at /usr/share/AAVMF/ — create symlinks from qemu-efi-aarch64
mkdir -p /usr/share/AAVMF
[ -f /usr/share/AAVMF/AAVMF_CODE.fd ] || \
    ln -sf /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/AAVMF/AAVMF_CODE.fd
[ -f /usr/share/AAVMF/AAVMF_VARS.fd ] || \
    ln -sf /usr/share/qemu-efi-aarch64/QEMU_VARS.fd /usr/share/AAVMF/AAVMF_VARS.fd
echo "AAVMF firmware: OK"

echo "=== Step 2: Download Debian 12 arm64 cloud image ==="
if [ -f "$IMAGE_PATH" ]; then
    echo "Already downloaded: $IMAGE_PATH"
else
    wget --progress=dot:giga -O "$IMAGE_PATH" "$IMAGE_URL"
fi

echo "=== Step 3: Remove existing VM $TEMPLATE_ID if present ==="
if qm status $TEMPLATE_ID &>/dev/null; then
    qm destroy $TEMPLATE_ID --purge 1
    echo "Removed existing VM $TEMPLATE_ID"
fi

echo "=== Step 4: Create arm64 VM $TEMPLATE_ID ==="
qm create $TEMPLATE_ID \
    --name "$TEMPLATE_NAME" \
    --arch aarch64 \
    --machine virt \
    --bios ovmf \
    --cpu cortex-a72 \
    --cores 2 \
    --memory 2048 \
    --net0 virtio,bridge=vmbr0 \
    --ostype l26 \
    --scsihw virtio-scsi-pci \
    --serial0 socket \
    --vga serial0

echo "=== Step 5: Import cloud image as OS disk ==="
qm importdisk $TEMPLATE_ID "$IMAGE_PATH" $STORAGE

echo "=== Step 6: Attach OS disk, boot order, PBS data disk, cloud-init ==="
qm set $TEMPLATE_ID \
    --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0,discard=on,size=16G \
    --boot order=scsi0

# Second disk — PBS datastore partition (/dev/sdb inside the VM)
qm set $TEMPLATE_ID --scsi1 ${STORAGE}:4,format=raw

# Cloud-init drive
qm set $TEMPLATE_ID --ide2 ${STORAGE}:cloudinit,media=cdrom

echo "=== Step 7: Configure cloud-init ==="
ENCODED_KEY=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))" <<< "$JENKINS_PUBKEY")
qm set $TEMPLATE_ID \
    --ciuser root \
    --ipconfig0 ip=${VM_IP}/24,gw=${GATEWAY} \
    --nameserver 8.8.8.8 \
    --sshkeys "$ENCODED_KEY"

echo "=== Step 8: Convert to template ==="
qm template $TEMPLATE_ID

echo ""
echo "=== arm64 template $TEMPLATE_ID ($TEMPLATE_NAME) created successfully ==="
echo "    IP when cloned: $VM_IP"
echo "    Architecture:   aarch64 (emulated via QEMU)"
echo "    Used by:        proxmox-ci-backup-arm64 and proxmox-ci-dr-arm64"
