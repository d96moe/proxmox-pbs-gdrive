#!/bin/bash
# =============================================================================
# ci/spec/migration_spec.sh — checks after migrate-arm64-pxvirt-to-official.sh
#
# Run by Jenkinsfile.shellspec-arm64 when MIGRATE_TO_OFFICIAL=true, after the
# host was installed with pxvirt (like the cabin Pi), backed up, migrated to the
# official Proxmox arm64 repo and rebooted. Scenario A runs as well, so this file
# only covers what is specific to the migration.
# =============================================================================

pve_manager_version() { dpkg-query -W -f='${Version}' pve-manager; }
pve_manager_is_92() { dpkg --compare-versions "$(pve_manager_version)" ge 9.2; }
has_lierfang_source() { grep -rqs 'lierfang\.com' /etc/apt/sources.list /etc/apt/sources.list.d/; }
has_official_source() { grep -rqs 'download\.proxmox\.com/debian/pve' /etc/apt/sources.list.d/; }
held_proxmox_packages() { apt-mark showhold | grep -E '^(proxmox|pve)' || true; }
pbs_is_candidate() {
    # installed PBS == newest available, i.e. no longer stuck on the 4.2.1-1 fallback
    [ "$(dpkg-query -W -f='${Version}' proxmox-backup-server)" = \
      "$(apt-cache policy proxmox-backup-server | awk '/Candidate:/{print $2}')" ]
}
interfaces_unchanged() {
    local before
    before="$(ls -d /root/pre-migrate-*/interfaces.before 2>/dev/null | tail -1)"
    [ -n "${before}" ] && cmp -s "${before}" /etc/network/interfaces
}
count_pbs_ct100_snapshots() {
    pvesh get "/nodes/$(hostname)/storage/${PVE_PBS_STORAGE_ID}/content" --output-format json 2>/dev/null \
        | python3 -c 'import json,sys; print(len([x for x in json.load(sys.stdin) if x.get("vmid") == 100]))'
}

Describe 'Migration pxvirt → official Proxmox arm64'
    It 'runs pve-manager 9.2 or newer'
        When call pve_manager_is_92
        The status should be success
    End

    It 'has no pxvirt (lierfang) apt source left'
        When call has_lierfang_source
        The status should be failure
    End

    It 'uses the official Proxmox PVE repo'
        When call has_official_source
        The status should be success
    End

    It 'has no proxmox/pve package on hold any more'
        When call held_proxmox_packages
        The output should eq ''
    End

    It 'runs the newest available PBS (no fallback)'
        When call pbs_is_candidate
        The status should be success
    End

    It 'left /etc/network/interfaces unchanged'
        When call interfaces_unchanged
        The status should be success
    End

    It 'pve-cluster is active after the reboot'
        When run systemctl is-active pve-cluster
        The output should eq 'active'
    End

    It 'still sees the pre-migration PBS backups of ct/100'
        When call count_pbs_ct100_snapshots
        The output should not eq '0'
    End

    It 'test LXC 100 runs after the reboot'
        When run pct status 100
        The output should include 'running'
    End
End
