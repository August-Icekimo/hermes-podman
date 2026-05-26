FROM docker.io/nousresearch/hermes-agent:latest

USER root
# Install sudo if not already present (handles both Debian/Ubuntu and Alpine bases)
RUN command -v sudo >/dev/null 2>&1 || \
    { apt-get update && apt-get install -y --no-install-recommends sudo && rm -rf /var/lib/apt/lists/*; } 2>/dev/null || \
    apk add --no-cache sudo 2>/dev/null || true
RUN echo "#1000 ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
