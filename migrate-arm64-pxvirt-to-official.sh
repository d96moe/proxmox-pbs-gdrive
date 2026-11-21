#!/bin/bash
# =============================================================================
# migrate-arm64-pxvirt-to-official.sh — move an arm64 (Raspberry Pi 5) PVE host
# from pxvirt (community PVE port) to OFFICIAL Proxmox arm64 PVE (9.2+).
# PBS stays pipbs: there is no official PBS arm64 build.
#
#   bash migrate-arm64-pxvirt-to-official.sh                    # DRY RUN (default)
#   bash migrate-arm64-pxvirt-to-official.sh --apply --on-site  # do it
#
# DRY RUN changes NOTHING on this host: the official repos are evaluated through a
# private apt configuration (own sources/lists/cache dirs in a temp dir), and the
# full-upgrade is only simulated. It reports what would be installed/removed,
# kernel side effects, held packages, and pxvirt-only packages left behind.
#
# --apply, in order:
#   1. backups: vzdump of ALL guests to the PBS storage, plus a tarball of
#      /etc/pve, /etc/network/interfaces and /etc/apt
#   2. pxvirt sources moved aside (kept in the backup dir), official repo added
#   3. holds this repo's tooling set (proxmox-widget-toolkit, PBS fallback) released
#   4. apt full-upgrade, keeping existing config files (--force-confold)
#   5. checks: pve-manager 9.2+, /etc/network/interfaces unchanged
# It does NOT reboot — reboot when the checks pass.
#
# --apply refuses to run without --on-site (or CI=true): the upgrade replaces the
# network stack (ifupdown2 etc.), and a remote host has no rollback path that
# does not depend on that very network. Rollback plan: golden image from SD +
# restore from the local PBS (see README).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/arm64-repos.sh
. "${SCRIPT_DIR}/lib/arm64-repos.sh"

MODE="dry-run"; ON_SITE=0
for arg in "$@"; do
    case "${arg}" in
        --apply)   MODE="apply" ;;
        --on-site) ON_SITE=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown argument ${arg}"; exit 64 ;;
    esac
done

PVE_REMOVE_RE='^Remv (proxmox-ve|pve-manager|qemu-server|pve-container|pve-cluster) '
RELEASABLE_HOLDS="proxmox-widget-toolkit proxmox-backup-server proxmox-backup-docs"

[ "$(dpkg --print-architecture)" = "arm64" ] || { echo "ERROR: not an arm64 host"; exit 1; }
command -v pveversion >/dev/null || { echo "ERROR: PVE is not installed here"; exit 1; }
. /etc/os-release
CODENAME="${VERSION_CODENAME}"

echo "=== Facts ==="
echo "  host:      $(hostname), ${PRETTY_NAME}, kernel $(uname -r)"
echo "  PVE:       $(pveversion | head -1)"
LIERFANG_FILES="$(grep -rl 'lierfang\.com' /etc/apt/sources.list.d/ 2>/dev/null || true)"
echo "  pxvirt sources: ${LIERFANG_FILES:-none}"
HELD="$(apt-mark showhold | tr '\n' ' ')"
echo "  held:      ${HELD:-none}"
if grep -rqs 'download\.proxmox\.com/debian/pve' /etc/apt/sources.list /etc/apt/sources.list.d/; then
    echo "  official PVE repo already configured — nothing to migrate?"
fi

# -----------------------------------------------------------------------------
# Simulation against the official repos via a PRIVATE apt configuration
# -----------------------------------------------------------------------------
SIM="$(mktemp -d /tmp/pxvirt-migrate-sim.XXXXXX)"
trap 'rm -rf "${SIM}"' EXIT
mkdir -p "${SIM}/parts" "${SIM}/lists/partial" "${SIM}/archives/partial" "${SIM}/r"
: > "${SIM}/sources.list"
[ -f /etc/apt/sources.list ] && grep -v 'lierfang\.com' /etc/apt/sources.list > "${SIM}/sources.list" || true
for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "${f}" ] || continue
    grep -q 'lierfang\.com' "${f}" && continue
    cp "${f}" "${SIM}/parts/"
