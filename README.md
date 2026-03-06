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
└──────────────────────────────────────────┼──────────────────┘
                                           │ rclone (Google Drive transport)
                                           ▼
                          ┌───────────────────────────────┐
                          │  Google Drive                  │
                          │  bu/proxmox_home               │
                          │  restic repository             │
                          │  retention: last 3, daily 6,   │
                          │  weekly 3, monthly 5           │
                          └───────────────────────────────┘
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
| 02:00 | PBS backup all VMs/LXCs |
| 02:30 | restic snapshot PBS datastore → Google Drive |
| 03:00 | PBS prune (keep-last=3, keep-daily=7, keep-weekly=4) |
| 03:30 | restic forget (keep-last=3, keep-daily=6, keep-weekly=3, keep-monthly=5) |

---

## ⚠️ BEFORE YOU RUN ANYTHING — Edit config.env

All scripts source a single `config.env` file. **You must review and edit this file
before running any script.** The defaults are set for the home Proxmox instance.

Open `config.env` and verify/change the following:

| Variable | Default | Change for cabin? | Description |
|---|---|---|---|
| `PBS_DATASTORE_SIZE` | `350G` | **YES** → `100G` | Size of LVM volume for PBS |
| `PBS_LVM_VG` | `pve` | Verify with `vgs` | LVM volume group |
| `PBS_LVM_THIN_POOL` | `data` | Verify with `lvs` | LVM thin pool |
| `PBS_USER_PASSWORD` | `changeme` | **YES — always** | Set a strong password! |
| `RESTICPROFILE_GDRIVE_PATH` | `bu/proxmox_home` | **YES** → `bu/proxmox_cabin` | Google Drive path |

To verify LVM names on your system before editing:
```bash
vgs   # shows volume group names
lvs   # shows logical volume and pool names
```

---

## Disaster Recovery Procedure

### Prerequisites

Before running the scripts you need:
- A fresh Proxmox VE installation on new hardware
- Network configured (same hostname/IP recommended)
- Internet access to reach Google Drive
- Your restic repository password (store this somewhere safe, e.g. a password manager!)

---

### Step 0: Manual — Install Proxmox VE

1. Download Proxmox VE ISO from https://www.proxmox.com/downloads
2. Boot from ISO and install
3. Configure network (hostname, IP, gateway, DNS)
4. SSH in as root
5. Clone or copy this repo to the server:
   ```bash
   apt-get install -y git
   git clone https://github.com/YOUR-USERNAME/proxmox-backup-restore.git
   cd proxmox-backup-restore
   ```

---

### Step 1: Edit config.env, then run restore-1-install.sh

See the table above. Edit `config.env` first, then:

```bash
chmod +x restore-1-install.sh
./restore-1-install.sh
```

The script will print your configuration and ask you to confirm before doing anything.

**After script completes:**

#### A) Create Google OAuth credentials (one-time setup, skip if you already have these)

You need a **Desktop app** OAuth client in Google Cloud Console. Do this from any browser:

1. Go to https://console.cloud.google.com
2. Select your project (or create a new one)
3. Navigate to **APIs & Services → Library**
4. Search for **Google Drive API** and click **Enable**
5. Navigate to **APIs & Services → Credentials**
6. Click **+ Create Credentials → OAuth client ID**
7. Application type: **Desktop app**
8. Name: `rclone` (or anything)
9. Click **Create**
10. Copy the **Client ID** and **Client Secret** — you will need these in the next step

> ⚠️ If prompted to configure OAuth consent screen: choose **External**, fill in app name
> (e.g. "rclone"), add your Gmail address as both developer and test user, save and continue.

#### B) Configure rclone on the PVE server

Since the PVE server has no browser, you need a second machine (Windows/Mac/Linux with
a browser) with rclone installed (https://rclone.org/downloads/).

On the **PVE server**, run:

```bash
rclone config
```

Follow the prompts:

```
n          # New remote
gdrive     # Name — must match RESTICPROFILE_GDRIVE_REMOTE in config.env
drive      # Type: Google Drive
           # Paste your Client ID from step A
           # Paste your Client Secret from step A
1          # Scope: full access
           # Leave blank (no service account file)
n          # No advanced config
n          # No auto browser auth (server has no browser)
```

rclone will now print a command like:
```
rclone authorize "drive" "<YOUR-UNIQUE-TOKEN-STRING>"
```

Copy the **exact command** from your terminal. On your **Windows/Mac machine**, paste and run it:
```
rclone authorize "drive" "<YOUR-UNIQUE-TOKEN-STRING>"
```

This opens a browser window — log in with your Google account and click Allow.
Copy the resulting token (long JSON string) and paste it back into the PVE server terminal.

```
n          # Not a shared/team drive
y          # Confirm and save
q          # Quit config
```

#### C) Verify rclone works

```bash
rclone lsd gdrive:bu
# Should list folders including proxmox_home (or proxmox_cabin)
```

#### D) Save restic password

```bash
echo 'YOUR-RESTIC-PASSWORD' > /etc/resticprofile/restic-password
chmod 600 /etc/resticprofile/restic-password
```

> ⚠️ This password is required to access the backup. Store it in a password manager!

---

### Step 2: Run restore-2-auth.sh

Verifies Google Drive access and restores PBS datastore from restic.

```bash
chmod +x restore-2-auth.sh
./restore-2-auth.sh
```

⚠️ This will download ~190GB+ from Google Drive. Allow several hours.

---

### Step 3: Run restore-3-pve.sh

Configures PBS, sets up PVE storage integration and activates nightly schedules.

```bash
chmod +x restore-3-pve.sh
./restore-3-pve.sh
```

---

### Step 4: Manual — Restore VMs/LXCs via Proxmox GUI

> ⚠️ After a full disaster recovery there are no VMs or LXCs yet — so you cannot
> navigate to a VM and click its Backup tab. Instead, browse the PBS storage directly:

1. Open Proxmox web GUI
2. Go to **Datacenter → Storage → pbs-local**
3. Click the **Content** tab
4. All snapshots from the PBS datastore are listed here, regardless of whether the VMs exist
5. Select a snapshot and click **Restore**
6. Enter the VM/LXC ID to restore it as (use the original ID or a new one)
7. Repeat for each VM/LXC you want to restore

If you only want to restore a single VM (not a full recovery), you can also navigate
to that VM → **Backup** tab → select `pbs-local` in the dropdown (top right) → Restore.

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
