#!/bin/bash
set -euo pipefail

# Ghost Backup - Entrypoint
# Handles command dispatching and scheduled backup loop

readonly SCRIPTS_DIR="/scripts"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

show_help() {
    cat <<EOF
Ghost Backup - Restic-based backup for Ghost Docker

Usage: docker compose run --rm backup <command>

Commands:
  (no command)    Run in daemon mode with scheduled backups
  backup          Run a backup immediately
  restore <id>    Restore a snapshot (use 'latest' or snapshot ID)
  snapshots       List available snapshots
  verify          Run validation checks
  stats           Show repository statistics
  unlock          Remove stale repository locks
  help            Show this help message

Examples:
  docker compose --profile=backup up -d     # Start with scheduled backups
  docker compose run --rm backup backup     # Manual backup
  docker compose run --rm backup snapshots  # List snapshots
  docker compose run --rm backup restore latest  # Restore latest snapshot

EOF
}

# Parse cron schedule into sleep intervals
# This is a simple implementation that handles standard cron expressions
calculate_next_run() {
    local schedule="$1"
    local minute hour day month weekday

    read -r minute hour day month weekday <<< "$schedule"

    # For simplicity, we use a polling approach
    # Check every minute if we match the schedule
    # This avoids complex cron parsing in bash

    local current_minute current_hour current_day current_month current_weekday
    current_minute=$(date +%-M)
    current_hour=$(date +%-H)
    current_day=$(date +%-d)
    current_month=$(date +%-m)
    current_weekday=$(date +%w)  # 0-6, Sunday=0 (matches cron weekday numbering)

    # Check if current time matches schedule
    match_field() {
        local value="$1"
        local current="$2"

        [[ "$value" == "*" ]] && return 0
        [[ "$value" == "$current" ]] && return 0

        # Handle */N syntax
        if [[ "$value" =~ ^\*/([0-9]+)$ ]]; then
            local interval="${BASH_REMATCH[1]}"
            (( current % interval == 0 )) && return 0
        fi

        # Handle comma-separated values
        if [[ "$value" == *,* ]]; then
            IFS=',' read -ra values <<< "$value"
            for v in "${values[@]}"; do
                [[ "$v" == "$current" ]] && return 0
            done
        fi

        # Handle ranges
        if [[ "$value" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            (( current >= start && current <= end )) && return 0
        fi

        return 1
    }

    if match_field "$minute" "$current_minute" && \
       match_field "$hour" "$current_hour" && \
       match_field "$day" "$current_day" && \
       match_field "$month" "$current_month" && \
       match_field "$weekday" "$current_weekday"; then
        return 0  # Should run now
    fi

    return 1  # Not time yet
}

run_scheduled_loop() {
    local schedule="${BACKUP_SCHEDULE:-0 3 * * *}"
    local last_run=""

    log "Starting backup daemon with schedule: $schedule"
    log "Retention policy: daily=${BACKUP_KEEP_DAILY:-7}, weekly=${BACKUP_KEEP_WEEKLY:-4}, monthly=${BACKUP_KEEP_MONTHLY:-6}, yearly=${BACKUP_KEEP_YEARLY:-2}"

    # Seed health so a freshly (re)started container is healthy immediately
    # (validation just passed) instead of waiting for the first scheduled
    # backup. The Docker HEALTHCHECK reads these (see scripts/healthcheck.sh).
    echo "ok $(date +%s)" > /tmp/backup-health 2>/dev/null || true
    touch /tmp/backup-alive 2>/dev/null || true

    while true; do
        # Liveness beacon: prove the scheduler loop is still running.
        touch /tmp/backup-alive 2>/dev/null || true

        local current_time
        current_time=$(date '+%Y-%m-%d %H:%M')

        # Only run once per minute window
        if [[ "$current_time" != "$last_run" ]] && calculate_next_run "$schedule"; then
            last_run="$current_time"
            log "Scheduled backup triggered"

            if "$SCRIPTS_DIR/backup.sh"; then
                log "Scheduled backup completed successfully"
            else
                log_error "Scheduled backup failed"
            fi
        fi

        # Sleep for 30 seconds before checking again
        sleep 30
    done
}

main() {
    local command="${1:-}"

    case "$command" in
        help|--help|-h)
            show_help
            exit 0
            ;;
        backup)
            log "Running manual backup..."
            exec "$SCRIPTS_DIR/backup.sh"
            ;;
        restore)
            local snapshot_id="${2:-}"
            if [[ -z "$snapshot_id" ]]; then
                log_error "Snapshot ID required. Use 'latest' or a specific snapshot ID."
                log "Run 'docker compose run --rm backup snapshots' to list available snapshots."
                exit 1
            fi
            exec "$SCRIPTS_DIR/restore.sh" "$snapshot_id"
            ;;
        snapshots)
            exec restic snapshots --tag ghost
            ;;
        verify)
            exec "$SCRIPTS_DIR/validate.sh"
            ;;
        stats)
            exec restic stats
            ;;
        unlock)
            log "Removing stale locks..."
            exec restic unlock
            ;;
        "")
            # Daemon mode - run startup validation then enter schedule loop
            log "Ghost Backup starting..."

            if ! "$SCRIPTS_DIR/validate.sh"; then
                log_error "Startup validation failed. Exiting."
                exit 1
            fi

            log "Validation passed. Entering scheduled backup mode."
            run_scheduled_loop
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
