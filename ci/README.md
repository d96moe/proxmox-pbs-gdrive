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
| Dependency check (ARM64, L2) | `proxmox-ci-arm64-deps` | `ci/Jenkinsfile.arm64-deps` | Nightly ~02:00 | Simulates installing pxvirt PVE + pipbs PBS in an arm64 chroot of the latest Pi OS (~2 min). Green = latest of both installs together, yellow = only the PBS fallback works, red = PVE does not resolve |
| Golden image (ARM64, Pi 5) | `proxmox-ci-golden-image-arm64` | `ci/Jenkinsfile.golden-image-arm64` | Saturdays ~06:00 | Builds the generic golden DR image (Pi OS Lite + official PVE + pipbs PBS + tools), leak-gates it, runs the full arm64 DR on a test copy (template 9004) and publishes it to `gdrive:bu/golden-image/` only if that passes |
| Template refresh (ARM64, Pi OS) | `proxmox-ci-template-refresh-arm64-pios` | `ci/Jenkinsfile.template-refresh-arm64-pios` | Sundays ~05:00 | Rebuilds VM 9003 from the latest Raspberry Pi OS Lite arm64 (boot layer swapped), smoke-boots a clone, then templates it |
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
    └── VM (clone of 9003)   — arm64 PVE node under test (Pi OS), fresh each build
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

Clones template 9003 by default (latest Raspberry Pi OS Lite arm64, the real Pi 5 base OS, no PVE); `TEMPLATE_ID=9002` runs against the vanilla Debian Trixie baseline instead. Runs under **full QEMU ARM64 emulation — no KVM acceleration**. No Pi 5 or separate arm64 hardware needed.

PVE is **installed by the script** during the CI run (`restore-1-install.sh` Step 0 installs pxvirt and reboots) — this tests the full arm64 install path from scratch.

Full QEMU emulation means arm64 pipelines run **3–5× slower** than x86_64.

Since every arm64 run installs the *latest* pxvirt and pipbs packages, these jobs are also the early warning for drift between the two community repos. Example: on 2026-11-19, pipbs PBS 4.2.11-1 could only be installed by removing `proxmox-ve`, so `pve-apt-hook` aborted the "Install tools" stage. `restore-1-install.sh` now dry-runs the PBS install. If no pipbs version keeps PVE, it installs the self-hosted fallback debs (see the main README).

The "Install tools" stage then reads `/root/.pbs-arm64-fallback` on the CI VM:
- **No marker:** green.
- **Marker present:** **UNSTABLE**.
- **Marker present for more than 30 days** (since `PBS_ARM64_FALLBACK_SINCE`): **FAILURE**. Then check pxvirt and pipbs, and either bump the fallback or drop it.

| Node | Role | Access method |
|---|---|---|
| LXC 200 | Jenkins agent, pipeline executor | — |
| VM (clone of 9001) | x86_64 PVE node under test | SSH |
| VM (clone of 9003) | arm64 PVE node under test (QEMU-emulated, Pi OS) | SSH |

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
- **Host extras** come back: Scenario A runs `ci/setup-extras-fixture.sh` before the config backup. That builds an nginx reverse proxy on `:8081` in front of a helper service, removes nginx's default site, persists a NAT rule for TEST-NET-2 (`198.51.100.0/24`) with iptables-persistent, and adds a sysctl drop-in (`log_martians=1`). The matching `EXTRA_*` values are in `config_ci*.env`. After the DR the spec checks:
  - both packages are installed
  - `curl :8081` returns the helper's marker
  - `sites-enabled/default` is **absent**, which shows the paths were restored after the package install
  - the NAT rule is loaded
  - the sysctl value is applied
  - all three services are enabled

  A DR job therefore needs a Scenario A run *with the fixture* before it, on the same arch.

*Gotcha:* the DR jobs' "Stage local config tar" step used to pick `pve-config-*.tar.gz`. That matched a stale **unencrypted** `pve-config-2026-03-27.tar.gz` left over from before encryption was introduced; the tarball prune only handles `.enc` files. So until 2026-11-22 every DR run restored a March `config.db`, and never exercised the decryption path in restore-2. The new host-extras specs caught it (#62/#63/#69). The step now takes the newest `.tar.gz.enc` and fails if it is more than 2 days old.

### Restore pairing (`ci/spec/restore_pair_spec.sh`)

