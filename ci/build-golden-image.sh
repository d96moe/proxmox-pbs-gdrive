#!/bin/bash
# =============================================================================
# ci/build-golden-image.sh — build the GENERIC golden DR image for a Raspberry
# Pi 5 node (runs on the CI BUILDER VM, never on the PVE host)
#
# The image = the latest official Raspberry Pi OS Lite arm64, with its own,
# untouched Pi boot chain, plus everything restore-1-install.sh would otherwise
# install over hours on site:
#   * official Proxmox VE arm64 (PVE 9.2+) + community pipbs PBS
#   * ZFS DKMS prebuilt for every installed Pi kernel (proxmox-ve pulls it in)
#   * restic, rclone, resticprofile
#   * this repository at /opt/proxmox-pbs-gdrive (the commit the image was built from)
#
# GENERIC — software only. Nothing that identifies a host or grants access:
# no accounts beyond Pi OS's own, no authorized_keys, no SSH host keys, no
# machine-id, no PVE/PBS keys or certificates, no config.env, no rclone token,
# no restic password, no hostname/IP. Those are created on first boot, set by
# Raspberry Pi Imager (user + SSH key) or come back from the config backup in a
# DR. ci/golden-leak-gate.sh enforces this; a hit fails the build.
#
# DR with the image: flash with Raspberry Pi Imager (set a user + SSH key),
# boot, then the usual restore-1 (configures THIS node, skips the installs,
# reboots), restore-1 again, restore-2, restore-3.
#
# Output in ${OUT_DIR}:
#   golden.img   raw disk image (the published .img.xz is made from it)
#   golden.env   manifest (versions, kernels, commit)
#
#   SRC_DIR=/srv/ci-build/golden-src GOLDEN_COMMIT=<sha> bash ci/build-golden-image.sh
# =============================================================================

set -euo pipefail

SRC_DIR="${SRC_DIR:-/srv/ci-build/golden-src}"     # repo checkout streamed in by Jenkins
GOLDEN_COMMIT="${GOLDEN_COMMIT:-unknown}"
IMAGE_SIZE_GB="${IMAGE_SIZE_GB:-8}"                # Pi OS grows the root fs to the disk on first boot
CACHE="/srv/ci-build/cache"
OUT_DIR="${OUT_DIR:-/srv/ci-build/out/golden}"
CHROOT_HOSTNAME="raspberrypi"                      # Pi OS's own default — never the builder's name

[ -f "${SRC_DIR}/lib/arm64-repos.sh" ] || { echo "ERROR: ${SRC_DIR} is not a repo checkout"; exit 1; }
# shellcheck source=../lib/arm64-repos.sh
. "${SRC_DIR}/lib/arm64-repos.sh"

