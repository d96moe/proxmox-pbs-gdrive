#!/bin/bash
# =============================================================================
# ci/pairing-fixture.sh setup|cleanup — GDrive fixtures for the restore-2
# pairing scenarios (ci/spec/restore_pairing_e2e_spec.sh)
#
# Runs on the DR CI VM BEFORE the real restore, while rclone + both passwords
# are in place. Builds three scratch folders next to the CI config folder from
# the newest real tarball (D0, which Scenario A paired with a restic snapshot):
#
#   <folder>_pairtest_normal  D0                        → pair D0
#   <folder>_pairtest_newer   D0 + D0+1 day ("newest")  → newest has no snapshot,
#                             switch back to D0 keeping the newest credentials
#   <folder>_pairtest_old     only 2020-01-01           → no pair at all
#
# The "newest" tarball carries markers so the spec can tell which tarball each
# file came from:
#   /etc/resticprofile/profiles.yaml          marker → credentials kept from newest
#   /etc/proxmox-backup-restore/config.env    marker → must be GONE (config from D0)
# (rclone.conf is excluded by the same rule, but rclone may rewrite it when it
#  refreshes the OAuth token, so it is not used as a marker.)
#
# State for the spec: /root/.pairtest.env. Scratch dir: /root/.pairtest.
# cleanup removes the scratch folders on GDrive, the scratch dir and any
# pve-config-* left in /tmp — safe to run any time, also in Jenkins post.
# =============================================================================

set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/proxmox-restore}"
# shellcheck source=/dev/null
. "${SCRIPTS_DIR}/config.env"
# shellcheck source=../lib/restore-pair.sh
. "${SCRIPTS_DIR}/lib/restore-pair.sh"

REMOTE="${RESTICPROFILE_GDRIVE_REMOTE}"
SRC="${REMOTE}:bu/${GDRIVE_CONFIG_FOLDER}"
BASE="${GDRIVE_CONFIG_FOLDER}_pairtest"
W=/root/.pairtest
STATE=/root/.pairtest.env
MARK="# pairtest-marker: from the NEWEST tarball"

cleanup() {
    local s
    for s in normal newer old; do
        rclone purge "${REMOTE}:bu/${BASE}_${s}" 2>/dev/null || true
    done
    rm -rf "${W}" "${STATE}"
    rm -f /tmp/pve-config-*
}

case "${1:-}" in
    cleanup) cleanup; echo "pairing fixture cleaned up"; exit 0 ;;
    setup)   ;;
    *) echo "usage: $0 setup|cleanup"; exit 64 ;;
esac

cleanup
mkdir -p "${W}/x"

NEWEST="$(rclone lsf "${SRC}/" --include 'pve-config-*.tar.gz.enc' | sort | sed -n '$p')"
[ -n "${NEWEST}" ] || { echo "fixture: no encrypted tarball in ${SRC} — run Scenario A first"; exit 1; }
D0="$(tarball_date "${NEWEST}")"
SNAP_DATES="$(restic -r "rclone:${REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
    --password-file "${RESTIC_PASSWORD_FILE}" --no-lock snapshots --json \
    | python3 -c 'import json,sys; print("\n".join(sorted({s["time"][:10] for s in json.load(sys.stdin)})))')"
grep -qx "${D0}" <<< "${SNAP_DATES}" \
    || { echo "fixture: newest tarball ${D0} has no restic snapshot — run Scenario A first"; exit 1; }
D_FUT="$(date -d "${D0} + 1 day" +%F)"
D_OLD="2020-01-01"
! grep -qx "${D_FUT}" <<< "${SNAP_DATES}" || { echo "fixture: ${D_FUT} unexpectedly has a snapshot"; exit 1; }
NEWEST_SNAP_DATE="$(sed -n '$p' <<< "${SNAP_DATES}")"

# D0 as-is, plus a re-packed copy with markers for the "newest" (D0+1) tarball
rclone copyto "${SRC}/${NEWEST}" "${W}/d0.enc"
openssl enc -d -aes-256-cbc -pbkdf2 -in "${W}/d0.enc" -out "${W}/d0.tar.gz" \
    -pass file:"${CONFIG_ENCRYPT_PASSWORD_FILE}"
tar -xzpf "${W}/d0.tar.gz" -C "${W}/x"
for f in etc/resticprofile/profiles.yaml etc/proxmox-backup-restore/config.env; do
    [ -f "${W}/x/${f}" ] || { echo "fixture: ${f} missing from ${NEWEST}"; exit 1; }
    echo "${MARK}" >> "${W}/x/${f}"
done
# same member layout as backup-pve-config.sh writes (etc/..., var/..., no ./)
( cd "${W}/x" && tar -czpf "${W}/fut.tar.gz" $(ls -A) )
openssl enc -aes-256-cbc -pbkdf2 -in "${W}/fut.tar.gz" -out "${W}/fut.enc" \
    -pass file:"${CONFIG_ENCRYPT_PASSWORD_FILE}"
cp "${W}/d0.enc" "${W}/old.enc"
rm -rf "${W}/x" "${W}/d0.tar.gz" "${W}/fut.tar.gz"

rclone copyto "${W}/d0.enc"  "${REMOTE}:bu/${BASE}_normal/pve-config-${D0}.tar.gz.enc"
rclone copyto "${W}/d0.enc"  "${REMOTE}:bu/${BASE}_newer/pve-config-${D0}.tar.gz.enc"
rclone copyto "${W}/fut.enc" "${REMOTE}:bu/${BASE}_newer/pve-config-${D_FUT}.tar.gz.enc"
rclone copyto "${W}/old.enc" "${REMOTE}:bu/${BASE}_old/pve-config-${D_OLD}.tar.gz.enc"

cat > "${STATE}" << EOF
D0=${D0}
D_FUT=${D_FUT}
D_OLD=${D_OLD}
NEWEST_SNAP_DATE=${NEWEST_SNAP_DATE}
BASE=${BASE}
W=${W}
MARK="${MARK}"
EOF
echo "pairing fixture ready: D0=${D0} D_FUT=${D_FUT} D_OLD=${D_OLD} newest snapshot=${NEWEST_SNAP_DATE}"
