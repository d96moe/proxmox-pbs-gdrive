#!/bin/bash
# =============================================================================
# ci/provision-builder.sh — install the tooling on the CI builder VM (9020)
#
# Runs ON the builder (ssh root@<builder> bash -s < ci/provision-builder.sh).
# Idempotent: safe to re-run any time to bring the tool set up to date.
#
# The builder is not production, so tools are installed freely here — this is
# exactly the stuff that must NOT be installed on the PVE host or the Jenkins
# LXC (see the CI README).
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

cloud-init status --wait >/dev/null 2>&1 || true

apt-get update -qq
apt-get install -y -qq \
    qemu-guest-agent \
    curl wget ca-certificates gnupg xz-utils zstd \
    qemu-utils fdisk dosfstools e2fsprogs parted kpartx \
    initramfs-tools-core \
    grub-common \
    qemu-user-static binfmt-support debootstrap \
    libguestfs-tools \
    python3 python3-venv git rsync jq shellcheck
systemctl enable --now qemu-guest-agent

# ShellSpec (same install method as the CI VMs)
if ! command -v shellspec >/dev/null 2>&1; then
    curl -fsSL https://git.io/shellspec | sh -s -- --yes --prefix /usr/local
fi

# arm64 binaries must run via binfmt (for the L2 apt dependency check)
update-binfmts --enable qemu-aarch64 >/dev/null 2>&1 || true
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "ERROR: qemu-aarch64 binfmt not registered"; exit 1; }

mkdir -p /srv/ci-build

echo "=== builder provisioned ==="
echo "  $(. /etc/os-release; echo "$PRETTY_NAME"), kernel $(uname -r)"
echo "  grub-mkstandalone $(grub-mkstandalone --version | awk '{print $NF}'), zstd $(zstd --version | awk '{print $NF}' | tr -d ,)"
echo "  shellspec $(shellspec --version)"
echo "  binfmt qemu-aarch64: $(head -1 /proc/sys/fs/binfmt_misc/qemu-aarch64)"
