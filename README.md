# proxmox-backup-restore

Disaster recovery and setup scripts for Proxmox VE with PBS + restic + rclone → Google Drive.

Supports both x86_64 (standard PVE install) and aarch64 (Raspberry Pi 5 with community ARM64 builds).

## Tested With

| Component | x86_64 standard | Raspberry Pi 5 (aarch64) |
|---|---|---|
| Proxmox VE | 9.1.4 | 9.0.10-2 (pxvirt) |
| PBS | 4.1.4-1 (official) | 4.1.4-1 (pipbs) |
| rclone | 1.73.1 | 1.73.2 |
| restic | 0.18.0 | 0.18.0 |
| Debian (base) | Bookworm | Trixie |
| Hardware | Any x86_64 with NVMe (tested: Minisforum Ryzen AI HX 370) | Raspberry Pi 5 8GB, NVMe (tested: NVMe via USB adapter) |

**ARM64 repos used on Pi5:**
- PBS: [pipbs](https://github.com/dexogen/pipbs) (dexogen) — community ARM64 PBS build
- QEMU/KVM: [pxvirt](https://download.lierfang.com/pxcloud/pxvirt) (lierfang) — community ARM64 PVE build

> ⚠️ pipbs and pxvirt are community projects, not officially supported by Proxmox.
> Keep their package versions in sync — mixing versions can cause GUI rendering issues.

## Architecture

```
Proxmox VE
    └── PBS (Proxmox Backup Server)
            ├── /mnt/pbs  ← dedicated partition (own partition, never shared with OS/VMs)
            └── restic (nightly) → rclone → Google Drive
```

- **PBS** handles incremental, deduplicated VM/LXC backups locally
- **restic** snapshots the full PBS datastore to Google Drive nightly
- **rclone** provides the Google Drive transport for restic
- **PBS is stopped** during restic snapshot to ensure consistency

## Backup Schedule

| Time | Job |
|------|-----|
| 02:00 | PBS backup all VMs/LXCs (vzdump via PVE schedule) |
| 03:00 | PBS prune (`nightly-prune` job, keep-last 3) |
| 03:30 | PBS garbage collection (frees chunks pruned the night before) |
| configurable | restic snapshot + forget → Google Drive (default `02:30`, `RESTIC_BACKUP_SCHEDULE`) |
| 04:00 | PVE config backup → Google Drive (`pve-config-backup.timer`) |

**Why this order matters:**
- Prune removes old snapshot index files but does not free disk space
- GC runs after prune and actually frees the unreferenced chunks (24h cutoff)
- restic runs last, uploading only the clean post-prune datastore,
  then runs `forget` to enforce retention in Google Drive
- Config backup runs after restic so it captures the final state of the night

**Two separate retention systems:**
- PBS prune → controls what stays in `/mnt/pbs` locally
- restic forget → controls what stays in Google Drive

## What Gets Backed Up

| Backup | Contents | Destination | Schedule |
|--------|----------|-------------|----------|
| PBS | All VM/LXC snapshots (incremental, deduplicated) | `/mnt/pbs` | Nightly 02:00 |
| restic | Full PBS datastore (`/mnt/pbs`) | Google Drive | Nightly (configurable) |
| Config tar | `/var/lib/pve-cluster/config.db`, rclone OAuth token, restic password, `/etc/pve/`, `/etc/fstab`, network config, custom scripts | Google Drive | Nightly 04:00 |

The **config tar** is what makes Scenario B (DR) self-contained — it contains everything needed to authenticate against Google Drive and decrypt backups, without requiring any manual setup.

> ⚠️ **Keep tar and restic snapshots in sync.** Both are created nightly. In a DR, pick a
> config tar and restic snapshot from the **same date** — they represent a consistent state.
> Mixing (e.g. today's tar with last week's restic snapshot) means your PVE config will
> reference VMs that don't exist in the restored datastore, or vice versa.

## Retention

| Storage | Retention |
|---------|-----------|
| PBS local | keep-last=3, keep-daily=3 |
| Google Drive (restic) | keep-last=3, keep-daily=6, keep-weekly=3, keep-monthly=5 |
| Google Drive (config tar) | 7 most recent tarballs (configurable via `CONFIG_KEEP_DAYS`) |

Local retention is intentionally short — Google Drive handles long-term retention.

---

## ⚠️ Before You Start — PBS Partition

PBS **must** be on its own dedicated partition. It cannot share a partition with the OS or VMs.

**Why:** PBS manages its own chunk store and assumes exclusive, predictable disk access.
Sharing a partition risks data loss if the OS or VMs fill up the disk.

**Minimum size:** 15% of total disk. In practice, ~20-30% is recommended.

You must create and format the partition **before** running any scripts:

```bash
# Example: create a new partition on /dev/sda after shrinking existing partitions
parted /dev/sda mkpart primary ext4 <start_sector>s <end_sector>s
mkfs.ext4 -m 0 /dev/sda3

# Get the partition UUID (you'll need this for config.env)
blkid /dev/sda3
```

The `restore-1-install.sh` script will:
- Verify the partition exists and is a block device
- Verify it is NOT the root partition
- Warn if it is smaller than 15% of total disk
- Add it to `/etc/fstab` and mount it automatically

---

## ⚠️ Before You Start — Edit config.env

All scripts source a single `config.env` file. Pre-configured templates are available:

```bash
cp config_x86_standard.env config.env    # x86_64 standard setup
cp config_rpi5.env config.env            # Raspberry Pi 5 (aarch64)
```

Key variables to set:

| Variable | Description |
|---|---|
| `PBS_PARTITION` | Dedicated PBS partition e.g. `/dev/sda3` or `/dev/nvme0n1p4` |
| `PBS_DATASTORE_PATH` | Mount point for PBS partition, default `/mnt/pbs` |
| `PBS_USER_PASSWORD` | **Always change this from `changeme`!** |
| `PBS_RETENTION_LOCAL` | Local PBS retention, default `keep-last=3,keep-daily=3` |
| `RESTICPROFILE_GDRIVE_PATH` | Google Drive restic repo path |
| `GDRIVE_CONFIG_FOLDER` | Google Drive config backup folder name |
| `CONFIG_KEEP_DAYS` | How many config tarballs to keep on Google Drive (default 7) |
| `RESTIC_RETENTION_KEEP_*` | Remote retention settings |

---

## Scenario A: Fresh Setup (first time, no existing backup)

Use this when setting up a new Proxmox instance from scratch.

### A0: Install Proxmox VE

**x86_64:**
1. Download Proxmox VE ISO from https://www.proxmox.com/downloads
2. Boot from ISO and install, configure network
3. SSH in as root

**aarch64 (Raspberry Pi 5):**

Proxmox VE is not officially supported on ARM64 — installation requires community repos and a few extra steps. Use `install-proxmox-rpi5.sh` to automate this:

1. Install Debian Trixie (64-bit) on the Pi5 using Raspberry Pi Imager
2. SSH in as root and clone the repo:
```bash
apt-get install -y git
git clone https://github.com/d96moe/proxmox-backup-restore.git
cd proxmox-backup-restore
chmod +x *.sh
```
3. Edit the configuration variables at the top of the script (hostname, IP, gateway, network interface):
```bash
nano install-proxmox-rpi5.sh
```
4. Run it:
```bash
./install-proxmox-rpi5.sh
```

The script will:
- Set hostname and configure network bridge
- Add pxvirt repo (community PVE ARM64 port) and pipbs repo (community PBS ARM64 build)
- Install proxmox-ve, pve-qemu-kvm, proxmox-backup-server
- Remove enterprise repos (avoid 401 errors)
- Switch to 4k kernel (`kernel=kernel8.img`) — required for PBS on Pi5
- Reboot

After reboot, Proxmox GUI is available at `https://<IP>:8006`.

> ⚠️ pxvirt and pipbs are community projects, not officially supported by Proxmox.
> Keep their package versions in sync — mixing can cause GUI rendering issues.
> Do NOT run `apt upgrade` without checking for version conflicts first.

### A1: Create PBS partition

Before running any scripts, create and format a dedicated partition for PBS.
See the **PBS Partition** section above.

### A2: Clone repo and edit config.env

```bash
apt-get install -y git
git clone https://github.com/d96moe/proxmox-backup-restore.git
cd proxmox-backup-restore
chmod +x *.sh
cp config_x86_standard.env config.env   # or config_rpi5.env
nano config.env                 # set PBS_PARTITION and PBS_USER_PASSWORD at minimum
```

### A3: Run restore-1-install.sh

```bash
./restore-1-install.sh
```

The script will:
- Run sanity checks on the PBS partition
- Install PBS (official repo on x86_64, pipbs community repo on ARM64)
- Install rclone, restic, resticprofile
- Mount the PBS partition and add it to /etc/fstab
- Create PBS datastore, user and ACL
- Create resticprofile config with retention settings from config.env
- Install and enable the daily PVE config backup timer (`pve-config-backup.timer`)

> ⚠️ **Raspberry Pi 5 only:** The script detects if the kernel uses 16k page-size
> (incompatible with PBS) and offers to fix it and reboot automatically.
> Run the script again after reboot.

### A4: Configure rclone (Google Drive)

#### Create Google OAuth credentials (one-time, skip if you already have these)

1. Go to https://console.cloud.google.com → select your project
2. **APIs & Services → Library** → search **Google Drive API** → Enable
3. **APIs & Services → Credentials** → **+ Create Credentials → OAuth client ID**
4. Application type: **Desktop app**, name: `rclone` → Create
5. Copy **Client ID** and **Client Secret**

> ℹ️ Reusing an existing OAuth client? You can reuse the same Client ID.
> Google doesn't show the secret again — go to **Credentials → pencil icon → Add secret**.

> ⚠️ OAuth consent screen: choose **External**, add your Gmail as developer and test user.

#### Run rclone config on the PVE server

The server has no browser — install rclone on a second machine (https://rclone.org/downloads/).

On the **PVE server**:
```bash
rclone config
```

Prompts:
```
n          # New remote
gdrive     # Name — must match RESTICPROFILE_GDRIVE_REMOTE in config.env
drive      # Type: Google Drive
           # Paste Client ID
           # Paste Client Secret
1          # Scope: full access
           # Leave blank (no service account file)
n          # No advanced config
n          # No auto browser auth (server has no browser)
```

rclone prints a command — copy it to your **Windows/Mac machine** and run it there.
A browser opens — log in with your Google account and click Allow.
Copy the resulting JSON token and paste it back in the server terminal.

```
n          # Not a shared/team drive — answer n even if you use Google Workspace!
y          # Confirm and save
q          # Quit
```

Verify:
```bash
rclone lsd gdrive:bu
```

### A5: Save restic password and init repo

```bash
# Save password (path must match RESTIC_PASSWORD_FILE in config.env)
echo 'YOUR-RESTIC-PASSWORD' > /etc/resticprofile/restic-password
chmod 600 /etc/resticprofile/restic-password

# Init the restic repo in Google Drive
source /etc/proxmox-backup-restore/config.env
restic --repo "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
  --password-file "${RESTIC_PASSWORD_FILE}" init
```

> ⚠️ Store this password in a password manager — losing it means losing access to all backups!

### A6: Run restore-3-pve.sh

Adds PBS as storage in PVE and activates nightly restic schedules:

```bash
./restore-3-pve.sh
```

### A7: Run first manual backup

```bash
# PBS backup of all VMs/LXCs
pvesh create /nodes/$(hostname)/vzdump --all 1 --storage pbs-local --mode snapshot --compress zstd

# restic backup of PBS datastore to Google Drive
/opt/proxmox-restore/backup-restic-vms.sh
```

> ℹ️ First restic backup uploads the full PBS datastore — takes time depending on connection speed.
> Subsequent nightly backups are incremental and much faster.

---

## Scenario B: Disaster Recovery (restoring from existing backup)

Use this when replacing failed hardware. You already have backups in Google Drive.

### How it works

The nightly config backup (`pve-config-backup.timer`) creates a tarball containing:
- `/var/lib/pve-cluster/config.db` — the PVE cluster database (VM/LXC configs, storage config, ACLs)
- `/root/.config/rclone/` — rclone OAuth token for Google Drive access
- `/etc/resticprofile/` — restic profiles and password file
- `/etc/fstab`, network config, custom scripts

Restoring this tarball on fresh hardware gives you back rclone auth, the restic password,
**and** the full PVE configuration (all VM/LXC configs, storage definitions). No manual
rclone/restic setup needed.

> ⚠️ **Match your tar and restic snapshot dates.** Pick a config tar and restic snapshot
> from the **same night**. The tar is named `pve-config-YYYY-MM-DD.tar.gz`; match it to
> a restic snapshot from the same date (`restic snapshots` shows timestamps).
> Mixing dates means your PVE config and PBS datastore will be out of sync.

### B0: Install Proxmox VE

Same as A0.

### B1: Create PBS partition

Same as A1 — create and format a dedicated PBS partition on the new hardware.

### B2: Clone repo and run restore-1-install.sh

```bash
apt-get install -y git
git clone https://github.com/d96moe/proxmox-backup-restore.git
cd proxmox-backup-restore
chmod +x *.sh
cp config_x86_standard.env config.env   # or config_rpi5.env
nano config.env                 # verify PBS_PARTITION matches new hardware
./restore-1-install.sh
```

### B3: Download the config tarball

On any computer with a browser:

1. Go to https://drive.google.com
2. Navigate to `bu/proxmox_home_config/` (or `proxmox_cabin_config/`)
3. Download the `pve-config-YYYY-MM-DD.tar.gz` that matches the restic snapshot you plan to restore

Copy it to the PVE server's `/tmp/`:
```bash
scp pve-config-YYYY-MM-DD.tar.gz root@YOUR-PVE-IP:/tmp/
```

> ℹ️ Do **not** extract the tarball manually — `restore-2-auth.sh` handles the extraction
> correctly (stops pve-cluster first so the pmxcfs FUSE filesystem is unmounted, then restores
> the cluster database and restarts pve-cluster).

### B4: Run restore-2-auth.sh

```bash
cd proxmox-backup-restore
./restore-2-auth.sh
```

The script will:
1. Find the config tar in `/tmp/` (the one you copied in B3)
2. Stop pve-cluster, clear stale WAL files, extract the tarball (restoring `config.db`, rclone auth, restic password), restart pve-cluster
3. Verify rclone can reach Google Drive (now using the restored credentials)
4. List available restic snapshots and prompt for confirmation
5. Stop PBS, clear `/mnt/pbs`, restore the PBS datastore from Google Drive
6. Print a summary on completion

> ⚠️ Downloading the PBS datastore takes several hours (size depends on your setup).

After this step, all your VM/LXC configs are already visible in the PVE GUI (restored from `config.db`). The PBS datastore is fully restored and ready.

### B5: Run restore-3-pve.sh

```bash
./restore-3-pve.sh
```

This wires PBS into PVE (updates the fingerprint on the existing PBS storage entry restored from `config.db`), starts PBS, and re-enables backup schedules.

### B6: Restore VMs/LXCs

Since `config.db` was restored in step B4, your VMs and LXCs appear in the GUI already.
Restore them from the PBS snapshots:

1. Open Proxmox web GUI
2. Go to **Datacenter → Storage → pbs-local → Content** tab
3. All PBS snapshots are listed — select a snapshot → **Restore**
4. The VM/LXC ID is pre-filled from config.db — verify it matches and click Restore
5. Repeat for each VM/LXC

> ℹ️ Alternatively, restore via CLI: `pct restore <vmid> pbs-local:backup/ct/<vmid>/<timestamp> --storage local`

---

## Verify Backup Health

```bash
# Check nightly backup timers
systemctl list-timers | grep -E "restic|pve-config"
systemctl status restic-backup.timer
systemctl status pve-config-backup.timer

# View last restic backup log
journalctl -u restic-backup.service -n 50

# View last config backup log
journalctl -u pve-config-backup.service -n 20

# List restic snapshots in Google Drive
source /etc/proxmox-backup-restore/config.env
restic --repo "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
  --password-file "${RESTIC_PASSWORD_FILE}" snapshots

# Check PBS snapshots locally
PBS_PASSWORD="<your-pbs-password>" PBS_FINGERPRINT="<fingerprint>" \
  proxmox-backup-client snapshots \
  --repository backup@pbs@127.0.0.1:local-store

# Check PBS datastore disk usage
df -h /mnt/pbs
df -i /mnt/pbs

# Remove stale restic locks (if backup crashed)
restic --repo "rclone:${RESTICPROFILE_GDRIVE_REMOTE}:${RESTICPROFILE_GDRIVE_PATH}" \
  --password-file "${RESTIC_PASSWORD_FILE}" unlock --remove-all
```

---

## CI Testing

Two Jenkins pipelines verify the scripts end-to-end on a weekly basis:

### Scenario A: `proxmox-restore-test` (nightly, `Jenkinsfile.restore-test`)

Clones template VM 9001, runs the full setup flow and verifies backups reach Google Drive:
1. Install PBS, rclone, restic, resticprofile (`restore-1-install.sh`)
2. Create a minimal Debian 12 LXC as backup target
3. PBS backup of the LXC
4. Backup PVE config to Google Drive (`backup-pve-config.sh`, includes `config.db`)
5. restic backup of PBS datastore to Google Drive
6. Verify at least one restic snapshot exists in Google Drive

### Scenario B: `proxmox-dr-test` (weekly Sunday, `Jenkinsfile.dr-test`)

Simulates a full disaster recovery on a fresh VM:
1. Install PBS, rclone, restic, resticprofile (`restore-1-install.sh`)
2. Download config tar from Google Drive to `/tmp/`, then **delete rclone.conf** — forces the manual DR path (no pre-configured GDrive auth)
3. Run `restore-2-auth.sh` — finds local tar, extracts it (restores rclone + config.db), uses rclone to restore PBS datastore from GDrive
4. Verify `config.db` was restored: check LXC 100 (from Scenario A) is visible in PVE config
5. Wire PBS into PVE (`restore-3-pve.sh`)
6. Verify LXC snapshot is visible in PBS
7. Restore LXC 100 from PBS and verify it starts — proves full end-to-end recovery

> ℹ️ Scenario B depends on Scenario A having run at least once (needs a restic snapshot and config tar on Google Drive).

---

## Notes

- **PBS datastore uses ext4 with default inode ratio** — do NOT format with `-T largefile4`.
  PBS creates millions of small chunk files and will run out of inodes with large-file tuning.
- **restic stores PBS chunks as-is** (already deduplicated by PBS), so Google Drive usage
  ≈ local PBS datastore size — not double.
- **First restic snapshot** takes hours; subsequent snapshots are incremental and fast.
- **pbs-enterprise.sources** is automatically removed after PBS install — this repo requires
  a paid Proxmox subscription and causes 401 errors and potential package conflicts.
- **ARM64 (Pi5):** uses [pipbs](https://github.com/dexogen/pipbs) community repo for PBS.
  The pxvirt repo (lierfang) provides QEMU/KVM. Keep these repos separate — mixing versions
  can cause GUI rendering issues in the Proxmox web interface.
- **config.db WAL checkpoint:** `backup-pve-config.sh` runs `PRAGMA wal_checkpoint(FULL)` before
  archiving to ensure all recent writes (VM creates, storage changes) are flushed from the
  SQLite WAL file into the main database. Without this, the backup could capture a stale
  `config.db` missing recent changes.
- **pmxcfs and config restore:** `/etc/pve/` is a FUSE filesystem managed by pmxcfs. Restoring
  PVE config requires restoring `/var/lib/pve-cluster/config.db` (the underlying SQLite database),
  not the `/etc/pve/` files directly. `restore-2-auth.sh` handles this by stopping pve-cluster
  before extraction and restarting it after, so pmxcfs rebuilds `/etc/pve/` from the restored database.
- **proxmox-backup-client auth:** when running non-interactively, set `PBS_PASSWORD` and
  `PBS_FINGERPRINT` environment variables. The `--fingerprint` flag does not exist on the
  `snapshots` subcommand — use the env var instead.
