# CI & Testing

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

### x86_64: Nested Proxmox inside a privileged LXC

The x86_64 pipelines use **nested Proxmox** — a full PVE instance running inside a privileged LXC container on the host PVE node. This means the scripts run against a real `pvesh` / `pct` environment, not a mock.

```
Physical x86_64 host (PVE)
    ├── LXC 200  — Jenkins agent (runs pipeline, issues pct exec commands)
    └── LXC 199  — Nested PVE node under test (full Proxmox VE inside a privileged LXC)
                        ├── PBS installed here by restore-1-install.sh
                        ├── test LXC created and backed up here
                        └── DR restore runs here (scenario B)
```

LXC 199 is a **privileged** container with nesting enabled (`features: nesting=1`) — required for PVE and PBS to run inside it (systemd, cgroups, `/dev` access).

Jenkins (LXC 200) runs commands on LXC 199 via `pct exec 199 -- bash -c "..."` — no SSH into the nested node needed.

### arm64: Fully emulated ARM64 VM on x86_64 host

The arm64 pipelines do **not** run on real Pi 5 hardware. Instead, Jenkins clones a vanilla Debian arm64 VM template (template 9002) on the same x86_64 host and runs it under **full QEMU ARM64 emulation — no KVM acceleration**.

```
Physical x86_64 host (PVE)
    ├── LXC 200         — Jenkins agent
    └── VM (clone of 9002) — vanilla Debian arm64, fully QEMU-emulated
                                ├── Step 0 of restore-1-install.sh installs pxvirt (arm64 PVE) and reboots
                                ├── Step 1+ installs pipbs (arm64 PBS), rclone, restic
                                ├── test LXC created and backed up here
                                └── Jenkins accesses via SSH (not pct exec)
```

PVE itself is **installed by the script** (`restore-1-install.sh` Step 0 installs pxvirt and reboots) — the template starts as plain Debian with no PVE. This tests the full arm64 install path from scratch.

Full QEMU emulation means arm64 pipelines run **3–5× slower** than x86_64.

| Node | Role | Access method |
|---|---|---|
| LXC 200 | Jenkins agent, pipeline executor | — |
| LXC 199 | Nested PVE under test (x86_64) | `pct exec 199` |
| VM (clone of 9002) | Emulated arm64 PVE under test | SSH |

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
- For ARM64 pipelines: the arm64 template VM (9002) must exist on the x86_64 PVE host — run `ci/setup-arm64-template.sh` once to create it (see [ARM64 Template Setup](#arm64-template-setup)). No Pi 5 or separate arm64 hardware needed.

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

### VM Templates

Both pipeline families clone a fresh VM from a template for each build and destroy it afterwards. Two templates are needed on the x86_64 PVE host:

| Template ID | Used by | Base OS | Script |
|---|---|---|---|
| 9001 | x86_64 pipelines | Vanilla Debian Bookworm x86_64 with cloud-init + Jenkins SSH key | Manual (no script in repo) |
| 9002 | arm64 pipelines | Vanilla Debian Trixie arm64 with cloud-init + Jenkins SSH key | `ci/setup-arm64-template.sh` |

Neither template has PVE or PBS pre-installed — the whole point is that `restore-1-install.sh` installs them as part of the test.

**Template 9001 (x86_64):** Create a standard Debian Bookworm VM with cloud-init in PVE, add the Jenkins SSH public key to `~/.ssh/authorized_keys`, and convert it to a template (`qm template 9001`). No script provided — this is a one-time manual step.

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
