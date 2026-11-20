#!/bin/bash
# =============================================================================
# ci/setup-arm64-pios-template.sh — (Re)build the Pi OS arm64 CI template VM
#
# Builds VM 9003 (NOT yet a template — the Jenkins job smoke-boots a clone of it
# first and only then runs `qm template 9003`):
#
#   * Disk = the LATEST official Raspberry Pi OS Lite arm64 image, unmodified
#     userland: same apt sources (incl. archive.raspberrypi.com), same defaults
#     (cloud-init NoCloud seed in /boot/firmware, netplan + NetworkManager), same
#     partition layout. This is the image you would flash in a real disaster.
#   * Only the boot layer is swapped (the "MCAL" of this L3 test): the Pi kernel
#     has no virtio/PCI-host support and cannot boot on QEMU `virt`, so Debian's
#     arm64 cloud kernel + initrd + its modules are added, booted by a standalone
#     GRUB EFI binary placed on the Pi OS FAT partition. The Pi kernels stay
#     installed (and keep getting upgraded by apt) — they are just not booted.
#   * First-boot config goes into the NoCloud seed files exactly like
#     Raspberry Pi Imager writes them (user-data / network-config / meta-data).
#
# Runs entirely on the PVE host with tools it already has (qemu-img, losetup,
# sfdisk, resize2fs, dpkg-deb, grub-mkstandalone). No arm64 code is executed
# here and NO packages are installed on the host.
#
# Kernel source: the Debian trixie genericcloud arm64 image — the same kernel
# the Debian-based template 9002 runs PVE/PBS/LXC on today.
#
#   bash ci/setup-arm64-pios-template.sh
# =============================================================================

set -euo pipefail

TEMPLATE_ID=9003
TEMPLATE_NAME="arm64-pios-restore-ci"
VM_IP="192.168.0.252"
GATEWAY="192.168.0.1"
NAMESERVER="8.8.8.8"
STORAGE="local-lvm"
DISK_SIZE_GB=32
ISO_DIR="/var/lib/vz/template/iso"
DEBIAN_CODENAME="trixie"

WORK="$(mktemp -d /var/tmp/pios-template.XXXXXX)"
LOOPS=()
MOUNTS=()
cleanup() {
    local m l
    for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do umount "${MOUNTS[$i]}" 2>/dev/null || true; done
    for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null || true; done
    rm -rf "${WORK}"
}
trap cleanup EXIT

mnt() {  # mnt <dev> <dir> [opts]
    mkdir -p "$2"
    mount ${3:+-o "$3"} "$1" "$2"
    MOUNTS+=("$2")
}

# Jenkins SSH pubkey — extracted from template 9001 (same as setup-arm64-template.sh)
JENKINS_PUBKEY=$(qm config 9001 | grep sshkeys \
    | sed 's/sshkeys: //' \
    | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))")
[ -z "$JENKINS_PUBKEY" ] && { echo "ERROR: cannot extract Jenkins pubkey from template 9001"; exit 1; }

