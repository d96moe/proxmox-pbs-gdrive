#!/bin/bash
# =============================================================================
# spec/scenario_a_spec.sh — Scenario A: Install + Backup
#
# ShellSpec DRIVES the proxmox-restore scripts:
#   1. restore-1-install.sh (Step 1+) — installs PBS, rclone, restic, resticprofile
#   2. Backs up LXC 100 to PBS (verifies PBS storage is working)
#   3. backup-pve-config.sh — backs up PVE config to Google Drive
#   4. resticprofile — backs up PBS datastore to Google Drive
#
# Jenkins handles: VM/disk setup, credentials, script deploy,
# PVE install + reboot (pve_install_spec.sh), pve-cluster fix,
# ShellSpec install, and creating LXC 100 as a backup target.
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
