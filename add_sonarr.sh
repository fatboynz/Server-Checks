#!/usr/bin/env bash
set -euo pipefail

########################################
# Config
########################################
SONARR_URL="http://192.168.2.175:8989"
SONARR_API_KEY=""

SONARR_API_BASE="${SONARR_URL%/}/api/v3"

########################################
# Helpers
########################################
api_get() {
  local path="$1"
  curl -sS \
    -H "X-Api-Key: ${SONARR_API_KEY}" \
    "${SONARR_API_BASE}${path}"
}

api_post() {
  local path="$1"
  local json="$2"
  curl -sS -X POST \
    -H "X-Api-Key: ${SONARR_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${json}" \
    "${SONARR_API_BASE}${path}"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  missing-search        Trigger search for all missing episodes
  refresh               Refresh all series & rescan disk
  rss-sync              Trigger RSS sync
  list-series           List all series (id + title)
  list-missing          List missing episodes (first page)
  health                Show Sonarr health issues
  backup [dest]         Backup Sonarr config (local files)
  help                  Show this help

Environment:
  SONARR_URL            Default: http://localhost:8989
  SONARR_API_KEY        (required)
  SONARR_CONFIG_DIR     Used by 'backup' (default: /var/lib/sonarr)
  SONARR_SERVICE_FILE   Used by 'backup' (default: /etc/systemd/system/sonarr.service)
  BACKUP_DIR            Used by 'backup' (default: \$HOME/sonarr-backups)

EOF
}

########################################
# Commands
########################################
cmd_missing_search() {
  api_post "/command" '{"name":"missingEpisodeSearch"}' >/dev/null
  echo "Triggered missing episode search."
}

cmd_refresh() {
  api_post "/command" '{"name":"refreshSeries"}' >/dev/null
  echo "Triggered refresh for all series."
}

cmd_rss_sync() {
  api_post "/command" '{"name":"rssSync"}' >/dev/null
  echo "Triggered RSS sync."
}

cmd_list_series() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for list-series." >&2
    exit 1
  fi

  api_get "/series" \
    | jq -r '.[] | "\(.id)\t\(.title)"' \
    | sort -k2
}

cmd_list_missing() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for list-missing." >&2
    exit 1
  fi

  local page=1
  local pagesize=200

  api_get "/wanted/missing?page=${page}&pageSize=${pagesize}" \
    | jq -r '.records[] |
      . as $e |
      ($e.series.title) + " - " +
      "S" + ( ($e.seasonNumber|tostring| (if length==1 then "0"+. else . end)) ) +
      "E" + ( ($e.episodeNumber|tostring| (if length==1 then "0"+. else . end)) ) +
      " - " + $e.title' 2>/dev/null || true
}

cmd_health() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for health." >&2
    exit 1
  fi

  api_get "/health" \
    | jq -r '.[] | "\(.type): \(.message)"'
}

cmd_backup() {
  local dest_dir="${1:-}"
  local config_dir="${SONARR_CONFIG_DIR:-/var/lib/sonarr}"
  local service_file="${SONARR_SERVICE_FILE:-/etc/systemd/system/sonarr.service}"
  local backup_dir="${BACKUP_DIR:-$HOME/sonarr-backups}"

  if [[ -n "$dest_dir" ]]; then
    backup_dir="$dest_dir"
  fi

  mkdir -p "$backup_dir"

  local stamp
  stamp="$(date +%F-%H%M%S)"
  local archive="${backup_dir}/sonarr-backup-${stamp}.tar.gz"

  # Some environments may not have a systemd unit file, so ignore errors
  tar -czf "$archive" \
    "$config_dir" \
    "$service_file" 2>/dev/null || true

  echo "Sonarr backup created: $archive"
}

########################################
# Main
########################################
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    missing-search)
      cmd_missing_search "$@"
      ;;
    refresh)
      cmd_refresh "$@"
      ;;
    rss-sync)
      cmd_rss_sync "$@"
      ;;
    list-series)
      cmd_list_series "$@"
      ;;
    list-missing)
      cmd_list_missing "$@"
      ;;
    health)
      cmd_health "$@"
      ;;
    backup)
      cmd_backup "$@"
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
