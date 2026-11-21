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
        --post-check) MODE="post-check" ;;
        --on-site) ON_SITE=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown argument ${arg}"; exit 64 ;;
    esac
done

PVE_REMOVE_RE='^Remv (proxmox-ve|pve-manager|qemu-server|pve-container|pve-cluster) '
RELEASABLE_HOLDS="proxmox-widget-toolkit proxmox-backup-server proxmox-backup-docs"

[ "$(dpkg --print-architecture)" = "arm64" ] || { echo "ERROR: not an arm64 host"; exit 1; }

# -----------------------------------------------------------------------------
# --post-check: run after the reboot, ON SITE, before leaving
# -----------------------------------------------------------------------------
if [ "${MODE}" = "post-check" ]; then
    BK="$(ls -d /root/pre-migrate-* 2>/dev/null | tail -1)"
    [ -n "${BK}" ] || { echo "ERROR: no /root/pre-migrate-* backup dir — was --apply run?"; exit 1; }
    FAIL=0
    chk() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; FAIL=1; fi; }
    echo "=== Post-migration check (${BK}) ==="
    chk "pve-manager >= 9.2 ($(dpkg-query -W -f='${Version}' pve-manager))" 'dpkg --compare-versions "$(dpkg-query -W -f="\${Version}" pve-manager)" ge 9.2'
    chk "running the Raspberry Pi kernel ($(uname -r))" '[[ "$(uname -r)" == *-rpi-* ]]'
    chk "pve-cluster active" 'systemctl is-active -q pve-cluster'
    chk "proxmox-backup active" 'systemctl is-active -q proxmox-backup'
    chk "/etc/network/interfaces unchanged" 'cmp -s "${BK}/interfaces.before" /etc/network/interfaces'
    chk "default route present" 'ip route show default | grep -q .'
    chk "all guests that were running are running again" \
        'diff <(sort "${BK}/guests-running.before") <( { qm list 2>/dev/null; pct list 2>/dev/null; } | awk "\$3==\"running\" || \$2==\"running\" {print \$1}" | sort) >/dev/null'
    if [ -s "${BK}/bt.before" ]; then
        chk "Bluetooth adapter hci0 is UP" 'hciconfig hci0 2>/dev/null | grep -q "UP RUNNING"'
        chk "Bluetooth firmware loaded again ($(cat "${BK}/bt.before"))" "dmesg | grep -qF \"\$(cat '${BK}/bt.before')\""
    fi
    [ ${FAIL} -eq 0 ] && { echo "RESULT: migration verified"; exit 0; }
    echo "RESULT: CHECK FAILED — fix on site, or roll back (golden image from SD + restore from local PBS)"; exit 1
fi
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
# Node identity must survive the reboot. pmxcfs (pve-cluster) needs the node name
# to resolve to a non-loopback IP of this host; otherwise /etc/pve stays empty
# after the reboot: no GUI, no guests, and root's authorized_keys (a symlink into
# /etc/pve/priv) no longer works. On Raspberry Pi OS, cloud-init (Imager seed,
# manage_etc_hosts: true) re-renders /etc/hosts from a template on EVERY boot, so
# the entry must be in that template, not just in /etc/hosts (CI #307/#309).
# -----------------------------------------------------------------------------
NODE="$(hostname)"
NODE_IP="$(getent ahostsv4 "${NODE}" | awk '$1 !~ /^127\./ {print $1; exit}')"
if [ -z "${NODE_IP}" ] || ! ip -4 -o addr show | grep -qF " ${NODE_IP}/"; then
    echo "  ✗ node name ${NODE} does not resolve to a local non-loopback IP (got: ${NODE_IP:-nothing})"
    echo "RESULT: NOT SAFE — fix /etc/hosts first"; exit 1
fi
CI_MANAGES_HOSTS=0
if command -v cloud-init >/dev/null && [ ! -e /etc/cloud/cloud-init.disabled ] \
   && grep -qsiE '^\s*manage_etc_hosts:\s*(true|template)' /var/lib/cloud/instance/cloud-config.txt /boot/firmware/user-data; then
    CI_MANAGES_HOSTS=1
fi
if [ ${CI_MANAGES_HOSTS} -eq 1 ]; then
    if awk -v ip="${NODE_IP}" -v h="${NODE}" '$1 == ip { for (i = 2; i <= NF; i++) if ($i == h) f = 1 } END { exit !f }' \
         /etc/cloud/templates/hosts.debian.tmpl 2>/dev/null; then
        echo "  ✓ node identity: ${NODE} → ${NODE_IP}, also in cloud-init's hosts template (survives reboot)"
    else
        echo "  ✗ cloud-init rewrites /etc/hosts on every boot, and its template lacks '${NODE_IP} ${NODE}'"
        echo "    → after the reboot pve-cluster would fail and root SSH by key would be locked out"
        echo "RESULT: NOT SAFE — add '${NODE_IP} ${NODE}' to /etc/cloud/templates/hosts.debian.tmpl first"; exit 1
    fi
