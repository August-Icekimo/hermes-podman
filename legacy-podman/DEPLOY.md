# DEPLOY.md — Claude Code Worker Delegation

Bring-up order, auth phases, network lockdown, Hermes wiring, and the isolation
checks that prove the threat model holds. Run everything with the project's
`./podman-compose` wrapper (it passes `--in-pod 0`, required for `keep-id`).

## 0. Prerequisites

```bash
# host directories (independent worker home + shared task surface)
mkdir -p ~/.claude-worker/.claude ~/hermes-tasks

# copy the role contract + permission policy into the worker home
cp worker-home/.claude/settings.json ~/.claude-worker/.claude/settings.json
cp worker-home/.claude/CLAUDE.md      ~/.claude-worker/.claude/CLAUDE.md

# confirm the rootless podman user socket exists (the broker mounts it)
systemctl --user enable --now podman.socket
ls -l /run/user/$(id -u)/podman/podman.sock
```

If your UID isn't 1000, change `1000:1000`, the volume host paths, and the
socket path `/run/user/1000/...` in `docker-compose.yml` accordingly.

## 1. Build images

```bash
./podman-compose build claude-worker task-broker
./podman-compose up -d
```

The worker idles (`sleep infinity`); the broker comes up on `task-broker:8777`
inside `hermesnet`.

## 2. Authenticate the worker — TWO PHASES

The worker's credentials live in the mounted home and survive restarts.

### Phase A — now until June 15, 2026 (API key, your ~$18 balance)

```bash
# put the key in the worker home's .env — NOT in compose environment
printf 'ANTHROPIC_API_KEY=sk-ant-...\n' > ~/.claude-worker/.env
chmod 600 ~/.claude-worker/.env

# tell claude to read it (console/API billing)
podman exec -it claude-code-worker bash -lc \
  'set -a; . /opt/data/.env; set +a; claude auth status --text'
```

Set a **spend limit of ~$15 in the Anthropic Console** as the hard fuse. The
broker's `MONTHLY_SOFT_CAP_USD=18` trips first as an early brake.

> Why the key goes in `.env` and not compose: if `ANTHROPIC_API_KEY` is present
> in the environment, Claude Code silently bills the API instead of any
> subscription. Keeping it in a file you source deliberately avoids leaking it
> into other processes and makes the post-6/15 switch a one-line deletion.

### Phase B — June 15, 2026 onward (OAuth, the $20/mo Agent SDK credit)

```bash
rm -f ~/.claude-worker/.env            # remove the API key entirely
podman exec -it claude-code-worker claude auth login   # browser OAuth (Pro)
podman exec -it claude-code-worker claude auth status  # expect: subscription/OAuth
```

After this, programmatic `claude -p` runs draw from the Pro plan's separate $20
Agent SDK credit, NOT your interactive Claude usage and NOT pay-as-you-go API.

## 3. Lock down worker egress

The worker should reach **only** the Anthropic API and your git remote. Compose
puts it on its own `workernet`; enforce the allow-list at the host. Example with
firewalld (adapt to your host):

```bash
# find workernet's subnet
podman network inspect hermes-podman_workernet -f '{{range .Subnets}}{{.Subnet}}{{end}}'

# default-deny egress for that subnet, then allow only what's needed
# (api.anthropic.com + your git host). Pin to resolved IPs or use a proxy.
```

If you can't easily IP-pin, run a tiny egress proxy (e.g. tinyproxy) on
`workernet` allowing only those hosts, and set `HTTPS_PROXY` in the worker.
The deny list in `settings.json` already blocks curl/wget/ssh/WebFetch as a
second layer.

## 4. Wire Hermes to the broker (skill change)

The upstream `claude-code` skill assumes `claude` runs in Hermes' own shell.
In your fork, replace direct `claude -p` calls with a broker call, and add a
delegation threshold so routine work doesn't get shipped over.

Hermes-side call shape (it already has `BROKER_URL` in its environment):

```bash
# inside Hermes' terminal tool
curl -s -X POST "$BROKER_URL/delegate" \
  -H 'content-type: application/json' \
  -d '{"task_type":"implement","task_id":"feat-jwt-auth",
       "prompt":"Add JWT auth to the login handler in app/auth.py"}'
```

Add to the skill's guidance (paraphrase into the SKILL.md you control):

> **Delegate to the worker only for heavy work** — multi-file changes,
> refactors, test suites, or anything needing iterative debugging. For one-line
> fixes, single commands, or file lookups, handle it directly. Valid
> `task_type` values: `implement`, `refactor`, `test`, `review`. Put the repo
> for the task under `~/hermes-tasks/<task_id>/` first; the worker only sees
> that directory.

Response JSON includes `total_cost_usd`, `num_turns`, `subtype`, and `result`.
Have Hermes persist `total_cost_usd` to keep its own running ledger.

## 5. Verify isolation (do this before trusting it)

```bash
# worker cannot see the host home beyond /work
podman exec claude-code-worker ls / | grep -q home && echo "FAIL: home visible" || echo "ok: no host home"
podman exec claude-code-worker sh -c 'cat /opt/data/../.hermes/* 2>&1 | head' # should fail / not exist

# worker has no podman socket (only the broker does)
podman exec claude-code-worker sh -c 'ls /run/podman/podman.sock 2>&1' # expect: No such file

# worker is not reachable from Hermes' network (no ports, different net)
podman exec hermes-gateway sh -lc 'getent hosts claude-code-worker || echo "ok: worker not on hermesnet"'

# broker enforces the whitelist (arbitrary type rejected)
curl -s -X POST http://localhost:8777/delegate -H 'content-type: application/json' \
  -d '{"task_type":"run_anything","task_id":"x","prompt":"rm -rf /"}' # expect 400
# (only works from host if you temporarily publish 8777; normally broker is
#  internal to hermesnet — test from inside hermes-gateway instead)
```

## 6. Day-to-day

```bash
./podman-compose logs -f task-broker      # watch delegations + costs
curl -s http://task-broker:8777/health    # spend so far vs soft cap
podman exec -it claude-code-worker claude auth status --text  # auth sanity
```

## Quick reference — what lives where

| Concern            | Location / mechanism                                  |
|--------------------|-------------------------------------------------------|
| Worker credentials | `~/.claude-worker/` (independent home, survives restart) |
| Task sandbox       | `~/hermes-tasks/<task_id>/` → `/work/<task_id>` in worker |
| Exec capability    | `task-broker` only (holds podman socket)              |
| Task whitelist     | `broker/broker.py` → `TASK_TYPES`                      |
| Tool permissions   | `~/.claude-worker/.claude/settings.json`              |
| Role contract      | `~/.claude-worker/.claude/CLAUDE.md`                  |
| Budget fuses       | `--max-budget-usd` (per call) + Console limit + soft cap |
| Delegation gate    | Hermes skill threshold (heavy work only)              |
