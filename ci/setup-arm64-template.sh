#!/bin/bash
# =============================================================================
# ci/setup-arm64-template.sh — (Re)build the arm64 CI template VM
#
# Creates template VM 9002: vanilla current-Debian-stable arm64 cloud image
# (codename resolved dynamically, not pinned — matches the Pi 5's real base
# OS, which tracks Debian stable too, and follows future major bumps).
# No PVE, no PBS — the CI pipeline tests those via restore-1-install.sh.
#
# Destructive/idempotent: destroys and recreates VM 9002 from scratch, so
# re-running it is exactly how the template gets refreshed. Run directly on
# the PVE host, or via the Jenkins job proxmox-ci-template-refresh-arm64
# (ci/Jenkinsfile.template-refresh-arm64), which runs this weekly, before the
# other weekly/daily CI jobs that clone this template. Requires template 9001
# to exist already (Jenkins pubkey is extracted from it) — the x86 refresh
# job runs first for this reason.
#   bash ci/setup-arm64-template.sh
#
# Fast — no booting required, just disk import + cloud-init config.
# =============================================================================

set -euo pipefail

TEMPLATE_ID=9002
TEMPLATE_NAME="arm64-restore-ci"
VM_IP="192.168.0.252"
GATEWAY="192.168.0.1"
STORAGE="local-lvm"

# Jenkins SSH pubkey — extracted from template 9001
JENKINS_PUBKEY=$(qm config 9001 | grep sshkeys \
    | sed 's/sshkeys: //' \
    | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))")
[ -z "$JENKINS_PUBKEY" ] && { echo "ERROR: cannot extract Jenkins pubkey from template 9001"; exit 1; }

# =============================================================================
echo "=== Step 1: Resolve current Debian stable codename + image filename ==="
# =============================================================================
DEBIAN_CODENAME=$(curl -fsSL https://deb.debian.org/debian/dists/stable/Release | awk '/^Codename:/{print $2}')
[ -z "${DEBIAN_CODENAME}" ] && { echo "ERROR: could not resolve current Debian stable codename"; exit 1; }
echo "Current Debian stable: ${DEBIAN_CODENAME}"

IMAGE_FILENAME=$(curl -fsSL "https://cloud.debian.org/images/cloud/${DEBIAN_CODENAME}/daily/latest/" \
    | grep -oE 'debian-[0-9]+-genericcloud-arm64-daily\.qcow2' | sort -u | head -1)
[ -z "${IMAGE_FILENAME}" ] && { echo "ERROR: could not find a genericcloud-arm64-daily image for ${DEBIAN_CODENAME}"; exit 1; }
echo "Image: ${IMAGE_FILENAME}"

IMAGE_URL="https://cloud.debian.org/images/cloud/${DEBIAN_CODENAME}/daily/latest/${IMAGE_FILENAME}"
IMAGE_PATH="/var/lib/vz/template/iso/${IMAGE_FILENAME}"

# =============================================================================
echo "=== Step 2: Install arm64 UEFI firmware ==="
# =============================================================================
apt-get install -y ovmf

ln -sf /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/pve-edk2-firmware/AAVMF_CODE.fd
ln -sf /usr/share/AAVMF/AAVMF_VARS.fd /usr/share/pve-edk2-firmware/AAVMF_VARS.fd
echo "AAVMF firmware: OK"

# =============================================================================
echo "=== Step 3: Download ${IMAGE_FILENAME} ==="
# =============================================================================
# Always re-fetch — the URL points at "daily/latest", and this script is
# re-run weekly to keep the template current, so a cached copy would defeat
# the point (and previously meant "latest" only meant "latest at first run").
wget --progress=dot:giga -O "$IMAGE_PATH" "$IMAGE_URL"

# =============================================================================
echo "=== Step 4: Destroy existing VM $TEMPLATE_ID if present ==="
# =============================================================================
if qm status $TEMPLATE_ID &>/dev/null; then
    qm stop $TEMPLATE_ID 2>/dev/null || true
    sleep 3
    qm destroy $TEMPLATE_ID --purge 1
    echo "Removed existing VM $TEMPLATE_ID"
fi

# =============================================================================
echo "=== Step 5: Create arm64 VM ==="
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
echo "=== Step 6: Import cloud image as OS disk ==="
# =============================================================================
qm importdisk $TEMPLATE_ID "$IMAGE_PATH" $STORAGE

# =============================================================================
echo "=== Step 7: Attach disks ==="
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
echo "=== Step 8: Configure cloud-init ==="
# =============================================================================
TMPKEY=$(mktemp)
echo "$JENKINS_PUBKEY" > "$TMPKEY"
qm set $TEMPLATE_ID \
    --ciuser root \
    --cipassword "ci-template-root" \
    --ipconfig0 ip=${VM_IP}/24,gw=${GATEWAY} \
    --nameserver 8.8.8.8 \
    --sshkeys "$TMPKEY"
rm -f "$TMPKEY"

# =============================================================================
echo "=== Step 9: Convert to template ==="
# =============================================================================
qm template $TEMPLATE_ID

echo ""
echo "=== arm64 template $TEMPLATE_ID ($TEMPLATE_NAME) created ==="
echo "    Base OS:      Debian ${DEBIAN_CODENAME} arm64 (vanilla cloud image)"
echo "    IP:           $VM_IP"
echo "    PVE/PBS:      NOT pre-installed (tested by restore-1-install.sh in CI)"
echo "    Used by:      proxmox-ci-backup-arm64 and proxmox-ci-dr-arm64"
