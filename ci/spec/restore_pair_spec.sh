#!/bin/bash
# =============================================================================
# ci/spec/restore_pair_spec.sh — unit tests for lib/restore-pair.sh
#
# Pure functions, no GDrive/restic needed. Run by the DR jobs next to Scenario B,
# and locally: shellspec --shell bash ci/spec/restore_pair_spec.sh
# =============================================================================

Include lib/restore-pair.sh

Describe 'pick_restore_date'
    It 'picks the newest date that has both a tarball and a snapshot'
        When call pick_restore_date "2026-11-20 2026-11-21 2026-11-22" "2026-11-20 2026-11-21 2026-11-22"
        The output should eq '2026-11-22'
    End

    It 'falls back to the previous pair when the newest tarball has no snapshot (restic failed that night)'
        When call pick_restore_date "2026-11-20 2026-11-21 2026-11-22" "2026-11-20 2026-11-21"
        The output should eq '2026-11-21'
    End

    It 'falls back when the newest snapshot has no tarball (config backup failed that night)'
        When call pick_restore_date "2026-11-19 2026-11-20" "2026-11-19 2026-11-20 2026-11-21"
        The output should eq '2026-11-20'
    End

    It 'uses an old pair if that is the newest possible one (age does not matter)'
        When call pick_restore_date "2026-03-01 2026-11-22" "2026-03-01 2026-11-21"
        The output should eq '2026-03-01'
    End

    It 'accepts newline-separated input and ignores junk lines'
        When call pick_restore_date "$(printf '2026-11-21\n\nnot-a-date\n2026-11-22\n')" "$(printf '2026-11-22\n2026-11-21\n')"
        The output should eq '2026-11-22'
    End

    It 'fails with a reason when no date has both'
        When call pick_restore_date "2026-11-22" "2026-11-21"
        The status should be failure
        The stderr should include 'no date has both'
        The stderr should include '2026-11-22'
        The stderr should include '2026-11-21'
    End

    It 'honours a forced date that has both'
        When call pick_restore_date "2026-11-20 2026-11-21" "2026-11-20 2026-11-21" "2026-11-20"
        The output should eq '2026-11-20'
    End

    It 'rejects a forced date without a snapshot'
        When call pick_restore_date "2026-11-20 2026-11-21" "2026-11-21" "2026-11-20"
        The status should be failure
        The stderr should include 'no restic snapshot dated 2026-11-20'
    End

    It 'rejects a forced date without a tarball'
        When call pick_restore_date "2026-11-21" "2026-11-20 2026-11-21" "2026-11-20"
        The status should be failure
        The stderr should include 'no config tarball dated 2026-11-20'
    End
End

Describe 'tarball_date'
    It 'reads the date from an encrypted tarball path'
        When call tarball_date /tmp/pve-config-2026-11-22.tar.gz.enc
        The output should eq '2026-11-22'
    End

    It 'reads the date from a legacy unencrypted name'
        When call tarball_date pve-config-2026-03-27.tar.gz
        The output should eq '2026-03-27'
    End
End

Describe 'snapshot_for_date'
    It 'returns the newest snapshot of that day'
        When call snapshot_for_date "$(printf '2026-11-21 aaaa1111\n2026-11-22 bbbb2222\n2026-11-22 cccc3333\n')" 2026-11-22
        The output should eq 'cccc3333'
    End

    It 'returns nothing for a day without snapshots'
        When call snapshot_for_date "$(printf '2026-11-21 aaaa1111\n')" 2026-11-22
        The output should eq ''
    End
End