mkdir -p "${CACHE}" "${OUT_DIR}"
WORK="$(mktemp -d /srv/ci-build/golden.XXXXXX)"
LOOPS=()
cleanup() {
    local l m p
    for p in /proc/[0-9]*; do
        [ "$(readlink "$p/root" 2>/dev/null)" = "${WORK}/root" ] && kill -KILL "${p#/proc/}" 2>/dev/null
    done
    sleep 1
    for m in $(findmnt -rno TARGET | grep "^${WORK}" | sort -r); do
        umount -R "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    done
    for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null || true; done
    rm -rf --one-file-system "${WORK}"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

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

# =============================================================================
echo "=== Step 2: Working copy, root partition grown to ${IMAGE_SIZE_GB} GB ==="
# =============================================================================
DISK="${WORK}/golden.img"
cp --sparse=always "${PIOS_IMG}" "${DISK}"
truncate -s "${IMAGE_SIZE_GB}G" "${DISK}"
echo ", +" | sfdisk -q -N 2 "${DISK}"
LOOP=$(losetup -fP --show "${DISK}"); LOOPS+=("${LOOP}")
e2fsck -fy "${LOOP}p2" >/dev/null || [ $? -le 1 ]
resize2fs "${LOOP}p2" >/dev/null
R="${WORK}/root"
B="${R}/boot/firmware"
mkdir -p "${R}"
mount "${LOOP}p2" "${R}"
mount "${LOOP}p1" "${B}"
CODENAME="$(. "${R}/etc/os-release"; echo "${VERSION_CODENAME}")"
PIOS_VERSION="$(. "${R}/etc/os-release"; echo "${PRETTY_NAME}") / $(head -1 "${R}/etc/rpi-issue" 2>/dev/null)"
echo "Pi OS: ${PIOS_VERSION}"
# The Pi boot chain must stay exactly as shipped: remember it, compare at the end.
cp "${B}/cmdline.txt" "${WORK}/cmdline.orig"
cp "${B}/config.txt" "${WORK}/config.orig"

# =============================================================================
echo "=== Step 3: Install PVE (official) + PBS (pipbs) + backup tools in an arm64 chroot ==="
# =============================================================================
for d in proc sys dev dev/pts; do mount --bind "/${d}" "${R}/${d}"; done
mv "${R}/etc/resolv.conf" "${R}/etc/resolv.conf.pios-orig" 2>/dev/null || true
cp /etc/resolv.conf "${R}/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "${R}/usr/sbin/policy-rc.d"   # no service starts in the chroot
chmod +x "${R}/usr/sbin/policy-rc.d"

# Repos with the SAME code restore-1-install.sh uses (lib/arm64-repos.sh)
add_official_pve_repo "${CODENAME}" "${R}"
add_pipbs_repo "${CODENAME}" "${R}"

# inroot <script>: run in the chroot inside its own UTS namespace whose hostname
# is Pi OS's default, so no package records the BUILDER's hostname anywhere.
inroot() {
    unshare --uts /bin/bash -c "hostname ${CHROOT_HOSTNAME}; exec chroot '${R}' /usr/bin/env DEBIAN_FRONTEND=noninteractive HOME=/root bash -c \"\$0\"" "$1"
}

inroot '
    set -euo pipefail
    apt_get() { apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"; }
    apt-get update -qq
    apt_get -y -qq dist-upgrade
    # Keep only the newest Pi kernel per flavour (DKMS builds ZFS for each one)
    for flavour in rpi-v8 rpi-2712; do
        newest=$(ls /usr/lib/modules | grep -E "rpt-${flavour}\$" | sort -V | tail -1)
        for k in $(ls /usr/lib/modules | grep -E "rpt-${flavour}\$"); do
            [ "$k" = "$newest" ] && continue
            apt_get -y -qq purge "linux-image-$k" "linux-headers-$k" || true
        done
    done
    apt_get -y -qq autoremove --purge

    # postfix asks questions; a local-only MTA with a neutral mailname (the node
    # name is set later by restore-1, never baked in here)
    echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
    echo "postfix postfix/mailname string localhost" | debconf-set-selections

    echo "--- proxmox-ve (official arm64) — same package set as restore-1 Step 0"
    apt_get -y install proxmox-ve postfix open-iscsi chrony ifupdown2 ca-certificates curl gnupg unzip
    command -v pvesh >/dev/null || { echo "ERROR: proxmox-ve did not install"; exit 1; }
    rm -f /etc/apt/sources.list.d/*enterprise*
    for f in $(grep -l "enterprise\.proxmox\.com" /etc/apt/sources.list.d/* 2>/dev/null || true); do rm -f "$f"; done
    apt-get update -qq

    echo "--- proxmox-backup-server (pipbs) — must not remove any PVE package"
    sim="$(apt-get -s install proxmox-backup-server)"
    if printf "%s\n" "$sim" | grep -qE "^Remv (proxmox-ve|pve-manager|qemu-server|pve-container|pve-cluster) "; then
        echo "ERROR: installing pipbs PBS would remove PVE packages:"; printf "%s\n" "$sim" | grep "^Remv"; exit 1
    fi
    apt_get -y install proxmox-backup-server
    rm -f /etc/apt/sources.list.d/*enterprise*

    echo "--- restic, rclone, resticprofile (as restore-1 Steps 2-4)"
    apt_get -y install restic
    curl -fsSL --retry 3 https://rclone.org/install.sh | bash
    cd /tmp && curl -sfL --retry 3 https://raw.githubusercontent.com/creativeprojects/resticprofile/master/install.sh | sh
    mv /tmp/bin/resticprofile /usr/local/bin/ && rm -rf /tmp/bin

    if dpkg -s zfs-dkms >/dev/null 2>&1; then
        echo "--- ZFS DKMS must be built for every installed Pi kernel (with headers)"
        for k in $(ls /usr/lib/modules | grep rpt); do
            [ -d "/usr/lib/modules/$k/build" ] || continue
            dkms autoinstall -k "$k" >/dev/null || true
            dkms status -k "$k" zfs | grep -q installed || { echo "ERROR: zfs DKMS not built for $k"; exit 1; }
        done
    else
        echo "--- zfs-dkms not pulled in — nothing to prebuild"
    fi

    apt_get -y -qq autoremove --purge
    apt-get clean
    echo "versions: pve-manager=$(dpkg-query -W -f="\${Version}" pve-manager) proxmox-backup-server=$(dpkg-query -W -f="\${Version}" proxmox-backup-server) restic=$(dpkg-query -W -f="\${Version}" restic) rclone=$(rclone version | awk "NR==1{print \$2}") resticprofile=$(resticprofile version | awk "{print \$3; exit}")"
'

# This repository, as built (public code — no config.env, no secrets)
mkdir -p "${R}/opt/proxmox-pbs-gdrive"
cp -a "${SRC_DIR}/." "${R}/opt/proxmox-pbs-gdrive/"
rm -rf "${R}/opt/proxmox-pbs-gdrive/.git" "${R}/opt/proxmox-pbs-gdrive/config.env"
echo "${GOLDEN_COMMIT}" > "${R}/opt/proxmox-pbs-gdrive/GOLDEN_COMMIT"

# =============================================================================
echo "=== Step 4: Generalize — remove everything that identifies a host ==="
# =============================================================================
rm -f "${R}/usr/sbin/policy-rc.d" "${R}/etc/resolv.conf"
mv "${R}/etc/resolv.conf.pios-orig" "${R}/etc/resolv.conf" 2>/dev/null || true
for d in dev/pts dev sys proc; do umount "${R}/${d}"; done

# SSH host keys (Pi OS regenerates them on first boot) and any root keypair
rm -f "${R}"/etc/ssh/ssh_host_*
rm -rf "${R}/root/.ssh"
# machine-id: empty file = "generate on first boot" (systemd)
: > "${R}/etc/machine-id"
rm -f "${R}/var/lib/dbus/machine-id" "${R}/var/lib/systemd/random-seed" "${R}/var/lib/systemd/credential.secret"
# PVE: /etc/pve is pmxcfs's mount point — anything a postinst wrote to the bare
# directory would be hidden later anyway; config.db is created on first start
find "${R}/etc/pve" -mindepth 1 -delete 2>/dev/null || true
rm -rf "${R}"/var/lib/pve-cluster/*
# PBS keys/certs — generated again when PBS first starts
rm -f "${R}"/etc/proxmox-backup/{proxy.key,proxy.pem,authkey.key,authkey.pub,csrf.key}
# cloud-init must start from scratch so Raspberry Pi Imager's seed applies
rm -rf "${R}"/var/lib/cloud/instances "${R}"/var/lib/cloud/instance "${R}"/var/lib/cloud/data "${R}"/var/lib/cloud/sem
# logs, caches, shell history
find "${R}/var/log" -type f -exec truncate -s 0 {} +
rm -rf "${R}"/var/cache/apt/archives/*.deb "${R}"/tmp/* "${R}"/var/tmp/* "${R}"/root/.bash_history "${R}"/root/.cache

# Pi boot chain untouched?
cmp -s "${WORK}/cmdline.orig" "${B}/cmdline.txt" || { echo "ERROR: cmdline.txt changed"; diff "${WORK}/cmdline.orig" "${B}/cmdline.txt"; exit 1; }
cmp -s "${WORK}/config.orig"  "${B}/config.txt"  || { echo "ERROR: config.txt changed";  diff "${WORK}/config.orig"  "${B}/config.txt";  exit 1; }
PI_KERNELS="$(ls "${R}/usr/lib/modules" | grep rpt | tr '\n' ' ')"
FREE_MB=$(df -m --output=avail "${B}" | tail -1 | tr -d ' ')
echo "Pi kernels: ${PI_KERNELS}; free on /boot/firmware: ${FREE_MB} MB"
[ "${FREE_MB}" -lt 150 ] && { echo "ERROR: <150 MB left on /boot/firmware"; exit 1; }

# =============================================================================
echo "=== Step 5: Leak gate ==="
# =============================================================================
BUILDER_ID="$(hostname) $(hostname -I 2>/dev/null)"
bash "${SRC_DIR}/ci/golden-leak-gate.sh" "${R}" "${B}" ${BUILDER_ID}

PVE_VERSION="$(chroot "${R}" dpkg-query -W -f='${Version}' pve-manager)"
PBS_VERSION="$(chroot "${R}" dpkg-query -W -f='${Version}' proxmox-backup-server)"
sync
umount "${B}"
umount "${R}"
e2fsck -fy "${LOOP}p2" >/dev/null || [ $? -le 1 ]
losetup -d "${LOOP}"; LOOPS=()

# =============================================================================
echo "=== Step 6: Write artifact ==="
# =============================================================================
mv "${DISK}" "${OUT_DIR}/golden.img.tmp"
mv "${OUT_DIR}/golden.img.tmp" "${OUT_DIR}/golden.img"
cat > "${OUT_DIR}/golden.env" << EOF
GOLDEN_DATE="$(date -u +%F)"
GOLDEN_COMMIT="${GOLDEN_COMMIT}"
PIOS_IMAGE="$(basename "${PIOS_IMG}")"
PIOS_VERSION="${PIOS_VERSION}"
PVE_VERSION="${PVE_VERSION}"
PBS_VERSION="${PBS_VERSION}"
PI_KERNELS="${PI_KERNELS}"
EOF
echo "Artifact: ${OUT_DIR}/golden.img ($(du -h --apparent-size "${OUT_DIR}/golden.img" | cut -f1) apparent, $(du -h "${OUT_DIR}/golden.img" | cut -f1) on disk)"
cat "${OUT_DIR}/golden.env"
