#!/bin/bash
# =============================================================================
# ci/publish-golden-image.sh — publish a TESTED golden image to Google Drive
# (runs on the CI builder VM; Jenkins only calls it after the full DR on the
# image passed, and hands it a temporary rclone.conf that it removes afterwards)
#
# Uploads to ${REMOTE}:bu/golden-image/<date>_<commit>/:
#   golden-<date>.img.xz     whole disk — flash to an SD card / disk with
#                            Raspberry Pi Imager ("Use custom")
#   rootfs-<date>.tar.zst    root filesystem only — plan B on a node whose disk
#   bootfs-<date>.tar.zst    also holds the PBS datastore: rewrite only the root
#                            (and boot) partition and keep the PBS partition
#   golden.env               versions + commit
#   SHA256SUMS
# Keeps the newest ${KEEP} image folders and removes older ones.
#
# The image is generic (ci/golden-leak-gate.sh), so nothing secret is uploaded.
# =============================================================================

set -euo pipefail

OUT_DIR="${OUT_DIR:-/srv/ci-build/out/golden}"
REMOTE="${REMOTE:-gdrive}"
DEST_ROOT="${DEST_ROOT:-bu/golden-image}"
KEEP="${KEEP:-3}"

[ -f "${OUT_DIR}/golden.img" ] && [ -f "${OUT_DIR}/golden.env" ] \
    || { echo "ERROR: no golden.img/golden.env in ${OUT_DIR}"; exit 1; }
command -v rclone >/dev/null || { apt-get update -qq && apt-get install -y -qq rclone; }
rclone listremotes | grep -qx "${REMOTE}:" || { echo "ERROR: rclone remote '${REMOTE}:' not configured"; exit 1; }
# shellcheck source=/dev/null
. "${OUT_DIR}/golden.env"

STAGE="$(mktemp -d /srv/ci-build/publish.XXXXXX)"
LOOP=""
cleanup() {
    for m in $(findmnt -rno TARGET | grep "^${STAGE}" | sort -r); do umount "$m" 2>/dev/null || umount -l "$m"; done
    [ -n "${LOOP}" ] && losetup -d "${LOOP}" 2>/dev/null || true
    rm -rf --one-file-system "${STAGE}"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

TAG="${GOLDEN_DATE}_${GOLDEN_COMMIT:0:7}"
echo "=== Packing golden image ${TAG} ==="
xz -T0 -6 -c "${OUT_DIR}/golden.img" > "${STAGE}/golden-${GOLDEN_DATE}.img.xz"

LOOP="$(losetup -fPr --show "${OUT_DIR}/golden.img")"
mkdir -p "${STAGE}/root" "${STAGE}/boot"
mount -o ro "${LOOP}p2" "${STAGE}/root"
mount -o ro "${LOOP}p1" "${STAGE}/boot"
tar --numeric-owner --xattrs --acls -C "${STAGE}/root" -cpf - . | zstd -T0 -19 -q > "${STAGE}/rootfs-${GOLDEN_DATE}.tar.zst"
tar --numeric-owner -C "${STAGE}/boot" -cpf - . | zstd -T0 -19 -q > "${STAGE}/bootfs-${GOLDEN_DATE}.tar.zst"
umount "${STAGE}/boot" "${STAGE}/root"
losetup -d "${LOOP}"; LOOP=""
rmdir "${STAGE}/root" "${STAGE}/boot"

cp "${OUT_DIR}/golden.env" "${STAGE}/golden.env"
( cd "${STAGE}" && sha256sum golden-*.img.xz rootfs-*.tar.zst bootfs-*.tar.zst golden.env > SHA256SUMS )
ls -lh "${STAGE}"

echo "=== Uploading to ${REMOTE}:${DEST_ROOT}/${TAG}/ ==="
rclone copy --timeout 30m --retries 3 "${STAGE}/" "${REMOTE}:${DEST_ROOT}/${TAG}/"
# Verify what landed before pruning anything older
rclone check --one-way "${STAGE}/" "${REMOTE}:${DEST_ROOT}/${TAG}/" \
    || { echo "ERROR: upload verification failed — not pruning older images"; exit 1; }

echo "=== Keeping the newest ${KEEP} images ==="
mapfile -t DIRS < <(rclone lsf --dirs-only "${REMOTE}:${DEST_ROOT}/" | sed 's:/$::' | sort -r)
for ((i=KEEP; i<${#DIRS[@]}; i++)); do
    echo "  removing old image ${DIRS[$i]}"
    rclone purge "${REMOTE}:${DEST_ROOT}/${DIRS[$i]}"
done
rclone lsf --dirs-only "${REMOTE}:${DEST_ROOT}/"
echo "=== Published golden image ${TAG} ==="
