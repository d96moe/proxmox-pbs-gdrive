#!/bin/bash
# =============================================================================
# spec/scenario_b_spec.sh — Scenario B: DR Restore
#
# ShellSpec DRIVES the full DR restore flow:
#   1. restore-1-install.sh (Step 1+) — installs PBS, rclone, restic, resticprofile
#   2. restore-2-auth.sh — restores rclone config from local tar, mounts PBS
#   3. restore-3-pve.sh — wires PBS storage into PVE, enables schedules
#   4. Restores LXC 100 from PBS snapshot
#   5. Verifies LXC is running
#
# Jenkins handles only: VM/disk setup, credentials, script deploy,
# PVE install + reboot (pve_install_spec.sh), pve-cluster fix, ShellSpec install,
# and staging the local config tar in /tmp/.
# =============================================================================

SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/proxmox-restore}"
ARCH="$(uname -m)"

# =============================================================================
Describe 'restore-1-install.sh: Install PBS and backup tools'
# =============================================================================

    It 'completes successfully'
        When run env CI=true bash "${SCRIPTS_DIR}/restore-1-install.sh"
        The status should be success
        The output should include 'restore-1-install.sh COMPLETE'
        The stderr should be present
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
        The output should include 'restic'
    End

    It 'rclone is installed'
        When run which rclone
        The output should include 'rclone'
    End

    It 'resticprofile is installed'
        When run which resticprofile
        The output should include 'resticprofile'
    End

End

# =============================================================================
Describe 'restore-2-auth.sh: Restore rclone config + PBS datastore from GDrive'
# =============================================================================

    It 'completes successfully'
        When run env CI=true bash "${SCRIPTS_DIR}/restore-2-auth.sh"
        The status should be success
        The output should include 'restore-2-auth.sh COMPLETE'
        The stderr should be present
    End

    It 'rclone.conf is present after restore'
        When run test -f /root/.config/rclone/rclone.conf
        The status should be success
    End

    It 'can access Google Drive after auth restore'
        When run bash -c "source ${SCRIPTS_DIR}/config.env && rclone lsd \"\${RESTICPROFILE_GDRIVE_REMOTE}:bu\" 2>/dev/null"
        The output should be present
    End

    It 'PBS datastore is still mounted after restore'
        When run mountpoint -q /mnt/pbs
        The status should be success
    End

End

# =============================================================================
Describe 'restore-3-pve.sh: Wire PBS storage into PVE'
# =============================================================================

    It 'completes successfully'
        When run env CI=true bash "${SCRIPTS_DIR}/restore-3-pve.sh"
        The status should be success
        The output should include 'restore-3-pve.sh COMPLETE'
        The stderr should be present
    End

    It 'PBS storage is registered in PVE'
        When run bash -c "source ${SCRIPTS_DIR}/config.env && pvesh get /storage/\"\${PVE_PBS_STORAGE_ID}\" 2>/dev/null"
        The output should include 'pbs'
    End

    count_pbs_ct100_snapshots() {
        source "${SCRIPTS_DIR}/config.env"
        pvesh get "/nodes/$(hostname)/storage/${PVE_PBS_STORAGE_ID}/content" \
            --output-format json 2>/dev/null \
            | python3 -c '
import json, sys
items = json.load(sys.stdin)
print(len([x for x in items if x.get("vmid") == 100]))
'
    }

    It 'at least one ct/100 snapshot is visible in PBS'
        When call count_pbs_ct100_snapshots
        The output should not eq '0'
    End

End

# =============================================================================
Describe 'Restore LXC 100 from PBS'
# =============================================================================

    restore_lxc_100() {
        source "${SCRIPTS_DIR}/config.env"

        if ! ip link show vmbr0 &>/dev/null; then
            ip link add name vmbr0 type bridge 2>/dev/null || true
            ip link set vmbr0 up
        fi

        systemctl is-active --quiet pvedaemon \
            || systemctl start pvedaemon pveproxy pvestatd
        sleep 3

        local SNAP
        SNAP=$(pvesh get "/nodes/$(hostname)/storage/${PVE_PBS_STORAGE_ID}/content" \
            --output-format json 2>/dev/null \
            | python3 -c "
import json, sys
items = json.load(sys.stdin)
ct = [x for x in items if x.get('vmid') == 100]
if not ct:
    raise SystemExit('ERROR: no backup for CT 100 in ${PVE_PBS_STORAGE_ID}')
ct.sort(key=lambda x: x.get('ctime', 0))
print(ct[-1]['volid'])
")

        echo "Restoring from: ${SNAP}"
        rm -f /etc/pve/lxc/100.conf
        pct restore 100 "${SNAP}" --storage local

        if [ "${ARCH}" = "aarch64" ]; then
            sed -i '/^net/d; /^lxc[.]seccomp/d; /^lxc[.]apparmor/d' /etc/pve/lxc/100.conf
            echo "lxc.apparmor.profile: unconfined" >> /etc/pve/lxc/100.conf
        fi

        pct start 100
        sleep 5
    }

    It 'pct restore and start of LXC 100 succeeds'
        When call restore_lxc_100
        The status should be success
    End

    It 'LXC 100 is running'
        When run pct status 100
        The output should include 'running'
    End

End
