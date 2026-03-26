# proxmox-backup-restore

> **⚠️ HOBBY PROJECT — USE AT YOUR OWN RISK**
>
> This is a personal homelab project built for two reasons: to have a reasonable backup safety net at home, and to have fun exploring what Claude Code can do as a coding assistant. It is not production software, has no guarantees, and comes with no support. The scripts work on my hardware — they may or may not work on yours. If you use this and lose data, that's on you.

## Why This Exists

### The use case

The specific setup this was built for: a small remote location with minimal IT infrastructure. The requirements were to run **Home Assistant** for home automation and a full **Unifi OS** instance for network management — specifically to get site-to-site VPN ("site magic"), which is not supported by the Unifi Network add-on in Home Assistant and requires a proper Unifi OS server.

A Raspberry Pi 5 running Proxmox VE covers both: HA and Unifi OS each get their own LXC/VM on a single small, low-power device. No rack, no noise, no separate hardware per service.

### The backup problem

If you run a homelab Proxmox node and want proper offsite backups — but you only have one physical machine — you have a problem: there's nowhere local to send backups that isn't at risk alongside the hardware itself.

This repo solves that by pairing Proxmox Backup Server (PBS) with Google Drive as the offsite destination:

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

- **PBS** stores incremental, deduplicated VM/LXC snapshots locally on `/mnt/pbs`
- **restic** snapshots the full PBS datastore to Google Drive nightly (PBS is stopped during snapshot for consistency)
- **config tarball** backs up everything needed to recover on new hardware: PVE cluster database, rclone OAuth token, restic password, network config

> The config tarball is what makes disaster recovery hands-free — it contains the credentials to reach Google Drive and the password to decrypt backups. No manual rclone/restic reconfiguration needed on new hardware.

---

## Supported Platforms

| Component | x86_64 standard | Raspberry Pi 5 (aarch64) |
|---|---|---|
| Proxmox VE | 9.1.4 | 9.0.10-2 (pxvirt) |
| PBS | 4.1.4-1 (official) | 4.1.4-1 (pipbs) |
| rclone | 1.73.1 | 1.73.2 |
| restic | 0.18.0 | 0.18.0 |
| Debian (base) | Bookworm | Trixie |
| Hardware | Any x86_64 with NVMe | Pi 5 8GB + NVMe (tested via USB adapter) |

