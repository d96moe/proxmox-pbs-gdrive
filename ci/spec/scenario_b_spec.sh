#!/bin/bash
# =============================================================================
# ci/spec/scenario_b_spec.sh — ShellSpec integration tests for Scenario B
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
        --repository "${PBS_USER}@127.0.0.1:${PBS_DATASTORE_NAME}" 2>&1 \
        | grep -c 'ct/' || echo '0'
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

Describe 'Prerequisites'
    It 'restic snapshot repo exists in GDrive bu/ci-restore-test (run proxmox-shellspec / Scenario A at least once first)'
        When run rclone lsd "${RESTICPROFILE_GDRIVE_REMOTE}:bu"
        The output should include 'ci-restore-test'
    End
End

Describe 'PVE cluster'
    It 'pve-cluster is active after config restore'
        When run systemctl is-active pve-cluster
        The output should eq 'active'
    End
End

Describe 'Config database restore'
    It 'LXC 100 is visible in PVE config (config.db was restored)'
        When run pct config 100
        The output should include 'hostname'
    End
End

Describe 'rclone credentials'
    It 'can access Google Drive (credentials restored from config tar)'
        When run rclone lsd "${RESTICPROFILE_GDRIVE_REMOTE}:bu"
        The output should include 'ci-restore-test'
    End
End

Describe 'PBS storage integration'
    It 'pbs-ci storage exists in PVE'
        When run pvesh get "/storage/${PVE_PBS_STORAGE_ID}"
        The output should include 'pbs'
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

# Host extras: Scenario A ran ci/setup-extras-fixture.sh before the config
# backup; restore-3-pve.sh must bring packages, paths and services back.
Describe 'Host extras (EXTRA_PACKAGES / EXTRA_CONFIG_PATHS / EXTRA_SERVICES)'
    It 'extra packages are installed'
        When run dpkg-query -W -f '${Status}\n' nginx iptables-persistent
        The output should eq "install ok installed
install ok installed"
    End

    It 'reverse proxy answers through nginx → helper service (site + unit + script restored)'
        When run curl -fsS --max-time 5 http://127.0.0.1:8081/
        The output should eq 'ci-extras-ok'
    End

    It 'the package default site did not come back (paths restored exactly, after install)'
        Path default-site=/etc/nginx/sites-enabled/default
        The path default-site should not be exist
    End

    It 'the NAT rule is loaded from the restored /etc/iptables/rules.v4'
        When run iptables -t nat -S POSTROUTING
        The output should include '-A POSTROUTING -d 198.51.100.0/24 -j MASQUERADE'
    End

    It 'the restored sysctl drop-in is applied'
        When run sysctl -n net.ipv4.conf.all.log_martians
        The output should eq '1'
    End

    It 'every extra service is enabled'
        When run systemctl is-enabled netfilter-persistent ci-extras-echo nginx
        The output should eq "enabled
enabled
enabled"
    End
End
