"""
task-broker — the single gate between Hermes and the Claude Code worker.

Design contract (do not loosen without re-reading the threat model):
  * Hermes can ONLY trigger one of a fixed set of task types.
  * Each task type maps to a hard-coded `claude -p` command template.
  * Hermes supplies a task_id + a free-text prompt. Nothing else is interpolated
    into the shell. The command is built as an argv list (no shell=True), so the
    prompt can never break out into another command.
  * Every invocation carries --max-budget-usd and --max-turns as fuses.
  * The worker only ever runs inside /work/<task_id>, never elsewhere.
  * This broker holds the podman-exec capability. Hermes does not.

Run inside its own container (see compose). It reaches the worker via:
    podman exec <WORKER_CONTAINER> claude -p ...
which requires the podman socket mounted into THIS broker container only.
"""

import asyncio
import os
import re
import shlex
from pathlib import PurePosixPath

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

# --- configuration (overridable via env in compose) ------------------------
WORKER_CONTAINER = os.environ.get("WORKER_CONTAINER", "claude-code-worker")
PODMAN_BIN = os.environ.get("PODMAN_BIN", "podman")
WORK_ROOT = os.environ.get("WORK_ROOT", "/work")          # as seen INSIDE the worker
DEFAULT_MODEL = os.environ.get("CLAUDE_MODEL", "sonnet")
MAX_BUDGET_USD = os.environ.get("CLAUDE_MAX_BUDGET_USD", "0.50")
EXEC_TIMEOUT_S = int(os.environ.get("EXEC_TIMEOUT_S", "600"))

# A shared monthly soft cap the broker tracks in-process. Hard cap still lives
# in the Anthropic Console (pre-6/15 API key) or is the $20 Agent SDK credit
# (post-6/15 OAuth). This is just an early brake so a runaway loop trips here
# before it eats the whole month.
MONTHLY_SOFT_CAP_USD = float(os.environ.get("MONTHLY_SOFT_CAP_USD", "18.0"))

# task_id must be filesystem-safe and cannot traverse out of WORK_ROOT.
_TASK_ID_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$")

# --- task-type whitelist ----------------------------------------------------
# Each entry defines:
#   tools     : value passed to --allowedTools (narrowest set that still works)
#   max_turns : agentic-loop ceiling for this kind of work
#   verb      : short instruction prefix prepended to the user's prompt so the
#               worker stays in role even if the prompt is terse.
# These reflect the bash/python/go stack: lint/test/build commands are gated by
# the worker's own settings.json deny/allow list (Read(.env) denied, no push).
TASK_TYPES: dict[str, dict] = {
    "implement": {
        "tools": "Read,Edit,Write,Bash(git add:*),Bash(git commit:*),"
                 "Bash(python3:*),Bash(go:*),Bash(bash:*),Bash(pytest:*),Bash(npm:*)",
        "max_turns": 25,
        "verb": "Implement the following. Work only inside this directory, "
                "create a feature branch, and finish with a clean commit. "
                "Do not push. Task: ",
    },
    "refactor": {
        "tools": "Read,Edit,Write,Bash(git add:*),Bash(git commit:*),"
                 "Bash(python3:*),Bash(go:*),Bash(bash:*),Bash(pytest:*)",
        "max_turns": 20,
        "verb": "Refactor as described, preserving behavior. Add/keep tests "
                "green. Commit on a feature branch, do not push. Task: ",
    },
    "test": {
        "tools": "Read,Write,Bash(python3:*),Bash(go:*),Bash(bash:*),"
                 "Bash(pytest:*),Bash(go test:*)",
        "max_turns": 20,
        "verb": "Write and run tests for the following. Report pass/fail "
                "summary at the end. Task: ",
    },
    "review": {
        # Read-only review: no Edit, no Write, no Bash. Cannot mutate anything.
        "tools": "Read",
        "max_turns": 8,
        "verb": "Review the code/diff for bugs, security issues, and style. "
                "Be specific and do not modify any files. Task: ",
    },
}

app = FastAPI(title="task-broker", version="1.0.0")

# crude in-process spend ledger; resets on restart. For durable accounting,
# Hermes should also persist total_cost_usd from each response.
_spend_total = {"usd": 0.0}


