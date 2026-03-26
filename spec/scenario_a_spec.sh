#!/bin/bash
# =============================================================================
# spec/scenario_a_spec.sh — ShellSpec integration tests for Scenario A
#
# Verifies end-state after: install + PBS backup + GDrive backup + config backup.
# Run by Jenkinsfile.restore-test after all pipeline stages complete.
#
# Prerequisites: spec_helper.sh sources config.env and exports all variables.
# =============================================================================

# spec_helper.sh is loaded automatically via --require spec_helper in .shellspec
# (sourcing manually is not possible here since $0 points to the ShellSpec runner)

# -----------------------------------------------------------------------------
# Helper functions (called via "When call" to avoid quoting/subshell issues)
# -----------------------------------------------------------------------------

count_pbs_ct100_snapshots() {
    pvesh get "/nodes/$(hostname)/storage/${PVE_PBS_STORAGE_ID}/content" \
        --output-format json 2>/dev/null \
        | python3 -c '
import json, sys
items = json.load(sys.stdin)
print(len([x for x in items if x.get("vmid") == 100]))
'
}

count_gdrive_restic_snapshots() {
    restic \
        -r "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
        --password-file "${RESTIC_PASSWORD_FILE}" \
        snapshots --json 2>/dev/null \
        | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))'
}

count_gdrive_config_tarballs() {
    rclone lsf "${RESTICPROFILE_GDRIVE_REMOTE}:bu/${GDRIVE_CONFIG_FOLDER}/" \
        --include 'pve-config-*.tar.gz' 2>/dev/null \
        | wc -l \
        | tr -d ' '
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

Describe 'Tool installation'
    It 'installs proxmox-backup-server'
        When run dpkg-query -W -f='${Status}' proxmox-backup-server
        The output should include 'install ok installed'
    End

    It 'installs restic'
        When run which restic
        The output should include 'restic'
    End

    It 'installs rclone'
        When run which rclone
        The output should include 'rclone'
    End

    It 'installs resticprofile'
        When run which resticprofile
        The output should include 'resticprofile'
    End
End

Describe 'PBS service'
    It 'proxmox-backup is active'
        When run systemctl is-active proxmox-backup
        The output should eq 'active'
    End

    It 'PBS datastore is mounted at /mnt/pbs'
        When run mountpoint -q /mnt/pbs
        The status should be success
    End
End

Describe 'PBS backup'
    It 'has at least one snapshot for ct/100 in pbs-ci storage'
        When call count_pbs_ct100_snapshots
        The output should not eq '0'
    End
End

Describe 'Google Drive restic backup'
    It 'has at least one snapshot in ci-restore-test repository'
        When call count_gdrive_restic_snapshots
        The output should not eq '0'
    End
End

Describe 'Google Drive config backup'
    It 'has at least one config tarball uploaded'
        When call count_gdrive_config_tarballs
        The output should not eq '0'
    End
End
