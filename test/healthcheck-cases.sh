#!/bin/bash
# Deterministic exit-code tests for scripts/healthcheck.sh.
# Builds the image locally and runs healthcheck.sh against planted /tmp state.
# No database/restic needed — this tests the healthcheck logic in isolation.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=ghost-backup:hctest
echo "Building $IMAGE ..."
docker build -q -t "$IMAGE" . >/dev/null

# run_case <name> <expected_exit> <setup-shell>
run_case() {
    local name="$1" expected="$2" setup="$3" actual
    actual=$(docker run --rm --entrypoint bash "$IMAGE" -c \
        "$setup; /scripts/healthcheck.sh; echo \$?" | tail -1)
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS: $name (exit $actual)"
    else
        echo "FAIL: $name (expected $expected, got $actual)"; exit 1
    fi
}

NOW='echo "ok $(date +%s)" > /tmp/backup-health; touch /tmp/backup-alive'

run_case "healthy: fresh beacon + ok run" 0 "$NOW"
run_case "unhealthy: no files at all" 1 "true"
run_case "unhealthy: last run failed" 1 \
    'echo "fail $(date +%s)" > /tmp/backup-health; touch /tmp/backup-alive'
run_case "unhealthy: scheduler beacon stale" 1 \
    'echo "ok $(date +%s)" > /tmp/backup-health; touch /tmp/backup-alive; touch -d "10 minutes ago" /tmp/backup-alive'
run_case "unhealthy: backup stale (>8d)" 1 \
    'touch /tmp/backup-alive; echo "ok $(date +%s)" > /tmp/backup-health; touch -d "9 days ago" /tmp/backup-health'

echo "All healthcheck-cases passed."
