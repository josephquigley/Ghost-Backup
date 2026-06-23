#!/bin/bash
# Docker HEALTHCHECK for the backup daemon. Healthy only if ALL hold:
#   1. the scheduler loop is alive   (beacon touched within ALIVE window)
#   2. the last backup run succeeded (health file starts with "ok ")
#   3. a backup ran recently         (health file touched within HEALTH window)
# Thresholds are env-overridable so a changed BACKUP_SCHEDULE needs no rebuild.
# Defaults suit the weekly production schedule.
set -u

ALIVE_FILE="/tmp/backup-alive"
HEALTH_FILE="/tmp/backup-health"
ALIVE_MAX_AGE="${BACKUP_ALIVE_MAX_AGE:-2}"        # minutes; loop ticks every 30s
HEALTH_MAX_AGE="${BACKUP_HEALTH_MAX_AGE:-11520}"  # minutes; 8 days > weekly cadence

# 1. scheduler alive
find "$ALIVE_FILE" -mmin -"$ALIVE_MAX_AGE" 2>/dev/null | grep -q . || exit 1
# 3. a recent run
find "$HEALTH_FILE" -mmin -"$HEALTH_MAX_AGE" 2>/dev/null | grep -q . || exit 1
# 2. that run succeeded
grep -q '^ok ' "$HEALTH_FILE" 2>/dev/null || exit 1

exit 0