The DR jobs also run this unit spec for `lib/restore-pair.sh`, the date pairing that `restore-2-auth.sh` uses to restore a config tarball and a restic snapshot from the **same** day. It covers:
- the normal case
- a night where restic failed (the newest tarball has no snapshot)
- a night where the config backup failed
- an old pair that is still the newest possible one
- no pair at all (must fail)
- a forced `RESTORE_DATE`
- choosing the newest snapshot of the day

**End to end (`ci/spec/restore_pairing_e2e_spec.sh`)** runs in a stage before the real DR. `restore-2-auth.sh` runs with `RESTORE_PLAN_ONLY=1`. It does real GDrive downloads, real decryption, real extraction with pve-cluster restarts, and a real restic snapshot list, then stops before PBS is touched, so each scenario takes seconds.

`ci/pairing-fixture.sh` builds scratch folders `<config folder>_pairtest_{normal,newer,old}` from the newest real tarball D0. The "newer" folder adds a re-packed copy dated D0+1 with markers.

The scenarios:
- Path B, normal night
- the newest tarball has no snapshot: it switches back to D0. `profiles.yaml` must keep the newest tarball's marker (credentials kept), and `config.env` must lose its marker (config from D0)
- no pair, CI: refuses
- `RESTORE_DATE`, valid and without a snapshot
- Path A: normal, and a date without a snapshot
- Path A with `RESTORE_DATE` different from the local tarball
- interactive `mismatch`, and any other answer, which aborts
- no password file: the password is read from stdin, and a wrong one fails cleanly

A failing scenario fails the build, but the full DR still runs (`catchError`). The scratch folders are purged after the stage, in `post`, and again at the start of the next setup.

The full DR run then exercises the normal Path A end to end. Its log shows `=== Restore pair: config <date> + restic snapshot <id> ===`.

### Cleanup: stale restic locks

Each Scenario A job ends with `restic unlock` followed by `forget --keep-last 1 --prune` on its GDrive CI repo. If that fails, the build is marked **UNSTABLE**. It used to end in `|| true`. A run that was aborted on 2026-09-14 left a lock in the arm64 repo. A stale non-exclusive lock doesn't block backup or restore, so every job stayed green, but every prune failed. By 2026-11-21 the repo had 73 snapshots and 3 GiB that should have been pruned. `unlock` without `--remove-all` only removes locks restic itself considers stale: a dead PID on the same host, or a lock not refreshed for 30 minutes. A running restic refreshes its lock every 5 minutes, so it is never affected, even though the cleanup in `post {}` runs after the Jenkins lock is released. One caveat: every arm64 CI VM is called `arm64-ci`, and every x86 one shares a hostname too. restic would therefore treat a live lock from *another* CI VM as stale if that PID doesn't exist locally. That is safe only because a job runs restic exclusively inside its locked `Run` stage. While one job's cleanup runs, the next job can at most be cloning and booting its VM. Keep `unlock` out of anywhere that can overlap another job's `Run`. The production `backup-restic-vms.sh` runs the same `unlock` before its nightly forget.

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

### Where things run

Each machine has one role. Keep it that way:

| Machine | Role | Never |
|---|---|---|
| **Jenkins** | Orchestration only: runs the pipelines and streams artifacts between machines | Dev tooling or image work on the Jenkins host itself |
| **CI builder VM** (VM 9020, `ci-builder`) | All disk-image work: downloading OS images, loop-mounting, swapping boot layers, writing seed files, arm64 `qemu-user` chroots | — (it is disposable, so any tool may be installed here) |
| **PVE host** | `qm` operations only: import a finished disk, clone, start, stop, template, destroy. Test and debug VMs are fine | Loop-mounting or modifying images, running build scripts by hand, installing packages |

The builder is **persistent and always on** (`onboot=1`), so using it is just an `ssh`. It is also **disposable**: nothing on it is precious, and it can be destroyed and recreated at any time:

```bash
# on the PVE host (qm only):
FORCE=1 EXTRA_PUBKEYS="$(cat ~/.ssh/id_ed25519.pub)" bash ci/setup-builder-vm.sh
# from any machine with SSH access to it:
ssh root@<builder> bash -s < ci/provision-builder.sh
```

`provision-builder.sh` is idempotent: re-run it to bring the tool set up to date.

Today only the Pi OS template (9003) is built on the builder. Templates 9001/9002 still download their cloud image onto the PVE host's ISO storage and are due to move to the builder too.

### arm64 dependency check (L2)

`ci/check-arm64-deps.sh` runs nightly on the CI builder VM through `proxmox-ci-arm64-deps`. It answers in about two minutes what a fully emulated DR run needs 30 to find: can the *current* pxvirt PVE and pipbs PBS still be installed together on the *current* Raspberry Pi OS?

