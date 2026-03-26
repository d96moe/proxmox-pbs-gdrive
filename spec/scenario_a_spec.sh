#!/bin/bash
# =============================================================================
# spec/scenario_a_spec.sh — Scenario A: Install + Backup
#
# ShellSpec DRIVES the full install+backup flow:
#   1. restore-1-install.sh (Step 1+) — installs PBS, rclone, restic, resticprofile
#   2. Creates a test LXC (arch-aware)
#   3. Backs up LXC to PBS
#   4. Backs up PVE config to Google Drive
#   5. Backs up PBS datastore to Google Drive via restic
#
# Jenkins handles only: VM/disk setup, credentials, script deploy,
# PVE install + reboot (pve_install_spec.sh), pve-cluster fix, ShellSpec install.
# =============================================================================

SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/proxmox-restore}"
ARCH="$(uname -m)"

# =============================================================================
Describe 'restore-1-install.sh: Install PBS and backup tools'
# =============================================================================

    It 'completes successfully'
        When run env CI=true bash "${SCRIPTS_DIR}/restore-1-install.sh"
        The status should be success
    End

    It 'proxmox-backup-server is installed'
        When run dpkg-query -W -f='${Status}' proxmox-backup-server
        The output should include 'install ok installed'
    End

    It 'proxmox-backup service is active'
        When run systemctl is-active proxmox-backup
        The output should eq 'active'
    End

    It 'PBS datastore is mounted'
        When run mountpoint -q /mnt/pbs
        The status should be success
    End

    It 'restic is installed'
        When run which restic
        The status should be success
    End

    It 'rclone is installed'
        When run which rclone
        The status should be success
    End

    It 'resticprofile is installed'
        When run which resticprofile
        The status should be success
    End

End

# =============================================================================
Describe 'Create test LXC'
# =============================================================================

    create_test_lxc() {
        if ! ip link show vmbr0 &>/dev/null; then
            ip link add name vmbr0 type bridge 2>/dev/null || true
            ip link set vmbr0 up
        fi

        local TMPL_DIR="/var/lib/vz/template/cache"

        if [ "${ARCH}" = "aarch64" ]; then
            local TMPL_NAME="debian-12-standard_arm64.tar.xz"
            if [ ! -f "${TMPL_DIR}/${TMPL_NAME}" ]; then
                local BASE="https://images.linuxcontainers.org/images/debian/bookworm/arm64/default"
                local LATEST
                LATEST=$(curl -sL "${BASE}/" \
                    | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}' | sort -r | head -1)
                [ -z "${LATEST}" ] && { echo "ERROR: could not list arm64 templates"; return 1; }
                curl -fsSL "${BASE}/${LATEST}/rootfs.tar.xz" \
                    -o "${TMPL_DIR}/${TMPL_NAME}"
            fi
            pct create 100 "${TMPL_DIR}/${TMPL_NAME}" \
                --arch arm64 --ostype unmanaged \
                --hostname ci-test-lxc --memory 64 \
                --rootfs local:1 --unprivileged 1
            sed -i '/^lxc[.]seccomp/d; /^lxc[.]apparmor/d' /etc/pve/lxc/100.conf
            echo "lxc.apparmor.profile: unconfined" >> /etc/pve/lxc/100.conf
        else
            local TMPL_NAME
            TMPL_NAME=$(pveam list local 2>/dev/null | grep debian | awk '{print $1}' | head -1)
            if [ -z "${TMPL_NAME}" ]; then
                pveam update
                pveam download local debian-12-standard_amd64.tar.zst
                TMPL_NAME="local:vztmpl/debian-12-standard_amd64.tar.zst"
            fi
            pct create 100 "${TMPL_NAME}" \
                --hostname ci-test-lxc --memory 64 \
                --rootfs local:1 --unprivileged 1
        fi

        pct start 100
        sleep 5
    }

    It 'creates and starts LXC 100'
        When call create_test_lxc
        The status should be success
    End

    It 'LXC 100 is running'
        When run pct status 100
        The output should include 'running'
    End

End

# =============================================================================
Describe 'PBS backup of LXC 100'
# =============================================================================

    run_pbs_backup() {
        local FINGERPRINT
        FINGERPRINT=$(proxmox-backup-manager cert info 2>/dev/null \
            | grep "Fingerprint (sha256):" | awk '{print $NF}')
        pvesh create /storage \
            --storage "${PVE_PBS_STORAGE_ID}" \
            --type pbs \
            --server "${PVE_PBS_SERVER}" \
            --datastore "${PBS_DATASTORE_NAME}" \
            --username "${PBS_USER}" \
            --password "${PBS_USER_PASSWORD}" \
            --fingerprint "${FINGERPRINT}" \
            --content backup \
            --prune-backups "${PBS_RETENTION_LOCAL}" 2>/dev/null || true

        systemctl is-active --quiet pvedaemon \
            || systemctl start pvedaemon pveproxy pvestatd
        sleep 3
        vzdump 100 --storage "${PVE_PBS_STORAGE_ID}" \
            --mode snapshot --compress zstd
    }

    count_ct100_snapshots() {
        pvesh get "/nodes/$(hostname)/storage/${PVE_PBS_STORAGE_ID}/content" \
            --output-format json 2>/dev/null \
            | python3 -c '
import json, sys
items = json.load(sys.stdin)
print(len([x for x in items if x.get("vmid") == 100]))
'
    }

    It 'vzdump of LXC 100 to PBS succeeds'
        When call run_pbs_backup
        The status should be success
    End

    It 'at least one ct/100 snapshot exists in PBS'
        When call count_ct100_snapshots
        The output should not eq '0'
    End

End

# =============================================================================
Describe 'Backup PVE config to Google Drive'
# =============================================================================

    count_gdrive_config_tarballs() {
        rclone lsf "${RESTICPROFILE_GDRIVE_REMOTE}:bu/${GDRIVE_CONFIG_FOLDER}/" \
            --include 'pve-config-*.tar.gz' 2>/dev/null | wc -l | tr -d ' '
    }

    It 'backup-pve-config.sh completes successfully'
        When run /usr/local/bin/backup-pve-config.sh
        The status should be success
    End

    It 'config tarball is present on Google Drive'
        When call count_gdrive_config_tarballs
        The output should not eq '0'
    End

End

# =============================================================================
Describe 'Restic backup of PBS datastore to Google Drive'
# =============================================================================

    run_restic_backup() {
        /usr/local/bin/stop-proxmox-backup.sh
        resticprofile \
            -c /etc/resticprofile/profiles.yaml \
            -n pbs-backup \
            init 2>/dev/null || true
        resticprofile \
            -c /etc/resticprofile/profiles.yaml \
            -n pbs-backup \
            backup
        systemctl start proxmox-backup proxmox-backup-proxy
    }

    count_restic_snapshots() {
        restic \
            -r "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
            --password-file "${RESTIC_PASSWORD_FILE}" \
            snapshots --json 2>/dev/null \
            | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))'
    }

    It 'restic backup to Google Drive completes'
        When call run_restic_backup
        The status should be success
    End

    It 'at least one restic snapshot exists on Google Drive'
        When call count_restic_snapshots
        The output should not eq '0'
    End

End
