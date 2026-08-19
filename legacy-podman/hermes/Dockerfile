FROM docker.io/nousresearch/hermes-agent:latest

USER root
# Install sudo if not already present (handles both Debian/Ubuntu and Alpine bases)
RUN command -v sudo >/dev/null 2>&1 || \
    { apt-get update && apt-get install -y --no-install-recommends sudo && rm -rf /var/lib/apt/lists/*; } 2>/dev/null || \
    apk add --no-cache sudo 2>/dev/null || true
RUN echo "#1000 ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Fix: LINE adapter _env_enablement() returned home_channel as a plain string,
# but gateway/config.py requires {"chat_id": "..."} dict to wire up HomeChannel.
RUN sed -i \
    's/seeded\["home_channel"\] = os\.environ\["LINE_HOME_CHANNEL"\]/seeded["home_channel"] = {"chat_id": os.environ["LINE_HOME_CHANNEL"]}/' \
    /opt/hermes/plugins/platforms/line/adapter.py
