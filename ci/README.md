# CI & Testing

Two Jenkins pipelines automatically verify the scripts end-to-end on real Proxmox VMs.

---

## Overview

| Pipeline | Jenkins job | Jenkinsfile | Schedule | What it tests |
|---|---|---|---|---|
| Scenario A | `proxmox-ci-backup` | `ci/Jenkinsfile.shellspec` | Weekly | Install + PBS backup + GDrive backup |
| Scenario B (DR) | `proxmox-ci-dr` | `ci/Jenkinsfile.shellspec-dr` | Weekly | Full DR restore from GDrive |
| Scenario A (ARM64) | `proxmox-ci-backup-arm64` | `ci/Jenkinsfile.shellspec-arm64` | Weekly | Same as A, on Pi 5 |
| Scenario B (ARM64) | `proxmox-ci-dr-arm64` | `ci/Jenkinsfile.shellspec-dr-arm64` | Weekly | Full DR restore on Pi 5 |

Scenario B depends on Scenario A having run at least once (needs a restic snapshot and config tarball on Google Drive).

---

## How It Works

Each pipeline follows the same pattern:

1. **Jenkins drives the scripts** — runs `restore-1-install.sh`, creates test LXCs, triggers backups, runs restore scripts. Full console output visible in the build log.
2. **ShellSpec verifies end state** — after all scripts complete, ShellSpec runs and checks that the expected end state is present (tools installed, PBS active, snapshots in GDrive, LXC restored and running).

This separation is intentional: Jenkins shows you everything that happened; ShellSpec tells you whether it ended up in the right state.

---

## Test Infrastructure (Nested Proxmox)

The CI setup uses **nested Proxmox** — a full Proxmox VE instance running inside a privileged LXC container on the host PVE node. This means the scripts run against a real `pvenode` + `pvesh` + `pct` environment, not a mock.

```
Physical host (PVE)
    ├── LXC 200  — Jenkins agent (runs the pipeline, issues pct exec commands)
    └── LXC 199  — Nested PVE node under test (full Proxmox VE inside a privileged LXC)
                        ├── PBS installed here by restore-1-install.sh
                        ├── test LXC created and backed up here
                        └── DR restore runs here (scenario B)
```

LXC 199 is a **privileged** LXC container with nesting enabled (`features: nesting=1`). This is required for PVE and PBS to run inside it — systemd, cgroups, and `/dev` access all need elevated container privileges.

Jenkins (LXC 200) runs commands on LXC 199 via `pct exec 199 -- bash -c "..."`, which avoids needing SSH into the nested node and keeps networking simple.

For ARM64, the same pattern runs on a Raspberry Pi 5 (the host PVE is pxvirt, PBS is pipbs).

| Container | Role | Notes |
|---|---|---|
| LXC 200 | Jenkins agent, pipeline executor | Runs on x86_64 host PVE |
| LXC 199 | Nested PVE node under test | Privileged LXC, nesting=1 |
| TBD (arm64) | Jenkins agent | Raspberry Pi 5 |

---

## What ShellSpec Tests Verify

### Scenario A (`spec/scenario_a_spec.sh`)

After the full install + backup pipeline:

- `proxmox-backup-server` is installed and the package is marked `install ok installed`
- `restic`, `rclone`, `resticprofile` are on PATH
- `proxmox-backup` systemd service is `active`
- PBS datastore is mounted at `/mnt/pbs`
- At least one ct/100 snapshot exists in PBS storage
- At least one restic snapshot exists in the Google Drive repository
- At least one config tarball (`pve-config-*.tar.gz`) exists on Google Drive

### Scenario B (`spec/scenario_b_spec.sh`)

After the full DR restore pipeline:

- `pve-cluster` service is `active` (config.db was restored correctly)
- `pct config 100` returns output including `hostname` (LXC 100 is visible in PVE config)
- rclone can reach Google Drive (credentials restored from config tar)
- PBS storage (`pbs-ci`) exists in PVE
- At least one ct/100 snapshot is visible via `proxmox-backup-client`
- `pct status 100` returns `running` (LXC was restored from PBS and started)

---

## Jenkins Setup

### Prerequisites

**Infrastructure:**
- Jenkins running (in this setup: LXC 200 on the x86_64 PVE node)
- Jenkins Pipeline plugin installed
- A **test node** (LXC 199) that Jenkins can reach via SSH — this is the Proxmox node the scripts run against. It must have a dedicated PBS partition available before the pipelines run.
- For ARM64 pipelines: a Raspberry Pi 5 with a running PVE instance and a test LXC template (see [ARM64 Template Setup](#arm64-template-setup))

**Jenkins credentials** (configure in Jenkins → Manage Credentials):
- SSH private key for `root` on the test node — used by the Jenkinsfiles to exec commands via `pct exec`

**On the test node (LXC 199):**
- ShellSpec installed: `bash <(curl -fsSL https://git.io/shellspec) --yes`
- The repo cloned at a known path (the Jenkinsfiles handle this via `git clone` or workspace checkout)

**CI config files (`ci/config_ci.env`, `ci/config_ci_arm64.env`):**

These must be filled in before the pipelines can run. Key variables to set:

| Variable | Description |
|---|---|
| `PBS_PARTITION` | Dedicated PBS partition on the test node |
| `PBS_USER_PASSWORD` | Password for the PBS backup user |
| `RESTICPROFILE_GDRIVE_REMOTE` | rclone remote name configured on the test node |
| `RESTICPROFILE_GDRIVE_PATH` | Google Drive path for the CI restic repo (use a separate path from production!) |
| `GDRIVE_CONFIG_FOLDER` | Google Drive folder for CI config tarballs |
| `PVE_PBS_STORAGE_ID` | PVE storage ID for PBS (e.g. `pbs-ci`) |

> ⚠️ Use a separate Google Drive path for CI (`ci-restore-test` by convention) — not the same path as your production backups. CI runs `restic forget` and could prune production snapshots if paths overlap.

### Job Configuration

For each pipeline, set the **Script Path** in the Jenkins job to the Jenkinsfile in `ci/`:

| Job | Script Path |
|---|---|
| proxmox-ci-backup | `ci/Jenkinsfile.shellspec` |
| proxmox-ci-dr | `ci/Jenkinsfile.shellspec-dr` |
| proxmox-ci-backup-arm64 | `ci/Jenkinsfile.shellspec-arm64` |
| proxmox-ci-dr-arm64 | `ci/Jenkinsfile.shellspec-dr-arm64` |

### ARM64 Template Setup

The arm64 pipelines require a pre-built LXC template on the Pi 5. Run once:

```bash
./ci/setup-arm64-template.sh
```

This downloads a vanilla Debian arm64 rootfs from linuxcontainers.org and registers it as a PVE template.

---

## Running ShellSpec Locally

Install ShellSpec on the PVE node:
```bash
bash <(curl -fsSL https://git.io/shellspec) --yes
```

Copy the CI config and run:
```bash
cp ci/config_ci.env config.env
shellspec --shell bash --format documentation spec/scenario_a_spec.sh
shellspec --shell bash --format documentation spec/scenario_b_spec.sh
```

> Note: tests query live system state — they only pass if the corresponding pipeline has already run and completed successfully.
