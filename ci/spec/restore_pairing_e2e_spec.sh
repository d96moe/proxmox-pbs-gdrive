#!/bin/bash
# =============================================================================
# ci/spec/restore_pairing_e2e_spec.sh — restore-2 pairing, end to end
#
# Real GDrive download, real decryption, real extraction (pve-cluster restart),
# real restic snapshot list — but RESTORE_PLAN_ONLY=1 stops before PBS is
# touched, so every scenario takes seconds. Fixtures: ci/pairing-fixture.sh.
# The unit-level logic is covered by restore_pair_spec.sh.
# =============================================================================

load_state() { . /root/.pairtest.env; }

# run_plan VAR=value ... — Path B (GDrive) restore-2 in plan mode
run_plan() {
    rm -f /tmp/pve-config-*
    env "$@" RESTORE_PLAN_ONLY=1 bash "${SCRIPTS_DIR}/restore-2-auth.sh" 2>&1
}

# run_plan_local <encrypted file> <date> VAR=value ... — Path A (tarball in /tmp)
run_plan_local() {
    local src="$1" d="$2"; shift 2
    rm -f /tmp/pve-config-*
    cp "${src}" "/tmp/pve-config-${d}.tar.gz.enc"
    env "$@" RESTORE_PLAN_ONLY=1 bash "${SCRIPTS_DIR}/restore-2-auth.sh" 2>&1
}

# run_plan_no_pwfile VAR=value ... — decryption password from stdin, not the file
run_plan_no_pwfile() {
    local pwf="${CONFIG_ENCRYPT_PASSWORD_FILE}" rc=0
    cp -p "${pwf}" "${W}/pw.keep"
    rm -f "${pwf}"
    run_plan "$@" || rc=$?
    cp -p "${W}/pw.keep" "${pwf}"      # the extracted tarball may have put it back; same content
    return "${rc}"
}

Describe 'restore-2 pairing (end to end, RESTORE_PLAN_ONLY)'
    BeforeEach 'load_state'

    It 'Path B, normal night: restores the newest tarball with the snapshot of the same day'
        When run run_plan CI=true RESTORE_CONFIG_FOLDER="${BASE}_normal"
        The status should be success
        The output should include "RESTORE_PLAN date=${D0} "
        The output should include "newest_tarball=${D0} switched=0 mismatch=0"
    End

    It 'newest tarball has no snapshot (restic failed that night): switches to the previous pair, keeps the newest credentials'
        When run run_plan CI=true RESTORE_CONFIG_FOLDER="${BASE}_newer"
        The status should be success
        The output should include "has no restic snapshot from that day"
        The output should include "RESTORE_PLAN date=${D0} "
        The output should include "newest_tarball=${D_FUT} switched=1 mismatch=0"
        The contents of file /etc/resticprofile/profiles.yaml should include "pairtest-marker"
        The contents of file /etc/proxmox-backup-restore/config.env should not include "pairtest-marker"
    End

    It 'no date has both (CI): refuses instead of restoring a mismatched pair'
        When run run_plan CI=true RESTORE_CONFIG_FOLDER="${BASE}_old"
        The status should be failure
        The output should include "no date has both"
        The output should include "refusing a mismatched restore"
        The output should not include "RESTORE_PLAN date="
    End

    It 'RESTORE_DATE forces an older day that has both'
        When run run_plan CI=true RESTORE_CONFIG_FOLDER="${BASE}_newer" RESTORE_DATE="${D0}"
        The status should be success
        The output should include "RESTORE_PLAN date=${D0} "
        The output should include "newest_tarball=${D0} switched=0"
    End

    It 'RESTORE_DATE for a day without a snapshot fails'
        When run run_plan CI=true RESTORE_CONFIG_FOLDER="${BASE}_newer" RESTORE_DATE="${D_FUT}"
        The status should be failure
        The output should include "no restic snapshot dated ${D_FUT}"
    End

    It 'Path A, your own tarball in /tmp: its date decides the snapshot'
        When run run_plan_local "${W}/d0.enc" "${D0}" CI=true
        The status should be success
        The output should include "Found local config backup"
        The output should include "RESTORE_PLAN date=${D0} "
    End

    It 'Path A with a tarball from a day without a snapshot fails in CI'
        When run run_plan_local "${W}/old.enc" "${D_OLD}" CI=true
        The status should be failure
        The output should include "no date has both"
    End

    It 'Path A with RESTORE_DATE different from the local tarball fails'
        When run run_plan_local "${W}/d0.enc" "${D0}" CI=true RESTORE_DATE="${D_OLD}"
        The status should be failure
        The output should include "but the local tarball is from ${D0}"
    End

    It 'interactive, no pair: typing "mismatch" goes on with the newest snapshot'
        Data "mismatch"
        When run run_plan CI= RESTORE_CONFIG_FOLDER="${BASE}_old"
        The status should be success
        The output should include "RESTORE_PLAN date=${NEWEST_SNAP_DATE} "
        The output should include "mismatch=1"
    End

    It 'interactive, no pair: any other answer aborts'
        Data "yes"
        When run run_plan CI= RESTORE_CONFIG_FOLDER="${BASE}_old"
        The status should be failure
        The output should include "Aborted."
    End

    It 'no password file: the decryption password is read from stdin'
        Data:expand
            #|$(cat "${CONFIG_ENCRYPT_PASSWORD_FILE}")
        End
        When run run_plan_no_pwfile CI=true RESTORE_CONFIG_FOLDER="${BASE}_normal"
        The status should be success
        The output should include "RESTORE_PLAN date=${D0} "
    End

    It 'no password file and a wrong password: fails at decryption'
        Data "definitely-not-the-password"
        When run run_plan_no_pwfile CI=true RESTORE_CONFIG_FOLDER="${BASE}_normal"
        The status should be failure
        The output should include "bad decrypt"
        The output should not include "RESTORE_PLAN"
    End
End