done
add_official_pve_repo "${CODENAME}" "${SIM}/r" >/dev/null
sed "s#Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg#Signed-By: ${SIM}/r/usr/share/keyrings/proxmox-archive-keyring.gpg#" \
    "${SIM}/r/etc/apt/sources.list.d/pve-install-repo.sources" > "${SIM}/parts/pve-install-repo.sources"

APTOPT=(-o "Dir::Etc::sourcelist=${SIM}/sources.list" -o "Dir::Etc::sourceparts=${SIM}/parts"
        -o "Dir::State::lists=${SIM}/lists" -o "Dir::Cache::archives=${SIM}/archives"
        -o "Dir::Cache::pkgcache=" -o "Dir::Cache::srcpkgcache=" -o "APT::Get::List-Cleanup=0")

echo ""
echo "=== Simulating full-upgrade against the official Proxmox arm64 repo ==="
apt-get "${APTOPT[@]}" update -qq
set +e
apt-get "${APTOPT[@]}" -s --allow-change-held-packages -o Dpkg::Options::=--force-confold full-upgrade > "${SIM}/plan" 2>&1
SIM_RC=$?
set -e
if [ ${SIM_RC} -ne 0 ]; then
    echo "  ✗ the full-upgrade does not resolve:"; grep -E '^(E:| )' "${SIM}/plan" | sed 's/^/      /' | tail -20
    echo "RESULT: NOT SAFE — do not migrate"; exit 1
fi
if grep -E "${PVE_REMOVE_RE}" "${SIM}/plan" > "${SIM}/remv-pve"; then
    echo "  ✗ the full-upgrade would REMOVE PVE packages:"; sed 's/^/      /' "${SIM}/remv-pve"
    echo "RESULT: NOT SAFE — do not migrate"; exit 1
