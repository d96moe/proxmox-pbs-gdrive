#!/bin/bash
# =============================================================================
# spec/scenario_b_spec.sh — ShellSpec integration tests for Scenario B
#
# Verifies end-state after full DR restore:
#   config.db restored → rclone auth working → PBS wired into PVE →
#   LXC snapshot visible in PBS → LXC 100 restored and running.
#
# Run by Jenkinsfile.dr-test after all pipeline stages complete.
#
# Prerequisites: spec_helper.sh sources config.env and exports all variables.
# =============================================================================

# spec_helper.sh is loaded automatically via --require spec_helper in .shellspec
# (sourcing manually is not possible here since $0 points to the ShellSpec runner)

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

get_pbs_fingerprint() {
    proxmox-backup-manager cert info 2>/dev/null \
        | grep 'Fingerprint (sha256):' \
        | awk '{print $NF}'
}

count_pbs_ct100_snapshots_via_client() {
    local fingerprint
    fingerprint="$(get_pbs_fingerprint)"
    PBS_PASSWORD="${PBS_USER_PASSWORD}" PBS_FINGERPRINT="${fingerprint}" \
        proxmox-backup-client snapshots \
        --repository "${PBS_USER}@${PVE_PBS_SERVER}:${PBS_DATASTORE_NAME}" 2>&1 \
        | grep -c 'ct/' || echo '0'
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

Describe 'PVE cluster'
    It 'pve-cluster is active after config restore'
        When run systemctl is-active pve-cluster
        The output should eq 'active'
    End
End

Describe 'Config database restore'
    It 'LXC 100 is visible in PVE config (config.db was restored)'
        When run pct config 100
        The status should be success
    End
End

Describe 'rclone credentials'
    It 'can access Google Drive (credentials restored from config tar)'
        When run rclone lsd "${RESTICPROFILE_GDRIVE_REMOTE}:bu"
        The status should be success
    End
End

Describe 'PBS storage integration'
    It 'pbs-ci storage exists in PVE'
        When run pvesh get "/storage/${PVE_PBS_STORAGE_ID}"
        The status should be success
    End

    It 'at least one ct/100 snapshot is visible via PBS client'
        When call count_pbs_ct100_snapshots_via_client
        The output should not eq '0'
    End
End

Describe 'Full DR: LXC restore from PBS'
    It 'LXC 100 is running after pct restore'
        When run pct status 100
        The output should include 'running'
    End
End