- **Root filesystem:** the latest Pi OS Lite image from the builder cache, the same one template 9003 is built from. It is mounted read-only, with a throw-away tmpfs overlay on top, so nothing is ever written to the image.
- **Execution:** an arm64 chroot via `qemu-user` (binfmt). It boots no VM and takes no `ci-vm-arm64` lock.
- **Repositories:** added through `lib/arm64-repos.sh`, the same file `restore-1-install.sh` sources. The check cannot drift from what a real install uses.
- **What it runs:** apt only *simulates*:
  1. `dist-upgrade`;
  2. installing PVE;
  3. installing PVE together with the latest pipbs PBS;
  4. if step 3 conflicts, installing PVE together with the self-hosted fallback debs.
  A simulation fails if it does not resolve, or if it would remove a PVE package.
- **Result:** green when the latest of both install together, **UNSTABLE** when only the PBS fallback works, red otherwise.

The job runs this for **both** PVE sources, pxvirt and official, and its result is the worse of the two; the build description shows both. The first runs on 2026-11-21 gave pxvirt yellow (PBS fallback needed) and official green: official ships `proxmox-mail-forward` 1.1.0, so the latest pipbs PBS installs with no fallback.

It would have flagged the 2026-11 pipbs 4.2.11-1 clash (`Breaks: proxmox-mail-forward (<< 1.1.0)`, while pxvirt ships 1.0.2) the same night it appeared. apt's own solver output in the log names the conflicting packages.

### VM Templates

Both pipeline families clone a fresh VM from a template for each build and destroy it afterwards. Two templates are needed on the x86_64 PVE host:

| Template ID | Name | Used by | Base OS | PVE pre-installed | Script |
|---|---|---|---|---|---|
| 9001 | `restore-test-ci` | x86_64 pipelines | Debian Bookworm x86_64 | Yes | `ci/setup-x86-template.sh` |
| 9002 | `arm64-restore-ci` | arm64 pipelines (default) | Debian Trixie arm64 | No (installed by CI) | `ci/setup-arm64-template.sh` |
| 9003 | `arm64-pios-restore-ci` | arm64 pipelines (**default**) | **Latest Raspberry Pi OS Lite arm64** (boot layer swapped) | No (installed by CI) | `ci/build-pios-disk.sh` (builder) + `ci/setup-arm64-pios-template.sh` (PVE, qm only) |

**Why the difference?** x86_64 PVE installs cleanly from official repos so it's baked into the template. For arm64, installing pxvirt (the community ARM64 PVE port) is exactly what we want to test, so the template starts as plain Debian and `restore-1-install.sh` Step 0 installs pxvirt during the CI run.

Neither template has PBS pre-installed — `restore-1-install.sh` installs it as part of every test run.

**Template 9001 (x86_64):** Run once on the x86_64 PVE host:

```bash
./ci/setup-x86-template.sh
```

Downloads a Debian Bookworm x86_64 cloud image, creates a VM with a 16 GB OS disk and a 4 GB PBS data disk, installs Proxmox VE via SSH, then converts to template.

The OS disk is `scsi0` and the PBS data disk is `scsi1`. Never address them as `/dev/sda` / `/dev/sdb`: the kernel doesn't guarantee sdX order between the two, and on 2026-11-01 `scsi1` came up as `sda`. That broke the template refresh (grub-pc was preseeded to install onto the empty data disk) and the backup pipeline (it tried to format the OS disk). The template script, `config_ci.env` and the pipelines' *Prepare disk* stage resolve them through `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0` / `...-drive-scsi1` instead. The arm64 config already detects the data disk dynamically.

**Template 9002 (arm64):** Run once on the x86_64 PVE host:

```bash
./ci/setup-arm64-template.sh
```

This installs AAVMF arm64 UEFI firmware, downloads a vanilla Debian Trixie arm64 cloud image, creates a QEMU VM with `--arch aarch64` for full emulation, and converts it to a template. No Pi 5 or separate arm64 hardware required.

**Template 9003 (arm64, Raspberry Pi OS):** built weekly by `proxmox-ci-template-refresh-arm64-pios` (`ci/Jenkinsfile.template-refresh-arm64-pios`, Sundays ~05:00, after 9002).

