# syntax=docker/dockerfile:1
# claude-code-worker: an isolated container that runs `claude -p` on delegated tasks.
# Stack: bash, python3, go. No services, no exposed ports — broker exec's into it.
FROM docker.io/library/debian:bookworm-slim

# --- base tooling: git + build essentials + the three runtimes -------------
# python3 + venv for python tasks, golang for go tasks, bash is the default shell.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq ripgrep \
        python3 python3-venv python3-pip \
        golang-go \
        nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# --- non-root user matching host UID 1000 (keep-id maps it to your host user) ---
# We do NOT create the user here; userns_mode=keep-id + user: "1000:1000" in
# compose makes the container run as your host user. We just prepare a home it
# can own at runtime. HOME is set to /opt/data (the mounted volume) via compose.

# --- claude code CLI --------------------------------------------------------
# Install globally into a prefix the runtime user can use. We point npm's global
# prefix at the mounted home at runtime (PATH includes /opt/data/.npm-global/bin),
# but we also install a baseline copy here so the image works before first login.
ENV NPM_CONFIG_PREFIX=/usr/local
RUN npm install -g @anthropic-ai/claude-code \
    && claude --version || true

# Go module/cache dirs will live under the mounted home at runtime.
ENV GOPATH=/opt/data/go \
    GOCACHE=/opt/data/.cache/go-build \
    GOFLAGS=-mod=mod

# Sanity: show what we have. (Build-time only; harmless.)
RUN bash --version | head -1 \
    && python3 --version \
    && go version \
    && node --version

# The container idles; the broker drives it with `podman exec ... claude -p`.
CMD ["sleep", "infinity"]
