#!/bin/bash
# =============================================================================
# ci/build-pios-disk.sh — build the Pi OS arm64 CI disk image (runs on the
# CI BUILDER VM, never on the PVE host)
#
# Output: ${OUT_DIR}/pios-ci.qcow2 + ${OUT_DIR}/pios-ci.env (metadata).
# ci/setup-arm64-pios-template.sh then imports it on the PVE host (qm only).
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
# Kernel source: the Debian trixie genericcloud arm64 image — the same kernel
# the Debian-based template 9002 runs PVE/PBS/LXC on today.
#
#   JENKINS_PUBKEY="ssh-ed25519 ..." bash ci/build-pios-disk.sh
# =============================================================================

set -euo pipefail

: "${JENKINS_PUBKEY:?JENKINS_PUBKEY must be set (pubkey the CI VMs accept)}"
TEMPLATE_ID="${TEMPLATE_ID:-9003}"
VM_IP="${VM_IP:-192.168.0.252}"
GATEWAY="${GATEWAY:-192.168.0.1}"
NAMESERVER="${NAMESERVER:-8.8.8.8}"
DISK_SIZE_GB="${DISK_SIZE_GB:-32}"
DEBIAN_CODENAME="trixie"
CACHE="/srv/ci-build/cache"
OUT_DIR="${OUT_DIR:-/srv/ci-build/out}"

