#!/usr/bin/env bash

# ==============================================================================
# sync.sh -- Linux to Windows SFTP sync via lftp
#
# Mirrors one or more source directories on a Linux machine to a remote Windows
# machine over SFTP using lftp. Designed for large transfers (multi-TiB).
#
# Features:
#   - Only copies files missing on the destination (never overwrites)
#   - Deletes files on destination that no longer exist on source (true sync)
#   - Sanitizes filenames before transfer -- replaces NTFS-illegal characters
#     ( \ : * ? " < > | ) with underscores so Windows can actually receive them
#   - Parallel file transfers and multi-segment per file for LAN saturation
#   - Per-directory lftp logs plus a main run log
#   - Automatic retry and reconnect on connection drops
#
# Requirements:
#   - lftp  (sudo apt install lftp  /  sudo dnf install lftp)
#   - OpenSSH server running on the Windows machine
#     (Settings > Apps > Optional Features > OpenSSH Server)
#
# Usage:
#   chmod 700 sync.sh       # keep permissions tight since password is stored here
#   ./sync.sh               # run interactively
#   nohup ./sync.sh &       # run in background, survives terminal close
#
# WINDOWS SFTP PATH FORMAT:
#   Windows built-in OpenSSH exposes drives as /DriveLetter:/path
#   Examples:
#     C:\backup\media  -->  /C:/backup/media
#     E:\backup        -->  /E:/backup
#   If you are using Cygwin's sshd instead, the format is /cygdrive/e/backup
# ==============================================================================

set -uo pipefail

# ==============================================================================
# CONFIGURATION -- Edit this section before running
# ==============================================================================

# ------------------------------------------------------------------------------
# Destination (Windows machine)
# ------------------------------------------------------------------------------
DEST_HOST="192.168.1.100"      # IP address or hostname of the Windows machine
DEST_USER="myusername"         # Windows username to SSH in as
DEST_PASS="mypassword"         # Password -- file should be chmod 700
DEST_PORT=22                   # SSH port -- 22 is default, change if you moved it

# ------------------------------------------------------------------------------
# Paths
# ------------------------------------------------------------------------------
SRC_BASE="/mnt/data/source"    # Root directory on this Linux machine to sync from

DEST_BASE="/E:/backup"         # Root directory on the Windows machine to sync to
                               # See WINDOWS SFTP PATH FORMAT note in the header above

# ------------------------------------------------------------------------------
# Directories to sync
#
# Each entry here is a subdirectory name under SRC_BASE that will be mirrored
# to the same name under DEST_BASE.
#
# Example: if SRC_BASE="/mnt/data/source" and you list "Movies" here, then
#   /mnt/data/source/Movies  -->  /E:/backup/Movies
#
# Directories that don't exist on the source are skipped with a log message.
# Add as many entries as you need. Spaces in names are fine -- use quotes.
# ------------------------------------------------------------------------------
SYNC_DIRS=(
    "Documents"
    "Photos"
    "Videos"
    "Music"
    "My Directory With Spaces"
    # "AnotherDirectory"      # comment out entries to temporarily skip them
)

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
LOG_DIR="/var/log/lftp-sync"   # Where to write logs. Must be writable.
                               # Change to e.g. "$HOME/logs/lftp-sync" if you
                               # don't want to write to /var/log

# ------------------------------------------------------------------------------
# Transfer tuning
#
# PARALLEL_FILES    -- how many files to transfer simultaneously per directory
# PARALLEL_SEGMENTS -- how many TCP segments per file (pget -n)
#
# Total concurrent streams = PARALLEL_FILES x PARALLEL_SEGMENTS
#
# Rule of thumb for a gigabit LAN:
#   ~100 MB/s available --> 4 files x 8 segments = 32 streams works well
#
# For slower links (e.g. 100 Mbit or WAN):
#   Reduce both values -- try 2 files x 2 segments to start
#
# For very large files (movies, ISOs, disk images):
#   More segments per file helps more than more parallel files
#   Try: PARALLEL_FILES=2, PARALLEL_SEGMENTS=16
#
# For many small files (music, documents, photos):
#   More parallel files helps more than more segments
#   Try: PARALLEL_FILES=8, PARALLEL_SEGMENTS=2
# ------------------------------------------------------------------------------
PARALLEL_FILES=4
PARALLEL_SEGMENTS=8

