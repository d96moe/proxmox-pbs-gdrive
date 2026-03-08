# proxmox-backup-restore

Disaster recovery scripts for Proxmox VE with PBS + restic + rclone → Google Drive.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Proxmox VE Host                         │
│                                                              │
│  ┌──────────────┐  02:00   ┌──────────────────────────────┐ │
│  │  VMs & LXCs  │─backup──▶│  PBS (Proxmox Backup Server) │ │
│  │              │          │  /mnt/pbs  (LVM thin volume)  │ │
│  │  vm/100 Win  │          │  dedup + compressed chunks    │ │
│  │  vm/101 HAOS │          │  retention: last 3, daily 7,  │ │
│  │  vm/102 LLM  │          │  weekly 4                     │ │
│  │  ct/10x LXCs │          └──────────────┬───────────────┘ │
│  └──────────────┘                         │                  │
│                                      02:30 PBS stopped       │
│                                           │                  │
│                          ┌────────────────▼──────────────┐  │
│                          │  restic                        │  │
│                          │  reads PBS chunks as-is        │  │
│                          │  no re-compression needed      │  │
│                          └────────────────┬──────────────┘  │
│                                      PBS restarted           │
│                                           │                  │
│  ┌─────────────────────────┐  04:00       │                  │
│  │  PVE host config        │──────────────┤                  │
│  │  /etc/pve/              │  rclone      │                  │
│  │  /root/.config/rclone/  │  direct      │                  │
│  │  /etc/resticprofile/    │              │                  │
│  │  /etc/network/ etc      │              │                  │
│  └─────────────────────────┘              │                  │
└──────────────────────────────────────────┼──────────────────┘
                                           │
                          ┌────────────────▼──────────────┐
                          │  Google Drive                  │
                          │                                │
                          │  bu/proxmox_home/              │
                          │    restic repo                 │
                          │    retention: last 3, daily 6, │
                          │    weekly 3, monthly 5         │
                          │                                │
                          │  bu/proxmox_home_config/       │
                          │    pve-config-YYYY-MM-DD.tar.gz│
                          │    last 7 days kept            │
                          └────────────────────────────────┘
```

- **PBS** handles incremental, deduplicated VM/LXC backups locally
- **restic** snapshots the PBS datastore to Google Drive nightly
- **rclone** provides the Google Drive transport for restic

---

## How it works & why

### Why not just rclone directly to Google Drive?

The obvious approach — pointing rclone directly at the PBS datastore and syncing to
Google Drive — is known to break PBS. PBS stores backups as thousands of small chunk
files in a `.chunks/` directory, and relies on precise file metadata (atime, permissions,
ownership) to maintain the integrity of its deduplication index. rclone's sync operations
update atime and can alter permissions, which silently corrupts the chunk index. This is a
well-documented issue confirmed by multiple users in the Proxmox community.

### Why PBS + restic?

The solution is to use restic as a middle layer:

- **PBS** runs locally and does what it does best: incremental, deduplicated, compressed
  VM/LXC backups with a clean restore UI in Proxmox. Multiple restore points (last 3,
  daily for a week, weekly for a month) without multiplying disk usage thanks to deduplication.

- **restic** treats the entire PBS datastore as an opaque collection of files and backs it
  up to Google Drive. It never modifies the source, so PBS internals stay intact.

- **rclone** is used purely as a transport layer by restic, handling the Google Drive
  OAuth and API communication.

### Why stop PBS during the restic backup?

PBS must be stopped before restic takes its snapshot. If PBS is writing new chunks or
updating index files while restic reads the datastore, the result is an inconsistent
snapshot that cannot be restored. The `stop-proxmox-backup.sh` script waits until PBS
has no running tasks, stops it, lets restic run, then automatically restarts PBS when
done — or if it fails.

The nightly window looks like this:

```
02:00  PBS backup starts    (all VMs/LXCs backed up to local datastore)
02:30  restic starts        (PBS stopped -> snapshot to Google Drive -> PBS restarted)
03:00  PBS prune runs       (old local snapshots removed per retention policy)
03:30  restic forget runs   (old Google Drive snapshots removed per retention policy)
```

### What does incremental backup mean here?

There are two levels of incrementality:

**PBS level:** After the first backup, PBS only transfers changed blocks from each VM/LXC
disk. A 512GB Ollama VM with 86% empty space takes ~12 minutes the first time; subsequent
nightly backups take seconds to minutes if little has changed.

**restic level:** After the first upload to Google Drive (several hours), restic only
uploads new PBS chunks — the data from VMs that changed since last night. A typical
nightly restic run uploads a few hundred MB rather than the full datastore.

### Storage sizing

Because PBS already deduplicates and compresses, restic finds almost nothing to compress
further. restic copies PBS chunks as-is, so each restic snapshot on Google Drive is
the same size as the local PBS datastore at that point in time.

The two retention policies are deliberately different:

| | Local PBS | Google Drive (restic) |
|---|---|---|
| keep-last | 3 | 3 |
| keep-daily | 7 | 6 |
| keep-weekly | 4 | 3 |
| keep-monthly | — | 5 |

Google Drive keeps monthly snapshots for 5 months, giving longer history for disaster
recovery. Local PBS keeps fewer snapshots to conserve disk space on the NVMe datastore.
Since restic is incremental and PBS chunks are shared between snapshots, the extra
monthly snapshots on Google Drive cost very little additional storage.

---

## Backup Schedule

| Time  | Job |
|-------|-----|
| 02:00 | PBS backup all VMs/LXCs → local datastore |
| 02:30 | restic: PBS stopped → snapshot to Google Drive → PBS restarted |
| 03:00 | PBS prune (keep-last=3, keep-daily=7, keep-weekly=4) |
| 03:30 | restic forget (keep-last=3, keep-daily=6, keep-weekly=3, keep-monthly=5) |
| 04:00 | PVE host config backup → Google Drive (rclone direct, keep 7 days) |

---

## ⚠️ BEFORE YOU RUN ANYTHING — Edit config.env

All scripts source a single `config.env` file. Pre-configured templates are available:

```bash
cp config_home.env config.env    # Home Proxmox (x86_64, LVM)
cp config_cabin.env config.env   # Cabin Pi5 (aarch64, dir)
```

Key variables to review:

| Variable | Home | Cabin | Description |
|---|---|---|---|
| `STORAGE_TYPE` | `lvm-thin` | `dir` | Storage backend type |
| `PBS_DATASTORE_SIZE` | `350G` | n/a | Size of LVM volume |
| `PBS_USER_PASSWORD` | `changeme` | `changeme` | **Always change this!** |
| `RESTICPROFILE_GDRIVE_PATH` | `bu/proxmox_home` | `bu/proxmox_cabin` | GDrive restic repo |
| `GDRIVE_CONFIG_FOLDER` | `proxmox_home_config` | `proxmox_cabin_config` | GDrive config backup |

---

## Scenario A: Fresh Setup (first time, no existing backup)

Use this when setting up a new Proxmox instance from scratch.

### A1: Install Proxmox VE

1. Download Proxmox VE ISO from https://www.proxmox.com/downloads (x86_64)
   or set up Proxmox on Debian (aarch64/Pi5 — see community guides)
2. Configure network (hostname, IP, gateway, DNS)
3. SSH in as root and clone this repo:
   ```bash
   apt-get install -y git
   git clone https://github.com/d96moe/proxmox-backup-restore.git
   cd proxmox-backup-restore
   chmod +x *.sh
   ```

### A2: Edit config.env and run restore-1-install.sh

```bash
cp config_home.env config.env   # or config_cabin.env
nano config.env                 # set PBS_USER_PASSWORD at minimum
./restore-1-install.sh
```

> ⚠️ **Raspberry Pi 5 only:** The script detects if the kernel uses 16k page-size
> (incompatible with PBS) and offers to fix it and reboot automatically.
> Run the script again after reboot.

### A3: Configure rclone (Google Drive)

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

### A4: Save restic password and init repo

```bash
echo 'YOUR-RESTIC-PASSWORD' > /etc/resticprofile/restic-password
chmod 600 /etc/resticprofile/restic-password
resticprofile -c /etc/resticprofile/profiles.yaml -n pbs-backup init
```

> ⚠️ Store this password in a password manager — losing it means losing access to backups!

### A5: Run restore-3-pve.sh

Adds PBS as storage in PVE and activates nightly schedules:

```bash
./restore-3-pve.sh
```

### A6: Run first manual backup

```bash
# PBS backup of all VMs/LXCs
pvesh create /nodes/$(hostname)/vzdump --all 1 --storage pbs-local --mode snapshot --compress zstd

