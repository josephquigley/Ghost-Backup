#!/bin/bash
set -euo pipefail

# Ghost Backup - Backup Execution Script
# Dumps MySQL and backs up content to Restic repository

readonly CONTENT_DIR="/data/ghost"
readonly STAGING_DIR="/tmp/backup-staging"
readonly LOCK_FILE="/tmp/ghost-backup.lock"
readonly MYSQL_HOST="${MYSQL_HOST:-db}"
readonly MYSQL_PORT="${MYSQL_PORT:-3306}"
readonly MYSQL_USER="${MYSQL_USER:-ghost}"
readonly MYSQL_DATABASE="${MYSQL_DATABASE:-ghost}"

# Retention policy defaults
readonly KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
readonly KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
readonly KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-6}"
readonly KEEP_YEARLY="${BACKUP_KEEP_YEARLY:-2}"

# Health check URL (optional)
readonly HEALTHCHECK_URL="${BACKUP_HEALTHCHECK_URL:-}"

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Another backup/restore operation is in progress (PID: $lock_pid)" >&2
            exit 1
        fi
        # Stale lock - process no longer running
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Removing stale lock from PID $lock_pid" >&2
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

cleanup() {
    if [[ -d "$STAGING_DIR" ]]; then
        rm -rf "$STAGING_DIR"
    fi
    release_lock
}

trap cleanup EXIT

# Local heartbeat for the Docker HEALTHCHECK (see scripts/healthcheck.sh):
# "<ok|fail> <epoch>", rewritten every run so its mtime is the last-run time.
# Best-effort: monitoring must never break or fail the backup itself.
write_health() {
    local state="$1"  # "ok" or "fail"
    echo "$state $(date +%s)" > /tmp/backup-health 2>/dev/null || true
}

ping_healthcheck() {
    local status="$1"  # "success" or "fail"

    # Update the local heartbeat FIRST, before the external-URL guard below,
    # so the Docker healthcheck works even on a site with no hc-ping URL.
    if [[ "$status" == "fail" ]]; then
        write_health fail
    else
        write_health ok
    fi

    if [[ -z "$HEALTHCHECK_URL" ]]; then
        return 0
    fi

    local url="$HEALTHCHECK_URL"
    if [[ "$status" == "fail" ]]; then
        # Append /fail for failure notification if URL supports it
        url="${HEALTHCHECK_URL}/fail"
    fi

    if curl -fsS --retry 3 --max-time 10 "$url" > /dev/null 2>&1; then
        log "Health check ping sent ($status)"
    else
        log "Warning: Health check ping failed"
    fi
}

# Pre-backup validation (lighter than full startup validation)
pre_backup_check() {
    log "Running pre-backup checks..."

    # Check database connectivity
    if ! mysqladmin ping -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent 2>/dev/null; then
        log_error "Database is not accessible"
        return 1
    fi

    # Check content directory
    if [[ ! -r "$CONTENT_DIR" ]]; then
        log_error "Content directory is not readable"
        return 1
    fi

    # Check repository
    if ! restic snapshots --json 2>/dev/null | head -1 > /dev/null; then
        log_error "Restic repository is not accessible"
        return 1
    fi

    log "Pre-backup checks passed"
    return 0
}

dump_database() {
    local database="$1"
    local output_file="$2"

    log "Dumping database: $database"

    local start_time
    start_time=$(date +%s)

    if ! mysqldump \
        -h "$MYSQL_HOST" \
        -P "$MYSQL_PORT" \
        -u "$MYSQL_USER" \
        -p"$MYSQL_PASSWORD" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --routines \
        --triggers \
        "$database" > "$output_file" 2>/dev/null; then
        log_error "Failed to dump database: $database"
        return 1
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    local dump_size
    dump_size=$(du -h "$output_file" | cut -f1)

    log "Database dump complete: $database ($dump_size in ${duration}s)"
    return 0
}

run_backup() {
    log "Starting Restic backup..."

    local start_time
    start_time=$(date +%s)

    local backup_paths=("$STAGING_DIR" "$CONTENT_DIR")
    local today
    today=$(date +%Y-%m-%d)

    # Find broken symlinks and build exclude list
    local exclude_args=()
    while IFS= read -r broken_link; do
        if [[ -n "$broken_link" ]]; then
            log "Excluding broken symlink: $broken_link"
            exclude_args+=("--exclude=$broken_link")
        fi
    done < <(find "$CONTENT_DIR" -xtype l 2>/dev/null)

    if ! restic backup \
        "${backup_paths[@]}" \
        --tag ghost \
        --tag "$today" \
        --exclude-caches \
        --one-file-system \
        "${exclude_args[@]}"; then
        log_error "Restic backup failed"
        return 1
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log "Restic backup completed in ${duration}s"
    return 0
}

apply_retention() {
    log "Applying retention policy..."
    log "Keeping: daily=$KEEP_DAILY, weekly=$KEEP_WEEKLY, monthly=$KEEP_MONTHLY, yearly=$KEEP_YEARLY"

    if ! restic forget \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" \
        --keep-yearly "$KEEP_YEARLY" \
        --tag ghost \
        --prune; then
        log_error "Failed to apply retention policy"
        return 1
    fi

    log "Retention policy applied"
    return 0
}

main() {
    acquire_lock

    log "========================================="
    log "Ghost Backup - Starting"
    log "========================================="

    # Pre-backup validation
    if ! pre_backup_check; then
        log_error "Pre-backup checks failed, aborting"
        ping_healthcheck "fail"
        exit 1
    fi

    # Create staging directory
    mkdir -p "$STAGING_DIR"

    # Dump Ghost database
    if ! dump_database "$MYSQL_DATABASE" "$STAGING_DIR/ghost.sql"; then
        ping_healthcheck "fail"
        exit 1
    fi

    # Check for ActivityPub database and dump if accessible
    if mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "USE activitypub" 2>/dev/null; then
        if ! dump_database "activitypub" "$STAGING_DIR/activitypub.sql"; then
            log "Warning: ActivityPub database dump failed, continuing with Ghost backup"
        fi
    fi

    # Run Restic backup
    if ! run_backup; then
        ping_healthcheck "fail"
        exit 1
    fi

    # Apply retention policy
    if ! apply_retention; then
        # Non-fatal, backup succeeded
        log "Warning: Retention policy application failed"
    fi

    # Get final stats
    log "========================================="
    log "Backup Summary"
    log "========================================="

    local latest_snapshot
    latest_snapshot=$(restic snapshots --json --latest 1 --tag ghost 2>/dev/null | grep -o '"short_id":"[^"]*"' | head -1 | cut -d'"' -f4)
    log "Latest snapshot: $latest_snapshot"

    local repo_size
    repo_size=$(restic stats --json 2>/dev/null | grep -o '"total_size":[0-9]*' | cut -d':' -f2)
    if [[ -n "$repo_size" ]]; then
        # Convert to human readable
        local size_mb=$((repo_size / 1024 / 1024))
        if [[ $size_mb -gt 1024 ]]; then
            local size_gb=$((size_mb / 1024))
            log "Repository size: ${size_gb} GB"
        else
            log "Repository size: ${size_mb} MB"
        fi
    fi

    local snapshot_count
    snapshot_count=$(restic snapshots --json --tag ghost 2>/dev/null | grep -c '"id"' || echo "0")
    log "Total snapshots: $snapshot_count"

    log "========================================="
    log "Backup completed successfully"
    log "========================================="

    ping_healthcheck "success"
    exit 0
}

main "$@"
