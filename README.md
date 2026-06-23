# Ghost Backup

Docker-based backup solution for [Ghost](https://ghost.org) deployments. Uses [Restic](https://restic.net/) for encrypted, deduplicated backups to S3 or Backblaze B2.

> **Note:** Work in progress. Use at your own risk.

## What It Does

- Backs up your Ghost database (MySQL dump) and content files (images, themes, etc.)
- Encrypts everything with AES-256 before uploading
- Deduplicates data - only uploads what changed
- Runs on a schedule (default: 3 AM daily)
- Supports point-in-time recovery from any snapshot
- it DOES NOT backup anything else in the directory such as the docker compose file

## Important Note about .env file

Make sure you backup your .env file separately to something like a password manager. This makes it easier to restore to a completely new instance. 


## Quick Start

### 1. Add to your `docker-compose.yml`

```yaml
services:
  # ... your existing ghost and db services ...

  backup:
    image: ghcr.io/mansoormajeed/ghost-backup:main
    restart: unless-stopped
    environment:
      MYSQL_HOST: db
      MYSQL_USER: ${DATABASE_USER}
      MYSQL_PASSWORD: ${DATABASE_PASSWORD}
      RESTIC_REPOSITORY: ${RESTIC_REPOSITORY}
      RESTIC_PASSWORD: ${RESTIC_PASSWORD}
      # For AWS S3:
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
      # For Backblaze B2 (use instead of AWS creds):
      # B2_ACCOUNT_ID: ${B2_ACCOUNT_ID}
      # B2_ACCOUNT_KEY: ${B2_ACCOUNT_KEY}
      # Health check (optional):
      BACKUP_HEALTHCHECK_URL: ${BACKUP_HEALTHCHECK_URL:-}
    volumes:
      - ./data/ghost:/data/ghost
      - ./data/restore:/restore
    depends_on:
      db:
        condition: service_healthy
    profiles:
      - backup
    networks:
      - ghost_network
```

### 2. Add to your `.env`

```bash
# Enable backup
COMPOSE_PROFILES=backup

# Where to store backups
RESTIC_REPOSITORY=s3:s3.amazonaws.com/your-bucket/ghost-backups

# Encryption password (SAVE THIS - you need it to restore)
RESTIC_PASSWORD=your-secure-password

# Health check (optional) - get your UUID from healthchecks.io
BACKUP_HEALTHCHECK_URL=https://hc-ping.com/your-uuid

# Cloud credentials
AWS_ACCESS_KEY_ID=your-key
AWS_SECRET_ACCESS_KEY=your-secret
```

### 3. Start

```bash
docker compose up -d
```

The backup container validates config on startup and runs backups automatically.

## Cloud Storage Setup

- [AWS S3 Setup Guide](docs/aws-setup.md)
- [Backblaze B2 Setup Guide](docs/b2-setup.md)

## Commands

```bash
# Run a backup now
docker compose run --rm backup backup

# List all snapshots
docker compose run --rm backup snapshots

# Restore from latest backup
docker compose run --rm -it backup restore latest

# Restore specific snapshot
docker compose run --rm -it backup restore abc123

# Check configuration
docker compose run --rm backup verify

# View repository stats
docker compose run --rm backup stats
```

## Restore Process

1. Stop Ghost:
   ```bash
   docker compose stop ghost
   ```

2. Run restore (interactive):
   ```bash
   docker compose run --rm -it backup restore latest
   ```

3. Start Ghost:
   ```bash
   docker compose start ghost
   ```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `RESTIC_REPOSITORY` | required | Repository URL |
| `RESTIC_PASSWORD` | required | Encryption password |
| `BACKUP_SCHEDULE` | `0 3 * * *` | Cron schedule |
| `BACKUP_KEEP_DAILY` | `7` | Daily snapshots to keep |
| `BACKUP_KEEP_WEEKLY` | `4` | Weekly snapshots to keep |
| `BACKUP_KEEP_MONTHLY` | `6` | Monthly snapshots to keep |
| `BACKUP_KEEP_YEARLY` | `2` | Yearly snapshots to keep |
| `BACKUP_HEALTHCHECK_URL` | | URL to ping on success/failure |
| `BACKUP_ALIVE_MAX_AGE` | `2` | Minutes the Docker healthcheck tolerates without a scheduler heartbeat before reporting unhealthy |
| `BACKUP_HEALTH_MAX_AGE` | `11520` | Minutes since the last successful backup before the Docker healthcheck reports unhealthy (8 days; size this to your `BACKUP_SCHEDULE` plus grace) |

## Health Check Notifications

Get notified when backups succeed or fail using [healthchecks.io](https://healthchecks.io), [Uptime Kuma](https://github.com/louislam/uptime-kuma), or any compatible service.

1. Create a check at healthchecks.io (or your preferred service)
2. Add to your `.env`:
   ```bash
   BACKUP_HEALTHCHECK_URL=https://hc-ping.com/your-uuid
   ```

**How it works:**
- On successful backup: pings `https://hc-ping.com/your-uuid`
- On failure: pings `https://hc-ping.com/your-uuid/fail`

If no pings are received within your configured grace period, you'll be notified that backups have stopped.

The container also exposes a Docker `HEALTHCHECK`: it reports healthy only when the scheduler loop is alive, the last backup succeeded, and a backup ran within `BACKUP_HEALTH_MAX_AGE`. View it with `docker ps` (the `(healthy)` marker) or `docker inspect`. One-shot command containers (e.g. `docker compose run --rm backup snapshots`) have no running scheduler and will therefore report `unhealthy` — this is expected and not a fault.

## What Gets Backed Up

- **Database**: Ghost database (and ActivityPub if present)
- **Content**: images, media, files, themes, settings

## Troubleshooting

```bash
# Check logs
docker compose logs backup

# Remove stale restic lock
docker compose run --rm backup unlock
```

## License

MIT
