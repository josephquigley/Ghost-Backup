# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

**⚠️ WORK IN PROGRESS - DO NOT USE IN PRODUCTION**

This project is currently under active development and should not be used in production environments.

## Project Overview

Ghost Backup is a Docker-based backup solution for [Ghost Docker](https://github.com/TryGhost/ghost-docker) deployments. It uses Restic for encrypted, deduplicated backups to cloud storage (S3, Backblaze B2, or S3-compatible providers).

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Backup Container                                               │
│                                                                 │
│  entrypoint.sh                                                  │
│  ├── Daemon mode: validate → cron loop → run backup.sh         │
│  └── Command mode: dispatch to backup/restore/snapshots/etc    │
│                                                                 │
│  scripts/                                                       │
│  ├── validate.sh   # Startup checks (env, db, disk, restic)    │
│  ├── backup.sh     # mysqldump + restic backup + retention     │
│  └── restore.sh    # restic restore to staging directory       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
    MySQL (db:3306)    Ghost Content        Cloud Storage
                       (/data/ghost)        (S3/B2/etc)
```

### Key Components

- **entrypoint.sh**: Main entrypoint that handles command dispatching and the scheduled backup loop
- **scripts/validate.sh**: Validates environment variables, database connectivity, content directory, disk space, and restic repository access
- **scripts/backup.sh**: Executes backups - dumps MySQL, runs restic backup, applies retention policy
- **scripts/restore.sh**: Interactive restore - extracts snapshots, imports databases, and restores content files
- **scripts/healthcheck.sh**: Docker HEALTHCHECK — passes when the scheduler beacon (`/tmp/backup-alive`) is fresh, `/tmp/backup-health` starts with `ok`, and the last run is within `BACKUP_HEALTH_MAX_AGE`.

### How Backups Work

1. **Staging**: MySQL databases are dumped to `/tmp/backup-staging/`
   - `ghost` database (always)
   - `activitypub` database (if detected and accessible)
2. **Symlink check**: Broken symlinks are detected and excluded (e.g., default theme symlinks pointing to Ghost container paths)
3. **Backup**: Restic streams staging dir + content dir directly to cloud storage (no local repository needed)
4. **Cleanup**: Staging directory is removed, retention policy is applied

**Note**: Restic backs up directly to the remote repository (S3/B2/etc). No local backup repository is created. Only the MySQL dump requires temporary local disk space.

### Lock Mechanism

Backup and restore operations use a PID-based lock file (`/tmp/ghost-backup.lock`) to prevent concurrent operations:

- Lock file contains the PID of the running process
- Before acquiring, checks if the PID is still alive
- Stale locks (from crashed processes) are automatically removed
- Lock is released on exit via trap

### ActivityPub Support

Ghost Backup automatically detects and backs up the ActivityPub database if present:

- **Detection**: During validation (validate.sh:104-111), the script checks if the `activitypub` database exists and is accessible
- **Backup**: If detected, the ActivityPub database is dumped to `activitypub.sql` (backup.sh:188-193)
- **Non-blocking**: If ActivityPub database dump fails, the backup continues with just the Ghost database
- **Restore**: The restore process includes ActivityPub SQL if it was backed up

This happens automatically without any configuration - the presence of the database is sufficient.

## File Structure

```
ghost-backup/
├── Dockerfile                # MySQL 8.0 base image + restic (ensures MySQL client compatibility)
├── entrypoint.sh             # Command dispatch + cron scheduler
├── scripts/
│   ├── validate.sh           # Startup validation
│   ├── backup.sh             # Backup execution
│   └── restore.sh            # Restore helper
├── docs/
│   ├── aws-setup.md          # AWS S3 setup guide
│   └── b2-setup.md           # Backblaze B2 setup guide
├── .github/
│   └── workflows/
│       └── docker.yml        # Build and push to ghcr.io
├── README.md                 # User documentation
├── GHOST_DOCKER_INTEGRATION.md  # Integration guide for ghost-docker
└── CLAUDE.md                 # This file
```

## Common Commands

```bash
# Build the Docker image locally
docker build -t ghost-backup .

# Run validation checks
docker run --rm \
  -e MYSQL_HOST=localhost \
  -e MYSQL_PASSWORD=test \
  -e RESTIC_REPOSITORY=/tmp/repo \
  -e RESTIC_PASSWORD=test \
  ghost-backup verify

# Run a manual backup (requires proper environment)
docker run --rm ghost-backup backup

# List snapshots
docker run --rm ghost-backup snapshots

# Show help
docker run --rm ghost-backup help
```

## Environment Variables

### Required
- `RESTIC_REPOSITORY` - Restic repository URL (e.g., `s3:s3.amazonaws.com/bucket/path`)
- `RESTIC_PASSWORD` - Repository encryption password
- `MYSQL_PASSWORD` - Database password (inherited from ghost-docker)

### Optional
- `MYSQL_HOST` - Database host (default: `db`)
- `MYSQL_PORT` - Database port (default: `3306`)
- `MYSQL_USER` - Database user (default: `ghost`)
- `MYSQL_DATABASE` - Database name (default: `ghost`)
- `BACKUP_SCHEDULE` - Cron schedule (default: `0 3 * * *`)
- `BACKUP_KEEP_DAILY` - Daily snapshots to keep (default: `7`)
- `BACKUP_KEEP_WEEKLY` - Weekly snapshots to keep (default: `4`)
- `BACKUP_KEEP_MONTHLY` - Monthly snapshots to keep (default: `6`)
- `BACKUP_KEEP_YEARLY` - Yearly snapshots to keep (default: `2`)
- `BACKUP_HEALTHCHECK_URL` - URL to ping on success/failure (e.g., healthchecks.io or Uptime Kuma). On success, the URL is pinged as-is. On failure, `/fail` is appended to the URL (if supported by the monitoring service)
- `BACKUP_ALIVE_MAX_AGE` - Minutes the Docker healthcheck tolerates without a scheduler heartbeat before reporting unhealthy (default: `2`)
- `BACKUP_HEALTH_MAX_AGE` - Minutes since the last successful backup before the Docker healthcheck reports unhealthy (default: `11520`, i.e. 8 days; size this to your `BACKUP_SCHEDULE` plus grace)

### Cloud Credentials
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` - For S3
- `B2_ACCOUNT_ID` / `B2_ACCOUNT_KEY` - For Backblaze B2

## Development Guidelines

### Shell Scripts
- All scripts use `#!/bin/bash` with `set -euo pipefail`
- Use `log()`, `log_error()`, `log_success()` functions for consistent output
- Timestamps are in `[YYYY-MM-DD HH:MM:SS]` format
- Exit codes: 0 = success, 1 = failure

### Validation Flow
1. Environment variables (required vars set)
2. Database connectivity (can connect, database exists, has tables, detect ActivityPub database)
3. Content directory (mounted, readable, has expected structure)
4. Disk space (enough space in /tmp for MySQL dump, including ActivityPub if present)
5. Restic repository (accessible, or can be initialized)

### Adding New Validation Checks
Add a new function in `validate.sh`:
```bash
check_something() {
    log "Checking something..."

    if [[ some_condition ]]; then
        add_error "Description of what went wrong"
        return 1
    fi

    log_success "Something is valid"
    return 0
}
```
Then add it to the `main()` function's check sequence.

### Adding New Commands
Add a new case in `entrypoint.sh`:
```bash
case "$command" in
    newcommand)
        exec "$SCRIPTS_DIR/newcommand.sh" "${@:2}"
        ;;
    ...
esac
```

## Testing

### Local Testing with Docker Compose
Create a test `docker-compose.yml`:
```yaml
services:
  db:
    image: mysql:8
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: ghost
      MYSQL_USER: ghost
      MYSQL_PASSWORD: ghost
    healthcheck:
      test: mysqladmin ping -proot
      interval: 5s
      retries: 10

  backup:
    build: .
    environment:
      MYSQL_HOST: db
      MYSQL_USER: ghost
      MYSQL_PASSWORD: ghost
      RESTIC_REPOSITORY: /backups
      RESTIC_PASSWORD: testpassword
    volumes:
      - ./test-content:/data/ghost
      - ./test-backups:/backups
    depends_on:
      db:
        condition: service_healthy
    command: verify
```

### Testing Individual Scripts
```bash
# Test validation
docker compose run --rm backup verify

# Test backup
docker compose run --rm backup backup

# Test restore
docker compose run --rm backup restore latest
```

## CI/CD

The GitHub Actions workflow (`.github/workflows/docker.yml`):
- Triggers on push to `main` and version tags (`v*`), also on pull requests
- Builds multi-platform images (linux/amd64, linux/arm64)
- Pushes to `ghcr.io/${{ github.repository }}` (e.g., `ghcr.io/mansoorMajeed/ghost-backup`)
- Tags: `main`, `v1.0.0`, `v1.0`, `v1`, `sha-xxxxxxx`
- Uses GitHub Actions cache for faster builds

## Integration with ghost-docker

This container is designed to run as part of the ghost-docker stack:
- Uses the same MySQL database (`db` service)
- Mounts the same content volume (read-write for restore support)
- Enabled via `COMPOSE_PROFILES=backup`

See `GHOST_DOCKER_INTEGRATION.md` for the specific changes needed in ghost-docker.

### Restore Flow

The interactive restore command handles database and content restoration:

```
1. Extract snapshot to /restore
2. Show contents summary (databases, content size)
3. Warn: "Stop Ghost before restoring" + confirm
4. "Restore Ghost database?" [y/N]
5. "Restore ActivityPub database?" [y/N] (if present)
6. "Restore content files?" [y/N] (if present)
7. Summary + "Start Ghost to pick up changes"
```

Content restore is safe - existing files are moved to `/data/ghost.bak` before restore. If restore fails, original content is automatically restored.