# =============================================================================
echo "=== Step 1: Download latest Raspberry Pi OS Lite arm64 ==="
# =============================================================================
PIOS_URL=$(curl -fsSI https://downloads.raspberrypi.com/raspios_lite_arm64_latest \
    | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')
[ -z "${PIOS_URL}" ] && { echo "ERROR: could not resolve latest Pi OS Lite arm64 URL"; exit 1; }
PIOS_XZ="${ISO_DIR}/$(basename "${PIOS_URL}")"
PIOS_IMG="${PIOS_XZ%.xz}"
echo "Latest: $(basename "${PIOS_URL}")"
[ -f "${PIOS_XZ}" ] || curl -fsSL --retry 3 -o "${PIOS_XZ}" "${PIOS_URL}"
curl -fsSL "${PIOS_URL}.sha256" | awk -v f="${PIOS_XZ}" '{print $1"  "f}' | sha256sum -c -
[ -f "${PIOS_IMG}" ] || xz -dk "${PIOS_XZ}"
# Keep only the current image (+.xz) — older ones are just disk usage.
find "${ISO_DIR}" -maxdepth 1 -name '*-raspios-*-arm64-lite.img*' \
    ! -name "$(basename "${PIOS_IMG}")*" -delete

# =============================================================================
echo "=== Step 2: Extract Debian ${DEBIAN_CODENAME} arm64 cloud kernel + initrd + modules ==="
# =============================================================================
DEB_IMAGE_FILENAME=$(curl -fsSL "https://cloud.debian.org/images/cloud/${DEBIAN_CODENAME}/daily/latest/" \
    | grep -oE 'debian-[0-9]+-genericcloud-arm64-daily\.qcow2' | sort -u | head -1)
[ -z "${DEB_IMAGE_FILENAME}" ] && { echo "ERROR: no genericcloud-arm64-daily image found"; exit 1; }
DEB_QCOW="${ISO_DIR}/${DEB_IMAGE_FILENAME}"
# setup-arm64-template.sh refreshes this same file weekly; fetch only if missing.
[ -f "${DEB_QCOW}" ] || wget --progress=dot:giga -O "${DEB_QCOW}" \
    "https://cloud.debian.org/images/cloud/${DEBIAN_CODENAME}/daily/latest/${DEB_IMAGE_FILENAME}"
qemu-img convert -O raw "${DEB_QCOW}" "${WORK}/debian.raw"
DLOOP=$(losetup -fPr --show "${WORK}/debian.raw"); LOOPS+=("${DLOOP}")
DROOT=""
for p in "${DLOOP}"p*; do
    mkdir -p "${WORK}/probe"
    if mount -o ro "$p" "${WORK}/probe" 2>/dev/null; then
        if ls "${WORK}"/probe/boot/vmlinuz-* >/dev/null 2>&1; then DROOT="$p"; fi
        umount "${WORK}/probe"
    fi
    [ -n "${DROOT}" ] && break
done
[ -z "${DROOT}" ] && { echo "ERROR: no partition with /boot/vmlinuz-* in ${DEB_IMAGE_FILENAME}"; exit 1; }
mnt "${DROOT}" "${WORK}/deb" ro
KVER=$(basename "$(ls "${WORK}"/deb/boot/vmlinuz-* | sort -V | tail -1)" | sed 's/^vmlinuz-//')
echo "Debian kernel: ${KVER}"
for k in VIRTIO_PCI EXT4_FS EFI_STUB; do
    grep -q "^CONFIG_${k}=y" "${WORK}/deb/boot/config-${KVER}" \
        || { echo "ERROR: ${KVER} lacks CONFIG_${k}=y"; exit 1; }
done
# Best-effort initrd peek: Debian's initrd is zstd-compressed and the PVE host
# has no zstd binary (deliberately not installed here). If it can't be listed,
# the Jenkins smoke-boot of a clone is the real proof that root mounts.
if INITRD_LIST=$(lsinitramfs "${WORK}/deb/boot/initrd.img-${KVER}" 2>/dev/null); then
    grep -q 'virtio_scsi' <<< "${INITRD_LIST}" \
        || { echo "ERROR: initrd for ${KVER} has no virtio_scsi module"; exit 1; }
else
    echo "  NOTE: cannot list initrd on this host (no zstd) — relying on the smoke-boot"
fi

# =============================================================================
echo "=== Step 3: Standalone GRUB arm64-efi binary (modules from the Debian .deb, not installed) ==="
# =============================================================================
GRUB_DEB_PATH=$(curl -fsSL "https://deb.debian.org/debian/dists/${DEBIAN_CODENAME}/main/binary-arm64/Packages.xz" \
    | xz -dc | awk '/^Package: grub-efi-arm64-bin$/{f=1} f&&/^Filename:/{print $2; exit}')
[ -z "${GRUB_DEB_PATH}" ] && { echo "ERROR: grub-efi-arm64-bin not found in Debian index"; exit 1; }
curl -fsSL --retry 3 -o "${WORK}/grub.deb" "https://deb.debian.org/debian/${GRUB_DEB_PATH}"
dpkg-deb -x "${WORK}/grub.deb" "${WORK}/grubpkg"
[ -d "${WORK}/grubpkg/usr/lib/grub/arm64-efi" ] || { echo "ERROR: arm64-efi modules missing in grub deb"; exit 1; }
# GRUB config is filled in after the root PARTUUID is known (step 4).

# =============================================================================
echo "=== Step 4: Build the VM disk from the Pi OS image ==="
# =============================================================================
DISK="${WORK}/disk.raw"
cp --sparse=always "${PIOS_IMG}" "${DISK}"
truncate -s "${DISK_SIZE_GB}G" "${DISK}"
# Grow the root partition (p2) to the end of the disk — what the Pi's first-boot
# "resize" (cmdline.txt) would do; that hook never runs here because GRUB boots
# with its own command line.
echo ", +" | sfdisk -q -N 2 "${DISK}"
PLOOP=$(losetup -fP --show "${DISK}"); LOOPS+=("${PLOOP}")
e2fsck -fy "${PLOOP}p2" >/dev/null || [ $? -le 1 ]
resize2fs "${PLOOP}p2" >/dev/null
mnt "${PLOOP}p2" "${WORK}/root"
mnt "${PLOOP}p1" "${WORK}/root/boot/firmware"
R="${WORK}/root"
B="${R}/boot/firmware"

ROOT_PARTUUID=$(awk '$2=="/"{sub(/^PARTUUID=/,"",$1); print $1}' "${R}/etc/fstab")
[ -z "${ROOT_PARTUUID}" ] && { echo "ERROR: cannot read root PARTUUID from Pi OS fstab"; exit 1; }
PIOS_VERSION=$(. "${R}/etc/os-release"; echo "${PRETTY_NAME}")
echo "Pi OS: ${PIOS_VERSION} ($(head -1 "${R}/etc/rpi-issue" 2>/dev/null)), root PARTUUID=${ROOT_PARTUUID}"

# Kernel modules for the swapped-in kernel (Pi OS is usrmerged: /lib -> usr/lib)
cp -a "${WORK}/deb/usr/lib/modules/${KVER}" "${R}/usr/lib/modules/"

# Kernel + initrd + GRUB on the FAT partition (Pi firmware files stay untouched)
mkdir -p "${B}/ci-boot" "${B}/EFI/BOOT"
cp "${WORK}/deb/boot/vmlinuz-${KVER}" "${B}/ci-boot/vmlinuz"
cp "${WORK}/deb/boot/initrd.img-${KVER}" "${B}/ci-boot/initrd.img"
echo "${KVER}" > "${B}/ci-boot/KERNEL_VERSION"
cat > "${WORK}/grub.cfg" << EOF
set timeout=0
insmod part_msdos
insmod fat
insmod gzio
search --no-floppy --set=root --file /ci-boot/vmlinuz
linux /ci-boot/vmlinuz root=PARTUUID=${ROOT_PARTUUID} rootfstype=ext4 rw rootwait console=ttyAMA0
initrd /ci-boot/initrd.img
boot
EOF
grub-mkstandalone -O arm64-efi -d "${WORK}/grubpkg/usr/lib/grub/arm64-efi" \
    --modules="part_msdos fat gzio search search_fs_file linux normal" \
    -o "${B}/EFI/BOOT/BOOTAA64.EFI" "boot/grub/grub.cfg=${WORK}/grub.cfg"

# Pi firmware partition must keep headroom: apt upgrades of the Pi kernels write here.
FREE_MB=$(df -m --output=avail "${B}" | tail -1 | tr -d ' ')
echo "Free on /boot/firmware: ${FREE_MB} MB"
[ "${FREE_MB}" -lt 150 ] && { echo "ERROR: <150 MB left on /boot/firmware"; exit 1; }

# =============================================================================
echo "=== Step 5: First-boot config via the NoCloud seed (as Raspberry Pi Imager writes it) ==="
# =============================================================================
cat > "${B}/meta-data" << EOF
dsmode: local
instance_id: pios-ci-${TEMPLATE_ID}
EOF
cat > "${B}/user-data" << EOF
#cloud-config
hostname: restore-ci-arm64
manage_etc_hosts: true
disable_root: false
ssh_pwauth: false
users:
  - name: root
    lock_passwd: false
    ssh_authorized_keys:
      - ${JENKINS_PUBKEY}
chpasswd:
  expire: false
  users:
    - {name: root, password: ci-template-root, type: text}
EOF
cat > "${B}/network-config" << EOF
network:
  version: 2
  ethernets:
    ci0:
      match:
        driver: virtio_net
      dhcp4: false
      addresses: [${VM_IP}/24]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${NAMESERVER}]
      optional: false
