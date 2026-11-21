#!/bin/bash
# =============================================================================
# ci/check-arm64-deps.sh — nightly L2 arm64 dependency check (runs on the CI
# builder VM, never on the PVE host)
#
# Answers in about a minute what a full emulated DR run takes 30 min to find:
# can the CURRENT pxvirt (PVE) and pipbs (PBS) packages still be installed
# together on the CURRENT Raspberry Pi OS?
#
#   * Root filesystem: the latest Pi OS Lite image from the builder cache (the
#     same image the 9003 template is built from), mounted read-only with a
#     throw-away tmpfs overlay on top — nothing is ever written to the image.
#   * arm64 chroot via qemu-user (binfmt). Repos are added with the SAME code a
#     real install uses (lib/arm64-repos.sh), then apt only SIMULATES (-s).
#
# Exit codes (mapped to Jenkins results by Jenkinsfile.arm64-deps):
#   0 — latest PVE + latest pipbs PBS install together            (green)
#   3 — latest PBS conflicts, but the self-hosted fallback works   (yellow)
#   1 — PVE itself does not resolve, or even the fallback conflicts (red)
# =============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/arm64-repos.sh
. "${HERE}/../lib/arm64-repos.sh"

CACHE="/srv/ci-build/cache"
# Which PVE source to test: pxvirt (community port, what the cabin runs today)
# or official (Proxmox's own arm64 build, PVE 9.2+). PBS is pipbs either way.
PVE_ARM64_SOURCE="${PVE_ARM64_SOURCE:-pxvirt}"
case "${PVE_ARM64_SOURCE}" in
    pxvirt)   PVE_PKGS="proxmox-ve pve-qemu-kvm" ;;                       # what restore-1 step 0 installs
    official) PVE_PKGS="proxmox-ve postfix open-iscsi chrony" ;;          # per the official Debian 13 install wiki
    *) echo "ERROR: PVE_ARM64_SOURCE must be pxvirt or official"; exit 1 ;;
esac
PVE_REMOVE_RE='^Remv (proxmox-ve|pve-manager|qemu-server|pve-container|pve-cluster) '

IMG="$(ls -t "${CACHE}"/*-raspios-*-arm64-lite.img 2>/dev/null | awk 'NR==1')"
[ -n "${IMG}" ] || { echo "ERROR: no Pi OS image in ${CACHE} — run the Pi OS template build first"; exit 1; }

