#!/bin/bash
# =============================================================================
# lib/restore-pair.sh — pick a config tarball + restic snapshot from the SAME day
#
# Sourced by restore-2-auth.sh. Pure functions (no GDrive, no restic) so they
# can be unit-tested: ci/spec/restore_pair_spec.sh.
#
# Why: config.db (tarball) and the PBS datastore (restic) must describe the same
# night, or the restored PVE lists guests that have no backup, or backups of
# guests it doesn't know. backup-pve-config.sh already prunes tarballs to the
# restic snapshot dates, so a common date almost always exists — but if one of
# the two nightly jobs failed, the NEWEST of each are from different days.
# =============================================================================

# _dates_sorted "<dates>" — one YYYY-MM-DD per line, sorted, unique, no blanks.
# Input may be space- or newline-separated.
_dates_sorted() {
    tr ' \t' '\n\n' <<< "${1}" | sed -n '/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$/p' | sort -u
}

# pick_restore_date "<tarball dates>" "<snapshot dates>" [forced date]
# Prints the newest date present in BOTH lists (or the forced date if it is in
# both) and returns 0. Prints the reason to stderr and returns 1 otherwise.
# Age does not matter: the newest POSSIBLE pair wins, even if it is old.
pick_restore_date() {
    local tars snaps forced="${3:-}" d
    tars="$(_dates_sorted "${1}")"
    snaps="$(_dates_sorted "${2}")"
    if [ -n "${forced}" ]; then
        grep -qx "${forced}" <<< "${tars}"  || { echo "no config tarball dated ${forced}" >&2; return 1; }
        grep -qx "${forced}" <<< "${snaps}" || { echo "no restic snapshot dated ${forced}" >&2; return 1; }
        echo "${forced}"
        return 0
    fi
    d="$(comm -12 <(printf '%s\n' "${tars}") <(printf '%s\n' "${snaps}") | sed -n '$p')"
    if [ -z "${d}" ]; then
        echo "no date has both a config tarball (newest: $(sed -n '$p' <<< "${tars}")) and a restic snapshot (newest: $(sed -n '$p' <<< "${snaps}"))" >&2
        return 1
    fi
    echo "${d}"
}

# tarball_date <file name or path> — pve-config-YYYY-MM-DD.tar.gz[.enc] → YYYY-MM-DD
tarball_date() {
    local n="${1##*/}"
    n="${n#pve-config-}"
    echo "${n%%.tar.gz*}"
}

# snapshot_for_date "<date id lines>" <date> — newest snapshot id on that date.
# Input lines: "YYYY-MM-DD <id>", oldest first (as restic lists them).
snapshot_for_date() {
    awk -v d="${2}" '$1 == d { id = $2 } END { print id }' <<< "${1}"
}