EOF
# Pi OS enables sshd on first boot when this file exists (sshswitch.service)
touch "${B}/ssh"

sync
for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do umount "${MOUNTS[$i]}"; done
MOUNTS=()

# =============================================================================
echo "=== Step 6: (Re)create VM ${TEMPLATE_ID} ==="
# =============================================================================
if qm status ${TEMPLATE_ID} &>/dev/null; then
    qm stop ${TEMPLATE_ID} 2>/dev/null || true
    sleep 3
    qm destroy ${TEMPLATE_ID} --purge 1
    echo "Removed existing VM ${TEMPLATE_ID}"
fi
qm create ${TEMPLATE_ID} \
    --name "${TEMPLATE_NAME}" \
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
    --vga serial0 \
    --description "Pi OS CI template: ${PIOS_VERSION}, $(basename "${PIOS_IMG}"), boot kernel ${KVER} (Debian cloud, swapped boot layer)"
qm importdisk ${TEMPLATE_ID} "${DISK}" ${STORAGE} --format raw
qm set ${TEMPLATE_ID} --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0,discard=on --boot order=scsi0
# PBS data disk — formatted fresh each CI run by the pipeline (same as 9002)
qm set ${TEMPLATE_ID} --scsi1 ${STORAGE}:4,format=raw

echo ""
echo "=== VM ${TEMPLATE_ID} (${TEMPLATE_NAME}) built — NOT yet a template ==="
echo "    Base OS:      ${PIOS_VERSION} ($(basename "${PIOS_IMG}"))"
echo "    Boot kernel:  ${KVER} (Debian cloud — Pi kernels installed but not booted)"
echo "    IP:           ${VM_IP} (NoCloud network-config)"
echo "    Next:         smoke-boot a clone, then: qm template ${TEMPLATE_ID}"