*Why it exists.* The real Pi 5 runs Raspberry Pi OS, not plain Debian. Pi OS has its own apt repo (`archive.raspberrypi.com`), whose packages win over Debian's, and different defaults (cloud-init NoCloud seed in `/boot/firmware`, netplan + NetworkManager instead of ifupdown). Template 9002 tests none of that. A real disaster recovery starts from the *latest* Pi OS Lite image, so that is what 9003 is built from, every week.

*What is swapped, and only that.* The Pi kernel has no virtio or generic PCI host support, so it cannot see a disk or NIC on QEMU `virt`. `ci/build-pios-disk.sh` keeps the Pi OS image as it is: userland, apt sources, partition layout and the Pi kernels themselves. It adds only these:
- Debian's arm64 **cloud** kernel, initrd and modules. This is the same kernel 9002 runs PVE/PBS/LXC on.
- A standalone GRUB EFI binary on the FAT partition that boots that kernel.
- The NoCloud seed files, written the way Raspberry Pi Imager writes them.

The disk is built on the **CI builder VM** (see *Where things run*). The PVE host only imports the finished qcow2 (`ci/setup-arm64-pios-template.sh`, qm only).

*Gotcha:* the seed sets `manage_etc_hosts: true`, so cloud-init rewrites `/etc/hosts` on every boot. Once PVE is installed that breaks the next reboot: pmxcfs can't resolve the node name, `/etc/pve` stays empty, and root's `authorized_keys`, a symlink into `/etc/pve/priv/`, points nowhere. SSH then answers `Permission denied (publickey)` (backup-arm64 #307). A real Pi flashed with Raspberry Pi Imager has the same seed, so this was a real DR bug. The "Fix pve-cluster" stage used to patch `/etc/hosts` itself and so hid it. Build #309 confirmed it was not a network problem: after the reboot, the same MAC and the same host key answered on the CI IP, and they refused the key. It also showed that a `manage_etc_hosts: false` drop-in in `cloud.cfg.d` is not enough, because the seed's user-data overrides it.

The fix is in the product, not in CI. When `restore-1-install.sh` installs PVE, it maps the node name to `PVE_IP` in `/etc/hosts` and disables cloud-init completely (`/etc/cloud/cloud-init.disabled`). From then on PVE is the only thing that manages hostname, hosts and network. `migrate-arm64-pxvirt-to-official.sh` refuses to run if the node name doesn't resolve to a local IP that survives a reboot. On the cabin Pi, the entry lives in cloud-init's hosts template, which counts.

The CI stages no longer repair anything. After each reboot they only check that pve-cluster comes up, without restarting it. To keep a broken host diagnosable, CI adds one piece of instrumentation: a second `authorized_keys` outside `/etc/pve` (`/etc/ssh/ci_authorized_keys`). If the bug comes back, Jenkins can still log in and print `/etc/hosts` and the pve-cluster journal, instead of seeing a VM that looks gone.

*Gotcha:* Pi OS renders netplan through **NetworkManager**, which does not support `match: driver:`. With a driver match, cloud-init's whole init-local stage crashes and neither the IP nor the SSH key is applied; the VM silently falls back to DHCP. The seed therefore names the NIC explicitly (`enp0s18`, which follows from the VM's PCI layout).

*Gotcha 2:* Pi OS keeps its swap file on a **loop device** (`rpi-swap`), and `lsblk` lists `loop0` first. The old "first disk that isn't the root disk" detection picked that 2 GB swap loop as the PBS data disk. The arm64 pipelines and `config_ci_arm64.env` now resolve the data disk through its stable name `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1`, like x86 does. `restore-1-install.sh` also refuses loop, zram and optical devices, active swap, and a partition without a filesystem UUID. The real configs (`config_rpi5.env`, `config_x86_standard.env`) name their partition explicitly and were never affected.

In test-automation terms this is a virtual-ECU **L3** setup: production base software with only the hardware-specific boot layer abstracted. The boot chain (Pi firmware, Pi kernel, RP1 NIC, NVMe boot) is not covered and needs a manual test on real hardware.

*Smoke test before templating.* The job boots a throwaway clone (VM 9198) and checks that it reached a Pi OS userland, that the swapped kernel is running, the Pi apt source is present, cloud-init finished, network/DNS/apt work and `/boot/firmware` is mounted. Only then does it run `qm template 9003`, so a broken image never becomes the template.

*PVE source.* Both arm64 pipelines also take `PVE_ARM64_SOURCE`:
- `pxvirt` (default) is the community port the cabin runs today.
- `official` is Proxmox's own arm64 build, PVE 9.2+.