**ARM64 community repos used on Pi 5:**
- PBS: [pipbs](https://github.com/dexogen/pipbs) (dexogen)
- QEMU/KVM: [pxvirt](https://download.lierfang.com/pxcloud/pxvirt) (lierfang)

> ⚠️ pipbs and pxvirt are community projects, not officially supported by Proxmox. Keep their package versions in sync — mixing can cause GUI rendering issues.

---

## Which Scenario Applies to You?

| Situation | Use |
|---|---|
| Setting up a new Proxmox node with no existing backups | [Scenario A](#scenario-a-fresh-setup) |
| Replacing failed hardware, you have backups in Google Drive | [Scenario B](#scenario-b-disaster-recovery) |

---

## Before You Start

### 0. Prerequisites

Before running any scripts, make sure you have:

- A **Google account** with Google Drive — this is where all offsite backups land
- **Enough Google Drive space** — plan for roughly 1.5× the size of your PBS datastore (the initial upload is the full datastore; incremental snapshots grow it slowly after that)
- **Root SSH access** to your Proxmox node
- A **dedicated partition** for PBS (see below) — this must be prepared before running any scripts
- A **restic password** — pick one and store it in a password manager before you start. You cannot recover your Google Drive backups without it.

### 1. Create a dedicated PBS partition

PBS should have its own dedicated partition. It can technically run on a shared partition, but it's strongly discouraged: if anything else (OS, VMs, logs) fills the disk, PBS backups fail. Keeping it separate also makes it easy to see exactly how much space backups are consuming.

**Size:** depends on how many VMs/LXCs you have and how large they are. PBS deduplicates aggressively so the datastore is often much smaller than the sum of VM sizes — but leave headroom. The script will warn (not fail) if the partition is smaller than 15% of the total disk.

**The script does not create or format the partition — you must do this manually before running `restore-1-install.sh`.** The script will verify the partition exists and is a block device, but will exit with an error if it doesn't.

```bash
# Example: create partition on /dev/sda
parted /dev/sda mkpart primary ext4 <start>s <end>s
mkfs.ext4 -m 0 /dev/sda3   # -m 0: no reserved blocks (only useful on root partition)

# Get UUID for config.env
blkid /dev/sda3
```

> ⚠️ Format with the **default inode ratio** — do NOT use `-T largefile4`. PBS stores data as millions of small 64 KB chunk files. `largefile4` sets 4 MB per inode, leaving far too few inodes for the chunk store.

`restore-1-install.sh` will verify the partition, mount it, and add it to `/etc/fstab` automatically.

### 2. Edit config.env

All scripts source a single `config.env`. Start from a template:

```bash
cp config_x86_standard.env config.env   # x86_64
cp config_rpi5.env config.env           # Raspberry Pi 5 (aarch64)
nano config.env
```

Minimum variables to set:

| Variable | Description |
|---|---|
| `PBS_PARTITION` | Dedicated PBS partition, e.g. `/dev/sda3` or `/dev/nvme0n1p4` |
| `PBS_USER_PASSWORD` | **Change from `changeme`!** |
| `RESTICPROFILE_GDRIVE_REMOTE` | rclone remote name (must match what you configure in rclone) |
| `RESTICPROFILE_GDRIVE_PATH` | Google Drive path for restic repo |
| `GDRIVE_CONFIG_FOLDER` | Google Drive folder for config tarballs |

---

## Scenario A: Fresh Setup

Use this when setting up a new Proxmox node with no existing backups.

### A0: Install Proxmox VE

**x86_64:**
1. Download and install Proxmox VE from https://www.proxmox.com/downloads
2. SSH in as root

**aarch64 (Raspberry Pi 5):**

Proxmox is not officially supported on ARM64. Use `install-proxmox-rpi5.sh` to automate the community install:

1. Install Debian Trixie (64-bit) with Raspberry Pi Imager
2. SSH in as root, then:

```bash
apt-get install -y git
git clone https://github.com/d96moe/proxmox-backup-restore.git
cd proxmox-backup-restore
```

3. Edit the variables at the top of the script (hostname, IP, gateway, network interface):

```bash
nano install-proxmox-rpi5.sh
./install-proxmox-rpi5.sh
```

The script sets hostname, configures the network bridge, adds pxvirt and pipbs repos, installs Proxmox VE + PBS, switches to the 4k kernel (required for PBS on Pi5), and reboots. GUI available at `https://<IP>:8006` after reboot.

> ⚠️ Do NOT run `apt upgrade` without checking for pxvirt/pipbs version conflicts first.

### A1: Create PBS partition

See [Before You Start → Create a dedicated PBS partition](#1-create-a-dedicated-pbs-partition).

### A2: Clone repo and configure

```bash
apt-get install -y git
git clone https://github.com/d96moe/proxmox-backup-restore.git
cd proxmox-backup-restore
chmod +x *.sh
cp config_x86_standard.env config.env   # or config_rpi5.env
nano config.env
```

### A3: Install PBS and backup tools

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

### A4: Configure rclone (Google Drive OAuth)

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

### A5: Init restic repository and save password

```bash
echo 'YOUR-RESTIC-PASSWORD' > /etc/resticprofile/restic-password
chmod 600 /etc/resticprofile/restic-password

source /etc/proxmox-backup-restore/config.env
restic --repo "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
  --password-file "${RESTIC_PASSWORD_FILE}" init
```

> ⚠️ Store this password in a password manager — losing it means losing access to all Google Drive backups.

### A6: Wire PBS into PVE and activate schedules

```bash
./restore-3-pve.sh
```

Adds PBS as PVE storage and activates the nightly restic backup schedule.

### A7: Run first manual backup

```bash
# PBS backup of all VMs/LXCs
pvesh create /nodes/$(hostname)/vzdump --all 1 --storage pbs-local --mode snapshot --compress zstd

# restic backup of PBS datastore to Google Drive
resticprofile backup
```

> ℹ️ The first restic backup uploads the full PBS datastore — can take hours depending on size and connection speed. Subsequent backups are incremental and fast.

---

## Scenario B: Disaster Recovery

Use this when replacing failed hardware. You already have backups in Google Drive.

**Prerequisite:** Scenario A must have completed at least once on the old hardware. You need:
- At least one restic snapshot in Google Drive (from a previous Scenario A run)
- At least one config tarball (`pve-config-YYYY-MM-DD.tar.gz`) in Google Drive
- Access to Google Drive from a browser (to download the tarball in step B3)

### How it works

The nightly config tarball (`pve-config-backup.timer`) contains:
- `/var/lib/pve-cluster/config.db` — PVE cluster database (all VM/LXC configs, storage config, ACLs)
- `/root/.config/rclone/` — rclone OAuth token for Google Drive
- `/etc/resticprofile/` — restic profiles and password file
- `/etc/fstab`, network config, custom scripts

Restoring this tarball on new hardware gives you back rclone auth, the restic password, and the full PVE configuration — no manual reclone/restic reconfiguration needed.

> ⚠️ **Match your tar and restic snapshot dates.** Pick a config tar and restic snapshot from the **same night**. The tar is named `pve-config-YYYY-MM-DD.tar.gz`. Mixing dates means your PVE config will reference VMs that don't exist in the restored PBS datastore, or vice versa.

### B0: Install Proxmox VE

Same as [A0](#a0-install-proxmox-ve).

### B1: Create PBS partition

Same as [A1](#a1-create-pbs-partition) — create a dedicated partition on the new hardware.

### B2: Clone repo, configure, and run restore-1-install.sh

```bash
apt-get install -y git
git clone https://github.com/d96moe/proxmox-backup-restore.git
cd proxmox-backup-restore
chmod +x *.sh
cp config_x86_standard.env config.env   # or config_rpi5.env
nano config.env                         # verify PBS_PARTITION matches new hardware
./restore-1-install.sh
```

### B3: Download config tarball

On any machine with a browser:

1. Go to https://drive.google.com
2. Navigate to `bu/<GDRIVE_CONFIG_FOLDER>/`
3. Download `pve-config-YYYY-MM-DD.tar.gz` matching the restic snapshot you plan to restore

Copy to the PVE server:
```bash
scp pve-config-YYYY-MM-DD.tar.gz root@YOUR-PVE-IP:/tmp/
```

> ℹ️ Do not extract it manually. `restore-2-auth.sh` stops pve-cluster first (so the pmxcfs FUSE filesystem is unmounted), restores `config.db` and rclone auth, then restarts pve-cluster — all in the correct order.

### B4: Restore config, credentials, and PBS datastore

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

After this step, all VM/LXC configs are visible in the PVE GUI (from the restored `config.db`), and the PBS datastore is fully restored.

### B5: Wire PBS into PVE

```bash
./restore-3-pve.sh
```

Updates the PBS fingerprint on the storage entry already in `config.db`, starts PBS, and re-enables backup schedules.

### B6: Restore VMs and LXCs

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

| Time | Job |
|------|-----|
| 02:00 | PBS backup all VMs/LXCs (vzdump via PVE schedule) |
| 03:00 | PBS prune (keep-last 3, keep-daily 3) |
| 03:30 | PBS garbage collection (frees chunks pruned the night before) |
| ~02:30 | restic snapshot PBS datastore → Google Drive |
| 04:00 | PVE config backup → Google Drive |

**Why this order:** Prune removes index entries but doesn't free disk space. GC (24h cutoff) runs after prune and actually frees chunks. restic runs after GC, uploading the clean post-prune datastore. Config backup runs last, capturing the final night's state.

| Storage | Retention |
|---------|-----------|
| PBS local `/mnt/pbs` | keep-last=3, keep-daily=3 |
| Google Drive (restic) | keep-last=3, keep-daily=6, keep-weekly=3, keep-monthly=5 |
| Google Drive (config tarballs) | 7 most recent (configurable via `CONFIG_KEEP_DAYS`) |

Local retention is intentionally short — Google Drive handles long-term retention.

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
- **ARM64 (Pi5):** `install-proxmox-rpi5.sh` switches to the 4k kernel (`kernel=kernel8.img`) — required because the default Pi5 kernel uses 16k page size, which is incompatible with PBS.
- **config.db WAL checkpoint:** `backup-pve-config.sh` runs `PRAGMA wal_checkpoint(FULL)` before archiving to flush all pending writes from the SQLite WAL file. Without this, recent VM creates or storage changes may be missing from the backup.
- **pmxcfs and config restore:** `/etc/pve/` is a FUSE filesystem managed by pmxcfs. Restoring PVE config requires restoring `/var/lib/pve-cluster/config.db` (the underlying SQLite DB), not the `/etc/pve/` files directly. `restore-2-auth.sh` stops pve-cluster before extraction and restarts it after — pmxcfs then rebuilds `/etc/pve/` from the restored database.
- **proxmox-backup-client auth:** when running non-interactively, set `PBS_PASSWORD` and `PBS_FINGERPRINT` as environment variables. The `--fingerprint` flag does not exist on the `snapshots` subcommand.

---

## CI & Testing

Two Jenkins pipelines run on a weekly basis to verify both scenarios end-to-end. ShellSpec integration tests verify the end state after each run.

See [ci/README.md](ci/README.md) for pipeline setup, Jenkins job configuration, and test details.
