#!/usr/bin/env bash
#
# disk_health_report.sh
# - Checks SMART (HDD/SSD), NVMe, mdadm RAID, logs
# - Sends summary to Discord
# - If "BAD", also sends Pushover notification
#

#############################
# CONFIG
#############################

# Discord webhook (create one in your Discord channel settings)
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/webhook"

# Pushover (optional but recommended if you want critical alerts)
PUSHOVER_TOKEN="TOKEN"    # Application token
PUSHOVER_USER="USER"      # Your user/group key

# How far back to check logs for I/O errors (journalctl)
LOG_LOOKBACK_HOURS=18

#############################
# INTERNAL VARS
#############################

SUMMARY=""
OVERALL_STATUS="OK"   # OK, WARN, BAD
HOSTNAME="$(hostname)"
NOW="$(date -Iseconds)"

#############################
# HELPER FUNCTIONS
#############################

set_status() {
    # escalate severity: OK < WARN < BAD
    local new="$1"
    case "$OVERALL_STATUS" in
        BAD)   : ;;  # already worst
        WARN)  [ "$new" = "BAD" ] && OVERALL_STATUS="BAD" ;;
        OK)    OVERALL_STATUS="$new" ;;
    esac
}

append_summary() {
    SUMMARY+="$1"$'\n'
}

send_discord() {
    local content="$1"
    [ -z "$DISCORD_WEBHOOK_URL" ] && return 0

    # Discord expects JSON
    curl -sS -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$(printf '{"content": "%s"}' "$(echo "$content" | sed 's/"/\\"/g')")" >/dev/null 2>&1
}