fi
printf '  %s upgraded/installed, %s removed\n' "$(grep -c '^Inst ' "${SIM}/plan" || true)" "$(grep -c '^Remv ' "${SIM}/plan" || true)"
echo "  key packages after migration:"
for p in proxmox-ve pve-manager proxmox-widget-toolkit proxmox-backup-server proxmox-mail-forward ifupdown2; do
    v="$(sed -n "s/^Inst ${p} \[[^]]*\] (\([^ ]*\) .*/\1/p; s/^Inst ${p} (\([^ ]*\) .*/\1/p" "${SIM}/plan" | head -1)"
    printf '    %-24s %s\n' "${p}" "${v:-unchanged ($(dpkg-query -W -f='${Version}' "${p}" 2>/dev/null || echo 'not installed'))}"
done
echo "  removals:"; grep '^Remv ' "${SIM}/plan" | sed 's/^/    /' || echo "    none"
echo "  kernel side effects (the Pi keeps booting its rpi kernel — Pi OS hooks only copy *-rpi-* kernels):"
grep -E '^Inst (linux-image|proxmox-kernel|proxmox-default-kernel|raspi-firmware)' "${SIM}/plan" | awk '{print "    " $2}' || echo "    none"

# pxvirt-only leftovers: PVE-stack packages whose installed version exists in no
# configured repo after the switch (they stay installed but never get updates).
echo "  pxvirt-only packages left behind (installed version in no repo after the switch):"
# In `apt-cache policy`, the installed version is the "***" line; the lines
# below it (8-space indent) are where that version is available from. If the
# only one is /var/lib/dpkg/status, no configured repo carries it any more.
is_orphan() {
    apt-cache "${APTOPT[@]}" policy "$1" | awk '
        /^ \*\*\* /                      {inst=1; next}
        inst && /^        [0-9]+ /       {if ($0 !~ /\/var\/lib\/dpkg\/status/) ok=1; next}
        inst && /^     [^ ]/             {inst=0}
        END {exit ok ? 1 : 0}'
}
LEFT=0
for p in $(dpkg-query -W -f='${Package}\n' | grep -E '^(pve-|proxmox-|libpve|libproxmox|qemu-server|lxc-pve|lxcfs|corosync|libknet|criu|ifupdown2|novnc-pve|spiceterm|vncterm|zfs|libzfs|libzpool)'); do
    grep -qE "^Inst ${p} " "${SIM}/plan" && continue          # gets upgraded/replaced
    if is_orphan "${p}"; then
        echo "    ${p} $(dpkg-query -W -f='${Version}' "${p}")"; LEFT=$((LEFT + 1))
    fi
done
[ ${LEFT} -eq 0 ] && echo "    none"

if [ "${MODE}" = "dry-run" ]; then
    echo ""
    echo "RESULT: dry run OK — nothing was changed. To migrate (on site!):"
    echo "  bash $0 --apply --on-site"
    exit 0
fi

# -----------------------------------------------------------------------------
# --apply
# -----------------------------------------------------------------------------
if [ "${ON_SITE}" != 1 ] && [ "${CI:-}" != "true" ]; then
    echo "ERROR: --apply needs --on-site. The upgrade replaces the network stack and a remote"
    echo "  host has no rollback path that doesn't depend on that network. Run it at the console."
    exit 1
fi

STAMP="$(date +%F-%H%M%S)"
BK="/root/pre-migrate-${STAMP}"
mkdir -p "${BK}/apt-disabled"
echo ""
echo "=== 1. Backups → ${BK} ==="
tar -czf "${BK}/etc.tar.gz" /etc/pve /etc/network/interfaces /etc/apt 2>/dev/null
cp /etc/network/interfaces "${BK}/interfaces.before"
PBS_STORE="$(pvesm status --content backup 2>/dev/null | awk 'NR>1 && $2=="pbs" && $3=="active" {print $1; exit}')"
if [ -z "${PBS_STORE}" ]; then
    echo "ERROR: no active PBS storage for the pre-migration vzdump — refusing to continue"; exit 1
fi
if [ -n "$(qm list 2>/dev/null | awk 'NR>1')$(pct list 2>/dev/null | awk 'NR>1')" ]; then
    vzdump --all 1 --storage "${PBS_STORE}" --mode snapshot --notes-template "pre-migrate ${STAMP}"
else
    echo "  no guests to back up"
fi

echo "=== 2. Switch sources: pxvirt → official ==="
for f in ${LIERFANG_FILES}; do mv -v "${f}" "${BK}/apt-disabled/"; done
add_official_pve_repo "${CODENAME}"

echo "=== 3. Release holds set by this repo's tooling ==="
for p in ${RELEASABLE_HOLDS}; do
    apt-mark showhold | grep -qx "${p}" && apt-mark unhold "${p}"
done
rm -f /root/.pbs-arm64-fallback
OTHER_HOLDS="$(apt-mark showhold | tr '\n' ' ')"
[ -n "${OTHER_HOLDS}" ] && echo "  NOTE: still held (not touched): ${OTHER_HOLDS}"

echo "=== 4. full-upgrade ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
rm -f /etc/apt/sources.list.d/*enterprise*
for f in $(grep -l "enterprise\.proxmox\.com" /etc/apt/sources.list.d/* 2>/dev/null || true); do rm -f "${f}"; done
apt-get update -qq

echo "=== 5. Checks ==="
PVEV="$(dpkg-query -W -f='${Version}' pve-manager)"
if dpkg --compare-versions "${PVEV}" ge 9.2; then echo "  ✓ pve-manager ${PVEV}"; else echo "  ✗ pve-manager is ${PVEV}, expected >= 9.2"; exit 1; fi
if cmp -s /etc/network/interfaces "${BK}/interfaces.before"; then
    echo "  ✓ /etc/network/interfaces unchanged"
else
    echo "  ✗ /etc/network/interfaces CHANGED — review before rebooting:"; diff "${BK}/interfaces.before" /etc/network/interfaces || true
    exit 1
fi
grep -rqs 'lierfang\.com' /etc/apt/ && { echo "  ✗ a lierfang source reappeared"; exit 1; }
echo "  ✓ no pxvirt sources left"
echo ""
echo "RESULT: migrated to official Proxmox arm64 PVE. Backups in ${BK}. Reboot now."
