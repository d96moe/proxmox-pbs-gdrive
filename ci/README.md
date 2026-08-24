# CI & Testing

## Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Test Infrastructure](#test-infrastructure)
- [What ShellSpec Tests Verify](#what-shellspec-tests-verify)
- [Jenkins Setup](#jenkins-setup)
- [Credentials and Secrets](#credentials-and-secrets)
- [Running ShellSpec Locally](#running-shellspec-locally)

---

Jenkins pipelines automatically verify the scripts end-to-end on real Proxmox VMs, and keep the CI templates themselves refreshed weekly.

---

## Overview

| Pipeline | Jenkins job | Jenkinsfile | Schedule | What it tests |
|---|---|---|---|---|
| Template refresh (x86) | `proxmox-ci-template-refresh` | `ci/Jenkinsfile.template-refresh` | Sundays ~03:00 | Rebuilds CI template VM 9001 from a fresh Bookworm image |
| Template refresh (ARM64) | `proxmox-ci-template-refresh-arm64` | `ci/Jenkinsfile.template-refresh-arm64` | Sundays ~04:00 | Rebuilds CI template VM 9002 from a fresh Trixie arm64 image |
| Scenario A | `proxmox-ci-backup` | `ci/Jenkinsfile.shellspec` | Nightly ~21:00 | Install + PBS backup + GDrive backup |
| Scenario B (DR) | `proxmox-ci-dr` | `ci/Jenkinsfile.shellspec-dr` | Sundays ~21:00 | Full DR restore from GDrive |
| Scenario A (ARM64) | `proxmox-ci-backup-arm64` | `ci/Jenkinsfile.shellspec-arm64` | Nightly ~22:00 | Same as A, emulated arm64 on x86_64 host |
| Scenario B (ARM64) | `proxmox-ci-dr-arm64` | `ci/Jenkinsfile.shellspec-dr-arm64` | Sundays ~23:00 | Full DR restore, emulated arm64 on x86_64 host |

Scenario B depends on Scenario A having run at least once (needs a restic snapshot and config tarball on Google Drive).

The two template-refresh jobs exist so the CI template VMs (9001/9002) don't silently drift further behind current Debian every week — they destroy and rebuild the template from a fresh cloud image each run, before any other job that day clones it. The x86 refresh must run before the arm64 one: the arm64 template's cloud-init SSH key is extracted live from VM 9001's config. See `ci/setup-x86-template.sh` and `ci/setup-arm64-template.sh` — same scripts used for the original one-time setup, just re-run weekly now. `restore-1-install.sh`'s own `apt_get dist-upgrade` during restore stays in place regardless — it's what makes a genuine disaster recovery (no template at all) work, and is a harmless no-op against an already-fresh template.

Side benefit: since the same-day CI runs (install, backup, DR restore) exercise this freshly-updated OS/package set before any real production host gets manually `apt upgrade`d, a weekly CI failure here is an early warning that a pending upstream Debian/Proxmox package update breaks something — a canary, ahead of applying that same update in prod. This happens at two layers: the refresh job itself tests a clean `apt-get install proxmox-ve` against the latest OS image, and the same-day downstream jobs test the full `restore-1-install.sh` install flow against that same fresh image — so either a plain package install or this repo's own install logic breaking on the latest packages gets caught here first.

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
                                   ├── run 1: restore-1-install.sh detects no PVE → installs pxvirt, reboots
                                   ├── run 2: restore-1-install.sh installs pipbs, rclone, restic
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

### Scenario A (`ci/spec/scenario_a_spec.sh`)

After the full install + backup pipeline:

- `proxmox-backup-server` is installed and the package is marked `install ok installed`
- `restic`, `rclone`, `resticprofile` are on PATH
- `proxmox-backup` systemd service is `active`
- PBS datastore is mounted at `/mnt/pbs`
- At least one ct/100 snapshot exists in PBS storage
- At least one restic snapshot exists in the Google Drive repository
- At least one config tarball (`pve-config-*.tar.gz`) exists on Google Drive

### Scenario B (`ci/spec/scenario_b_spec.sh`)

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

**Adapt IPs to your network:**

The Jenkinsfiles and setup scripts contain IPs specific to this setup. Change them to match your environment before running:

| Variable | Where | Default (this repo) | What to set |
|---|---|---|---|
| `PVE_HOST` | All Jenkinsfiles (top) | `192.168.0.200` | Your PVE host IP |
| `VM_IP` | x86 Jenkinsfiles (top) | `192.168.0.251` | Free IP for the x86 CI VM |
| `VM_IP` | arm64 Jenkinsfiles (top) | `192.168.0.252` | Free IP for the arm64 CI VM |
| `VM_IP` / `GATEWAY` | `ci/setup-x86-template.sh` | `192.168.0.251` / `.1` | Same IP + your gateway |
| `VM_IP` / `GATEWAY` | `ci/setup-arm64-template.sh` | `192.168.0.252` / `.1` | Same IP + your gateway |

The test VMs are **created by Jenkins** from these templates at the start of each build and destroyed afterwards. No persistent test node to maintain.

**Jenkins credentials** (configure in Jenkins → Manage Credentials):
- One SSH key pair is used for everything — SSHing into the PVE host to run `qm` commands, and SSHing into the cloned test VMs. `ci/setup-arm64-template.sh` injects the public key via cloud-init (the arm64 template never boots during its own build, so cloud-init gets a genuine first run on every clone). `ci/setup-x86-template.sh` instead bakes the key into a real `/root/.ssh/authorized_keys` file directly, after installing proxmox-ve — cloud-init's own key injection is unreliable there (installing proxmox-ve turns that path into a symlink into `/etc/pve`, which is never mounted on these single-node clones, so a cloud-init-injected key silently stops working; see the commit history around 2026-08-24 for the full chain of x86 template network/auth fixes if this needs revisiting).

  **Step 1** — Generate the key inside LXC 200 (where Jenkins runs):
  ```bash
  pct exec 200 -- sudo -u jenkins ssh-keygen -t ed25519 -f /var/lib/jenkins/.ssh/id_ed25519 -N ""
  ```

  **Step 2** — Add the private key to Jenkins via the web UI: Manage Jenkins → Credentials → Add Credential → *SSH Username with private key* → paste the contents of `/var/lib/jenkins/.ssh/id_ed25519` from inside LXC 200.

  **Step 3** — Before running the template setup scripts on the PVE host, make the public key available there:
  ```bash
  mkdir -p /root/.ssh
  pct exec 200 -- cat /var/lib/jenkins/.ssh/id_ed25519.pub > /root/.ssh/jenkins_ci.pub
  ```
  `ci/setup-x86-template.sh` reads `/root/.ssh/jenkins_ci.pub` on the PVE host and copies it directly into the template's `authorized_keys` (see above — not via cloud-init). This only needs doing once — the arm64 template script re-derives its own copy from VM 9001's config each run, so it stays in sync automatically as long as the x86 refresh keeps running.

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
| proxmox-ci-template-refresh | `ci/Jenkinsfile.template-refresh` |
| proxmox-ci-template-refresh-arm64 | `ci/Jenkinsfile.template-refresh-arm64` |
| proxmox-ci-backup | `ci/Jenkinsfile.shellspec` |
| proxmox-ci-dr | `ci/Jenkinsfile.shellspec-dr` |
| proxmox-ci-backup-arm64 | `ci/Jenkinsfile.shellspec-arm64` |
| proxmox-ci-dr-arm64 | `ci/Jenkinsfile.shellspec-dr-arm64` |

The two template-refresh jobs need no `ci/config_ci*.env` setup and don't clone a test VM — they SSH straight to the PVE host and rebuild templates 9001/9002 in place, so the only prerequisite is that the SSH key from Step 2/3 above is already working.

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

## Credentials and Secrets

| What | Where it lives | How CI gets it |
|---|---|---|
| rclone OAuth token (`rclone.conf`) | `/root/.config/rclone/rclone.conf` on the PVE host | Piped live over SSH from PVE host to CI VM during `Copy credentials` stage |
| restic repository password | `/etc/resticprofile/restic-password` on the PVE host | Same — piped live over SSH |
| PBS user password | `ci/config_ci.env` (placeholder value only) | Read from config file on the CI VM |
| SSH private key | Inside LXC 200 at `/var/lib/jenkins/.ssh/id_ed25519` | Jenkins credential store — never in git |

`config.env` (the real working config with actual passwords) is excluded via `.gitignore` and has never been committed. The files in `ci/config_ci.env` and `ci/config_ci_arm64.env` contain only placeholder values — no real passwords or tokens.

The rclone OAuth token gives access to Google Drive and never touches the repository — it is streamed directly between two SSH sessions by Jenkins at build time and exists only in memory and on the CI VM's filesystem for the duration of the build.

---

## Running ShellSpec Locally

Install ShellSpec on the PVE node:
```bash
bash <(curl -fsSL https://git.io/shellspec) --yes
```

Copy the CI config and run:
```bash
cp ci/config_ci.env config.env
shellspec --shell bash --format documentation ci/spec/scenario_a_spec.sh
shellspec --shell bash --format documentation ci/spec/scenario_b_spec.sh
```

> Note: tests query live system state — they only pass if the corresponding pipeline has already run and completed successfully.
