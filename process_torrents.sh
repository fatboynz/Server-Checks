#!/bin/bash

# ==============================================================================
# SCRIPT: 00_process_torrents.sh
# DESCRIPTION: Finds files (default: everything matched by find filter), processes
#              them with FileBot (e.g., renaming/organizing), and then optionally
#              handles the original file (KEEP/TRASH/DELETE).
#              Sends a rich Discord embed for EVERY file processed.
# AUTHOR: Jonathan Pickard (spliced for Discord notifications)
# DATE: 2025-06-14
# ==============================================================================

set -u  # (No -e: we want to continue even if a command fails)

# --- CONFIGURATION (EDIT THESE VARIABLES TO SUIT YOUR NEEDS) ---
SEARCH_DIR="/srv/Share/torrents/"
OUTPUT_DIR="/srv/TVShows/"
# Discord Webhook (rich embed per file)
DISCORD_WEBHOOK="https://discord.com/api/webhooks/"
PUSHOVER="/home/jdip/Scripts/00_pushover_script.sh"
FILEBOT_FORMAT="-non-strict --order Airdate --conflict auto --def movieDB=TheMovieDB seriesDB=TheTVDB"
FILEBOT_ACTION="copy"  # 'copy' (safer) or 'move'

# Options for what to do with the original file after FileBot processes it:
# "DELETE" : Permanently deletes the original file (use with extreme caution!)
# "TRASH"  : Moves the original file to TRASH_DIR
# "KEEP"   : Leaves the original as-is
ORIGINAL_FILE_ACTION="KEEP"

# Excludes for FileBot & find:
FILEBOT_EXCLUDE="--def excludeList=/home/jdip/amc.excludes"
# Use an array for find excludes to avoid quoting bugs
FIND_EXCLUDE=(-not -name "*qB*")
FIND_TIME="-mtime -3"
TRASH_DIR="$HOME/FileBot_Processed_Trash"

# Dry run (no FileBot or file deletion/moves). A Discord message still sends,
# but marked as DRY-RUN in the embed description.
DRY_RUN="false"

# Skip confirmation prompts for each file (DANGEROUS if action is DELETE).
AUTO_CONFIRM="true"

# ==============================================================================

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -s <directory>  Set the search directory (default: $SEARCH_DIR)"
    echo "  -o <directory>  Set the FileBot output directory (default: $OUTPUT_DIR)"
    echo "  -f <format>     Set the FileBot format string (default: \"$FILEBOT_FORMAT\")"
    echo "  -a <action>     Set action for original file (DELETE, TRASH, KEEP; default: $ORIGINAL_FILE_ACTION)"
    echo "  -t <directory>  Set trash directory if action is TRASH (default: $TRASH_DIR)"
    echo "  --filebot-action <copy|move>  Set FileBot's internal action (default: $FILEBOT_ACTION)"
    echo "  --dry-run       Perform a dry run (no actual changes)"
    echo "  --auto-confirm  Skip confirmation prompts for each file (use with caution!)"
    echo "  -h, --help      Display this help message"
    echo ""
    echo "Examples:"
    echo "  $0"
    echo "  $0 -s /mnt/media -o /mnt/organized --dry-run"
    echo "  $0 -s . -f \"Movies/{n} ({y})/{n} ({y})\" -a DELETE --auto-confirm"
    exit 1
}

# ----------------- Tell Pushover  -----------------

bash $PUSHOVER "Wendy Update" "WendyCron - Running the torrent clean up script"



# ----------------- Small helpers (portable) -----------------

# Portable file size in bytes (GNU/BSD)
file_size_bytes() {
    local p="$1"
    if command -v stat >/dev/null 2>&1; then
        # GNU stat
        stat -c %s "$p" 2>/dev/null && return 0
        # BSD/macOS stat
        stat -f %z "$p" 2>/dev/null && return 0
    fi
    # Fallback
    wc -c < "$p" 2>/dev/null || echo 0
}

# MIME type best-effort
mime_type() {
    local p="$1"
    if command -v file >/dev/null 2>&1; then
        file --mime-type -b "$p" 2>/dev/null && return 0
    fi
    echo "application/octet-stream"
}

