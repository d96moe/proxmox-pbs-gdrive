# proxmox-pbs-gdrive

> **⚠️ HOBBY PROJECT — USE AT YOUR OWN RISK**
>
> This is a personal homelab project built for two reasons: to have a reasonable backup safety net at home, and to have fun exploring what Claude Code can do as a coding assistant. The scripts, the CI pipelines, the tests, and yes — this README — were all written with Claude Code assistance. It is not production software, has no guarantees, and comes with no support. The scripts work on my hardware — they may or may not work on yours. If you use this and lose data, that's on you.
>
> A real-world disaster recovery using this setup has never actually been performed. To compensate for that, a fairly advanced automated test environment has been implemented: Jenkins pipelines run both the full backup scenario and a complete end-to-end disaster recovery restore on a nested virtualized Proxmox instance, with ShellSpec integration tests verifying the end state. It's as close to the real thing as you can get without actually pulling the plug — but it's still not the same as having done it for real.
>
> This README also serves as personal documentation — a reference for how everything is set up, why decisions were made the way they were, and what to do when something breaks. If it reads like it's written for an audience of one, that's because it largely is.

## Contents

- [Why This Exists](#why-this-exists)
- [What You Get](#what-you-get)
- [Pros and Cons](#pros-and-cons)
- [How It Works](#how-it-works)
- [Supported Platforms](#supported-platforms)
- [Repository Layout](#repository-layout)
- [Configuration Reference](#configuration-reference)
- [Setup](#setup)
- [Fresh Installation](#fresh-installation)
- [Disaster Recovery](#disaster-recovery)
- [Backup Schedule and Retention](#backup-schedule-and-retention)
- [Verify Backup Health](#verify-backup-health)
- [Troubleshooting](#troubleshooting)
- [Notes](#notes)
- [CI & Testing](#ci--testing)

---

## Why This Exists

If you run a homelab Proxmox node and want proper offsite backups — but you only have one physical machine — you have a problem: there's nowhere local to send backups that isn't at risk alongside the hardware itself.

This repo solves that by pairing [Proxmox Backup Server (PBS)](https://www.proxmox.com/en/proxmox-backup-server) with Google Drive as the offsite destination:

- **PBS** handles fast, incremental, deduplicated VM/LXC snapshots locally
- **restic + rclone** push the full PBS datastore to Google Drive nightly
- **A nightly config tarball** backs up everything needed to recover on new hardware: PVE cluster database, Google Drive credentials, restic password

The result is a setup where a hardware failure means: buy new hardware, run three scripts, wait for the download, done. All VMs and LXCs are back, exactly as they were.

## What You Get

After running these scripts, your Proxmox node will have:

- PBS running on a dedicated partition, backing up all VMs/LXCs nightly
- Automated offsite backups to Google Drive via restic (nightly, incremental after the first)
- Nightly config tarball to Google Drive containing everything needed for a bare-metal restore
- Retention configured at both layers (local PBS + Google Drive)
- A tested disaster recovery path — just follow Scenario B

Everything is driven by shell scripts and a single `config.env` file. Two main scenarios:

- **Scenario A — Fresh setup:** install PBS, wire up Google Drive, start nightly backups
- **Scenario B — Disaster recovery:** restore a failed node from Google Drive to full running state

Supports **x86_64** (standard Proxmox VE) and **aarch64** (Raspberry Pi 5, community ARM64 builds).

---

## Pros and Cons

| | |
|---|---|
| ✅ Single machine | No second server or NAS needed for offsite backups |
| ✅ Real cloud backup | Google Drive is genuinely offsite — survives fire, theft, flood alongside the hardware |
| ✅ Recover from anywhere | Internet access + new hardware = full recovery |
| ✅ Self-contained restore | Config tarball carries credentials and PVE config — no manual rclone/restic setup on new hardware |
| ✅ PBS deduplication | Local backups fast and space-efficient; only changed blocks stored |
| ✅ restic incremental to GDrive | After first upload, only the diff is sent nightly |
| ⚠️ No built-in UI for GDrive backups | restic is CLI-only; no PVE interface for managing Google Drive snapshots — see [proxmox-backup-gui](https://github.com/d96moe/proxmox-backup-gui) for a companion web dashboard that covers this |
| ❌ No single-VM restore from GDrive | restic backs up the full PBS datastore as a unit — to recover one VM you must restore the entire datastore first |
| ❌ First backup is slow | Initial upload is the full PBS datastore — can take many hours |
| ❌ Full disaster recovery takes hours | Downloading the entire datastore from GDrive is not quick |
| ❌ GDrive quota | Base usage mirrors PBS datastore size; retention keeping multiple snapshots adds on top |

**Real-world storage examples:**

| Setup | VMs | LXCs | PBS on disk | GDrive actual (5 snapshots, deduplicated) |
|---|---|---|---|---|
| x86_64 homelab | 4 (Windows, macOS, Linux, HA OS) | 8 (services, automation, databases, utilities) | 275 GB | ~423 GiB |
| Pi 5 remote node | 2 (HA OS, Linux) | — | 17 GB | ~17 GiB |

Note that restic backs up the **entire PBS datastore** as a unit — not individual VMs. PBS has already deduplicated and chunked everything, so the datastore is compact. In practice, GDrive usage will be somewhat larger than the local PBS datastore even with the same number of snapshots — restic's snapshots capture the datastore at different points in time and may hold chunks that PBS has since pruned locally. The x86_64 numbers show 275 GB local vs 423 GiB on GDrive with 5 snapshots in each — but either way, far less than storing 5 full uncompressed copies would cost.


---

## How It Works

```
Proxmox VE (nightly at 02:00)
    └── PBS backup → /mnt/pbs  (dedicated partition)

backup-restic-vms.sh (nightly at 02:30, waits for PBS backup to finish)
    ├── 1. wait until PBS backup task completes (polls every 30s, max 4h)
    ├── 2. run PBS prune job   → removes old PBS snapshots per retention policy
    ├── 3. stop PBS            → consistent on-disk state for restic
    ├── 4. restic backup       → rclone → Google Drive
    ├── 5. restic forget/prune → apply cloud retention policy
    └── 6. start PBS again

backup-pve-config.sh (nightly at 04:00)
    └── config.db + rclone auth + restic password → Google Drive
            └── this tarball is what makes Scenario B self-contained
```

- **[Proxmox Backup Server (PBS)](https://www.proxmox.com/en/proxmox-backup-server)** stores incremental, deduplicated VM/LXC snapshots locally on `/mnt/pbs`
- **[restic](https://restic.net/)** snapshots the full PBS datastore to Google Drive nightly via **[rclone](https://rclone.org/)** — PBS is stopped during the snapshot to ensure a consistent on-disk state. PBS's chunk store has strict write-ordering requirements (chunks must exist before the index referencing them is written), and any tool that syncs the datastore while PBS is running risks producing a corrupted copy. Stopping PBS before restic reads the datastore avoids this entirely. Each restic snapshot is tagged with the exact PBS snapshot IDs it contains (e.g. `ct-104-1775554738`, `vm-100-1775554738`), allowing [proxmox-backup-gui](https://github.com/d96moe/proxmox-backup-gui) to match cloud snapshots back to specific VMs without ambiguity.
- **[resticprofile](https://creativeprojects.github.io/resticprofile/)** manages the restic schedule, retention config, and forget rules
- **config tarball** backs up everything needed to recover on new hardware: PVE cluster database, rclone OAuth token, restic password, network config

> The config tarball is what makes disaster recovery hands-free — it contains the credentials to reach Google Drive and the password to decrypt backups. No manual rclone/restic reconfiguration needed on new hardware.

---

## Supported Platforms

| Component | x86_64 standard | Raspberry Pi 5 (aarch64) | Links |
|---|---|---|---|
| <img src="https://cdn.simpleicons.org/proxmox" height="20"> Proxmox VE | 9.1.4 | 9.0.10-2 (pxvirt) | [proxmox.com](https://www.proxmox.com/en/proxmox-virtual-environment) · [pxvirt (arm64)](https://download.lierfang.com/pxcloud/pxvirt) |
| <img src="https://cdn.simpleicons.org/proxmox" height="20"> PBS | 4.1.4-1 (official) | 4.1.4-1 (pipbs) | [proxmox.com](https://www.proxmox.com/en/proxmox-backup-server) · [pipbs (arm64)](https://github.com/dexogen/pipbs) |
| <img src="https://cdn.simpleicons.org/rclone" height="20"> rclone | 1.73.1 | 1.73.2 | [rclone.org](https://rclone.org/) |
| <img src="https://restic.net/apple-touch-icon-144-precomposed.png" height="20"> restic | 0.18.0 | 0.18.0 | [restic.net](https://restic.net/) |
| <img src="https://creativeprojects.github.io/resticprofile/images/logo.png" height="20"> resticprofile | — | — | [creativeprojects.github.io](https://creativeprojects.github.io/resticprofile/) |
| <img src="https://www.debian.org/logos/openlogo-nd-100.png" height="20"> Debian (base) | included via PVE installer | Raspberry Pi OS Lite 64-bit (Trixie), installed before PVE | [debian.org](https://www.debian.org/) · [Raspberry Pi OS](https://www.raspberrypi.com/software/operating-systems/) |
| <img src="https://www.raspberrypi.com/app/uploads/2022/02/COLOUR-Raspberry-Pi-Symbol-Registered.png" height="20"> Hardware | Any x86_64 with NVMe | Pi 5 8GB + NVMe (tested via USB adapter) | [Raspberry Pi 5](https://www.raspberrypi.com/products/raspberry-pi-5/) |

> **Why Proxmox on a Pi 5?** The specific use case here is a small remote location with minimal IT infrastructure: running **Home Assistant** and a full **Unifi OS** instance side by side. Unifi OS is needed specifically for site-to-site VPN ("site magic") — this is not supported by the Unifi Network add-on in Home Assistant and requires a real Unifi OS server. A Pi 5 running Proxmox VE covers both on a single low-power device: HA and Unifi OS each get their own LXC/VM, no separate hardware needed.

> ⚠️ **Do NOT run this from an SD card.** Proxmox VE's write patterns (journals, VM disk I/O, PBS chunk store) will destroy an SD card quickly. You need an SSD. The setup this repo was built on uses a Pi 5 booting from an NVMe drive connected via USB adapter — cheap and works well.

> ⚠️ **ARM64 only:** PBS on arm64 always comes from pipbs, a community project. PVE comes either from pxvirt (community, the default) or from Proxmox's official arm64 repo (see below). With pxvirt, the two must have compatible API versions — a mismatch can cause GUI rendering issues and other instability. `restore-1-install.sh` checks versions from both repos **before installing anything** and automatically pins whichever package is ahead to a matching older version if needed. Before running `apt upgrade`, always verify both repos are at the same API version first:
> ```bash
> apt-cache policy proxmox-ve proxmox-backup-server | grep -A1 "Candidate:"
> dpkg -l proxmox-ve proxmox-backup-server | awk '/^ii/{print $2, $3}'
> ```
> If only one repo has a new version, wait for the other to catch up.
>
> A matching API version is not enough on its own: a new pipbs release can still pull dependencies that conflict with the installed pxvirt PVE, so apt "solves" it by **removing `proxmox-ve`/`pve-manager`**. `pve-apt-hook` blocks that, and the install fails. So before installing PBS, `restore-1-install.sh` dry-runs `apt-get -s install proxmox-backup-server`. If that would remove a PVE package, or doesn't resolve, the script tries these in order:
> 1. the newest older pipbs version still in its index (pipbs usually keeps only the latest);
> 2. **self-hosted fallback debs**: a known-good PBS version kept as a [GitHub release](https://github.com/d96moe/proxmox-pbs-gdrive/releases/tag/pbs-arm64-4.2.1-1) of this repo, with sha256 checksums pinned in the script (`PBS_ARM64_FALLBACK_*`). The fallback is installed and then held with `apt-mark hold`.
>
> Every install tries the latest pipbs first, so it switches back automatically once pxvirt catches up. A *real* restore never fails because the fallback is old. In CI, an arm64 build that used the fallback is marked **UNSTABLE**, and it **fails** once the fallback has been in use for more than 30 days (`PBS_ARM64_FALLBACK_SINCE`). That way it can't be forgotten.
>
> Why a self-hosted copy: pipbs deletes old versions, and the only other copy of a working version is the Pi's own apt cache. That copy disappears in exactly the disaster these scripts are for.
>
> Example: in 2026-11, pipbs 4.2.11-1 declared `Breaks: proxmox-mail-forward (<< 1.1.0)`, but pxvirt only ships 1.0.2, which `pve-manager` depends on. The fallback is 4.2.1-1, the version the cabin Pi runs. After pxvirt catches up, run `apt-mark unhold proxmox-backup-server proxmox-backup-docs` on a host that got the fallback.
>
> **Official Proxmox arm64:** since PVE 9.2 (2026-08), Proxmox ships an official arm64 PVE. There is still no official arm64 PBS. Set `PVE_ARM64_SOURCE="official"` in `config.env` to install PVE from Proxmox's own repo instead of pxvirt; PBS still comes from pipbs. Official PVE ships `proxmox-mail-forward` 1.1.0, which removes the pipbs 4.2.11 conflict described above. Validate it in CI before switching a real host.
>
> **Migrating an existing pxvirt host:** `migrate-arm64-pxvirt-to-official.sh` handles the move. By default it is a dry run that changes nothing: it simulates the full-upgrade against the official repos through a private apt configuration, then reports the versions, removals, kernel side effects, holds and any pxvirt-only packages that would be left behind.
>
> `--apply --on-site` performs the migration:
> 1. vzdump of every guest to PBS, plus a tarball of `/etc/pve`, `/etc/network/interfaces` and `/etc/apt`;
> 2. swap the sources from pxvirt to the official repo;
> 3. release the `proxmox-widget-toolkit` hold and the PBS fallback holds;
> 4. `full-upgrade`, keeping existing config files;
> 5. verify PVE is 9.2+ and `/etc/network/interfaces` is unchanged.
>
> It refuses to run remotely, because the upgrade replaces the network stack. It also refuses, already in the dry run, if the node name doesn't resolve to a local non-loopback IP that survives a reboot. On Raspberry Pi OS, cloud-init rewrites `/etc/hosts` from `/etc/cloud/templates/hosts.debian.tmpl` on every boot, so the entry must be in that template, unless cloud-init is disabled. Without it, pve-cluster fails after the reboot, and root's key login, which lives in `/etc/pve`, stops working. The whole path is tested in CI first (`MIGRATE_TO_OFFICIAL=true` on the arm64 backup pipeline).
>
> **Bluetooth** must keep working. The Pi 5 BT firmware ships in `bluez-firmware`, which official PVE's `pve-firmware` does not replace. The dry run refuses to continue if `bluez`, `bluez-firmware`, or the package owning the currently loaded BT firmware would be removed. After the reboot, run `--post-check` while still on site. It verifies PVE 9.2+, the Raspberry Pi kernel, pve-cluster, PBS, the network config and default route, that all previously running guests run again, that `hci0` is UP with the same BT firmware loaded, and (on a real Pi) that the bootloader EEPROM config is unchanged, `BOOT_ORDER` includes the disk the root filesystem is on, and the bootloader is not older than before. A wrong boot order would otherwise only surface at the next cold boot after a power cut, when nobody is on site. A pending EEPROM update is shown for information only; flashing it is a separate on-site step.
>
> On an existing ARM64 host, run the same dry-run before upgrading PBS:
> ```bash
> apt-get -s install proxmox-backup-server | grep '^Remv'   # must print nothing
> ```

---

## Repository Layout

```
proxmox-pbs-gdrive/
├── restore-1-install.sh      # Setup step 3: install PBS, rclone, restic, resticprofile
├── restore-2-auth.sh         # DR step 5: restore rclone auth + PVE config from GDrive
├── restore-3-pve.sh          # Fresh step 6 / DR step 6: wire PBS into PVE
├── config.env.example        # Template — copy to config.env and fill in your values
├── migrate-arm64-pxvirt-to-official.sh  # arm64: move a pxvirt PVE host to official Proxmox arm64 (dry run by default)
├── lib/
│   └── arm64-repos.sh        # Shared arm64 repo definitions (pxvirt, pipbs, PBS fallback), sourced by restore-1 and the CI dependency check
├── scripts/
│   ├── backup-pve-config.sh  # Daily PVE config backup (config.db, /etc/pve, rclone token, etc.)
│   │                         # Installed to /usr/local/bin/ by restore-1-install.sh
│   │                         # Runs as systemd service (pve-config-backup.timer)
│   └── backup-restic-vms.sh  # Nightly restic backup of PBS datastore to GDrive
│                             # Installed to /usr/local/bin/ by restore-3-pve.sh
│                             # Runs as systemd service (restic-backup.timer)
└── ci/                       # CI pipeline — not needed for normal use
    ├── Jenkinsfile.*         # Jenkins pipeline definitions
    ├── config_ci*.env        # CI-specific config templates
    ├── setup-*-template.sh   # VM template creation scripts (also re-run weekly by Jenkins to refresh the templates)
    └── spec/                 # ShellSpec integration tests
```

The two scripts under `scripts/` are **helper scripts installed onto your Proxmox host** by the main restore scripts — they are not CI-only. They run on a schedule after setup and are what keeps your backups going day-to-day.

---

## Configuration Reference

All configuration lives in `config.env`. Copy the template for your platform and fill in the values marked as required.

### PBS Datastore

| Variable | Default | Description |
|---|---|---|
| `PBS_PARTITION` | — | **Required.** Dedicated block device for PBS: a partition (`/dev/sda3`, `/dev/nvme0n1p4`), an LV (`/dev/pve/pbs-datastore`), a whole disk or an opened LUKS device. It must not be the root filesystem or a VM disk. Loop, zram, optical and swap devices are rejected. |
| `PBS_DATASTORE_NAME` | `local-store` | PBS datastore name (shown in GUI and used in API calls). |
| `PBS_DATASTORE_PATH` | `/mnt/pbs` | Mount point for the PBS partition. |

### PBS User & Auth

| Variable | Default | Description |
|---|---|---|
| `PBS_USER` | `backup@pbs` | PBS user that PVE uses to connect to PBS. |
| `PBS_USER_PASSWORD` | — | **Required.** Password for the PBS user. Set via `export PBS_USER_PASSWORD=...` or directly in config.env. |
| `PBS_TOKEN_NAME` | `pve-token` | Name of the API token created for the PBS user. |

### PVE Storage Integration

| Variable | Default | Description |
|---|---|---|
| `PVE_PBS_STORAGE_ID` | `pbs-local` | PVE storage ID for the PBS entry (shown in Datacenter → Storage). |

### Retention

| Variable | Default | Description |
|---|---|---|
| `PBS_RETENTION_LOCAL` | `keep-last=3,keep-daily=3` | PBS prune policy for local snapshots. Short retention — Google Drive handles long-term. |
| `RESTIC_RETENTION_KEEP_LAST` | `1` | restic: always keep at least this many snapshots regardless of age. |
| `RESTIC_RETENTION_KEEP_DAILY` | `3` | restic: keep one snapshot per day for this many days. |
| `RESTIC_RETENTION_KEEP_WEEKLY` | `2` | restic: keep one snapshot per week for this many weeks. |
| `RESTIC_RETENTION_KEEP_MONTHLY` | `3` | restic: keep one snapshot per month for this many months. |

### Restic / rclone / Google Drive

| Variable | Default | Description |
|---|---|---|
| `RESTICPROFILE_GDRIVE_REMOTE` | `gdrive` | rclone remote name — must match the name you give the remote in `rclone config`. |
| `RESTICPROFILE_GDRIVE_PATH` | `bu/proxmox_backup` | Google Drive path for the restic repository. |
| `RESTIC_PASSWORD_FILE` | `/etc/resticprofile/restic-password` | Path to the file containing the restic encryption password. |
| `CONFIG_ENCRYPT_PASSWORD_FILE` | `/etc/resticprofile/config-encrypt-password` | Path to the file containing the password used to encrypt config tarballs before upload to Google Drive. |

### PVE Config Backup

| Variable | Default | Description |
|---|---|---|
| `GDRIVE_CONFIG_FOLDER` | `proxmox_backup_config` | Google Drive folder where daily config tarballs are stored. |

Config tarballs are pruned automatically to match restic snapshot dates — every kept tarball has a corresponding restic snapshot to restore from, and no more.

### Host Extras (optional)

Anything the host needs that PVE/PBS don't bring along — for example a reverse proxy, a firewall/NAT rule, a sysctl drop-in or a small helper service — is lost in a DR unless you list it here. All three are space-separated; leave them empty if the host has none.

| Variable | Default | Description |
|---|---|---|
| `EXTRA_PACKAGES` | `""` | apt packages `restore-3-pve.sh` installs. It simulates first and refuses if apt would remove anything. |
| `EXTRA_CONFIG_PATHS` | `""` | Absolute files/dirs (at least two levels deep, no spaces) that `backup-pve-config.sh` adds to the nightly config tarball. A listed path that is missing gives a WARNING in the backup log. |
| `EXTRA_SERVICES` | `""` | systemd units `restore-3-pve.sh` enables and restarts last; the restore fails if one is not active. |

```bash
# Example: nginx reverse proxy + NAT rule + helper service
EXTRA_PACKAGES="nginx iptables-persistent"
EXTRA_CONFIG_PATHS="/etc/nginx /etc/iptables /etc/sysctl.d/99-ip-forward.conf /usr/local/bin/my-helper.py /etc/systemd/system/my-helper.service"
EXTRA_SERVICES="netfilter-persistent my-helper nginx"
```

On restore the paths are put back **exactly as backed up, after** the packages are installed — so package defaults that the original host didn't have (nginx's `sites-enabled/default` with `default_server` would shadow your own site on port 80) don't come back. The list used is the one in the restored `/etc/proxmox-backup-restore/config.env`, i.e. the one the backup was made with.

### Backup Schedules

Schedules use systemd calendar format (e.g. `02:00`, `Mon 03:30`). The recommended order ensures each job completes before the next starts:

| Variable | Default | Job |
|---|---|---|
| `PBS_BACKUP_SCHEDULE` | `02:00` | PVE runs vzdump of all VMs/LXCs to PBS |
| `RESTIC_BACKUP_SCHEDULE` | `02:30` | restic script: waits for PBS backup → PBS prune → restic backup + forget |
| `CONFIG_BACKUP_SCHEDULE` | `04:00` | Daily PVE config tarball uploaded to Google Drive |

> ℹ️ PBS prune is **not a separate timer** — `backup-restic-vms.sh` triggers the PBS prune job automatically after backup completes and before restic runs. This guarantees restic only snapshots the datastore after stale PBS snapshots are gone. The PBS prune job (`nightly-prune`) remains visible in the PBS GUI with its retention settings; its own schedule is a fallback only.
>
> All schedules are applied automatically by `restore-3-pve.sh`. The PBS backup job can be adjusted in the PVE GUI under Datacenter → Backup. To change the restic or config backup schedule, edit `/etc/systemd/system/restic-backup.timer` (or `pve-config-backup.timer`) and run `systemctl daemon-reload`. If you use [proxmox-backup-gui](https://github.com/d96moe/proxmox-backup-gui) as a companion dashboard, schedules can also be changed from its Settings modal.

### PVE Installation (aarch64 / Raspberry Pi 5 only)

These variables are only used by `restore-1-install.sh` on arm64 when Proxmox VE is not yet installed. They are ignored on x86_64.

| Variable | Default | Description |
|---|---|---|
| `PVE_HOSTNAME` | `proxmox` | Hostname for the Proxmox node. |
| `PVE_IP` | — | **Required.** Static IP with prefix length, e.g. `192.0.2.10/24`. |
| `PVE_GATEWAY` | — | **Required.** Default gateway, e.g. `192.0.2.1`. |
| `PVE_DNS` | `8.8.8.8` | DNS server. |
| `PVE_IFACE` | `eth0` | Ethernet interface name. Run `ip link` to find it (common: `eth0`, `enp2s0`). |
| `ROOT_PASSWORD` | — | Root password to set during install. Set via `export ROOT_PASSWORD=...` or directly in config.env. |

---

## Setup

Before starting, make sure you have a **Google account** with enough Drive space — roughly 1.5× your PBS datastore size.

Steps 1–3 are the same for both fresh installations and disaster recovery.

### Step 1: Install Proxmox VE and clone repo

**x86_64:**
1. Download and install Proxmox VE from https://www.proxmox.com/downloads
2. SSH in as root, then:

```bash
apt-get install -y git
git clone https://github.com/d96moe/proxmox-pbs-gdrive.git
cd proxmox-pbs-gdrive
cp config_x86_standard.env config.env
nano config.env
```

**aarch64 (Raspberry Pi 5):**

There is no Proxmox installer image for the Pi. You install Raspberry Pi OS first, and `restore-1-install.sh` installs Proxmox VE on top of it. Since PVE 9.2 Proxmox publishes an official arm64 PVE repo, but there is still no official arm64 PBS.

1. Flash **Raspberry Pi OS Lite (64-bit)** to the SSD with Raspberry Pi Imager, with SSH enabled. Use the Lite image, not Desktop. This is the base the CI tests run against.
2. SSH in as the user you created in Imager, become root (`sudo -i`), then:

```bash
apt-get install -y git
git clone https://github.com/d96moe/proxmox-pbs-gdrive.git
cd proxmox-pbs-gdrive
cp config_rpi5.env config.env
nano config.env   # set PVE_HOSTNAME, PVE_IP, PVE_GATEWAY, PVE_IFACE, PBS_PARTITION, PVE_ARM64_SOURCE
./restore-1-install.sh
```

`PVE_ARM64_SOURCE` selects where PVE comes from: `pxvirt` (default) or `official`.

The script sets hostname, configures the network bridge, adds the selected PVE repo, installs Proxmox VE, switches to the 4k kernel (required for PBS on Pi5), and reboots. Run it again after reboot to complete the install. GUI available at `https://<IP>:8006`.

> ⚠️ Do NOT run `apt upgrade` without checking for PVE/pipbs version conflicts first (see the ARM64 notes under [Supported Platforms](#supported-platforms)).

Fill in `config.env` — see [Configuration Reference](#configuration-reference) above. At minimum set `PBS_PARTITION`, `PBS_USER_PASSWORD`, `RESTICPROFILE_GDRIVE_REMOTE`, `RESTICPROFILE_GDRIVE_PATH`, and `GDRIVE_CONFIG_FOLDER`.

### Step 2: Create the PBS device

PBS needs its own block device: a partition or an LV. Size depends on your VMs/LXCs. PBS deduplicates aggressively, so the datastore is often much smaller than the sum of the VM sizes, but leave headroom.

**The script does not create the device.** Create it yourself before running `restore-1-install.sh`, then set `PBS_PARTITION` to it. In a disaster recovery, create it the same way and at least as large as before. The datastore contents come back from Google Drive later (DR Step 5).

**Option A: LV in the PVE thin pool (x86_64, default PVE installer layout).** The PVE installer creates VG `pve` with the thin pool `data`, which takes nearly the whole disk, so there is no room left for a partition. Carve the datastore out of the pool instead:

```bash
lvcreate -V 350G -T pve/data -n pbs-datastore
mkfs.ext4 -m 0 /dev/pve/pbs-datastore
# config.env: PBS_PARTITION="/dev/pve/pbs-datastore"
```

A thin LV shares free space with the VM disks. If the pool is overcommitted and runs full, both the VMs and PBS stop writing. Watch `Data%` in `lvs pve/data`.

**Option B: dedicated partition (e.g. a Raspberry Pi 5 with free space on its SSD):**

```bash
parted /dev/sda mkpart primary ext4 <start>s <end>s
mkfs.ext4 -m 0 /dev/sda3
# config.env: PBS_PARTITION="/dev/sda3"
```

> ⚠️ Use the **default inode ratio** — do NOT use `-T largefile4`. PBS stores millions of small 64 KB chunk files and will exhaust inodes with large-file tuning.

`restore-1-install.sh` verifies the partition, mounts it, and adds it to `/etc/fstab` automatically.

### Step 3: Install PBS and backup tools

```bash
./restore-1-install.sh
```

This will:
- Verify and mount the PBS partition, add to `/etc/fstab`
- Install PBS (official repo on x86_64, pipbs on ARM64)
- Install rclone, restic, resticprofile
- Create PBS datastore, backup user and ACL
- Create resticprofile config with retention from `config.env`
- Install and enable the daily PVE config backup timer (`pve-config-backup.timer`)

> ⚠️ **Raspberry Pi 5:** If the Pi is running a 16k page-size kernel (incompatible with PBS), the script detects this, offers to fix it, and reboots. Run the script again after reboot.

---

> **After Step 3 the paths diverge** — continue with [Fresh Installation](#fresh-installation) if this is a new node, or [Disaster Recovery](#disaster-recovery) if you are restoring from existing backups.

---

## Fresh Installation

Use this when setting up a new Proxmox node with no existing backups.

### Step 4: Configure rclone (Google Drive OAuth)

#### One-time: create Google OAuth credentials

1. https://console.cloud.google.com → your project
2. **APIs & Services → Library** → search **Google Drive API** → Enable
3. **APIs & Services → Credentials → + Create Credentials → OAuth client ID**
4. Application type: **Desktop app**, name: `rclone` → Create
5. Copy Client ID and Client Secret

> ℹ️ Reusing existing OAuth credentials? Google doesn't show the secret again — go to **Credentials → pencil → Add secret**.
> OAuth consent screen: choose **External**, add your Gmail as developer and test user.

#### Run rclone config on the PVE server

The server has no browser. Run rclone on a second machine to complete the auth flow.

On the **PVE server**:
```bash
rclone config
```

```
n          # New remote
gdrive     # Name — must match RESTICPROFILE_GDRIVE_REMOTE in config.env
drive      # Type: Google Drive
           # Paste Client ID
           # Paste Client Secret
1          # Scope: full access
           # Leave blank (no service account file)
n          # No advanced config
n          # No auto browser auth
```

rclone prints a command — copy it to your **Windows/Mac machine** and run it. A browser opens, log in, allow access, and copy the resulting token back to the server terminal.

```
n          # Not a shared drive (answer n even for Google Workspace)
y          # Save
q          # Quit
```

Verify:
```bash
rclone lsd gdrive:bu
```

### Step 5: Init restic repository and save password

```bash
echo 'YOUR-RESTIC-PASSWORD' > /etc/resticprofile/restic-password
chmod 600 /etc/resticprofile/restic-password

echo 'YOUR-CONFIG-ENCRYPT-PASSWORD' > /etc/resticprofile/config-encrypt-password
chmod 600 /etc/resticprofile/config-encrypt-password

source /etc/proxmox-backup-restore/config.env
restic --repo "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
  --password-file "${RESTIC_PASSWORD_FILE}" init
```

> ⚠️ Store this password in a password manager — losing it means losing access to all Google Drive backups.

### Step 6: Wire PBS into PVE and activate schedules

```bash
./restore-3-pve.sh
```

Adds PBS as PVE storage and activates the nightly restic backup schedule.

### Step 7: Run first manual backup

```bash
# PBS backup of all VMs/LXCs
pvesh create /nodes/$(hostname)/vzdump --all 1 --storage pbs-local --mode snapshot --compress zstd

# restic backup of PBS datastore to Google Drive
resticprofile backup
```

> ℹ️ The first restic backup uploads the full PBS datastore — can take hours depending on size and connection speed. Subsequent backups are incremental and fast.

---

## Disaster Recovery

Use this when replacing failed hardware with backups already in Google Drive.

**Prerequisites:**
- At least one restic snapshot in Google Drive
- At least one config tarball (`pve-config-YYYY-MM-DD.tar.gz.enc`) in Google Drive
- Access to Google Drive from a browser

The nightly config tarball contains:
- `/var/lib/pve-cluster/config.db` — PVE cluster database (all VM/LXC configs, storage config, ACLs)
- `/root/.config/rclone/` — rclone OAuth token for Google Drive
- `/etc/resticprofile/` — restic profiles and password file
- `/etc/fstab`, network config, custom scripts
- `/etc/pve-agent/` — PVE agent config (tokens, PBS connection — required if proxmox-backup-gui is deployed)
- `/opt/pve-agent/*.py` — PVE agent source files (venv excluded, recreatable)
- every path in `EXTRA_CONFIG_PATHS` (see [Host Extras](#host-extras-optional))

Restoring this tarball on new hardware gives you back rclone auth, the restic password, and the full PVE config — no manual rclone/restic reconfiguration needed.

### Raspberry Pi 5: start from the golden image (optional, faster)

On a Pi, installing PVE, PBS and the tools from scratch takes a long time. CI builds a **golden image** every week. It is the latest Raspberry Pi OS Lite with official Proxmox VE (arm64), pipbs PBS, restic, rclone, resticprofile and the DR scripts of this repository (`/opt/proxmox-pbs-gdrive`: restore-1/2/3, the migration script, `lib/`, `scripts/`, the config templates, README) already installed. CI publishes it to `bu/golden-image/<date>_<commit>/` in Google Drive **only after a full DR run on it has passed**, and keeps the newest three.

The image is **generic**. It holds software only: no user, SSH key, host keys, machine-id, PVE/PBS keys, hostname/IP or `config.env`. CI fails the build if any of these is found. You add your user and SSH key when you flash it, and everything else comes from your `config.env` and the config backup.

1. Download `golden-<date>.img.xz` (check it against `SHA256SUMS`) and flash it with Raspberry Pi Imager ("Use custom"). In Imager's settings, set a user and your SSH public key.
2. Boot it and log in with that user, then `sudo -i`.
3. `cd /opt/proxmox-pbs-gdrive`, copy your `config.env` there, and continue with the normal steps below. `restore-1-install.sh` sees that PVE is already installed. It only configures **this** node (hostname, `/etc/hosts`, vmbr0, cloud-init off) and reboots. Run it once more after the reboot. It refuses to rewrite the network of a node that already has guests.

The image also comes as `rootfs-<date>.tar.zst` and `bootfs-<date>.tar.zst`. These are for a node whose only disk also holds the PBS datastore: you rewrite just the root (and boot) partition and keep the PBS partition.

> ℹ️ **Config and snapshot come from the same night, automatically.** `restore-2-auth.sh` pairs the config tarball and the restic snapshot by date. It restores the newest day that has **both**, however old that day is. Mixing dates would leave PVE listing guests that have no backup, or backups of guests it doesn't know. If the newest tarball has no snapshot from that day (or the other way round), the script says so and uses the previous pair. To force a day, use `RESTORE_DATE=YYYY-MM-DD ./restore-2-auth.sh`. If no pair exists, it stops; you have to type `mismatch` to restore anyway. A tarball's date is the date in its **file name**, which `backup-pve-config.sh` stamps when it makes the backup. The script warns if `config.db` inside the archive is more than a day older or newer, for example after a file was renamed. Two more options: `RESTORE_CONFIG_FOLDER=<folder>` reads tarballs from another `bu/` folder, and `RESTORE_PLAN_ONLY=1` shows which pair would be restored without touching PBS. The plan-only run still extracts the config.

### Step 4: Download config tarball

On any machine with a browser:

1. Go to https://drive.google.com
2. Navigate to `bu/<GDRIVE_CONFIG_FOLDER>/`
3. Download the newest `pve-config-YYYY-MM-DD.tar.gz.enc`. Its date decides which restic snapshot is restored, so pick an older one only if you want an older state.

Copy to the PVE server:
```bash
scp pve-config-YYYY-MM-DD.tar.gz.enc root@YOUR-PVE-IP:/tmp/
```

> ℹ️ Do not extract it manually. `restore-2-auth.sh` stops pve-cluster first, restores `config.db` and rclone auth, then restarts pve-cluster — all in the correct order.

### Step 5: Restore config, credentials, and PBS datastore

```bash
./restore-2-auth.sh
```

The script will:
1. Find the config tar in `/tmp/`
2. Stop pve-cluster, clear WAL files, extract the tar (restoring `config.db`, rclone auth, restic password), restart pve-cluster
3. Verify rclone can reach Google Drive
4. Pick the restic snapshot from the **same date** as the config and show the pair for confirmation. It switches to the newest matching day if needed, and stops if there is none; see the note above.
5. Stop PBS, clear `/mnt/pbs`, restore that snapshot of the PBS datastore from Google Drive

> ⚠️ Downloading the PBS datastore takes several hours depending on size and connection speed.

After this step, all VM/LXC configs are visible in the PVE GUI and the PBS datastore is fully restored.

### Step 6: Wire PBS into PVE

```bash
./restore-3-pve.sh
```

Updates the PBS fingerprint on the storage entry already in `config.db`, starts PBS, and re-enables backup schedules. It also brings back the [host extras](#host-extras-optional): installs `EXTRA_PACKAGES`, puts `EXTRA_CONFIG_PATHS` back exactly as backed up, and enables/restarts `EXTRA_SERVICES`.

### Step 7: Restore VMs and LXCs

Your VMs/LXCs already appear in the GUI (from `config.db`). Restore them from PBS:

1. Open the Proxmox web GUI
2. **Datacenter → Storage → pbs-local → Content**
3. Select a snapshot → **Restore** — the VM/LXC ID is pre-filled, verify and click Restore
4. Repeat for each VM/LXC

CLI alternative:
```bash
pct restore <vmid> pbs-local:backup/ct/<vmid>/<timestamp> --storage local
```

---

## Backup Schedule and Retention

All schedules and retention values are configured in `config.env` — see [Configuration Reference](#configuration-reference) for all variables and defaults.

**Why the order matters:** restic snapshots the PBS datastore after PBS prune has run, so it never captures snapshots that are about to be deleted. `backup-restic-vms.sh` handles this automatically: it polls until the PBS backup task is done, triggers the PBS prune job, waits for it to complete, and only then stops PBS and runs restic. No fixed schedule gap is needed — the script waits for each step.

Local PBS retention is intentionally short — Google Drive handles long-term retention.

---

## Verify Backup Health

```bash
# Check nightly backup timers
systemctl list-timers | grep -E "restic|pve-config"

# View last restic backup log
journalctl -u restic-backup.service -n 50

# View last config backup log
journalctl -u pve-config-backup.service -n 20

# List restic snapshots in Google Drive
source /etc/proxmox-backup-restore/config.env
restic --repo "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
  --password-file "${RESTIC_PASSWORD_FILE}" snapshots

# Check PBS datastore disk usage
df -h /mnt/pbs

# List locks / remove stale ones (if a backup crashed mid-run)
restic --repo "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
  --password-file "${RESTIC_PASSWORD_FILE}" --no-lock list locks
restic --repo "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
  --password-file "${RESTIC_PASSWORD_FILE}" unlock
```

`backup-restic-vms.sh` runs the same `unlock` before every nightly forget/prune. Without `--remove-all`, restic only removes locks it considers stale (dead process on this host, or not refreshed for 30 minutes), so a running backup is never affected. A stale lock doesn't block backup or restore, but it makes every prune fail — so without this the cloud repo would quietly keep growing. Use `--remove-all` only when you are sure no restic process is running anywhere against the repo.

---

## Notes

- **PBS inode allocation:** format the PBS partition with default inode ratio — never use `-T largefile4`. PBS creates millions of small chunk files and will exhaust inodes with large-file tuning.
- **restic size vs PBS size:** restic stores PBS chunks as-is (already deduplicated by PBS), so Google Drive usage ≈ local PBS datastore size — not double.
- **First restic snapshot** uploads everything; subsequent runs are incremental.
- **pbs-enterprise repo** is automatically removed after PBS install — it requires a paid subscription and causes 401 errors otherwise.
- **ARM64 (Pi5):** `restore-1-install.sh` switches to the 4k kernel (`kernel=kernel8.img`) — required because the default Pi5 kernel uses 16k page size, which is incompatible with PBS.
- **config.db WAL checkpoint:** `backup-pve-config.sh` runs `PRAGMA wal_checkpoint(FULL)` before archiving to flush all pending writes from the SQLite WAL file. Without this, recent VM creates or storage changes may be missing from the backup.
- **pmxcfs and config restore:** `/etc/pve/` is a FUSE filesystem managed by pmxcfs. Restoring PVE config requires restoring `/var/lib/pve-cluster/config.db` (the underlying SQLite DB), not the `/etc/pve/` files directly. `restore-2-auth.sh` stops pve-cluster before extraction and restarts it after — pmxcfs then rebuilds `/etc/pve/` from the restored database.
- **proxmox-backup-client auth:** when running non-interactively, set `PBS_PASSWORD` and `PBS_FINGERPRINT` as environment variables. The `--fingerprint` flag does not exist on the `snapshots` subcommand.

---

## Troubleshooting

**`apt update` returns 401 errors**
The Proxmox enterprise repos require a paid subscription. The install script removes them automatically, but if they reappear (e.g. after a PBS upgrade):
```bash
rm -f /etc/apt/sources.list.d/*enterprise*
apt update
```

**PBS won't start after install**
Check that the PBS partition is mounted and the datastore path exists:
```bash
systemctl status proxmox-backup proxmox-backup-proxy
df -h /mnt/pbs
journalctl -u proxmox-backup -n 30
```

**PBS runs out of inodes**
Happens if the partition was formatted with `-T largefile4` or similar. PBS creates millions of small chunk files. Only fix is to reformat:
```bash
mkfs.ext4 -m 0 /dev/sdXN   # default inode ratio — do NOT use -T largefile4
```

**restic backup fails with "repository is already locked"**
A previous backup crashed mid-run. Remove the stale lock:
```bash
source /etc/proxmox-backup-restore/config.env
restic --repo "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
  --password-file "${RESTIC_PASSWORD_FILE}" unlock --remove-all
```

**rclone fails with "Token has been expired"**
The Google Drive OAuth token needs to be renewed. Run `rclone config` on the PVE node, select the existing remote, and re-authenticate. The token is stored in `/root/.config/rclone/rclone.conf`.

**GDrive upload is extremely slow or stalls**
rclone's default concurrency can saturate upload bandwidth. Tune with:
```bash
resticprofile --name pbs-backup backup -- --option rclone.args="copy --transfers=4 --checkers=8"
```

**ARM64: DNS broken after reboot**
pxvirt installs resolvconf which can overwrite `/etc/resolv.conf` on reboot. The install script detects and fixes this automatically on re-run. To fix manually:
```bash
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
```

**ARM64: PBS fails to start — "unsupported page size"**
The default Pi 5 kernel uses 16k pages; PBS requires 4k. The install script switches kernels automatically, but if you reinstalled the kernel manually:
```bash
echo "kernel=kernel8.img" >> /boot/firmware/config.txt
reboot
```

**Scenario B: VM restore fails — "no such snapshot"**
The PBS fingerprint or token in config.env doesn't match the restored PBS instance. Re-run `restore-2-auth.sh` after `restore-1-install.sh` completes — it regenerates the token and updates the PBS storage definition in PVE.

---

## CI & Testing

Jenkins pipelines verify both scenarios end-to-end automatically. Scenario A (install + backup) runs nightly; Scenario B (DR restore) runs weekly on Sundays. ShellSpec integration tests verify the end state after each run.

See [ci/README.md](ci/README.md) for pipeline setup, Jenkins job configuration, and test details.
