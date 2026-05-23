# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo is a Podman Compose configuration for running [NousResearch Hermes Agent](https://docker.io/nousresearch/hermes-agent) — an AI agent platform with a gateway API and web dashboard.

Two services are defined in `docker-compose.yml`:
- **hermes-gateway** — API gateway on port `8642` (`command: gateway run`)
- **hermes-dashboard** — Web UI on port `9119` (`command: dashboard --host 0.0.0.0 --insecure`)

Both mount `~/.hermes` as `/opt/data` inside the container for persistent state (config, logs, skills, sessions, etc.).

## Container Runtime

This project uses **Podman** (not Docker). A wrapper script `./podman-compose` is included that passes `--in-pod 0` automatically — always use it instead of the system `podman-compose`, because `userns_mode: keep-id` is incompatible with Podman's default pod mode.

```bash
# Start services
./podman-compose up -d

# Stop services
./podman-compose down

# Restart a single service
./podman-compose restart hermes

# View logs
./podman-compose logs -f hermes
./podman-compose logs -f dashboard

# Pull latest image
./podman-compose pull
```

`userns_mode: keep-id` and `user: "1000:1000"` are required so the container runs as the host user and can write to the volume without permission issues.

## Data Directory

All runtime data lives in `~/.hermes/` on the host (mounted as `/opt/data:Z` inside containers):

| Path | Contents |
|------|----------|
| `~/.hermes/config.yaml` | Main agent configuration |
| `~/.hermes/.env` | Secrets / API keys |
| `~/.hermes/logs/` | Gateway and agent logs |
| `~/.hermes/skills/` | Installed skills |
| `~/.hermes/plugins/` | Installed plugins |

The `:Z` SELinux label on the volume mount is required on systems with SELinux enabled.
