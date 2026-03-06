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

#### Configure rclone manually (requires browser)

```bash
rclone config
```

- Choose `n` (new remote)
- Name: `gdrive`
- Type: `drive` (Google Drive)
- Use your own client_id/secret (Desktop app type in Google Cloud Console)
- Scope: `1` (full access)
- When asked about browser auth: choose `n`, then open the provided URL in a browser on another machine

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
