#!/bin/bash
# =============================================================================
# scripts/setup-arm64-template.sh — One-time setup of arm64 CI template VM
#
# Creates template VM 9002 on the PVE host for the arm64 (Pi 5) CI pipelines.
# Mirrors the Pi 5 environment: Debian Trixie + pxvirt (community PVE ARM64)
# + pipbs (community PBS ARM64).
#
# Run once directly on the PVE host:
#   bash scripts/setup-arm64-template.sh
#
# Takes 20-60 minutes (QEMU arm64 emulation is slow).
# =============================================================================

set -euo pipefail

TEMPLATE_ID=9002
TEMPLATE_NAME="arm64-restore-ci"
VM_IP="192.168.0.252"
GATEWAY="192.168.0.1"
STORAGE="local-lvm"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10"
SSH_KEY="/var/lib/jenkins/.ssh/id_ed25519"

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
echo "=== Step 2: Download Debian Trixie arm64 nocloud image ==="
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
echo "=== Step 4: Create arm64 VM $TEMPLATE_ID ==="
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
    --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0,discard=on,size=16G \
    --boot order=scsi0

# PBS data disk (/dev/sdb inside the VM)
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
    --ipconfig0 ip=${VM_IP}/24,gw=${GATEWAY} \
    --nameserver 8.8.8.8 \
    --sshkeys "$TMPKEY"
rm -f "$TMPKEY"

# =============================================================================
echo "=== Step 8: First boot — install pxvirt + pipbs ==="
# =============================================================================
qm start $TEMPLATE_ID
echo "VM started. Waiting for SSH (arm64 emulation — may take 5-10 min for first boot)..."

for i in $(seq 1 120); do
    if ssh $SSH_OPTS -i "$SSH_KEY" root@${VM_IP} true 2>/dev/null; then
        echo "SSH ready after $((i * 5))s"
        break
    fi
    [ $i -eq 120 ] && { echo "ERROR: VM did not respond within 600s"; qm stop $TEMPLATE_ID; exit 1; }
    echo "  attempt $i/120..."
    sleep 5
done

# Detect primary network interface name
IFACE=$(ssh $SSH_OPTS -i "$SSH_KEY" root@${VM_IP} \
    "ip route show default 2>/dev/null | awk '/default/ {print \$5}' | head -1")
echo "Primary interface: $IFACE"

echo "Installing pxvirt (community PVE ARM64) + pipbs (community PBS ARM64)..."
ssh $SSH_OPTS -i "$SSH_KEY" root@${VM_IP} bash -s << ENDSSH
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "--- Updating base system ---"
apt-get update -qq
apt-get install -y ca-certificates curl gnupg ifupdown2

echo "--- Adding pxvirt repo (community PVE ARM64 port) ---"
curl -fsSL https://download.lierfang.com/pxcloud/pxvirt/pveport.gpg \\
    | gpg --dearmor > /etc/apt/trusted.gpg.d/pxvirt.gpg
echo "deb https://download.lierfang.com/pxcloud/pxvirt trixie main" \\
    > /etc/apt/sources.list.d/pxvirt.list

echo "--- Adding pipbs repo (community PBS ARM64) ---"
mkdir -p /etc/apt/keyrings
curl -fsSL https://dexogen.github.io/pipbs/gpg.key \\
    | gpg --dearmor > /etc/apt/keyrings/pipbs.gpg
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/pipbs.gpg] https://dexogen.github.io/pipbs/ trixie main" \\
    > /etc/apt/sources.list.d/pipbs.list

apt-get update -qq

echo "--- Installing proxmox-ve (pxvirt) ---"
apt-get install -y proxmox-ve proxmox-backup-server pve-qemu-kvm

echo "--- Removing enterprise repos (require subscription) ---"
rm -f /etc/apt/sources.list.d/*enterprise*
apt-get update -qq

echo "--- Setting hostname ---"
hostnamectl set-hostname arm64-ci
echo "127.0.1.1 arm64-ci.local arm64-ci" >> /etc/hosts

echo "--- Configuring vmbr0 bridge (needed for LXC creation in CI) ---"
# Disable cloud-init network management so our config persists across reboots
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

iface ${IFACE} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${VM_IP}/24
    gateway ${GATEWAY}
    dns-nameservers 8.8.8.8
    bridge-ports ${IFACE}
    bridge-stp off
    bridge-fd 0
EOF

echo "--- Rebooting to activate PVE kernel ---"
reboot
ENDSSH

echo "VM rebooting. Waiting for SSH after PVE kernel boot (may take 5-10 min)..."
sleep 30

for i in $(seq 1 120); do
    if ssh $SSH_OPTS -i "$SSH_KEY" root@${VM_IP} true 2>/dev/null; then
        echo "SSH ready after reboot ($((i * 5 + 30))s)"
        break
    fi
    [ $i -eq 120 ] && { echo "ERROR: VM did not come back within 630s after reboot"; qm stop $TEMPLATE_ID; exit 1; }
    echo "  attempt $i/120..."
    sleep 5
done

# =============================================================================
echo "=== Step 9: Verify PVE is running ==="
# =============================================================================
ssh $SSH_OPTS -i "$SSH_KEY" root@${VM_IP} bash -s << 'ENDSSH'
set -euo pipefail
echo "--- PVE version ---"
pveversion
echo "--- pve-cluster status ---"
systemctl is-active pve-cluster
echo "--- pvesh check ---"
pvesh get /version
echo "--- PBS version ---"
proxmox-backup-manager version
ENDSSH

# =============================================================================
echo "=== Step 10: Stop VM and convert to template ==="
# =============================================================================
qm stop $TEMPLATE_ID
sleep 5

qm template $TEMPLATE_ID

echo ""
echo "=== arm64 template $TEMPLATE_ID ($TEMPLATE_NAME) created successfully ==="
echo "    IP when cloned: $VM_IP"
echo "    Architecture:   aarch64 (emulated via QEMU, cpu=max)"
echo "    Base OS:        Debian Trixie"
echo "    PVE:            pxvirt (community ARM64 port)"
echo "    PBS:            pipbs (community ARM64 build)"
echo "    Used by:        proxmox-ci-backup-arm64 and proxmox-ci-dr-arm64"
