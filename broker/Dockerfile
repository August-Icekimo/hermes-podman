# syntax=docker/dockerfile:1
# task-broker: small FastAPI service that is the ONLY component allowed to
# `podman exec` into the worker. It needs a podman client + the socket mounted.
FROM docker.io/library/python:3.13-slim

# podman client (to talk to the mounted socket). We only need the CLI talking
# over the unix socket; the daemon/socket itself is the host's, mounted in.
RUN apt-get update && apt-get install -y --no-install-recommends \
        podman \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN pip install --no-cache-dir "fastapi==0.115.*" "uvicorn[standard]==0.34.*" "pydantic==2.*"

COPY broker.py /app/broker.py

# Talk to the host podman over the mounted socket.
ENV CONTAINER_HOST=unix:///run/podman/podman.sock

EXPOSE 8777
CMD ["uvicorn", "broker:app", "--host", "0.0.0.0", "--port", "8777"]
