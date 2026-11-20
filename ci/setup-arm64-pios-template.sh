#!/bin/bash
# =============================================================================
# ci/setup-arm64-pios-template.sh — import the Pi OS arm64 CI disk as VM 9003
#
# Runs on the PVE host and does ONLY qm operations. The disk itself is built on
# the CI builder VM by ci/build-pios-disk.sh (see that script for what the
# image contains); the Jenkins job streams it here as ${DISK_FILE}.
#
# Leaves VM 9003 as a normal VM, NOT a template — the Jenkins job smoke-boots a
# clone first and only then runs `qm template 9003`.
#
#   DISK_FILE=/var/lib/vz/images/pios-ci-incoming.qcow2 PIOS_DESC="..." bash ci/setup-arm64-pios-template.sh
# =============================================================================

set -euo pipefail

TEMPLATE_ID=9003
TEMPLATE_NAME="arm64-pios-restore-ci"
STORAGE="local-lvm"
: "${DISK_FILE:?DISK_FILE must point to the qcow2 built by ci/build-pios-disk.sh}"
PIOS_DESC="${PIOS_DESC:-Pi OS CI template}"

[ -f "${DISK_FILE}" ] || { echo "ERROR: ${DISK_FILE} not found"; exit 1; }
trap 'rm -f "${DISK_FILE}"' EXIT   # the incoming file is only a hand-off

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
    --description "${PIOS_DESC}"
qm importdisk ${TEMPLATE_ID} "${DISK_FILE}" ${STORAGE} --format raw | grep -v transferred
qm set ${TEMPLATE_ID} --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0,discard=on --boot order=scsi0
# PBS data disk — formatted fresh each CI run by the pipeline (same as 9002)
qm set ${TEMPLATE_ID} --scsi1 ${STORAGE}:4,format=raw

echo "=== VM ${TEMPLATE_ID} imported — NOT yet a template (${PIOS_DESC}) ==="