# Human-readable size
size_human() {
    local bytes="$1"
    local unit="B"
    local value="$bytes"
    local div=0
    local units=(B KB MB GB TB PB)
    while (( value >= 1024 && div < ${#units[@]}-1 )); do
        value=$(( value / 1024 ))
        ((div++))
    done
    # If we want a nicer 1 decimal output, try awk (if present)
    if command -v awk >/dev/null 2>&1; then
        local fbytes="$bytes"
        local i=0
        local fvalue="$fbytes"
        while (( $(printf "%.0f" "$fvalue") >= 1024 && i < ${#units[@]}-1 )); do
            fvalue=$(awk -v v="$fvalue" 'BEGIN{printf "%.1f", v/1024}')
            ((i++))
        done
        echo "$fvalue ${units[$i]}"
    else
        echo "$value ${units[$div]}"
    fi
}

# JSON escape (minimal, good enough for filenames/notes)
json_escape() {
    # Escape backslashes and quotes; also newlines
    echo -n "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

# Retry POST to Discord with simple backoff
discord_post_json() {
    local json="$1"
    local max_retries=5
    local attempt=1
    local backoff=1

    while (( attempt <= max_retries )); do
        # shellcheck disable=SC2155
        local resp_code=$(curl -sS -o /dev/null -w "%{http_code}" \
            -H "Content-Type: application/json" \
            -X POST "$DISCORD_WEBHOOK" \
            --data "$json" 2>/dev/null || echo "000")

        # 204 is the usual success for webhooks; accept any 2xx
        if [[ "$resp_code" =~ ^2[0-9][0-9]$ ]]; then
            return 0
        fi

        # 429 or 5xx -> retry with backoff
        if [[ "$resp_code" == "429" || "$resp_code" =~ ^5[0-9][0-9]$ || "$resp_code" == "000" ]]; then
            sleep "$backoff"
            if (( backoff < 20 )); then
                backoff=$(( backoff * 2 ))
            fi
            ((attempt++))
            continue
        fi

        # Other errors -> give up
        return 1
    done

    return 1
}

# Send a rich Discord embed for a processed file
send_discord_embed() {
    local file_path="$1"
    local ok="$2"          # "true" / "false"
    local started_ts="$3"  # epoch seconds (integer)
    local notes="$4"       # free text

    local fname="$(basename "$file_path")"
    local size_b=0
    if [[ -f "$file_path" ]]; then
        size_b="$(file_size_bytes "$file_path")"
    fi
    local size_hr
    size_hr="$(size_human "$size_b")"
    local mime
    mime="$(mime_type "$file_path")"
    local ended_ts
    ended_ts=$(date +%s)
    local duration=$(( ended_ts - started_ts ))

    local title
    local color
    if [[ "$ok" == "true" ]]; then
        title="✅ Processed: $fname"
        color=$((0x35C759))
    else
        title="❌ Failed: $fname"
        color=$((0xFF3B30))
    fi

    # DRY_RUN marker
    if [[ "$DRY_RUN" == "true" ]]; then
        notes="(DRY-RUN) ${notes}"
    fi

    # JSON escape dynamic fields
    local j_title j_notes j_fname j_mime j_size j_dur j_host
    j_title=$(json_escape "$title")
    j_notes=$(json_escape "$notes")
    j_fname=$(json_escape "$fname")
    j_mime=$(json_escape "$mime")
    j_size=$(json_escape "$size_hr")
    j_dur=$(json_escape "${duration}s")
    j_host=$(json_escape "$(hostname 2>/dev/null || echo file-processor)")

    # ISO timestamp
    local iso_ts
    iso_ts="$(date -Is)"

    # Build JSON payload (embed with fields)
    read -r -d '' payload <<EOF || true
{
  "username": "File Processor",
  "embeds": [
    {
      "title": "$j_title",
      "description": "$j_notes",
      "color": $color,
      "timestamp": "$iso_ts",
      "fields": [
        {"name": "File", "value": "$j_fname", "inline": false},
        {"name": "Size", "value": "$j_size", "inline": true},
        {"name": "MIME", "value": "\`$j_mime\`", "inline": true},
        {"name": "Duration", "value": "$j_dur", "inline": true}
      ],
      "footer": { "text": "$j_host" }
    }
  ]
}
EOF

    # Post and do not fail the whole script if it errors
    if ! discord_post_json "$payload"; then
        echo "[WARN] Failed to send Discord webhook for: $fname"
    fi
}

# ----------------- Parse arguments -----------------

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -s) SEARCH_DIR="$2"; shift ;;
        -o) OUTPUT_DIR="$2"; shift ;;
        -f) FILEBOT_FORMAT="$2"; shift ;;
        -a) ORIGINAL_FILE_ACTION=$(echo "$2" | tr '[:lower:]' '[:upper:]'); shift ;;
        -t) TRASH_DIR="$2"; shift ;;
        --filebot-action) FILEBOT_ACTION="$2"; shift ;;
        --dry-run) DRY_RUN="true" ;;
        --auto-confirm) AUTO_CONFIRM="true" ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter: $1"; usage ;;
    esac
    shift
done

# ----------------- Pre-flight -----------------