PBS comes from pipbs either way, because there is no official PBS arm64 build. On the official source, `proxmox-ve` pulls in `proxmox-default-kernel`. A Pi keeps booting its own rpi kernel regardless: Pi OS's `z50-raspi-firmware` kernel and initramfs hooks only copy `*-rpi-*` kernels to `/boot/firmware`, and they skip any other kernel with "Unsupported kernel version".

*Upgrade path.* With `MIGRATE_TO_OFFICIAL=true` (requires `PVE_ARM64_SOURCE=pxvirt`), the arm64 backup pipeline tests the cabin's migration:
1. Install with pxvirt.
2. Reproduce the cabin's `proxmox-widget-toolkit` hold and guest autostart.
3. Create the test LXC and back it up.
4. Run `migrate-arm64-pxvirt-to-official.sh` as a dry run, and fail if `/etc/apt` changes at all.
5. Run it with `--apply`, then reboot.
6. Run Scenario A plus `ci/spec/migration_spec.sh`. That spec checks PVE 9.2+, no lierfang source, the official repo, no held proxmox packages, the newest PBS (no fallback), `/etc/network/interfaces` unchanged, pve-cluster active, the pre-migration PBS backups still listed, and LXC 100 running.

*Using it.* Both arm64 pipelines take a `TEMPLATE_ID` build parameter. `9003` is the default since 2026-11-21 and is used by the scheduled runs; the first full Pi OS DR run passed 7/7. `9002` is the Debian comparison baseline. Its weekly refresh keeps running until 9003 has proven stable, then it can be retired.

### Golden image (`proxmox-ci-golden-image-arm64`, Saturdays ~06:00 UTC)

`ci/Jenkinsfile.golden-image-arm64` builds the **generic** golden DR image for a Pi 5 and publishes it only if a full DR on it passes:

1. **Build** (`ci/build-golden-image.sh`, on the builder):
   - Start from the latest Pi OS Lite. Its own Pi boot chain stays untouched; the build checks that `cmdline.txt` and `config.txt` are unchanged.
   - In a qemu-user chroot, install official PVE + pipbs PBS + restic/rclone/resticprofile, using the same repo code as `restore-1-install.sh` (`lib/arm64-repos.sh`). ZFS DKMS is prebuilt if `proxmox-ve` pulls it in. The repo is copied to `/opt/proxmox-pbs-gdrive`.
   - The chroot runs in its own UTS namespace with hostname `raspberrypi`, so no package records the builder's name.
   - Generalize: remove SSH host keys, `/root/.ssh`, `machine-id`, PVE/PBS keys, pmxcfs data, cloud-init state, logs and history.
2. **Leak gate** (`ci/golden-leak-gate.sh`) fails the build on any of:
   - forbidden files: host keys, `.ssh` contents, PVE/PBS keys, `config.db`, `config.env`, rclone/restic secrets, cloud-init instances, a non-empty `machine-id`
   - forbidden content in `etc`, `root`, `home`, `opt`, `srv`, `usr/local`, `var/lib` or `boot`: private keys, SSH public keys, OAuth/API tokens, non-comment private IPs, the builder's hostname/IPs
   - credentials in the boot seed

   It was tested locally against a clean and a deliberately dirty fixture: no false positives, and all 10 planted leaks caught.
3. **Test copy → template 9004:** `ci/build-pios-disk.sh` runs with `BASE_IMG=golden.img SKIP_PREP=1 OUT_NAME=golden-test TEMPLATE_ID=9004`. It applies the same boot-layer swap and CI seed as 9003, to a copy only. `ci/setup-arm64-pios-template.sh` takes `TEMPLATE_ID`/`TEMPLATE_NAME`.
4. **Full DR** = `proxmox-ci-dr-arm64` with `TEMPLATE_ID=9004 PVE_ARM64_SOURCE=official`, and it must be SUCCESS. `restore-1` takes the golden path: PVE is preinstalled, so it configures the node only. Then restore-2/3, the pairing scenarios and Scenario B run.
5. **Publish** (`ci/publish-golden-image.sh`, on the builder) writes `golden-<date>.img.xz`, `rootfs-`/`bootfs-<date>.tar.zst`, `golden.env` and `SHA256SUMS` to `gdrive:bu/golden-image/<date>_<commit>/`. It verifies the upload with `rclone check` before pruning to the newest 3. Jenkins hands the builder a temporary `rclone.conf` and deletes it in `post`.

Not covered by QEMU: the Pi's own boot chain on real hardware (firmware, EEPROM, rpi kernel). That is the spring hardware test.

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
