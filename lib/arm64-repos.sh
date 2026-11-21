#!/bin/bash
# =============================================================================
# lib/arm64-repos.sh — single source of truth for the arm64 (Raspberry Pi 5)
# community apt repositories and the PBS fallback.
#
# Sourced by:
#   * restore-1-install.sh       — the real install / DR path
#   * ci/check-arm64-deps.sh     — the nightly L2 dependency check (in a chroot)
# so the check always tests exactly the repos a real install uses.
#
# Every add_* function takes an optional root prefix ("" = the live system,
# or a chroot directory) so the same code writes into either.
# =============================================================================

# pxvirt = community PVE arm64 port. Use the us. mirror subdomain, NOT the bare
# download.lierfang.com / mirrors.lierfang.com domains: those sit behind a
# persistent Cloudflare bot-challenge (2026-09) that curl can never pass.
PXVIRT_REPO_URL="https://us.mirrors.lierfang.com/pxcloud/pxvirt"
PXVIRT_KEY_URL="${PXVIRT_REPO_URL}/pveport.gpg"

# pipbs = community PBS arm64 build (no official PBS arm64 exists).
PIPBS_REPO_URL="https://dexogen.github.io/pipbs/"
PIPBS_KEY_URL="https://dexogen.github.io/pipbs/gpg.key"

# Self-hosted known-good PBS debs, used only while the latest pipbs PBS cannot
# be installed next to pxvirt's PVE (see restore-1-install.sh). 2026-11: pipbs
# 4.2.11-1 Breaks proxmox-mail-forward << 1.1.0, pxvirt ships 1.0.2.
PBS_ARM64_FALLBACK_VERSION="4.2.1-1"
PBS_ARM64_FALLBACK_SINCE="2026-11-20"   # CI goes red if the fallback is used >30 days past this
PBS_ARM64_FALLBACK_URL="https://github.com/d96moe/proxmox-pbs-gdrive/releases/download/pbs-arm64-${PBS_ARM64_FALLBACK_VERSION}"
PBS_ARM64_FALLBACK_DEBS="
2a277745cf8677b6b021a5d9da38d2bc6b9964e97bf1b5e7f8afbe68c1e6817c  proxmox-backup-server_4.2.1-1_arm64.deb
3f9338dce4e2071e42bb7c51407c864d9dcb5aaa4f52c6e7b1c97e5fc78a3ba1  proxmox-backup-docs_4.2.1-1_all.deb
"

# Fetch a GPG key with retries. Third-party mirror endpoints occasionally return
# transient 403/5xx under rate limiting; a bare curl|gpg cannot recover from a
# blip that is gone moments later.
fetch_gpg_key() {
    local url="$1" dest="$2" attempt
    for attempt in 1 2 3 4 5; do
        if curl -fsSL "${url}" | gpg --batch --no-tty --dearmor > "${dest}" 2>/dev/null \
            && [ -s "${dest}" ]; then
            return 0
        fi
        echo "  GPG key fetch from ${url} failed (attempt ${attempt}/5), retrying in 10s..."
        rm -f "${dest}"
        sleep 10
    done
    echo "ERROR: could not fetch GPG key from ${url} after 5 attempts"
    return 1
}

# add_pxvirt_repo <codename> [root]
add_pxvirt_repo() {
    local codename="$1" root="${2:-}"
    mkdir -p "${root}/etc/apt/trusted.gpg.d" "${root}/etc/apt/sources.list.d"
    fetch_gpg_key "${PXVIRT_KEY_URL}" "${root}/etc/apt/trusted.gpg.d/pxvirt.gpg"
    echo "deb ${PXVIRT_REPO_URL} ${codename} main" > "${root}/etc/apt/sources.list.d/pxvirt.list"
}

# add_pipbs_repo <codename> [root]
add_pipbs_repo() {
    local codename="$1" root="${2:-}"
    mkdir -p "${root}/etc/apt/keyrings" "${root}/etc/apt/sources.list.d"
    fetch_gpg_key "${PIPBS_KEY_URL}" "${root}/etc/apt/keyrings/pipbs.gpg"
    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/pipbs.gpg] ${PIPBS_REPO_URL} ${codename} main" \
        > "${root}/etc/apt/sources.list.d/pipbs.list"
}

# fix_pxvirt_sources <codename> [root]
# proxmox-ve's postinst (re)writes its own pxvirt source pointing at the
# Cloudflare-blocked bare domain with codename bookworm. Point every lierfang
# source file back at the working mirror and the real codename.
fix_pxvirt_sources() {
    local codename="$1" root="${2:-}" f
    for f in $(grep -rl "lierfang\.com" "${root}/etc/apt/sources.list.d/" 2>/dev/null); do
        echo "deb ${PXVIRT_REPO_URL} ${codename} main" > "${f}"
    done
}
