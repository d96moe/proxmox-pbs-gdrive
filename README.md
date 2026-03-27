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
| ❌ No UI for GDrive backups | restic is CLI-only; no PVE interface for managing Google Drive snapshots *(separate hobby project underway to fix this)* |
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
            └── restic (nightly ~02:30) → rclone → Google Drive
                    └── keeps last 3 local, up to 5 months on Google Drive

backup-pve-config.sh (nightly at 04:00)
    └── config.db + rclone auth + restic password → Google Drive
            └── this tarball is what makes Scenario B self-contained
```

- **[Proxmox Backup Server (PBS)](https://www.proxmox.com/en/proxmox-backup-server)** stores incremental, deduplicated VM/LXC snapshots locally on `/mnt/pbs`
- **[restic](https://restic.net/)** snapshots the full PBS datastore to Google Drive nightly via **[rclone](https://rclone.org/)** (PBS is stopped during snapshot for consistency)
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
| <img src="https://www.debian.org/logos/openlogo-nd-100.png" height="20"> Debian (base) | included via PVE installer | Trixie (manual install before PVE) | [debian.org](https://www.debian.org/) |
| <img src="https://www.raspberrypi.com/app/uploads/2022/02/COLOUR-Raspberry-Pi-Symbol-Registered.png" height="20"> Hardware | Any x86_64 with NVMe | Pi 5 8GB + NVMe (tested via USB adapter) | [Raspberry Pi 5](https://www.raspberrypi.com/products/raspberry-pi-5/) |

> **Why Proxmox on a Pi 5?** The specific use case here is a small remote location with minimal IT infrastructure: running **Home Assistant** and a full **Unifi OS** instance side by side. Unifi OS is needed specifically for site-to-site VPN ("site magic") — this is not supported by the Unifi Network add-on in Home Assistant and requires a real Unifi OS server. A Pi 5 running Proxmox VE covers both on a single low-power device: HA and Unifi OS each get their own LXC/VM, no separate hardware needed.

> ⚠️ **Do NOT run this from an SD card.** Proxmox VE's write patterns (journals, VM disk I/O, PBS chunk store) will destroy an SD card quickly. You need an SSD. The setup this repo was built on uses a Pi 5 booting from an NVMe drive connected via USB adapter — cheap and works well.

> ⚠️ **ARM64 only:** pipbs and pxvirt are community projects, not officially supported by Proxmox. They must be kept at the same major.minor version — a mismatch can cause GUI rendering issues and other instability. `restore-1-install.sh` checks versions from both repos **before installing anything** and automatically pins whichever package is ahead to a matching older version if needed. Before running `apt upgrade`, always verify both repos are at the same version first:
> ```bash
> apt-cache policy proxmox-ve proxmox-backup-server | grep -A1 "Candidate:"
> dpkg -l proxmox-ve proxmox-backup-server | awk '/^ii/{print $2, $3}'
> ```
> If only one repo has a new version, wait for the other to catch up.

---

## Repository Layout

```
proxmox-pbs-gdrive/
├── restore-1-install.sh      # Setup step 3: install PBS, rclone, restic, resticprofile
├── restore-2-auth.sh         # DR step 5: restore rclone auth + PVE config from GDrive
├── restore-3-pve.sh          # Fresh step 6 / DR step 6: wire PBS into PVE
├── config.env.example        # Template — copy to config.env and fill in your values
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
    ├── setup-*-template.sh   # One-time VM template creation scripts
    └── spec/                 # ShellSpec integration tests
