# Worktree slots and `wt_up` (OSS PRs)

EE PRs do not use this: `_specs/ee-worktree.sh` → `ee_up` (runbook in the `langflow-enterprise-qa` skill).

**A pool of five permanent, warm worktrees** (Alice, 2026-10-16), created from the mirror
`~/Langflow/Local-instances/main/langflow` (which stays pristine on `main`). They are never removed.
**Clean = application state** (DB, `.env`, config dir, knowledge bases, logs, git tree), scrubbed when
a slot is freed and again when it is taken. Deps (`node_modules`, `.venv`, the frontend build) stay:
`make run_clic`'s chain runs `npm install` + `uv sync --frozen`, which reconcile them to the branch's lockfiles.

| Slot | Path (`~/Langflow/pr-validation/worktrees/…`) | Port | dev-mode UI / API (opt-in) |
|---|---|---|---|
| `active`  | `active`  | 7862 | 3000 / 7860 |
| `active2` | `active2` | 7864 | 3001 / 7861 |
| `active3` | `active3` | 7830 | 3002 / 7831 |
| `active4` | `active4` | 7832 | 3003 / 7833 |
| `active5` | `active5` | 7834 | 3004 / 7835 |

A freed slot sits on a detached `origin/main` with a baseline `.env` (fresh Fernet key,
`LANGFLOW_CONFIG_DIR` and `LANGFLOW_KNOWLEDGE_BASES_DIR` under `~/Langflow/Temp/langflow-config-<slot>`).

## Claims

Sessions run concurrently. A slot is yours only while `.claims/<slot>` (outside the worktrees) names
your session; a detached `wt-keeper` process touches it every 60 s (24 h TTL, tied to the Claude
process). Git state never proves a slot is idle.

| State | Meaning | `wt_claim` / `wt_up` |
|---|---|---|
| LIVE | keeper running | never taken, not even with `--force` |
| STALE | keeper gone < 12 h since the last heartbeat | refused; `--force` only with Alice's OK |
| EXPIRED | keeper gone ≥ 12 h | reaped |

A slot with a process running in it is never taken. **All five busy → `wt_up` exits 3** and prints
`wt_pool`; the agent asks Alice which slot to free (or whether to build a dedicated worktree) — see
SKILL.md § 2 — then runs `wt_up --take <slot> …` (`wt_free --force` + claim) or `wt_up --dedicated …`.
A dedicated worktree lives at `worktrees/<ticket>` on an even port in 7840–7852, recorded in
`worktrees/.own/<ticket>` (no keeper; `wt_mine`, `wt_status`, `wt_release`, `wt_down` all know it) and is
removed by `qa_cleanup`. `.own/` also holds bare port reservations (no worktree) of the RC sessions.
`wt_mine` failing in a later shell means your claim is gone (Alice freed the slot for another
session): stop touching the slot and tell her.

## Helper (`source ~/Langflow/pr-validation/_specs/worktree-claim.sh`)