mkdir -p "${CACHE}" "${OUT_DIR}"
WORK="$(mktemp -d /srv/ci-build/pios.XXXXXX)"
LOOPS=()
MOUNTS=()
cleanup() {
    local l
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

# =============================================================================
echo "=== Step 1: Latest Raspberry Pi OS Lite arm64 ==="
# =============================================================================
PIOS_URL=$(curl -fsSI https://downloads.raspberrypi.com/raspios_lite_arm64_latest \
    | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')
[ -z "${PIOS_URL}" ] && { echo "ERROR: could not resolve latest Pi OS Lite arm64 URL"; exit 1; }
PIOS_XZ="${CACHE}/$(basename "${PIOS_URL}")"
PIOS_IMG="${PIOS_XZ%.xz}"
echo "Latest: $(basename "${PIOS_URL}")"
[ -f "${PIOS_XZ}" ] || curl -fsSL --retry 3 -o "${PIOS_XZ}" "${PIOS_URL}"
curl -fsSL "${PIOS_URL}.sha256" | awk -v f="${PIOS_XZ}" '{print $1"  "f}' | sha256sum -c -
[ -f "${PIOS_IMG}" ] || xz -dk "${PIOS_XZ}"
# Keep only the current image (+.xz) in the cache
find "${CACHE}" -maxdepth 1 -name '*-raspios-*-arm64-lite.img*' \
    ! -name "$(basename "${PIOS_IMG}")*" -delete

# =============================================================================
echo "=== Step 2: Debian ${DEBIAN_CODENAME} arm64 cloud kernel + initrd + modules ==="
# =============================================================================
DEB_IMAGE_FILENAME=$(curl -fsSL "https://cloud.debian.org/images/cloud/${DEBIAN_CODENAME}/daily/latest/" \
    | grep -oE 'debian-[0-9]+-genericcloud-arm64-daily\.qcow2' | sort -u | awk 'NR==1')
[ -z "${DEB_IMAGE_FILENAME}" ] && { echo "ERROR: no genericcloud-arm64-daily image found"; exit 1; }
DEB_QCOW="${CACHE}/${DEB_IMAGE_FILENAME}"
# "daily/latest" — always refresh so the kernel tracks Debian's current one
curl -fsSL --retry 3 -o "${DEB_QCOW}" \
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
# Capture first, then grep: `lsinitramfs | grep -q` lets grep exit on the first
# match, the zstd inside lsinitramfs dies of SIGPIPE ("zstd failed") and
# pipefail turns a successful check into a failure.
lsinitramfs "${WORK}/deb/boot/initrd.img-${KVER}" > "${WORK}/initrd.list"
grep -q 'virtio_scsi' "${WORK}/initrd.list" \
    || { echo "ERROR: initrd for ${KVER} has no virtio_scsi module"; exit 1; }

# =============================================================================
echo "=== Step 3: Build the disk from the Pi OS image ==="
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
PIOS_VERSION="$(. "${R}/etc/os-release"; echo "${PRETTY_NAME}") / $(head -1 "${R}/etc/rpi-issue" 2>/dev/null)"
echo "Pi OS: ${PIOS_VERSION}, root PARTUUID=${ROOT_PARTUUID}"

# Bring the image up to date ONCE here (weekly), instead of in every nightly CI
# run: the Pi kernels' upgrade + initramfs regeneration is slow under full
# arm64 emulation and has nothing DR-specific about it. restore-1-install.sh
# still runs its own dist-upgrade in CI (only the delta since this build).
# Done in an arm64 chroot via qemu-user (binfmt) — the image is never booted,
# so it stays pristine (no machine-id, no SSH host keys, no cloud-init state).
# PVE/ZFS are deliberately NOT installed here: installing them is the test.
echo "--- dist-upgrade in arm64 chroot (qemu-user) ---"
for d in proc sys dev dev/pts; do mount --bind "/${d}" "${R}/${d}"; MOUNTS+=("${R}/${d}"); done
# DNS for apt inside the chroot; the image's own resolv.conf (file or symlink) is restored after
mv "${R}/etc/resolv.conf" "${R}/etc/resolv.conf.pios-orig" 2>/dev/null || true
cp /etc/resolv.conf "${R}/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "${R}/usr/sbin/policy-rc.d"   # no service starts in the chroot
chmod +x "${R}/usr/sbin/policy-rc.d"
chroot "${R}" /usr/bin/env DEBIAN_FRONTEND=noninteractive bash -c '
    set -euo pipefail
    apt-get update -qq
    apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade
    apt-get -y -qq autoremove --purge
    apt-get clean
'
rm -f "${R}/usr/sbin/policy-rc.d" "${R}/etc/resolv.conf"
mv "${R}/etc/resolv.conf.pios-orig" "${R}/etc/resolv.conf" 2>/dev/null || true
for d in dev/pts dev sys proc; do umount "${R}/${d}"; done
MOUNTS=("${WORK}/deb" "${WORK}/root" "${WORK}/root/boot/firmware")
PI_KERNELS="$(ls "${R}/usr/lib/modules" | grep rpt | tr '\n' ' ')"
echo "Pi kernels after upgrade: ${PI_KERNELS}"

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
# grub-efi-arm64-bin is arm64-only (not installable on this x86 builder), so its
# modules are taken straight from the Debian .deb. awk must read to EOF: an
# early `exit` SIGPIPEs xz -> exit 141 under pipefail.
GRUB_DEB_PATH=$(curl -fsSL "https://deb.debian.org/debian/dists/${DEBIAN_CODENAME}/main/binary-arm64/Packages.xz" \
    | xz -dc | awk '/^Package: grub-efi-arm64-bin$/{f=1} f&&!d&&/^Filename:/{print $2; d=1}')
[ -z "${GRUB_DEB_PATH}" ] && { echo "ERROR: grub-efi-arm64-bin not found in Debian index"; exit 1; }
curl -fsSL --retry 3 -o "${WORK}/grub.deb" "https://deb.debian.org/debian/${GRUB_DEB_PATH}"
dpkg-deb -x "${WORK}/grub.deb" "${WORK}/grubpkg"
grub-mkstandalone -O arm64-efi -d "${WORK}/grubpkg/usr/lib/grub/arm64-efi" \
    --modules="part_msdos fat gzio search search_fs_file linux normal" \
    -o "${B}/EFI/BOOT/BOOTAA64.EFI" "boot/grub/grub.cfg=${WORK}/grub.cfg"

# Pi firmware partition must keep headroom: apt upgrades of the Pi kernels write here.
FREE_MB=$(df -m --output=avail "${B}" | tail -1 | tr -d ' ')
echo "Free on /boot/firmware: ${FREE_MB} MB"
[ "${FREE_MB}" -lt 150 ] && { echo "ERROR: <150 MB left on /boot/firmware"; exit 1; }

# =============================================================================
echo "=== Step 4: First-boot config via the NoCloud seed (as Raspberry Pi Imager writes it) ==="
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
# Pi OS renders netplan through NetworkManager, which does NOT support
# `match: driver:` — cloud-init's whole init-local stage crashes on it
# ("NetworkManager definitions do not support matching by driver"), so neither
# the IP nor the SSH key gets applied. Name the NIC explicitly instead: on this
# VM config (PVE net0 = virtio, PCI slot 0x12) it is always enp0s18. If PVE ever
# places it elsewhere, the smoke test fails loudly on the missing IP.
CI_NIC="${CI_NIC:-enp0s18}"
cat > "${B}/network-config" << EOF
network:
  version: 2
  ethernets:
    ${CI_NIC}:
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
for l in "${LOOPS[@]}"; do losetup -d "$l"; done
LOOPS=()

# =============================================================================
echo "=== Step 5: Write artifact ==="
# =============================================================================
qemu-img convert -O qcow2 "${DISK}" "${OUT_DIR}/pios-ci.qcow2.tmp"
mv "${OUT_DIR}/pios-ci.qcow2.tmp" "${OUT_DIR}/pios-ci.qcow2"
cat > "${OUT_DIR}/pios-ci.env" << EOF
PIOS_IMAGE="$(basename "${PIOS_IMG}")"
PIOS_VERSION="${PIOS_VERSION}"
BOOT_KERNEL="${KVER}"
PI_KERNELS="${PI_KERNELS}"
EOF
echo "Artifact: ${OUT_DIR}/pios-ci.qcow2 ($(du -h "${OUT_DIR}/pios-ci.qcow2" | cut -f1))"
cat "${OUT_DIR}/pios-ci.env"