# ==============================================================================
# END OF CONFIGURATION -- You should not need to edit anything below this line
# ==============================================================================

# ------------------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------------------
mkdir -p "$LOG_DIR"
MAIN_LOG="${LOG_DIR}/sync-$(date '+%Y%m%d_%H%M%S').log"
LFTP_LOG="${LOG_DIR}/lftp-$(date '+%Y%m%d_%H%M%S').log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$MAIN_LOG"
}

# ------------------------------------------------------------------------------
# Preflight checks
# ------------------------------------------------------------------------------
if ! command -v lftp &>/dev/null; then
    echo "ERROR: lftp not found."
    echo "  Ubuntu/Debian:  sudo apt install lftp"
    echo "  Fedora/RHEL:    sudo dnf install lftp"
    echo "  Arch:           sudo pacman -S lftp"
    echo "  openSUSE:       sudo zypper in lftp"
    exit 1
fi

# ------------------------------------------------------------------------------
# NTFS sanitization
#
# NTFS forbids these characters in filenames:  \ : * ? " < > |
# Linux (ext4, btrfs, zfs, xfs, etc.) allows all of them, so any file on your
# Linux machine containing these characters will fail to transfer to Windows.
#
# This function renames offending files and directories IN PLACE on the source
# before the transfer begins, replacing each illegal character with an underscore.
#
# Order of operations:
#   1. Rename files deepest-first so no filepath goes stale mid-pass
#   2. Rename directories deepest-first after all files are clean
#
# Collision handling:
#   If the sanitized name already exists, a numeric suffix is appended before
#   the extension: file_.mkv becomes file__1.mkv, file__2.mkv, etc.
#   Nothing is ever silently overwritten.
#
# All renames are written to the main log.
# ------------------------------------------------------------------------------
sanitize_source() {
    local base="$1"
    local rename_count=0
    local conflict_count=0
    local error_count=0

    log "SANITIZE -- scanning ${base} for NTFS-illegal characters ( \\ : * ? \" < > | ) ..."

    # -- Files (deepest paths first) ------------------------------------------
    while IFS= read -r -d '' filepath; do
        local dir basename newname newpath
        dir=$(dirname "$filepath")
        basename=$(basename "$filepath")
        newname=$(echo "$basename" | sed 's/[\\:*?"<>|]/_/g')

        [[ "$newname" == "$basename" ]] && continue

        newpath="${dir}/${newname}"

        if [[ -e "$newpath" ]]; then
            local stem ext counter=1
            if [[ "$newname" == *.* && "${newname#.}" == *"."* ]]; then
                stem="${newname%.*}"
                ext=".${newname##*.}"
            else
                stem="$newname"
                ext=""
            fi
            while [[ -e "${dir}/${stem}_${counter}${ext}" ]]; do
                (( counter++ ))
            done
            newpath="${dir}/${stem}_${counter}${ext}"
            log "  CONFLICT  \"${filepath}\"  ->  \"${newpath}\""
            (( conflict_count++ ))
        else
            log "  RENAME    \"${filepath}\"  ->  \"${newpath}\""
        fi

        if mv -- "$filepath" "$newpath" 2>>"$MAIN_LOG"; then
            (( rename_count++ ))
        else
            log "  ERROR     could not rename \"${filepath}\""
            (( error_count++ ))
        fi
    done < <(find "$base" -depth -not -type d -print0 2>/dev/null | grep -zP '[\\:*?"<>|]')

    # -- Directories (deepest first, after files are clean) -------------------
    while IFS= read -r -d '' dirpath; do
        local parent basename newname newpath
        parent=$(dirname "$dirpath")
        basename=$(basename "$dirpath")
        newname=$(echo "$basename" | sed 's/[\\:*?"<>|]/_/g')

        [[ "$newname" == "$basename" ]] && continue

        newpath="${parent}/${newname}"

        if [[ -e "$newpath" ]]; then
            log "  CONFLICT  dir \"${dirpath}\"  ->  \"${newpath}\" -- already exists, skipping"
            (( conflict_count++ ))
            continue
        fi

        log "  RENAME    dir \"${dirpath}\"  ->  \"${newpath}\""
        if mv -- "$dirpath" "$newpath" 2>>"$MAIN_LOG"; then
            (( rename_count++ ))
        else
            log "  ERROR     could not rename dir \"${dirpath}\""
            (( error_count++ ))
        fi
    done < <(find "$base" -depth -type d -print0 2>/dev/null | grep -zP '[\\:*?"<>|]')

    log "SANITIZE -- complete: ${rename_count} renamed, ${conflict_count} conflicts handled, ${error_count} errors."
    return $error_count
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
log "============================================================"
log " lftp-ntfs-sync starting"
log " Source      : $SRC_BASE"
log " Destination : sftp://${DEST_USER}@${DEST_HOST}${DEST_BASE}"
log " Directories : ${SYNC_DIRS[*]}"
log " Streams     : ${PARALLEL_FILES} files x ${PARALLEL_SEGMENTS} segments"
log " Log         : $MAIN_LOG"
log "============================================================"

OVERALL_START=$(date +%s)
ERRORS=0

# Sanitize the entire source tree before any transfers begin
sanitize_source "$SRC_BASE"

# ------------------------------------------------------------------------------
# Sync loop
#
# Runs one lftp session per directory in SYNC_DIRS. Keeping sessions separate
# means a failure or stall in one directory does not abort the others, and
# lftp detail logs stay clean and readable per directory.
# ------------------------------------------------------------------------------
for DIR in "${SYNC_DIRS[@]}"; do
    SRC_PATH="${SRC_BASE}/${DIR}"
    DEST_PATH="${DEST_BASE}/${DIR}"
    DIR_LOG="${LFTP_LOG%.log}-${DIR// /_}.log"

    if [[ ! -d "$SRC_PATH" ]]; then
        log "SKIP  [$DIR] -- source directory not found: $SRC_PATH"
        continue
    fi

    log "START [$DIR]"
    DIR_START=$(date +%s)

    lftp \
        -u "${DEST_USER},${DEST_PASS}" \
        -p "${DEST_PORT}" \
        "sftp://${DEST_HOST}" <<LFTP_CMDS
# -- Connection reliability ----------------------------------------------------
set net:timeout 60
set net:max-retries 10
set net:reconnect-interval-base 10
set net:reconnect-interval-multiplier 2
set net:reconnect-interval-max 300

# -- SFTP tuning (optimized for LAN; reduce packet sizes for WAN) --------------
set sftp:auto-confirm yes
set sftp:max-packets-in-flight 256
set sftp:size-read 131072
set sftp:size-write 131072

# -- Transfer settings ---------------------------------------------------------
set mirror:use-pget-n ${PARALLEL_SEGMENTS}

# mirror flags:
#   --reverse        push local --> remote (default direction is pull)
#   --only-missing   skip files that already exist on the remote side
#   --delete         remove files on destination not present on source
#   --ignore-time    match by name+size only; Windows timestamps are unreliable
#   --no-empty-dirs  do not create empty directories on the remote
#   --verbose=1      log each transferred file
#   --parallel       number of simultaneous file transfers
mirror \
    --reverse \
    --only-missing \
    --delete \
    --ignore-time \
    --no-empty-dirs \
    --verbose=1 \
    --log="${DIR_LOG}" \
    --parallel=${PARALLEL_FILES} \
    "${SRC_PATH}" \
    "${DEST_PATH}"

bye
LFTP_CMDS

    EXIT_CODE=$?
    DIR_END=$(date +%s)
    ELAPSED=$(( DIR_END - DIR_START ))
    ELAPSED_FMT=$(printf '%02dh %02dm %02ds' $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) $((ELAPSED%60)))

    if [[ $EXIT_CODE -eq 0 ]]; then
        log "DONE  [$DIR] -- completed in ${ELAPSED_FMT}"
    else
        log "ERROR [$DIR] -- lftp exited with code ${EXIT_CODE} after ${ELAPSED_FMT}. See: ${DIR_LOG}"
        ERRORS=$(( ERRORS + 1 ))
    fi
done

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
OVERALL_END=$(date +%s)
TOTAL=$(( OVERALL_END - OVERALL_START ))
TOTAL_FMT=$(printf '%02dh %02dm %02ds' $((TOTAL/3600)) $(((TOTAL%3600)/60)) $((TOTAL%60)))

log "============================================================"
log " Sync finished in ${TOTAL_FMT}"
log " Directories with errors: ${ERRORS}"
log " Full log  : $MAIN_LOG"
log " lftp logs : ${LOG_DIR}/"
log "============================================================"

exit $ERRORS