WORK="$(mktemp -d /srv/ci-build/l2.XXXXXX)"
R="${WORK}/root"
LOOP=""
cleanup() {
    local p m
    for p in /proc/[0-9]*; do
        [ "$(readlink "$p/root" 2>/dev/null)" = "${R}" ] && kill -KILL "${p#/proc/}" 2>/dev/null
    done
    sleep 1
    for m in $(findmnt -rno TARGET | grep "^${WORK}" | sort -r); do
        umount -R "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    done
    [ -n "${LOOP}" ] && losetup -d "${LOOP}" 2>/dev/null || true
    rm -rf --one-file-system "${WORK}"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

echo "=== L2 arm64 dependency check on $(basename "${IMG}") ==="
mkdir -p "${WORK}/lower" "${WORK}/rw" "${R}"
LOOP="$(losetup -fPr --show "${IMG}")"
mount -o ro "${LOOP}p2" "${WORK}/lower"
mount -t tmpfs -o size=4G tmpfs "${WORK}/rw"
mkdir -p "${WORK}/rw/upper" "${WORK}/rw/work"
mount -t overlay overlay -o "lowerdir=${WORK}/lower,upperdir=${WORK}/rw/upper,workdir=${WORK}/rw/work" "${R}"
for d in proc sys dev dev/pts; do mount --bind "/${d}" "${R}/${d}"; done
rm -f "${R}/etc/resolv.conf"; cp /etc/resolv.conf "${R}/etc/resolv.conf"

CODENAME="$(. "${R}/etc/os-release"; echo "${VERSION_CODENAME}")"
echo "Pi OS: $(. "${R}/etc/os-release"; echo "${PRETTY_NAME}") / $(head -1 "${R}/etc/rpi-issue" 2>/dev/null)"
echo "PVE source: ${PVE_ARM64_SOURCE}"
if [ "${PVE_ARM64_SOURCE}" = official ]; then
    add_official_pve_repo "${CODENAME}" "${R}"
else
    add_pxvirt_repo "${CODENAME}" "${R}"
fi
add_pipbs_repo "${CODENAME}" "${R}"

inroot() { chroot "${R}" /usr/bin/env DEBIAN_FRONTEND=noninteractive "$@"; }
inroot apt-get update -qq

# sim <label> <apt args...> — dry-run; ok = resolves AND removes no PVE package
sim() {
    local label="$1" out rc; shift
    set +e; out="$(inroot apt-get -s "$@" 2>&1)"; rc=$?; set -e
    if [ ${rc} -ne 0 ]; then
        echo "  ✗ ${label}: does not resolve"; printf '%s\n' "${out}" | grep -E '^(E:| )' | sed 's/^/      /' | tail -15
        return 1
    fi
    if printf '%s\n' "${out}" | grep -E "${PVE_REMOVE_RE}" > "${WORK}/remv"; then
        echo "  ✗ ${label}: would REMOVE PVE packages:"; sed 's/^/      /' "${WORK}/remv"
        return 1
    fi
    echo "  ✓ ${label}"
    # Kernel side effects (Pi must keep booting its own rpi kernel): show any
    # kernel/firmware package this install would pull in.
    printf '%s\n' "${out}" | grep -E '^Inst (linux-image|proxmox-kernel|proxmox-default-kernel|pve-kernel|raspi-firmware|linux-headers)' \
        | awk '{print "      kernel side effect: " $2 " " $3}' || true
}

echo "--- candidates ---"
inroot apt-cache policy proxmox-ve pve-manager proxmox-backup-server proxmox-backup-client \
    proxmox-mail-forward zfsutils-linux 2>/dev/null \
    | awk '/^[a-z0-9]/{p=$1} /Candidate:/{printf "  %-24s %s\n", p, $2}'

echo "--- simulations ---"
sim "dist-upgrade" dist-upgrade || { echo "RESULT: RED — Pi OS itself does not upgrade cleanly"; exit 1; }
# shellcheck disable=SC2086
sim "install PVE (${PVE_PKGS})" install ${PVE_PKGS} || { echo "RESULT: RED — ${PVE_ARM64_SOURCE} PVE does not install on current Pi OS"; exit 1; }
# shellcheck disable=SC2086
if sim "install PVE + latest pipbs PBS" install ${PVE_PKGS} proxmox-backup-server; then
    echo "RESULT: GREEN — latest ${PVE_ARM64_SOURCE} PVE and latest pipbs PBS install together"
    exit 0
fi

echo "--- latest PBS conflicts; checking the self-hosted fallback ${PBS_ARM64_FALLBACK_VERSION} ---"
FB="${R}/tmp/pbs-fallback"; mkdir -p "${FB}"
FB_ARGS=()
while read -r sum file; do
    [ -z "${file}" ] && continue
    curl -fsSL --retry 3 -o "${FB}/${file}" "${PBS_ARM64_FALLBACK_URL}/${file}"
    echo "${sum}  ${FB}/${file}" | sha256sum -c --quiet -
    FB_ARGS+=("/tmp/pbs-fallback/${file}")
done <<< "${PBS_ARM64_FALLBACK_DEBS}"
# shellcheck disable=SC2086
if sim "install PVE + fallback PBS ${PBS_ARM64_FALLBACK_VERSION}" install ${PVE_PKGS} "${FB_ARGS[@]}"; then
    echo "RESULT: YELLOW — latest pipbs PBS cannot co-install with ${PVE_ARM64_SOURCE} PVE; fallback ${PBS_ARM64_FALLBACK_VERSION} still works (in use since ${PBS_ARM64_FALLBACK_SINCE})"
    exit 3
fi
echo "RESULT: RED — neither latest pipbs PBS nor the fallback installs next to ${PVE_ARM64_SOURCE} PVE"
exit 1
