# CI & Testing

## Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Test Infrastructure](#test-infrastructure)
- [What ShellSpec Tests Verify](#what-shellspec-tests-verify)
- [Jenkins Setup](#jenkins-setup)
- [Running ShellSpec Locally](#running-shellspec-locally)

---

Two Jenkins pipelines automatically verify the scripts end-to-end on real Proxmox VMs.

---

## Overview

| Pipeline | Jenkins job | Jenkinsfile | Schedule | What it tests |
|---|---|---|---|---|
| Scenario A | `proxmox-ci-backup` | `ci/Jenkinsfile.shellspec` | Weekly | Install + PBS backup + GDrive backup |
| Scenario B (DR) | `proxmox-ci-dr` | `ci/Jenkinsfile.shellspec-dr` | Weekly | Full DR restore from GDrive |
| Scenario A (ARM64) | `proxmox-ci-backup-arm64` | `ci/Jenkinsfile.shellspec-arm64` | Weekly | Same as A, emulated arm64 on x86_64 host |
| Scenario B (ARM64) | `proxmox-ci-dr-arm64` | `ci/Jenkinsfile.shellspec-dr-arm64` | Weekly | Full DR restore, emulated arm64 on x86_64 host |

Scenario B depends on Scenario A having run at least once (needs a restic snapshot and config tarball on Google Drive).

---

## How It Works

Each pipeline follows the same pattern:

1. **Jenkins drives the scripts** — runs `restore-1-install.sh`, creates test LXCs, triggers backups, runs restore scripts. Full console output visible in the build log.
2. **ShellSpec verifies end state** — after all scripts complete, ShellSpec runs and checks that the expected end state is present (tools installed, PBS active, snapshots in GDrive, LXC restored and running).

This separation is intentional: Jenkins shows you everything that happened; ShellSpec tells you whether it ended up in the right state.

---

## Test Infrastructure

Both pipelines follow the same pattern: Jenkins clones a fresh VM from a template, runs the scripts against it via SSH, then destroys it after the build. Every build starts from a clean slate.

```
Physical x86_64 host (PVE)
    ├── LXC 200              — Jenkins agent (runs pipelines)
    ├── VM (clone of 9001)   — x86_64 PVE node under test, fresh each build
    │                              ├── PVE pre-installed in template
    │                              ├── PBS installed by restore-1-install.sh
    │                              ├── test LXC created and backed up
    │                              └── destroyed after build
    └── VM (clone of 9002)   — arm64 PVE node under test, fresh each build
                                   ├── vanilla Debian arm64 (no PVE in template)
                                   ├── Step 0: restore-1-install.sh installs pxvirt, reboots
                                   ├── Step 1+: pipbs, rclone, restic installed
                                   ├── test LXC created and backed up
                                   └── destroyed after build
```

Jenkins accesses both VMs via **SSH** — there is no `pct exec` involved.

### x86_64

Clones template 9001 (Debian Bookworm x86_64, PVE pre-installed). The scripts run against a real `pvesh` / `pct` environment, not a mock.

### arm64: Fully emulated ARM64 VM on x86_64 host

Clones template 9002 (vanilla Debian Trixie arm64, no PVE). Runs under **full QEMU ARM64 emulation — no KVM acceleration**. No Pi 5 or separate arm64 hardware needed.

PVE is **installed by the script** during the CI run (`restore-1-install.sh` Step 0 installs pxvirt and reboots) — this tests the full arm64 install path from scratch.

Full QEMU emulation means arm64 pipelines run **3–5× slower** than x86_64.

| Node | Role | Access method |
|---|---|---|
| LXC 200 | Jenkins agent, pipeline executor | — |
| VM (clone of 9001) | x86_64 PVE node under test | SSH |
| VM (clone of 9002) | arm64 PVE node under test (QEMU-emulated) | SSH |

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
- The x86_64 PVE host must have template VM 9001 — run `ci/setup-x86-template.sh` once to create it
- The x86_64 PVE host must have template VM 9002 — run `ci/setup-arm64-template.sh` once to create it. No Pi 5 or separate arm64 hardware needed.

The test VMs are **created by Jenkins** from these templates at the start of each build and destroyed afterwards. No persistent test node to maintain.

**Jenkins credentials** (configure in Jenkins → Manage Credentials):
- SSH private key for `root` on the PVE host — used to clone/start/destroy VMs via `qm`
- SSH private key for `root` on the test VM — used to run scripts inside the cloned VM

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

### VM Templates

Both pipeline families clone a fresh VM from a template for each build and destroy it afterwards. Two templates are needed on the x86_64 PVE host:

| Template ID | Name | Used by | Base OS | PVE pre-installed | Script |
|---|---|---|---|---|---|
| 9001 | `restore-test-ci` | x86_64 pipelines | Debian Bookworm x86_64 | Yes | `ci/setup-x86-template.sh` |
| 9002 | `arm64-restore-ci` | arm64 pipelines | Debian Trixie arm64 | No (installed by CI) | `ci/setup-arm64-template.sh` |

**Why the difference?** x86_64 PVE installs cleanly from official repos so it's baked into the template. For arm64, installing pxvirt (the community ARM64 PVE port) is exactly what we want to test, so the template starts as plain Debian and `restore-1-install.sh` Step 0 installs pxvirt during the CI run.

Neither template has PBS pre-installed — `restore-1-install.sh` installs it as part of every test run.

**Template 9001 (x86_64):** Run once on the x86_64 PVE host:

```bash
./ci/setup-x86-template.sh
```

Downloads a Debian Bookworm x86_64 cloud image, creates a VM with a 16 GB OS disk and a 4 GB PBS data disk, installs Proxmox VE via SSH, then converts to template.

**Template 9002 (arm64):** Run once on the x86_64 PVE host:

```bash
./ci/setup-arm64-template.sh
```

This installs AAVMF arm64 UEFI firmware, downloads a vanilla Debian Trixie arm64 cloud image, creates a QEMU VM with `--arch aarch64` for full emulation, and converts it to a template. No Pi 5 or separate arm64 hardware required.

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
