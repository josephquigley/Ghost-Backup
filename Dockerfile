FROM mysql:8.0

LABEL org.opencontainers.image.source="https://github.com/TryGhost/ghost-backup"
LABEL org.opencontainers.image.description="Backup solution for Ghost Docker deployments"
LABEL org.opencontainers.image.licenses="MIT"

# Install restic and other dependencies
RUN microdnf install -y \
        curl \
        bzip2 \
        tar \
    && microdnf clean all

# Install restic from GitHub releases
ARG RESTIC_VERSION=0.17.3
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/' | sed 's/x86_64/amd64/') \
    && curl -fsSL "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${ARCH}.bz2" \
        | bunzip2 > /usr/local/bin/restic \
    && chmod +x /usr/local/bin/restic

COPY entrypoint.sh /entrypoint.sh
COPY scripts/ /scripts/

RUN chmod +x /entrypoint.sh /scripts/*.sh

# Container health: daemon alive + last backup succeeded + ran recently.
# Thresholds tunable via BACKUP_ALIVE_MAX_AGE / BACKUP_HEALTH_MAX_AGE.
HEALTHCHECK --interval=5m --timeout=10s --start-period=2m --retries=3 \
    CMD ["/scripts/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