class DelegateRequest(BaseModel):
    task_type: str = Field(..., description="one of: implement, refactor, test, review")
    task_id: str = Field(..., description="fs-safe id; maps to /work/<task_id>")
    prompt: str = Field(..., min_length=1, max_length=8000)
    model: str | None = Field(None, description="override default model")


class DelegateResponse(BaseModel):
    ok: bool
    task_type: str
    task_id: str
    result: str | None = None
    total_cost_usd: float | None = None
    num_turns: int | None = None
    subtype: str | None = None
    session_id: str | None = None
    error: str | None = None


def _safe_workdir(task_id: str) -> str:
    """Resolve /work/<task_id> and refuse anything that escapes WORK_ROOT."""
    if not _TASK_ID_RE.match(task_id):
        raise HTTPException(400, "task_id must match ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
    resolved = PurePosixPath(WORK_ROOT) / task_id
    # PurePosixPath normalizes, but task_id regex already forbids '/', '.', '..'
    if not str(resolved).startswith(WORK_ROOT + "/"):
        raise HTTPException(400, "task_id escapes work root")
    return str(resolved)


def _build_argv(task_type: str, workdir: str, prompt: str, model: str) -> list[str]:
    """Assemble the exact argv. No shell, no interpolation of prompt into a string."""
    spec = TASK_TYPES[task_type]
    full_prompt = spec["verb"] + prompt
    # podman exec -w sets the working dir INSIDE the worker container.
    return [
        PODMAN_BIN, "exec", "-w", workdir, WORKER_CONTAINER,
        "claude", "-p", full_prompt,
        "--output-format", "json",
        "--model", model,
        "--allowedTools", spec["tools"],
        "--max-turns", str(spec["max_turns"]),
        "--max-budget-usd", MAX_BUDGET_USD,
        "--no-session-persistence",
    ]


@app.get("/health")
async def health():
    return {"status": "ok", "spend_usd": round(_spend_total["usd"], 4),
            "soft_cap_usd": MONTHLY_SOFT_CAP_USD}


@app.post("/delegate", response_model=DelegateResponse)
async def delegate(req: DelegateRequest):
    if req.task_type not in TASK_TYPES:
        raise HTTPException(400, f"unknown task_type; allowed: {list(TASK_TYPES)}")

    if _spend_total["usd"] >= MONTHLY_SOFT_CAP_USD:
        raise HTTPException(429, f"monthly soft cap reached (${MONTHLY_SOFT_CAP_USD}); "
                                 "refusing new delegations")

    workdir = _safe_workdir(req.task_id)
    model = (req.model or DEFAULT_MODEL).strip()
    if not re.match(r"^[a-zA-Z0-9._-]+$", model):
        raise HTTPException(400, "invalid model alias")

    argv = _build_argv(req.task_type, workdir, req.prompt, model)

    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(),
                                                    timeout=EXEC_TIMEOUT_S)
        except asyncio.TimeoutError:
            proc.kill()
            return DelegateResponse(ok=False, task_type=req.task_type,
                                    task_id=req.task_id,
                                    error=f"timed out after {EXEC_TIMEOUT_S}s")
    except FileNotFoundError:
        raise HTTPException(500, f"{PODMAN_BIN} not found in broker container")

    raw = stdout.decode("utf-8", "replace").strip()
    err = stderr.decode("utf-8", "replace").strip()

    if proc.returncode != 0 and not raw:
        return DelegateResponse(ok=False, task_type=req.task_type,
                                task_id=req.task_id,
                                error=f"exec failed (rc={proc.returncode}): {err[:500]}")

    # claude -p --output-format json prints a single JSON object on stdout.
    import json
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return DelegateResponse(ok=False, task_type=req.task_type,
                                task_id=req.task_id,
                                error=f"non-JSON output: {raw[:500]}")

    cost = float(data.get("total_cost_usd") or 0.0)
    _spend_total["usd"] += cost
    subtype = data.get("subtype")

    return DelegateResponse(
        ok=(subtype == "success"),
        task_type=req.task_type,
        task_id=req.task_id,
        result=data.get("result"),
        total_cost_usd=cost,
        num_turns=data.get("num_turns"),
        subtype=subtype,
        session_id=data.get("session_id"),
        error=None if subtype == "success" else f"stop: {subtype}",
    )