| Function | Does |
|---|---|
| `wt_status` | who holds what (state, ticket, since, heartbeat, running pids) |
| `wt_pool` | one `key=value` line per pool slot: state, ticket, `host_session`, instance, runner, results — the input of the pool-full question |
| `wt_up [--force] [--ref <git-ref>] [--extras "postgresql pgvector"] [--take <slot> \| --dedicated] <ticket> <pr>` | claim → stop the slot's servers → fetch `pull/N/head` → `checkout -B pr-N-qa` → scrub the slot state → `wt_env` → `make run_clic port=$PORT` detached → `wt_wait` → `wt_probe` → (`--extras`: `uv sync --frozen --extra …` + `wt_restart`, because `run_clic` strips extras). Pool full → exit 3 |
| `wt_free [--force] [slot]` | stop every server in the slot (by cwd, command line and port listener) → scrub (DBs, logs, config dir + KBs, test caches) → reset to a detached `origin/main` (+ delete the ticket's branches) → baseline `.env` with a fresh key → release. `--force` only for the slot Alice picked |
| `wt_warm <slot>` | create a missing pool slot: worktree on `origin/main` + `make install_frontend install_backend build_frontend` (run in background) |
| `wt_mine` | top of every later Bash call: re-exports `SLOT WT PORT`, re-arms the keeper |
| `wt_wait [secs]` | poll `/api/v1/version` on `$PORT`; fails fast if the launched process died |
| `wt_probe` | `POST /api/v1/variables/` type Credential must be **201** (then deleted) — a green `/version` does not cover the Fernet trap |
| `wt_restart` | kill `$PORT`, relaunch `.venv/bin/langflow run … --env-file .env --frontend-path src/backend/base/langflow/frontend` (no rebuild, keeps hand-installed packages), wait, probe |
| `wt_env [--new-key] [--no-backup]` | writes the slot `.env` keeping/minting a valid `LANGFLOW_SECRET_KEY`, `LOG_LEVEL=INFO`, `AUTO_LOGIN=true`, per-slot `LANGFLOW_CONFIG_DIR` and `LANGFLOW_KNOWLEDGE_BASES_DIR` |
| `wt_down` | **pause**: stop the slot's servers; claim, DB and checkout stay (re-test, `wt_restart`) |
| `wt_release` | release only (also stops the keeper) — leaves the state behind; prefer `wt_free` |
| `qa_ports` | who listens on which QA port (pid + worktree/plan) — run before any manual launch |
| `qa_cleanup <ticket>` | **after Alice's sign-off**: runner, plan, runs, `qa-<ticket>-*` containers (removed with `-v`: their anonymous volumes go too; named volumes only via the ticket-name match); pool slot → `wt_free` (kept), dedicated/EE worktree → removed, plus the findings doc and `<ticket>-assets/` — nothing of the ticket is kept |
| `wt_dev_ports` | exports `DEV_UI_PORT` / `DEV_API_PORT` for dev mode |

Logs: `worktrees/.run.<slot>.log` (make/run output) and `/tmp/langflow-<slot>.log` (app log).

## Machine-wide guards (OSS and EE)

| Guard | What happens | Tools |
|---|---|---|
| **Build queue** | One heavy build at a time on the machine: `run_clic` (until the server listens), the EE bring-up (until `BUILD_DONE`), `wt_warm`, `ee_warm`. The others wait; their log shows `[queue] waiting for the build lock -- held by: <slot> <ticket>`. A holder that died is broken by the next waiter. `wt_wait`/`ee_wait` do not count queued time (cap: 1 h). | lock dir `worktrees/.build-lock` |
| **Instance cap** | At most `QA_MAX_INSTANCES=4` QA Langflow servers listening on 7820–7898 (OSS + EE + RC; the nightly on 7810 does not count). One more → `wt_up`/`ee_up` exit **4**, slot still claimed. Ask Alice which instance to pause, `qa_pause <port>`, re-run; `--over-cap` only with her OK. | `qa_instances`, `qa_pause <port>` |

**Port map** (never pick one by hand): OSS pool 7862 / 7864 / 7830 / 7832 / 7834 · EE pool 7820 / 7822 / 7824 / 7826 / 7828 · OSS dedicated worktrees and RC reservations 7840–7858 (even) ·
EE per-ticket worktrees (pre-pool or --dedicated) 7866–7898 (even) · shared nightly 7810 · UI-plan runners 8900–8999 (derived per plan) ·
mock IdP 5557 · MCP testbed 8766 (admin 9999) · OpenSearch 9201. A port you did not allocate through a
helper belongs to another session: a reply from it (409 on a fresh DB, unknown data) is not a finding.

## Rules that are not in the helper

- **Never write `.env` by hand with `>`** — it drops `LANGFLOW_SECRET_KEY`, the instance falls back
  to the shared `~/Library/Caches/langflow/secret_key` (poisoned, ≥ 32 chars but not Fernet), boot
  stays green and the first credential save 500s in Alice's hands. Append with `>>`, then `wt_restart`.
- **Free only `$PORT`.** A sweep over 7860/7861/7862/3000 kills the other session's server. And kill
  only LISTENERS: `lsof -ti :<port>` also lists every client of the port (Alice's browser on the UI) —
  the helpers use `lsof -t -iTCP:<port> -sTCP:LISTEN`.
- **`checkout -B`, never a bare `reset --hard`** — it moves the previous PR's ref.
- **Never swap source files during a build** (vite serves a mixed bundle). Fail-before checks run
  after `/version` answers, then `wt_restart`. Grep the served bundle for each changed frontend file.
- `uv run` / `make run_cli*` / `uv sync` strip packages installed by hand (psycopg, crewai,
  opensearch-py). Install with `uv pip install …`, then `wt_restart` (launches `.venv/bin/langflow`).
- `disk I/O error` at boot = another Langflow holding the slot DB (often on a stray port like 7863).
  `pgrep -fl "langflow.__main__ run"` + `lsof -a -p <pid> -d cwd`; ask Alice before killing a process
  you did not start.
- Never force-checkout a worktree you did not create; a dedicated worktree is yours only while
  `worktrees/.own/<ticket>` names your session.
- A slot is handed back with `wt_free` (or `qa_cleanup`), never a bare `wt_release`: the next session
  must find it clean. Scratch lives in the session scratchpad.
- Inside Claude Code, `grep` is a shell function with different regex semantics — the helpers call
  `command grep`. Do the same in any script that matches names you will then delete.

## Dev mode (opt-in, only for live frontend iteration)

```bash
wt_dev_ports && wt_env
cd "$WT" && make backend port=$DEV_API_PORT &
cd "$WT/src/frontend" && VITE_PROXY_TARGET=http://127.0.0.1:$DEV_API_PORT npm run start -- --host 127.0.0.1 --port $DEV_UI_PORT &
```
The proxy defaults to 7860 and vite binds IPv6-only without `--host` (curl passes, the browser
fails). Verify through the proxy: `curl http://127.0.0.1:$DEV_UI_PORT/api/v1/version`.