```

The two scripts under `scripts/` are **helper scripts installed onto your Proxmox host** by the main restore scripts — they are not CI-only. They run on a schedule after setup and are what keeps your backups going day-to-day.

---

## Configuration Reference

All configuration lives in `config.env`. Copy the template for your platform and fill in the values marked as required.

### PBS Datastore

| Variable | Default | Description |
|---|---|---|
| `PBS_PARTITION` | — | **Required.** Dedicated partition for PBS, e.g. `/dev/sda3` or `/dev/nvme0n1p4`. Must not be shared with OS or VMs. |
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

### Backup Schedules

Schedules use systemd calendar format (e.g. `02:00`, `Mon 03:30`). The recommended order ensures each job completes before the next starts:

| Variable | Default | Job |
|---|---|---|
| `PBS_BACKUP_SCHEDULE` | `02:00` | PVE runs vzdump of all VMs/LXCs to PBS |
| `PBS_PRUNE_SCHEDULE` | `03:00` | PBS removes old snapshots per retention policy |
| `PBS_GC_SCHEDULE` | `03:30` | PBS garbage collection — frees chunks pruned above |
| `RESTIC_BACKUP_SCHEDULE` | `04:00` | restic snapshots PBS datastore to Google Drive |
| `RESTIC_FORGET_SCHEDULE` | `04:30` | restic prunes old Google Drive snapshots |
| `CONFIG_BACKUP_SCHEDULE` | `05:00` | Daily PVE config tarball uploaded to Google Drive |

> ℹ️ All schedules are applied automatically by `restore-3-pve.sh`. The PBS backup job (`PBS_BACKUP_SCHEDULE`) can be adjusted afterwards in the PVE GUI under Datacenter → Backup. The restic and config backup schedules are systemd timers — edit `/etc/systemd/system/restic-backup.timer` and `/etc/systemd/system/pve-config-backup.timer` and run `systemctl daemon-reload`.

### PVE Installation (aarch64 / Raspberry Pi 5 only)

These variables are only used by `restore-1-install.sh` on arm64 when Proxmox VE is not yet installed. They are ignored on x86_64.

| Variable | Default | Description |
|---|---|---|
| `PVE_HOSTNAME` | `proxmox` | Hostname for the Proxmox node. |
| `PVE_IP` | — | **Required.** Static IP with prefix length, e.g. `192.168.1.200/24`. |
| `PVE_GATEWAY` | — | **Required.** Default gateway, e.g. `192.168.1.1`. |
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

Proxmox is not officially supported on ARM64. `restore-1-install.sh` handles the full install automatically:

1. Install Debian Trixie (64-bit) with Raspberry Pi Imager
2. SSH in as root, then:

```bash
apt-get install -y git
git clone https://github.com/d96moe/proxmox-pbs-gdrive.git
cd proxmox-pbs-gdrive
cp config_rpi5.env config.env
nano config.env   # set PVE_HOSTNAME, PVE_IP, PVE_GATEWAY, PVE_IFACE, PBS_PARTITION
./restore-1-install.sh
```

The script sets hostname, configures the network bridge, adds the pxvirt repo, installs Proxmox VE, switches to the 4k kernel (required for PBS on Pi5), and reboots. Run it again after reboot to complete the install. GUI available at `https://<IP>:8006`.

> ⚠️ Do NOT run `apt upgrade` without checking for pxvirt/pipbs version conflicts first.

Fill in `config.env` — see [Configuration Reference](#configuration-reference) above. At minimum set `PBS_PARTITION`, `PBS_USER_PASSWORD`, `RESTICPROFILE_GDRIVE_REMOTE`, `RESTICPROFILE_GDRIVE_PATH`, and `GDRIVE_CONFIG_FOLDER`.

### Step 2: Create PBS partition

PBS needs its own dedicated partition — if anything else fills the disk, backups fail. Size depends on your VMs/LXCs; PBS deduplicates aggressively so the datastore is often much smaller than the sum of VM sizes, but leave headroom.

**The script does not create the partition** — you must do this manually before running `restore-1-install.sh`:

```bash
parted /dev/sda mkpart primary ext4 <start>s <end>s
mkfs.ext4 -m 0 /dev/sda3
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
- At least one config tarball (`pve-config-YYYY-MM-DD.tar.gz`) in Google Drive
- Access to Google Drive from a browser

The nightly config tarball contains:
- `/var/lib/pve-cluster/config.db` — PVE cluster database (all VM/LXC configs, storage config, ACLs)
- `/root/.config/rclone/` — rclone OAuth token for Google Drive
- `/etc/resticprofile/` — restic profiles and password file
- `/etc/fstab`, network config, custom scripts

Restoring this tarball on new hardware gives you back rclone auth, the restic password, and the full PVE config — no manual rclone/restic reconfiguration needed.

> ⚠️ **Match your tar and restic snapshot dates.** Pick a config tar and restic snapshot from the **same night**. The tar is named `pve-config-YYYY-MM-DD.tar.gz`. Mixing dates means your PVE config will reference VMs that don't exist in the restored PBS datastore, or vice versa.

### Step 4: Download config tarball

On any machine with a browser:

1. Go to https://drive.google.com
2. Navigate to `bu/<GDRIVE_CONFIG_FOLDER>/`
3. Download `pve-config-YYYY-MM-DD.tar.gz` matching the restic snapshot you plan to restore

Copy to the PVE server:
```bash
scp pve-config-YYYY-MM-DD.tar.gz root@YOUR-PVE-IP:/tmp/
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
4. List available restic snapshots and prompt for confirmation
5. Stop PBS, clear `/mnt/pbs`, restore the PBS datastore from Google Drive

> ⚠️ Downloading the PBS datastore takes several hours depending on size and connection speed.

After this step, all VM/LXC configs are visible in the PVE GUI and the PBS datastore is fully restored.

### Step 6: Wire PBS into PVE

```bash
./restore-3-pve.sh
```

Updates the PBS fingerprint on the storage entry already in `config.db`, starts PBS, and re-enables backup schedules.

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

**Why the order matters:** PBS prune removes index entries but doesn't free disk space — GC does that. restic runs after GC to snapshot the clean post-prune datastore. Config backup runs last.

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

# Remove stale restic locks (if a backup crashed mid-run)
restic --repo "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
  --password-file "${RESTIC_PASSWORD_FILE}" unlock --remove-all
```

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

Two Jenkins pipelines run on a weekly basis to verify both scenarios end-to-end. ShellSpec integration tests verify the end state after each run.

See [ci/README.md](ci/README.md) for pipeline setup, Jenkins job configuration, and test details.
