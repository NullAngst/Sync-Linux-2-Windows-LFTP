# lftp-ntfs-sync

A bash script for syncing directories from a Linux machine to a Windows machine over SFTP. Built for large transfers (multi-TiB), but works for any size.

## Why this exists

Moving files from Linux to Windows over SFTP seems simple until you run into the two problems this script solves:

**NTFS illegal characters** -- Linux filesystems (ext4, btrfs, zfs, xfs) allow characters in filenames that NTFS flat out rejects: `\ : * ? " < > |`. A colon in an album name or a question mark in a movie title means the file silently fails to transfer. This script renames those files on the source before transfer, replacing illegal characters with underscores.

**Dumb transfer tools** -- Most tools will either re-copy everything on every run (slow) or refuse to clean up orphaned files on the destination. This script uses `lftp mirror` to only copy what's missing and delete what shouldn't be there, giving you a true one-way sync.

---

## Features

- Only copies files **missing on the destination** -- never re-transfers files that already arrived
- **Deletes** files on the destination that no longer exist on the source (true sync)
- **NTFS filename sanitization** -- renames illegal characters in-place on the source before transfer
- Parallel file transfers and multi-segment per file to saturate your link
- One lftp session per configured directory -- a failure in one won't abort the others
- Timestamped logs for the main run and per-directory lftp detail logs
- Auto-retry and reconnect on connection drops

---

## Requirements

- **lftp** installed on the Linux machine
- **OpenSSH Server** installed on the Windows machine

### Install lftp

```bash
# Ubuntu / Debian
sudo apt install lftp

# Fedora / RHEL / CentOS
sudo dnf install lftp

# Arch
sudo pacman -S lftp
```

### Install OpenSSH Server on Windows

1. Open **Settings** > **Apps** > **Optional Features**
2. Click **Add a feature**
3. Find **OpenSSH Server** and install it
4. Open **Services**, find **OpenSSH SSH Server**, set it to **Automatic** and click **Start**

Alternatively via PowerShell (run as Administrator):

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

---

## Setup

### 1. Clone the repo

```bash
git clone https://github.com/yourusername/lftp-ntfs-sync.git
cd lftp-ntfs-sync
```

### 2. Edit sync.sh

Open `sync.sh` and fill in the configuration block at the top. Everything you need to change is clearly marked. You should not need to touch anything below the configuration section.

```bash
# Destination machine
DEST_HOST="192.168.1.100"   # IP or hostname of the Windows machine
DEST_USER="myusername"      # Windows username
DEST_PASS="mypassword"      # Password
DEST_PORT=22                # SSH port, 22 is the default

# Paths
SRC_BASE="/mnt/data/source" # Root of what you're syncing FROM on this machine
DEST_BASE="/E:/backup"      # Root of where it goes on Windows (see path format below)

# Which subdirectories to sync
SYNC_DIRS=(
    "Documents"
    "Photos"
    "Videos"
)
```

### 3. Set permissions

The password is stored in plaintext in the script, so lock it down:

```bash
chmod 700 sync.sh
```

### 4. Run it

```bash
./sync.sh
```

To run it in the background and walk away:

```bash
nohup ./sync.sh &> /var/log/lftp-sync/nohup.log &
echo $!   # prints the PID so you can monitor it
```

---

## Windows SFTP path format

Windows built-in OpenSSH exposes drives using the format `/DriveLetter:/path`.

| Windows path | SFTP path |
|---|---|
| `C:\backup` | `/C:/backup` |
| `E:\media\backup` | `/E:/media/backup` |
| `D:\` | `/D:/` |

Note: drive letters are case-insensitive here, `/e:/backup` and `/E:/backup` both work.

If you installed **Cygwin's sshd** instead of the Windows built-in, the format is different: `/cygdrive/e/backup`. Check which SSH server you're running if paths aren't resolving.

---

## Transfer tuning

The default settings (`PARALLEL_FILES=4`, `PARALLEL_SEGMENTS=8`) are tuned for a gigabit LAN. Adjust based on your situation:

| Scenario | Suggested settings |
|---|---|
| Gigabit LAN, mixed file sizes | `FILES=4, SEGMENTS=8` |
| Gigabit LAN, many large files (movies, ISOs) | `FILES=2, SEGMENTS=16` |
| Gigabit LAN, many small files (music, docs) | `FILES=8, SEGMENTS=2` |
| 100 Mbit LAN or slow link | `FILES=2, SEGMENTS=2` |
| WAN / internet transfer | `FILES=2, SEGMENTS=2` and reduce packet sizes in the lftp block |

Total concurrent TCP streams = `PARALLEL_FILES x PARALLEL_SEGMENTS`. On a LAN, 16-32 streams is a reasonable ceiling before you stop seeing gains.

---

## NTFS filename sanitization

NTFS forbids these characters in filenames:

```
\ : * ? " < > |
```

Linux allows all of them. This means files like these will fail silently when FileZilla or any naive tool tries to transfer them:

```
AC/DC: Live at Donington.flac
Movie (What Is This?).mkv
Interview "Raw Cut".mp4
```

Before the transfer begins, the script scans the entire source tree and renames any file or directory containing these characters, replacing each with `_`:

```
AC_DC_ Live at Donington.flac
Movie (What Is This_).mkv
Interview _Raw Cut_.mp4
```

**Important:** this modifies filenames on the source machine in place. If the source is a Plex or Jellyfin library, those tools may need a metadata refresh after the rename pass. Every rename is written to the main log so you have a full record.

To preview what would be renamed without changing anything:

```bash
find /your/source/path -print0 | grep -zP '[\\:*?"<>|]' | tr '\0' '\n'
```

---

## Logs

Logs are written to `LOG_DIR` (default `/var/log/lftp-sync`). Two types are created per run:

- `sync-YYYYMMDD_HHMMSS.log` -- main run log with timestamps, sanitization renames, per-directory start/done/error, and the final summary
- `lftp-YYYYMMDD_HHMMSS-DirectoryName.log` -- lftp detail log per directory showing every file transferred or deleted

If a directory fails, the lftp log for that directory is the first place to look.

---

## Scheduling with cron

To run the sync nightly at 2 AM:

```bash
crontab -e
```

Add:

```
0 2 * * * /path/to/sync.sh >> /var/log/lftp-sync/cron.log 2>&1
```

---

## Known limitations

- The password is stored in plaintext in the script. Use `chmod 700` and don't commit the configured script to a public repo. If you need better security, set up SSH key authentication and remove the password from the script (replace `DEST_PASS` with an empty string -- lftp will use your SSH key automatically).
- `--only-missing` compares by filename and size, not content checksum. If a file on the destination is corrupted but the same size, it won't be re-transferred. This is intentional for performance on large libraries -- if you need checksum validation, remove `--only-missing` and add `--use-cache`.
- NTFS also has reserved filenames (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`). The sanitizer does not currently handle these. They are rare in practice but if you have files named exactly `NUL.txt` or similar, Windows will reject them.

---

## License

MIT
