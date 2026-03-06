# proxmox-backup-restore

Disaster recovery scripts for Proxmox VE with PBS + restic + rclone → Google Drive.

## Architecture

```
Proxmox VE (nightly)
    └── PBS (Proxmox Backup Server) → /mnt/pbs (LVM thin volume)
            └── restic (02:30 nightly) → rclone → Google Drive (bu/proxmox_home)
```

- **PBS** handles incremental, deduplicated VM/LXC backups locally
- **restic** snapshots the PBS datastore to Google Drive nightly
- **rclone** provides the Google Drive transport for restic

## Backup Schedule

| Time  | Job |
|-------|-----|
| 02:00 | PBS backup all VMs/LXCs |
| 02:30 | restic snapshot PBS datastore → Google Drive |
| 03:00 | PBS prune (keep-last=3, keep-daily=7, keep-weekly=4) |
| 03:30 | restic forget (keep-last=3, keep-daily=6, keep-weekly=3, keep-monthly=5) |

## Disaster Recovery Procedure

### Prerequisites

Before running the scripts you need:
- A fresh Proxmox VE installation on new hardware
- Network configured (same hostname/IP recommended)
- Internet access to reach Google Drive
- Your restic repository password (store this somewhere safe!)

---

### Step 0: Manual — Install Proxmox VE

1. Download Proxmox VE ISO from https://www.proxmox.com/downloads
2. Boot from ISO and install
3. Configure network (hostname, IP, gateway, DNS)
4. SSH in as root

---

### Step 1: Run restore-1-install.sh

Installs PBS, rclone, restic, resticprofile and prepares storage.

```bash
chmod +x restore-1-install.sh
./restore-1-install.sh
```

**After script completes:**

#### A) Create Google OAuth credentials (one-time setup)

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

> ⚠️ If you see a warning about the app being unverified, that is expected for personal OAuth apps.
> If prompted to configure OAuth consent screen: choose **External**, fill in app name (e.g. "rclone"),
> add your Gmail address as both developer and test user, save and continue through all steps.

#### B) Configure rclone on the PVE server

Since the PVE server has no browser, you need a second machine (Windows/Mac/Linux with a browser) nearby.

On the **PVE server**, run:

```bash
rclone config
```

Follow the prompts:

```
n          # New remote
gdrive     # Name (must match RESTICPROFILE_GDRIVE_REMOTE in scripts)
drive      # Type: Google Drive
           # Paste your Client ID from step A
           # Paste your Client Secret from step A
1          # Scope: full access
           # Leave blank (no service account)
n          # No advanced config
n          # No auto browser auth (server has no browser)
```

rclone will now print a command like (the token string will be unique each time):
```
rclone authorize "drive" "<YOUR-UNIQUE-TOKEN-STRING>"
```

Copy the exact command from your terminal. On your **Windows/Mac machine** (with rclone installed, see https://rclone.org/downloads/), paste and run it:

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
# Should list folders in your Google Drive bu/ folder
```

#### Save restic password

```bash
echo 'YOUR-RESTIC-PASSWORD' > /etc/resticprofile/restic-password
chmod 600 /etc/resticprofile/restic-password
```

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

Configures PBS, sets up PVE storage integration and schedules.

```bash
chmod +x restore-3-pve.sh
./restore-3-pve.sh
```

---

### Step 4: Manual — Restore VMs/LXCs via Proxmox GUI

1. Open Proxmox web GUI
2. Navigate to the VM/LXC you want to restore
3. Click **Backup** tab
4. Select storage `pbs-local` in the dropdown (top right)
5. Select the desired snapshot
6. Click **Restore**

---

## Verify Backup Health

Check that nightly backups are running:

```bash
# Check restic schedule
systemctl list-timers | grep restic

# List restic snapshots in Google Drive
resticprofile -c /etc/resticprofile/profiles.yaml -n pbs-backup snapshots

# Check PBS snapshots
proxmox-backup-client snapshots --repository backup@pbs@127.0.0.1:local-store

# Check PBS datastore disk usage
df -h /mnt/pbs
df -i /mnt/pbs
```

## Notes

- PBS datastore uses **ext4 with default inode ratio** — do NOT format with `-T largefile4` as PBS creates many small chunk files
- restic stores PBS chunks as-is (already deduplicated by PBS), so Google Drive usage ≈ local PBS datastore size
- First restic snapshot takes several hours; subsequent snapshots are incremental and fast
- PBS is stopped during restic backup to ensure consistent snapshot (run-before/run-after in resticprofile)