# restic backup of PBS datastore to Google Drive
resticprofile -c /etc/resticprofile/profiles.yaml -n pbs-backup backup
```

> ℹ️ First restic backup uploads the full PBS datastore — takes time depending on
> connection speed. Subsequent nightly backups are incremental and much faster.

---

## Scenario B: Disaster Recovery (restoring from existing backup)

Use this when replacing failed hardware. You already have backups in Google Drive.

> ℹ️ No need to set up rclone/OAuth manually — your existing rclone config and restic
> password are stored in the config tarball on Google Drive. Just download it first.

### B1: Install Proxmox VE

Same as A1.

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

This restores rclone config, restic password, resticprofile config, network settings
and all custom scripts — everything needed to reach Google Drive and decrypt backups.

Verify rclone works:
```bash
rclone lsd gdrive:bu
```

### B3: Edit config.env and run restore-1-install.sh

```bash
cd proxmox-backup-restore
nano config.env   # verify settings — rclone is already configured from tarball
./restore-1-install.sh
```

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

## Verified versions

Tested and working with these versions. Document for future reference — scripts are not
locked to these versions but use this as a baseline if something stops working.

| Component | Home (x86_64) | Cabin (aarch64/Pi5) |
|---|---|---|
| Proxmox VE | 9.1.4 | 9.0.10-2 |
| Proxmox Backup Server | 4.1.4-1 | 4.1.4-1 (pipbs community build) |
| rclone | 1.73.1 | 1.73.2 |
| restic | 0.18.0 | 0.18.0 |
| resticprofile | 0.32.0 | 0.32.0 |
| OS | Debian 13.3 (bookworm) | Raspbian 13.3 (trixie) |
| Kernel | 6.17.4-2-pve | 6.12.62+rpt-rpi-v8 (4k page-size) |

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

- PBS datastore uses **ext4 with default inode ratio** — do NOT format with `-T largefile4`
  as PBS creates many small chunk files and will run out of inodes
- restic stores PBS chunks as-is (already deduplicated by PBS), so Google Drive
  usage ≈ local PBS datastore size (not double)
- First restic snapshot takes several hours; subsequent snapshots are incremental and fast
- PBS is stopped during restic backup to ensure consistent snapshot