else
    echo "  ✓ node identity: ${NODE} → ${NODE_IP} (/etc/hosts not managed by cloud-init)"
fi

# -----------------------------------------------------------------------------
# Simulation against the official repos via a PRIVATE apt configuration
# -----------------------------------------------------------------------------
# /var/tmp, not /tmp: on Raspberry Pi OS /tmp is a tmpfs, and the downloaded
# package indexes (~100 MB) would take RAM away from the running guests.
SIM="$(mktemp -d /var/tmp/pxvirt-migrate-sim.XXXXXX)"
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

# Private copy of the dpkg status with the holds that --apply releases already
# released — otherwise apt keeps e.g. proxmox-widget-toolkit at its held version
# and "solves" pve-manager 9.2 (needs widget-toolkit >= 5.2.14) by REMOVING PVE,
# which is not what --apply does (2026-11-21, cabin dry run).
awk -v holds=" ${RELEASABLE_HOLDS} " '
    BEGIN {RS=""; ORS="\n\n"}
    {
        if (match($0, /(^|\n)Package: [^\n]+/)) {
            pkg = substr($0, RSTART, RLENGTH); sub(/.*Package: /, "", pkg)
            if (index(holds, " " pkg " ")) sub(/Status: hold ok installed/, "Status: install ok installed")
        }
        print
    }' /var/lib/dpkg/status > "${SIM}/status"

APTOPT=(-o "Dir::Etc::sourcelist=${SIM}/sources.list" -o "Dir::Etc::sourceparts=${SIM}/parts"
        -o "Dir::State::lists=${SIM}/lists" -o "Dir::Cache::archives=${SIM}/archives"
        -o "Dir::State::status=${SIM}/status"
        -o "Dir::Cache::pkgcache=" -o "Dir::Cache::srcpkgcache=" -o "APT::Get::List-Cleanup=0"
        -o "APT::Sandbox::User=root")

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
    echo "  apt's reasoning (simulated install of proxmox-ve + pve-manager):"
    apt-get "${APTOPT[@]}" -s install proxmox-ve pve-manager 2>&1 | grep -vE '^(Inst|Conf|Reading|Building|Calculating) ' | sed 's/^/      /' | tail -25 || true
    echo "RESULT: NOT SAFE — do not migrate"; exit 1
fi
# Bluetooth must keep working (user requirement). The Pi 5 BT patch firmware
# comes from bluez-firmware, which pve-firmware does not conflict with — guard
# that: refuse if bluez/bluez-firmware would be removed, or if the BT firmware
# loaded right now would lose its owning package.
BT_FW="$(dmesg 2>/dev/null | sed -n "s/.*Bluetooth: hci0: BCM4345C0 '\([^']*\)'.*/\1/p" | tail -1)"
if grep -E '^Remv (bluez|bluez-firmware) ' "${SIM}/plan"; then
    echo "  ✗ the full-upgrade would remove the Bluetooth stack/firmware"; echo "RESULT: NOT SAFE — do not migrate"; exit 1
fi
if [ -n "${BT_FW}" ]; then
    BT_PKG="$(dpkg -S "/usr/lib/firmware/${BT_FW}" 2>/dev/null | cut -d: -f1 || true)"
    if [ -n "${BT_PKG}" ] && grep -qE "^Remv ${BT_PKG} " "${SIM}/plan"; then
        echo "  ✗ the loaded Bluetooth firmware ${BT_FW} belongs to ${BT_PKG}, which would be REMOVED"
        echo "RESULT: NOT SAFE — do not migrate"; exit 1
    fi
    echo "  ✓ Bluetooth firmware ${BT_FW} (${BT_PKG:-unknown package}) stays installed"
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
# state that --post-check compares against after the reboot
{ qm list 2>/dev/null; pct list 2>/dev/null; } | awk '$3=="running" || $2=="running" {print $1}' > "${BK}/guests-running.before"
if hciconfig hci0 2>/dev/null | grep -q "UP RUNNING"; then
    dmesg | sed -n "s/.*Bluetooth: hci0: BCM4345C0 '\([^']*\)'.*/\1/p" | tail -1 > "${BK}/bt.before"
fi
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
echo "RESULT: migrated to official Proxmox arm64 PVE. Backups in ${BK}."
echo "  Reboot now, then (still on site): bash $0 --post-check"