echo "--- Script Configuration ---"
echo "Search Directory: $SEARCH_DIR"
echo "FileBot Output Directory: $OUTPUT_DIR"
echo "FileBot Format: $FILEBOT_FORMAT"
echo "FileBot Internal Action: $FILEBOT_ACTION"
echo "Original File Action: $ORIGINAL_FILE_ACTION"
if [[ "$ORIGINAL_FILE_ACTION" == "TRASH" ]]; then
    echo "Trash Directory: $TRASH_DIR"
fi
echo "Dry Run: $DRY_RUN"
echo "Time Fram: $FIND_TIME"
echo "Auto Confirm: $AUTO_CONFIRM"
echo "Discord Webhook: $( [[ -n "$DISCORD_WEBHOOK" ]] && echo 'configured' || echo 'MISSING' )"
echo "----------------------------"
echo ""

# FileBot existence
#if ! command -v filebot >/dev/null 2>&1; then
#    echo "Error: FileBot is not installed or not in PATH."
#    echo "Install FileBot (https://www.filebot.net/) and ensure it's accessible."
#    # We won't exit hard—still allow loop/Discord notifications to flow if desired
#fi

# Ensure output/trash dirs (unless dry-run)
if [[ "$DRY_RUN" == "false" ]]; then
    if [[ -n "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR" || echo "Error: Could not create FileBot output directory: $OUTPUT_DIR"
    fi
    if [[ "$ORIGINAL_FILE_ACTION" == "TRASH" ]]; then
        mkdir -p "$TRASH_DIR" || echo "Error: Could not create trash directory: $TRASH_DIR"
    fi
fi

# ----------------- Main -----------------

echo "Scanning in '$SEARCH_DIR' ..."
# Using find with -print0 (space-safe). Respect FIND_EXCLUDE array.
# You can narrow this to only *.mkv by adding: -type f -iname "*.mkv"
echo "Clean out the empty directories"
find "$SEARCH_DIR" -type d -empty -delete
find "$SEARCH_DIR" -type f "${FIND_EXCLUDE[@]}" ! -path "*xattr*" $FIND_TIME -print0 | sort -n | while IFS= read -r -d '' file_path; do
    fname="$(basename "$file_path")"
    echo "--- Processing: $fname ---"
    echo "Full path: $file_path"

    start_ts=$(date +%s)

    # Build FileBot command (amc script with your options)
    filebot_cmd="/usr/local/bin/filebot '$file_path' -script fn:amc --output '$OUTPUT_DIR' --action $FILEBOT_ACTION $FILEBOT_EXCLUDE $FILEBOT_FORMAT"

    notes=""
    ok="false"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] Would execute FileBot: $filebot_cmd"
        notes="Would run FileBot with action=$FILEBOT_ACTION and then $ORIGINAL_FILE_ACTION original."
        ok="true"
    else
        echo "Executing FileBot..."
        # Run FileBot; don't stop script if it fails
        eval "$filebot_cmd"
        filebot_exit_status=$? || true

        if [[ "$filebot_exit_status" -eq 0 ]]; then
            echo "FileBot executed successfully."
            ok="true"
            notes="FileBot ok."

            # Handle original file if requested
            if [[ "$ORIGINAL_FILE_ACTION" == "KEEP" ]]; then
                echo "Original kept: $file_path"
            else
                if [[ "$AUTO_CONFIRM" != "true" ]]; then
                    read -r -p "Process successful. ${ORIGINAL_FILE_ACTION} original '$file_path'? (y/N): " confirm
                    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                        echo "Skipping ${ORIGINAL_FILE_ACTION}."
                        notes="$notes Skipped ${ORIGINAL_FILE_ACTION} by user."
                        # Still send Discord notification
                        send_discord_embed "$file_path" "$ok" "$start_ts" "$notes"
                        echo ""
                        continue
                    fi
                fi

                if [[ "$ORIGINAL_FILE_ACTION" == "DELETE" ]]; then
                    echo "Deleting original: $file_path"
                    if rm -v -- "$file_path"; then
                        echo "Original deleted."
                        notes="$notes Deleted original."
                    else
                        echo "Error deleting original."
                        notes="$notes Failed to delete original."
                    fi
                elif [[ "$ORIGINAL_FILE_ACTION" == "TRASH" ]]; then
                    echo "Moving original to trash: $file_path -> $TRASH_DIR"
                    if mv -v -- "$file_path" "$TRASH_DIR/"; then
                        echo "Original moved to trash."
                        notes="$notes Moved original to trash."
                    else
                        echo "Error moving to trash."
                        notes="$notes Failed to move to trash."
                    fi
                fi
            fi
        else
            echo "FileBot FAILED with exit status $filebot_exit_status for: $file_path"
            ok="false"
            notes="FileBot failed (exit $filebot_exit_status). Original untouched."
        fi
    fi

    # Send Discord message (never abort the script if this fails)
    send_discord_embed "$file_path" "$ok" "$start_ts" "$notes"
    echo ""
done

echo "All done."
