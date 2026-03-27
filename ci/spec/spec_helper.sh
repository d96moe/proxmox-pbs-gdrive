#!/bin/bash
# =============================================================================
# ci/spec/spec_helper.sh — Shared setup for ShellSpec integration tests
#
# Sources config.env and exports all variables so they are available
# inside When run / When call blocks in scenario specs.
# =============================================================================

SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/proxmox-restore}"
CONFIG_ENV="${SCRIPTS_DIR}/config.env"

if [ ! -f "${CONFIG_ENV}" ]; then
    echo "ERROR: ${CONFIG_ENV} not found — cannot run tests" >&2
    exit 1
fi

# shellcheck source=/dev/null
. "${CONFIG_ENV}"

# Export everything so subshells (When run bash -c / helper functions) see them
export SCRIPTS_DIR \
       RESTICPROFILE_GDRIVE_REMOTE \
       RESTICPROFILE_GDRIVE_PATH \
       RESTIC_PASSWORD_FILE \
       GDRIVE_CONFIG_FOLDER \
       PBS_USER \
       PBS_USER_PASSWORD \
       PBS_TOKEN_NAME \
       PBS_DATASTORE_NAME \
       PBS_DATASTORE_PATH \
       PVE_PBS_STORAGE_ID \
       PVE_PBS_SERVER
