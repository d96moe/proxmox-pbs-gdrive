#!/bin/bash
# =============================================================================
# spec/pve_install_spec.sh — Step 0: Install Proxmox VE (arm64 only)
#
# ShellSpec calls restore-1-install.sh which installs pxvirt and reboots.
# The reboot kills this SSH session — Jenkins handles the wait and reconnect.
# This spec only runs on aarch64 (x86 has PVE pre-installed from ISO).
# =============================================================================

SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/proxmox-restore}"
ARCH="$(uname -m)"

Describe 'restore-1-install.sh Step 0: Install Proxmox VE'

    Skip if 'not arm64' [ "${ARCH}" != "aarch64" ]

    It 'pxvirt is not yet installed (pre-condition)'
        When run command -v pvesh
        The status should be failure
    End

    It 'restore-1-install.sh installs pxvirt and initiates reboot'
        # Script calls reboot and exits — SSH session will die shortly after.
        # Jenkins waits for the VM to come back before running scenario specs.
        When run env CI=true bash "${SCRIPTS_DIR}/restore-1-install.sh"
        The status should be success
    End

End
