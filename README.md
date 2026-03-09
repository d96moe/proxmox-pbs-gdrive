# proxmox-backup-restore

Disaster recovery and setup scripts for Proxmox VE with PBS + restic + rclone → Google Drive.

Supports both x86_64 (standard PVE install) and aarch64 (Raspberry Pi 5 with community ARM64 builds).

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

| Time  | Job |
|-------|-----|
| 02:00 | PBS backup all VMs/LXCs (via PVE schedule) |
| 02:30 | restic snapshot PBS datastore → Google Drive |
| 03:00 | PBS prune (local retention) |
| 03:30 | restic forget (Google Drive retention) |
| 04:00 | PVE host config tarball → Google Drive |

## Retention

| Storage | Retention |
|---------|-----------|
| PBS local | keep-last=3, keep-daily=3 |
| Google Drive (restic) | keep-last=3, keep-daily=6, keep-weekly=3, keep-monthly=5 |

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
cp config_home.env config.env    # Home Proxmox (x86_64, Minisforum)
cp config_cabin.env config.env   # Cabin Pi5 (aarch64, Raspberry Pi 5)
```

Key variables to set:

| Variable | Description |
|---|---|
| `PBS_PARTITION` | Dedicated PBS partition e.g. `/dev/sda3` or `/dev/nvme0n1p4` |
| `PBS_DATASTORE_PATH` | Mount point for PBS partition, default `/mnt/pbs` |
| `PBS_USER_PASSWORD` | **Always change this from `changeme`!** |
| `PBS_RETENTION_LOCAL` | Local PBS retention, default `keep-last=3,keep-daily=3` |
| `RESTICPROFILE_GDRIVE_PATH` | Google Drive restic repo path |
| `GDRIVE_CONFIG_FOLDER` | Google Drive config backup folder |
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
1. Install Debian on the Pi5
2. Follow community guide to install Proxmox VE on top of Debian
3. SSH in as root

### A1: Create PBS partition

Before running any scripts, create and format a dedicated partition for PBS.
See the **PBS Partition** section above.

### A2: Clone repo and edit config.env

```bash
apt-get install -y git
git clone https://github.com/d96moe/proxmox-backup-restore.git
cd proxmox-backup-restore
chmod +x *.sh
cp config_home.env config.env   # or config_cabin.env
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
- Install and enable the daily PVE config backup timer

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
echo 'YOUR-RESTIC-PASSWORD' > /etc/resticprofile/restic-password
chmod 600 /etc/resticprofile/restic-password
resticprofile -c /etc/resticprofile/profiles.yaml -n pbs-backup init
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
resticprofile -c /etc/resticprofile/profiles.yaml -n pbs-backup backup
```

> ℹ️ First restic backup uploads the full PBS datastore — takes time depending on connection speed.
> Subsequent nightly backups are incremental and much faster.

---

## Scenario B: Disaster Recovery (restoring from existing backup)

Use this when replacing failed hardware. You already have backups in Google Drive.

> ℹ️ No need to set up rclone/OAuth manually — your existing rclone config and restic
> password are stored in the config tarball on Google Drive. Just download it first.

### B0: Install Proxmox VE

Same as A0.

### B1: Create PBS partition

Same as A1 — create and format a dedicated PBS partition on the new hardware.

### B2: Download config tarball via browser

On any computer with a browser:

1. Go to https://drive.google.com
2. Navigate to `bu/proxmox_home_config/` (or `proxmox_cabin_config/`)
3. Download the latest `pve-config-YYYY-MM-DD.tar.gz`

Copy it to the new Proxmox server and extract:
```bash
scp pve-config-YYYY-MM-DD.tar.gz root@YOUR-PVE-IP:/root/
ssh root@YOUR-PVE-IP
tar -xzf /root/pve-config-YYYY-MM-DD.tar.gz -C /
```

This restores rclone config, restic password, resticprofile config, fstab, network settings
and all custom scripts — everything needed to reach Google Drive and decrypt backups.

Verify rclone works:
```bash
rclone lsd gdrive:bu
```

### B3: Clone repo, edit config.env, run restore-1-install.sh

```bash
apt-get install -y git
git clone https://github.com/d96moe/proxmox-backup-restore.git
cd proxmox-backup-restore
chmod +x *.sh
cp config_home.env config.env   # or config_cabin.env
nano config.env                 # verify PBS_PARTITION matches new hardware, check password
./restore-1-install.sh
```

> ℹ️ rclone is already configured from the extracted tarball — skip OAuth setup.

### B4: Run restore-2-auth.sh

Downloads and restores the full PBS datastore from Google Drive:

```bash
./restore-2-auth.sh
```

> ⚠️ Downloading the PBS datastore takes several hours (size depends on your setup).

### B5: Run restore-3-pve.sh

```bash
./restore-3-pve.sh
```

### B6: Restore VMs/LXCs via Proxmox GUI

> ⚠️ After a full recovery there are no VMs yet — navigate to PBS storage directly:

1. Open Proxmox web GUI
2. Go to **Datacenter → Storage → pbs-local → Content** tab
3. All PBS snapshots are listed here regardless of whether the VMs exist
4. Select a snapshot → **Restore** → enter the VM/LXC ID
5. Repeat for each VM/LXC

---

## Verify Backup Health

```bash
# Check restic schedule timers
systemctl list-timers | grep restic

# List restic snapshots in Google Drive
resticprofile -c /etc/resticprofile/profiles.yaml -n pbs-backup snapshots

# Check PBS snapshots locally
proxmox-backup-client snapshots --repository backup@pbs@127.0.0.1:local-store

# Check PBS datastore disk usage
df -h /mnt/pbs
df -i /mnt/pbs
```

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
