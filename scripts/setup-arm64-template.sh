#!/bin/bash
# =============================================================================
# scripts/setup-arm64-template.sh — One-time setup of arm64 CI template VM
#
# Creates template VM 9002: vanilla Debian Trixie arm64 cloud image.
# No PVE, no PBS — the CI pipeline tests those via restore-1-install.sh.
#
# Run once directly on the PVE host:
#   bash scripts/setup-arm64-template.sh
#
# Fast — no booting required, just disk import + cloud-init config.
# =============================================================================

set -euo pipefail

TEMPLATE_ID=9002
TEMPLATE_NAME="arm64-restore-ci"
VM_IP="192.168.0.252"
GATEWAY="192.168.0.1"
STORAGE="local-lvm"

# Trixie arm64 cloud image — matches Pi 5 base OS
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-genericcloud-arm64-daily.qcow2"
IMAGE_PATH="/var/lib/vz/template/iso/debian-13-genericcloud-arm64.qcow2"

# Jenkins SSH pubkey — extracted from template 9001
JENKINS_PUBKEY=$(qm config 9001 | grep sshkeys \
    | sed 's/sshkeys: //' \
    | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))")
[ -z "$JENKINS_PUBKEY" ] && { echo "ERROR: cannot extract Jenkins pubkey from template 9001"; exit 1; }

# =============================================================================
echo "=== Step 1: Install arm64 UEFI firmware ==="
# =============================================================================
apt-get install -y ovmf

ln -sf /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/pve-edk2-firmware/AAVMF_CODE.fd
ln -sf /usr/share/AAVMF/AAVMF_VARS.fd /usr/share/pve-edk2-firmware/AAVMF_VARS.fd
echo "AAVMF firmware: OK"

# =============================================================================
echo "=== Step 2: Download Debian Trixie arm64 cloud image ==="
# =============================================================================
if [ -f "$IMAGE_PATH" ]; then
    echo "Already downloaded: $IMAGE_PATH"
else
    wget --progress=dot:giga -O "$IMAGE_PATH" "$IMAGE_URL"
fi

# =============================================================================
echo "=== Step 3: Destroy existing VM $TEMPLATE_ID if present ==="
# =============================================================================
if qm status $TEMPLATE_ID &>/dev/null; then
    qm stop $TEMPLATE_ID 2>/dev/null || true
    sleep 3
    qm destroy $TEMPLATE_ID --purge 1
    echo "Removed existing VM $TEMPLATE_ID"
fi

# =============================================================================
echo "=== Step 4: Create arm64 VM ==="
# =============================================================================
qm create $TEMPLATE_ID \
    --name "$TEMPLATE_NAME" \
    --arch aarch64 \
    --machine virt \
    --bios ovmf \
    --cpu max \
    --cores 4 \
    --memory 4096 \
    --net0 virtio,bridge=vmbr0 \
    --ostype l26 \
    --scsihw virtio-scsi-pci \
    --serial0 socket \
    --vga serial0

# =============================================================================
echo "=== Step 5: Import cloud image as OS disk ==="
# =============================================================================
qm importdisk $TEMPLATE_ID "$IMAGE_PATH" $STORAGE

# =============================================================================
echo "=== Step 6: Attach disks ==="
# =============================================================================
qm set $TEMPLATE_ID \
    --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0,discard=on \
    --boot order=scsi0

# Resize OS disk to 32G (importdisk imports at cloud image size ~3G)
qm resize $TEMPLATE_ID scsi0 32G

# PBS data disk — formatted fresh each CI run by the pipeline
qm set $TEMPLATE_ID --scsi1 ${STORAGE}:4,format=raw

# Cloud-init — must be scsi on arm64/virt (no IDE bus)
qm set $TEMPLATE_ID --scsi2 ${STORAGE}:cloudinit,media=cdrom

# =============================================================================
echo "=== Step 7: Configure cloud-init ==="
# =============================================================================
TMPKEY=$(mktemp)
echo "$JENKINS_PUBKEY" > "$TMPKEY"
qm set $TEMPLATE_ID \
    --ciuser root \
    --cipassword "ci-arm64-root" \
    --ipconfig0 ip=${VM_IP}/24,gw=${GATEWAY} \
    --nameserver 8.8.8.8 \
    --sshkeys "$TMPKEY"
rm -f "$TMPKEY"

# =============================================================================
echo "=== Step 8: Convert to template ==="
# =============================================================================
qm template $TEMPLATE_ID

echo ""
echo "=== arm64 template $TEMPLATE_ID ($TEMPLATE_NAME) created ==="
echo "    Base OS:      Debian Trixie arm64 (vanilla cloud image)"
echo "    IP:           $VM_IP"
echo "    PVE/PBS:      NOT pre-installed (tested by restore-1-install.sh in CI)"
echo "    Used by:      proxmox-ci-backup-arm64 and proxmox-ci-dr-arm64"