send_pushover() {
    local title="$1"
    local message="$2"

    [ -z "$PUSHOVER_TOKEN" ] && return 0
    [ -z "$PUSHOVER_USER" ] && return 0

    curl -sS \
        -F "token=$PUSHOVER_TOKEN" \
        -F "user=$PUSHOVER_USER" \
        -F "title=$title" \
        -F "message=$message" \
        https://api.pushover.net/1/messages.json >/dev/null 2>&1
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

#############################
# SMART CHECKS (SATA/USB HDD/SSD)
#############################

check_smart_drive() {
    local dev="$1"

    if ! have_cmd smartctl; then
        append_summary "SMART: smartctl not installed, skipping $dev"
        set_status "WARN"
        return
    fi

    local health reallo pend offunc
    local status="OK"
    local msg=""

    # Overall health
    health=$(sudo smartctl -H "$dev" 2>/dev/null | awk '/overall-health/ {print $NF}')
    [ -z "$health" ] && health="UNKNOWN"

    # Attributes (if available)
    reallo=$(sudo smartctl -A "$dev" 2>/dev/null | awk '/Reallocated_Sector_Ct/ {print $10}')
    pend=$(sudo smartctl -A "$dev" 2>/dev/null | awk '/Current_Pending_Sector/ {print $10}')
    offunc=$(sudo smartctl -A "$dev" 2>/dev/null | awk '/Offline_Uncorrectable/ {print $10}')

    [ -z "$reallo" ] && reallo=0
    [ -z "$pend" ] && pend=0
    [ -z "$offunc" ] && offunc=0

    msg="SMART $dev: health=$health, reallocated=$reallo, pending=$pend, uncorrectable=$offunc"

    if [ "$health" != "PASSED" ] && [ "$health" != "OK" ]; then
        status="BAD"
    fi

    # Heuristics for bad/warn
    if [ "$reallo" -gt 0 ] || [ "$pend" -gt 0 ] || [ "$offunc" -gt 0 ]; then
        if [ "$reallo" -gt 10 ] || [ "$pend" -gt 0 ] || [ "$offunc" -gt 0 ]; then
            status="BAD"
        else
            [ "$status" != "BAD" ] && status="WARN"
        fi
    fi

    append_summary "$msg"

    [ "$status" = "BAD" ] && set_status "BAD"
    [ "$status" = "WARN" ] && set_status "WARN"
}

#############################
# NVMe CHECKS
#############################

check_nvme_drive() {
    local dev="$1"

    if ! have_cmd nvme; then
        append_summary "NVMe: nvme-cli not installed, skipping $dev"
        set_status "WARN"
        return
    fi

    local log
    log=$(sudo nvme smart-log "$dev" 2>/dev/null)
    if [ -z "$log" ]; then
        append_summary "NVMe $dev: unable to read smart-log"
        set_status "WARN"
        return
    fi

    local media_errors err_logs pct_used crit temp
    media_errors=$(echo "$log" | awk '/media_errors/ {print $3}')
    err_logs=$(echo "$log" | awk '/num_err_log_entries/ {print $3}')
    pct_used=$(echo "$log" | awk '/percentage_used/ {print $3}')
    crit=$(echo "$log" | awk '/critical_warning/ {print $3}')
    temp=$(echo "$log" | awk '/temperature/ {print $3}')

    # Normalise values
    [ -z "$media_errors" ] && media_errors=0
    [ -z "$err_logs" ] && err_logs=0
    [ -z "$pct_used" ] && pct_used=0
    [ -z "$crit" ] && crit=0

    # Strip non-digits from pct_used (handles "23%" or "23")
    pct_used=${pct_used%%%}           # remove trailing % if present
    pct_used=${pct_used//[^0-9]/}     # keep only digits
    [ -z "$pct_used" ] && pct_used=0  # default if empty

    local status="OK"
    local msg="NVMe $dev: media_errors=$media_errors, err_logs=$err_logs, pct_used=$pct_used, critical=$crit, temp=$temp"

    if [ "$crit" -ne 0 ] || [ "$media_errors" -gt 0 ]; then
        status="BAD"
    elif [ "$pct_used" -ge 80 ] || [ "$err_logs" -gt 0 ]; then
        status="WARN"
    fi

    append_summary "$msg"

    [ "$status" = "BAD" ] && set_status "BAD"
    [ "$status" = "WARN" ] && set_status "WARN"
}

#############################
# MDADM RAID CHECKS
#############################

check_md_arrays() {
    if ! have_cmd mdadm; then
        append_summary "RAID: mdadm not installed, skipping md arrays"
        return
    fi

    local md
    md=$(grep -E '^md[0-9]+' /proc/mdstat | awk '{print $1}')
    [ -z "$md" ] && return

    while read -r array; do
        [ -z "$array" ] && continue
        local detail
        detail=$(sudo mdadm --detail "/dev/$array" 2>/dev/null)
        [ -z "$detail" ] && continue

        local state
        state=$(echo "$detail" | awk -F': ' '/State :/ {print $2}')

        append_summary "RAID /dev/$array: state=$state"

        if echo "$state" | grep -qiE 'degraded|faulty|recovering'; then
            set_status "BAD"
        fi
    done <<< "$md"
}

#############################
# LOG CHECKS (I/O errors)
#############################

check_logs() {
    local since
    since="$(date --date="-$LOG_LOOKBACK_HOURS hours" -Iseconds 2>/dev/null || echo "now-$(($LOG_LOOKBACK_HOURS*3600))s")"

    local dmesg_errs journal_errs
    dmesg_errs=$(dmesg | grep -iE 'I/O error|unrecovered read error|failed command: READ' | tail -n 10)
    if have_cmd journalctl; then
        journal_errs=$(sudo journalctl --since="$since" -p err 2>/dev/null | grep -iE 'I/O error|unrecovered read error|failed command: READ' | tail -n 10)
    else
        journal_errs=""
    fi

    if [ -n "$dmesg_errs" ] || [ -n "$journal_errs" ]; then
        append_summary "Recent I/O-related errors in logs (last $LOG_LOOKBACK_HOURS hours):"
        [ -n "$dmesg_errs" ] && append_summary "$dmesg_errs"
        [ -n "$journal_errs" ] && append_summary "$journal_errs"
        set_status "WARN"
    else
        append_summary "Logs: no obvious I/O errors in last $LOG_LOOKBACK_HOURS hours."
    fi
}

#############################
# MAIN
#############################

main() {
    append_summary "Disk Health Report for $HOSTNAME at $NOW"
    append_summary "===================================================="

    # 1) Block devices
    if ! have_cmd lsblk; then
        append_summary "lsblk not available; cannot enumerate drives."
        set_status "WARN"
    else
        # SATA/USB disks
        while read -r name type; do
            [ "$type" != "disk" ] && continue
            # NVMe will be handled separately
            if [[ "$name" == nvme* ]]; then
                continue
            fi
            check_smart_drive "/dev/$name"
        done < <(lsblk -ndo NAME,TYPE)

        # NVMe disks
        while read -r nv; do
            [ -z "$nv" ] && continue
            check_nvme_drive "/dev/$nv"
        done < <(lsblk -ndo NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/ {print $1}')
    fi

    append_summary "----------------------------------------------------"

    # 2) RAID
    check_md_arrays

    append_summary "----------------------------------------------------"

    # 3) Logs
    check_logs

    append_summary "----------------------------------------------------"
    append_summary "Overall status: $OVERALL_STATUS"

    # Send Discord summary
    send_discord "[$HOSTNAME] Disk Health Report ($OVERALL_STATUS)\n\n$SUMMARY"

    # If BAD, send Pushover
    if [ "$OVERALL_STATUS" = "BAD" ]; then
        send_pushover "[$HOSTNAME] DISK ALERT" "$SUMMARY"
    fi
}

main
