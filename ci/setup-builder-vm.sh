#!/bin/bash
# =============================================================================
# ci/setup-builder-vm.sh — create the persistent CI builder VM (VM 9020)
#
# The builder is where all disk-image work happens (downloading OS images,
# loop-mounting, GRUB, seed files, arm64 qemu-user chroots). The PVE host
# itself only runs `qm` operations (import/clone/start/template) on the
# finished artifacts — no image surgery on the hypervisor.
#
# Persistent and always on (onboot=1): it is created ONCE by this script and
# then just waits for work, so `ssh` into it is instant. It is disposable in
# the sense that it can be destroyed and recreated from this script + the
# provisioning script at any time — nothing on it is precious.
#
# Runs on the PVE host; only qm operations on an already-present Debian cloud
# image (the same one template 9001 uses). Refuses to overwrite an existing VM
# unless FORCE=1.
#
#   bash ci/setup-builder-vm.sh            # create
#   FORCE=1 bash ci/setup-builder-vm.sh    # destroy + recreate
# Then provision from a machine that can SSH to it:
#   ssh root@<BUILDER_IP> bash -s < ci/provision-builder.sh
# =============================================================================

set -euo pipefail

VM_ID="${VM_ID:-9020}"
VM_NAME="ci-builder"
VM_IP="${VM_IP:-192.168.0.248}"
GATEWAY="${GATEWAY:-192.168.0.1}"
NAMESERVER="${NAMESERVER:-8.8.8.8}"   # same as the other CI VMs
STORAGE="local-lvm"
BASE_IMAGE="/var/lib/vz/template/iso/debian-13-genericcloud-amd64.qcow2"
DISK_SIZE="60G"
# Extra pubkeys (one per line) besides Jenkins', e.g. a developer workstation
EXTRA_PUBKEYS="${EXTRA_PUBKEYS:-}"

[ -f "${BASE_IMAGE}" ] || { echo "ERROR: ${BASE_IMAGE} missing (template 9001's refresh job downloads it)"; exit 1; }

if qm status "${VM_ID}" &>/dev/null; then
    if [ "${FORCE:-0}" != "1" ]; then
        echo "VM ${VM_ID} already exists — nothing to do (FORCE=1 to recreate)."
        exit 0
    fi
    qm stop "${VM_ID}" 2>/dev/null || true
    sleep 3
    qm destroy "${VM_ID}" --purge 1
fi

JENKINS_PUBKEY=$(qm config 9001 | grep sshkeys | sed 's/sshkeys: //' \
    | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))")
[ -z "${JENKINS_PUBKEY}" ] && { echo "ERROR: cannot extract Jenkins pubkey from template 9001"; exit 1; }
KEYFILE=$(mktemp)
trap 'rm -f "${KEYFILE}"' EXIT
{ echo "${JENKINS_PUBKEY}"; [ -n "${EXTRA_PUBKEYS}" ] && echo "${EXTRA_PUBKEYS}"; } > "${KEYFILE}"

qm create "${VM_ID}" \
    --name "${VM_NAME}" \
    --description "Persistent CI builder: all disk-image work happens here, never on the PVE host. Rebuild: ci/setup-builder-vm.sh + ci/provision-builder.sh" \
    --cpu host \
    --cores 4 \
    --memory 4096 \
    --balloon 1024 \
    --net0 virtio,bridge=vmbr0 \
    --ostype l26 \
    --scsihw virtio-scsi-single \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1 \
    --onboot 1
qm importdisk "${VM_ID}" "${BASE_IMAGE}" "${STORAGE}"
qm set "${VM_ID}" --scsi0 "${STORAGE}:vm-${VM_ID}-disk-0,discard=on,iothread=1" --boot order=scsi0
qm resize "${VM_ID}" scsi0 "${DISK_SIZE}"
qm set "${VM_ID}" --ide2 "${STORAGE}:cloudinit"
qm set "${VM_ID}" \
    --ciuser root \
    --ipconfig0 "ip=${VM_IP}/24,gw=${GATEWAY}" \
    --nameserver "${NAMESERVER}" \
    --sshkeys "${KEYFILE}"
qm start "${VM_ID}"

echo ""
echo "=== Builder VM ${VM_ID} (${VM_NAME}) started at ${VM_IP} ==="
echo "    Next: ssh root@${VM_IP} bash -s < ci/provision-builder.sh"
