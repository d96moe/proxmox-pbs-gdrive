#!/bin/bash
# =============================================================================
# ci/golden-leak-gate.sh <root dir> <boot dir> [builder identifiers...]
#
# Fails (exit 1) if the golden image contains anything host-specific or secret.
# The image must be GENERIC: software only (user requirement). Run by
# ci/build-golden-image.sh on the mounted image before the artifact is written,
# so a leaking image is never produced, let alone published.
#
#   forbidden files     SSH host keys, any .ssh dir content, PVE/PBS keys,
#                       pmxcfs data, config.env, rclone/restic secrets,
#                       cloud-init instance state, a non-empty machine-id
#   forbidden content   private keys, SSH public keys, OAuth/API tokens,
#                       private IPs, the builder's hostname/IPs
#   boot seed           no user/password/SSH key in the NoCloud seed files
#
# Scans the places a host's own config ends up (etc, root, home, opt, srv,
# usr/local, var/lib, boot) — not /usr/share, where packages ship docs/tests.
# =============================================================================

set -uo pipefail

R="${1:?root dir}"; B="${2:?boot dir}"; shift 2
BUILDER_IDS=("$@")
FAIL=0
hit() { echo "  LEAK: $*"; FAIL=1; }

echo "--- forbidden files"
while IFS= read -r f; do hit "file ${f#${R}}"; done < <(
    { ls -d "${R}"/etc/ssh/ssh_host_* \
           "${R}"/etc/proxmox-backup/{proxy.key,proxy.pem,authkey.key,authkey.pub,csrf.key} \
           "${R}"/var/lib/pve-cluster/config.db* \
           "${R}"/etc/proxmox-backup-restore/config.env \
           "${R}"/opt/proxmox-pbs-gdrive/config.env \
           "${R}"/root/.config/rclone/rclone.conf \
           "${R}"/etc/resticprofile/*password* \
           "${R}"/var/lib/dbus/machine-id \
           "${R}"/var/lib/systemd/credential.secret 2>/dev/null
      find "${R}/root" "${R}/home" -path '*/.ssh/*' 2>/dev/null
      find "${R}/etc/pve" -mindepth 1 2>/dev/null
      find "${R}/var/lib/cloud/instances" -mindepth 1 -maxdepth 1 2>/dev/null
    } | sort -u)
[ -s "${R}/etc/machine-id" ] && hit "file /etc/machine-id is not empty"

echo "--- forbidden content"
SCAN=()
for d in etc root home opt srv usr/local var/lib boot; do [ -e "${R}/${d}" ] && SCAN+=("${R}/${d}"); done
# -I: skip binary files; exclude the CA bundle / package keyrings (public by design)
GREP=(grep -rIlE --exclude-dir=ssl --exclude-dir=keyrings --exclude-dir=trusted.gpg.d
      --exclude-dir=dpkg --exclude-dir=apt --exclude-dir=pve-manager --exclude='*.dpkg-dist')
declare -A PATTERNS=(
    ["private key"]='-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'
    ["SSH public key"]='(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+) AAAA[0-9A-Za-z+/]{20,}'
    ["OAuth token"]='"(refresh_token|access_token)"[[:space:]]*:'
    ["API token"]='PVEAPIToken=|PBSAPIToken=|ghp_[0-9A-Za-z]{30,}|AKIA[0-9A-Z]{16}'
    # not on comment lines: stock configs carry examples like "#static ip_address=192.168.0.10/24"
    ["private IP"]='^[^#]*(^|[^0-9.])(192\.168\.[0-9]{1,3}\.[0-9]{1,3}|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'
)
for name in "${!PATTERNS[@]}"; do
    while IFS= read -r f; do hit "${name} in ${f#${R}}"; done < <("${GREP[@]}" -- "${PATTERNS[$name]}" "${SCAN[@]}" 2>/dev/null)
done
for id in "${BUILDER_IDS[@]}"; do
    [ -n "${id}" ] || continue
    while IFS= read -r f; do hit "builder identity '${id}' in ${f#${R}}"; done < <(
        grep -rIlwF --exclude-dir=dpkg --exclude-dir=apt -- "${id}" "${SCAN[@]}" 2>/dev/null)
done

echo "--- boot seed (NoCloud) carries no user, password or key"
for f in user-data network-config meta-data; do
    [ -f "${B}/${f}" ] || continue
    grep -qiE '^[^#]*(ssh_authorized_keys|passwd|password|ssh-(ed25519|rsa))' "${B}/${f}" \
        && hit "credentials in boot seed ${f}"
done
[ -f "${B}/userconf.txt" ] && hit "boot/userconf.txt (pre-set user + password hash)"

if [ "${FAIL}" -ne 0 ]; then
    echo "LEAK GATE: FAILED — the image is not generic; nothing is written or published"
    exit 1
fi
echo "LEAK GATE: OK — no host identity or secrets found"
