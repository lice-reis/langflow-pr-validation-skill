# Gotchas — grep this, don't read it

Traps met in real validation runs, by area. `grep -i -A4 <keyword>` when something looks wrong.
Each entry: symptom → cause → what to do. Dates are when it was last confirmed.

## Finding the PR and what actually shipped

- **`description: null` from `jira_cards_get`** even though Jira has one (2026-09-24). Ask Alice to
  paste it. `jira_cards_list` has no description field at all.
- **A ticket can carry more PRs than `pr_url`.** LE-2759 had #15370 (table size) and #15420 (Chat
  Output clean-data) in Jira's Web links; `gh search prs "LE-XXXX"` misses PRs whose title lacks the
  key. If the diff doesn't touch the defect's file, or a defect comes back unchanged on re-test,
  ask for the Web links panel. Sibling PRs don't contain each other: test each, then the combination.
- **Squash merges.** PR-head commits and dev-cited SHAs are never ancestors of the release branch;
  a cited SHA can be commit 1 of 2 (LE-2239: commit 2 fixed a regression commit 1 introduced) or
  force-pushed away (LE-2241). Before/after = parent of the squash-merge → the squash-merge commit;
  `gh api repos/langflow-ai/langflow/compare/A...B`. CodeRabbit's "Merge Risk … up to <sha>" line
  shows where its review stopped; a dev-quoted test count lower than `pytest --collect-only` means
  the comment predates later commits.
- **Merged ≠ present.** Two of three QA-1.12.0 tickets were reverted hours after merge (revert PRs
  name neither the key nor the PR). `gh pr list --state all --search "revert <feature word>"`,
  confirm the merge is an ancestor of HEAD and that the fix's own artifact (file/string/import) is
  still at HEAD.
- **A before/after commit can be unbootable** from an adjacent PR (LE-2244: unclosed import). Check
  out bootable HEAD and toggle only the changed file's blob: `git checkout <parent> -- <path>` /
  `git checkout <head> -- <path>`, `wt_restart` between. Tell Alice it's history, not the PR.
- **Card `status` can be days stale** — check `synced_at` before acting on it.
- **Closed PR → successor** (EE): a card's `pr_url` may point at another ticket's PR; grep
  `headRefName` for the key in `gh pr list --state all`, read the closed PR's closing comment.
- **Stacked PRs get rebased**: SHAs change, content may not. Compare `git patch-id --stable` and
  `git range-diff <old-base>..<old-head> <new-base>..<new-head>` before re-testing "what changed".
  A rename in a lower PR can break the PR above it: grep the upper PR for the old name.

## Environment and worktree

- **Fernet trap.** `.env` written with `>` (or `wt_env` run before the worktree dir exists — it
  prints "wrote" and creates nothing) → shared `~/Library/Caches/langflow/secret_key` → boot green,
  `/version` 200, first Credential write 500 `Fernet key must be 32 url-safe base64-encoded bytes`,
  including `POST /api/v1/api_key/` (blocks `/run`). `wt_probe` catches it; `wt_up` orders the steps.
- **`disk I/O error` at boot** = another Langflow holding the slot DB (2026-07-20: a stray on 7863
  with `--log-level debug`, cwd = the slot). `df -h` to rule out disk, `pgrep -fl "langflow.__main__ run"`,
  `lsof -a -p <pid> -d cwd`; ask before killing a process you didn't start.
- **`uv run` / `make run_cli*` / `uv sync` strip hand-installed packages** (crewai, psycopg,
  pgvector, opensearch-py) — install with `uv pip install …`, launch `.venv/bin/langflow` directly
  (`wt_restart`). `uv sync` inside `src/lfx` removes **langflow itself** from the shared venv: the
  running backend reload-crashes and every request hangs to timeout (`ModuleNotFoundError:
  fastapi_pagination` in the log). Restore with `uv sync` at the worktree root.
- **lfx tests** refuse to run with langflow importable; the escape hatch is
  `LFX_TEST_ALLOW_LANGFLOW=1 ./.venv/bin/python -m pytest -p no:cacheprovider <paths>` from the
  worktree root (never the suggested `cd src/lfx && uv sync`). Isolated env when truly needed:
  `UV_PROJECT_ENVIRONMENT=<scratch>/lfx-venv uv sync --all-extras` in `src/lfx` (`--python 3.10`
  for version-gated branches).
- **Backend tests that build the app stall 25+ min** while a Langflow instance runs on this Mac
  (importlib.metadata walk; pytest prints no summary). Kill your slot instance, re-run; the
  deselected ones then pass in seconds. Never write "N of M run" without that second pass.
- **`.env` leaks into pytest** (pydantic-settings): a flag the live server needs ON breaks
  default-off tests → override on the command line (`LANGFLOW_X=false pytest …`); tests that mint
  API keys need a valid `LANGFLOW_SECRET_KEY` exported.
- **Never swap source files while vite builds** — the served bundle mixes fixed and pre-fix files
  while `git log`/`status` look right (LE-2742). Fail-before only after `/version` answers; before
  handing over a frontend PR grep the served bundle (`curl / | grep assets/index-*.js`) for a
  fragment of every changed file.
- **zsh doesn't word-split `$VAR`**: `git checkout <rev> -- $FILES` is one pathspec and reverts
  nothing while the next jest run "passes" on the fix. Use an array (`"${FILES[@]}"`) or
  `$(echo "$FILES")`, and grep that the old code is really back before trusting a red run.
- **Postgres**: homebrew PG 17 on `localhost:5432`, user `alice`, no password, `psql` keg-only
  (`/opt/homebrew/opt/postgresql@17/bin`). Alembic's postgres parametrization silently skips
  unless `LANGFLOW_TEST_DATABASE_URI` is set.
- **Alembic from the Python API**, not the CLI: `Config('alembic.ini')` (cwd
  `src/backend/base/langflow`), `script_location=alembic`, `sqlalchemy.url=sqlite+aiosqlite:///<copy>`;
  `python -m alembic` no-ops, `-x db_url` is ignored, plain `sqlite://` fails (async driver). Print
  raw output (a `grep -iE "running|error"` once swallowed a failure). Shape: downgrade to parent →
  seed → upgrade head → assert columns + legacy row → upgrade again (idempotent).
- **SQLite WAL**: `cp langflow.db` drops everything still in the WAL (a "seeded" fixture that is
  empty). Stop the instance, `PRAGMA wal_checkpoint(TRUNCATE)`, copy db + `-wal` + `-shm`, assert
  row counts; delete stale `-wal`/`-shm` when restoring.
- **Dep-gating PRs** (`python_version` markers, torch-free extras): prove with a fresh
  `uv venv --python 3.14 .venvX` + `uv pip install --python .venvX/bin/python --dry-run .` (gated
  packages absent, `langflow-base`/`lfx` from `file://`), or `uv pip compile --prerelease=allow
  --python-platform linux --python-version 3.12` (resolve-only, 2 s) before/after vs `main`. The warm
  venv already has everything and proves nothing. `--prerelease=allow` is global and contaminates the
  graph (rc3: 14 extra pre-releases vs the official image) — compare with the image's freeze.
- **Stale editable dist-info** after a bundle version bump fails
  `test_manifest_exposes_cassandra_as_a_separate_bundle` (`'0.1.4' == '0.1.3'`): refresh with
  `uv pip install -e src/bundles/datastax --no-deps`.
- **jest**: `--maxWorkers=2` while a backend is booting (default drove load to 121).
- **macOS has no `setsid`**: detach with `( nohup cmd > log 2>&1 < /dev/null & )`; a plain
  background task dies with the Bash call, and a later timed-out call kills its process group (a
  mock server dying silently reads as a product hang).
- **Dev mode (vite)**: proxy defaults to `http://localhost:7860` (`VITE_PROXY_TARGET`); vite binds
  `[::1]` only without `--host` — curl passes, the browser fails (`--host 127.0.0.1`, literal IPs);
  resolve pids by port (`lsof -ti :PORT`), never `pgrep -f vite` (Alice runs other vites).
- **Cookie ignores the port**: two instances on `localhost` log each other out. macOS resolves any
  `*.localhost` → one hostname per instance/persona (`ana.localhost:7864`).
- **Pool full** (all 5 slots) → `wt_up` exits 3; ask Alice (SKILL.md § 2), then `--take <slot>` or
  `--dedicated`. A force-checkout of a worktree you didn't create is classifier-blocked — `--take`
  goes through `wt_free --force`, which is the sanctioned path once she picked the slot.
- **Knowledge bases are per slot** (`LANGFLOW_KNOWLEDGE_BASES_DIR` under the slot config dir, since
  2026-10-16). A worktree whose `.env` predates that still writes to the shared `~/.langflow/knowledge_bases`.
- **Customer nightly in a container**: use `langflow-base-nightly` (the meta package pins
  unpublished bundle deps), console script `langflow-base`, add the Postgres driver and
  `langchain-openai`, pin `pydantic==2.13.4`.
- **Feature flags are read at import** (`FEATURE_FLAGS = FeatureFlags()`), before `langflow run
  --env-file` loads its file, so a `LANGFLOW_FEATURE_*` set only there stays off (LE-2991). The
  `langflow` launcher also runs a bare `load_dotenv()` that walks up from the package: a source
  install picks up the **worktree's `.env`** (flags, DB URL) for every var not already set. For a
  flag-on/flag-off pair: `env -i HOME=$HOME PATH=… LANGFLOW_FEATURE_X=… <venv>/bin/python -m langflow run …`.
- **Never `set -a; source .env`** in the Bash tool: the exports leak into later calls and every
  server you start inherits the slot's DB URL and flags. Pass variables inline.
- **A taken port is silently replaced**: ask for 7868 while something holds it and Langflow binds
  7869, while the health check you poll answers from the OTHER server. Read `Uvicorn running on`
  from your own log; check the port is free first (`qa_ports`).
- **Backend pytest in a slot**: the tests' `conftest` loads the slot `.env`, so its
  `LANGFLOW_LOG_FILE` diverts subprocess logs (run with `LANGFLOW_LOG_FILE=`). `uv sync --extra
  postgresql` installs `psycopg` without libpq here, and pytest 9 `importorskip("psycopg")` then
  errors instead of skipping (`uv sync --frozen` restores).
- **zsh**: never name a variable `path` (it is `$PATH`); `${PIPESTATUS[0]}` is empty (`$pipestatus[1]`);
  `echo ====` is an equals-expansion error. `make run_clic` defaults `log_level=debug`: pass `log_level=info`.
- **`qa_cleanup` can leave a `qa-<ticket>-*` container running** without saying so (LE-3026:
  `qa-LE-3026-caddy` survived it; a plain `podman rm -f` then worked). Afterwards run
  `podman ps -a | grep <number>` and remove what is left — that removal is pre-authorized.

## Platform facts (the few that change a plan)

- **Multi-worker only exists on Linux.** `--workers N` forks real Gunicorn workers on Linux; on
  macOS/Windows it is clamped to one uvicorn process, so multi-worker bugs (job-queue/streaming
  races, migration races) reproduce only in a Linux container, with `LANGFLOW_JOB_QUEUE_TYPE=redis`.
- **`api_key_required` tests are skipped by default** — a green CI never exercised real providers.
- **SQLite ≠ Postgres**: concurrency, types and migrations differ; a pass on one is not a pass on
  the other. Postgres is reachable locally (see "Postgres" above).
- **`SECRET_KEY` must persist** across restarts/upgrades (mount the config dir in containers), or
  every stored credential silently breaks.
- **A component's class name is its flow identifier** — a rename breaks existing flows; watch
  component-refactor PRs for it.
- **Vendor bundle components** (`lfx/components/<vendor>/` user bundles) are not triaged by
  engineering; core-path components are.
- `GET /health` is uvicorn-level liveness; `GET /health_check` exercises the DB and cache (500 = a
  subsystem failed). `GET /api/v1/version` is what the bring-up helpers poll.

## API testing

- **Auth**: `GET /api/v1/auto_login` (a POST returns empty → every call 403s "No authentication
  credentials provided"); `/api/v1/run` needs `x-api-key` even with AUTO_LOGIN (403 "Since v1.5…") —
  mint one at `POST /api/v1/api_key/`; `/api/v1/login` is a form body and there is no default password.
- **Multi-user scripts**: `/login` sets `access_token_lf`; some endpoints (`POST /api_key/`) prefer
  the cookie over the header, so the last login wins → `client.cookies.clear()` after each login,
  sanity-check with `/users/whoami`.
- **A write that never responds under `Authorization: Bearer` but 409s under `x-api-key`**:
  `MissingGreenlet` after a rollback (duplicate-key paths). Try both headers before calling it a
  hang; repro on a fresh boot with the conflict as the first mutation (a hung request holds its
  connection and makes later ones look hung). Pre-existing on release-1.12.0.
- **"database is locked" / 65 s calls from a tight curl loop** = your own contention; Alice's
  isolated call took 87 ms. Re-test in isolation before reporting.
- **Same `session_id` twice returns the cached first run** → a toggle looks inert. Fresh
  `session_id` per run; A/B as OFF → ON → OFF (only a value that flips back is real). The Playground
  caches the same way — tell Alice to start a new chat between toggles.
- **`/api/v1/run` with no Output component builds nothing** (`outputs: []`): use
  `POST /api/v1/build/<flow>/flow` → `GET /api/v1/build/<job>/events` (NDJSON, parse per line).
- `/api/v1/all` is gzipped (`curl --compressed`). OpenAPI at `/openapi.json`; some routers are
  `include_in_schema=False` (variables, authz teams).
- **`POST /api/v1/variables/`** needs `default_fields: []` (422 otherwise). URLs/usernames as
  `Generic`, secrets as `Credential`: a Credential-typed URL reads masked and the DB-provider modal
  shows "Needs setup" after a green Test Connection — our own API negatives seeded exactly that
  (LE-1996). Delete and recreate as Generic.
- **`load_from_db: true`** on `api_key`/`SecretStrInput` fields: a literal key is read as a
  variable NAME ("variable not found" / silent env fallback → 401). Set `load_from_db: false` to
  test a bad key.
- **Counting rows**: `str.splitlines()` splits on VT/FF/NEL/U+2028 too; tabulate only on `\n`/`\r`
  → six invented findings. Use `split("\n")` and corroborate with a size (MB, `tracemalloc`).
- `POST /api/v1/mcp/project/{id}/install` writes the real client config (`~/.cursor/mcp.json`) —
  remove it after.
- **Public flows** (1.12.0+) run as a non-DB principal: MCP Tools fails on `get_user_by_id` before
  spawning, so an RCE PoC never reaches its side effect. Assert the guard boundary instead: pre-fix
  = request admitted + vertex built; post-fix = `400 "This flow cannot be executed."` and no build.
- **UI on the same port** (`run_clic`): any unknown `/api/v1/...` path is GET 404 but POST/DELETE
  405 (the SPA catch-all allows HEAD, GET). "Route not mounted → 404" holds for GET, or backend-only.

## API-built flows (so the canvas and Alice see what the API sees)

- **A node from an `/api/v1/all` spec saves (`nodes=1`), builds, and draws nothing.** Copy the node
  shape from a UI-created flow: top-level `measured:{width,height}`, `selected`, `dragging`,
  `data.showNode: true`, `data.node.category`. Backend fixture flows without `position` crash the
  canvas (`reading 'x'`). A malformed node is silently dropped to `nodes=0` — re-GET and count.
- **Edge handles** are JSON with `"`→`œ`, keys sorted. Source: output `name`/`output_types`;
  target: field `inputTypes`/`type` from the component template (ChatOutput `input_value` is
  `type:"other"` with `[Data,JSON,DataFrame,Table,Message]`, not `str`/`[Message]`). Edge id =
  `xy-edge__<src><encoded sourceHandle>-<tgt><encoded targetHandle>`. A mismatch → red toast "Some
  connections were removed" **and the browser autosaves the pruned graph** (edge gone from the DB,
  a later PATCH no-ops). After any browser visit re-read the flow via API and count edges.
- **A CustomComponent node renders only its first output** — one output per node.
- **Saved flows embed component code** (`template.code.value`) and run that, not the file on disk.
  Helper fixes (`lfx/helpers/*`) reach old flows; component-file fixes reach them only after "Update
  All". Component PR → test a flow created on the fix, one saved before it, that one after Update
  All. A pre-fix copy of the code pasted into a node gives a fail-before on the same instance.
- **Hand-built MCPTools node** returns "You must select a tool" unless `tool` has `show: True` +
  `options`; `mcp_server = {"name": …}`; each tool argument is its own template field.
- Grouped model outputs (`model_output`/`text_output`) built by hand are dropped by the UI —
  reconnect that edge in the UI. Open and screenshot the flow before handing the URL to Alice.

## UI, Browser pane

- Browser pane: no clipboard (⌘V/⌘A dead; reload to clear a field); `computer type` still enforces
  `maxLength` (valid for truncation tests, report ⌘V as `na`); coordinates are half the image on a
  2x display — `resize_window` 1440x900 first; measure with `javascript_tool` (`data-testid`,
  `getBoundingClientRect`), not screenshots; a `key` after `javascript_tool` needs a click to
  re-focus; console errors from your own restarts are residue, check only for new ones.
- **One automated click that "didn't work"** after pane timeouts is not evidence (LE-1388 Stop
  button worked for Alice). Retry with fresh refs and corroborate with the network log or backend log.
- Sub-second states: a `MutationObserver` + `performance.now()`; state the duration (a 115 ms
  blink and "stuck until reload" are different bugs).
- Empty-looking UI after a secret-key rotation = stale JWT, not data loss — mint a fresh token and
  query the API.

## Features

- **Assistant**: `LANGFLOW_AGENTIC_EXPERIENCE=true` or `/api/v1/agentic/*` → 404 "not available".
  The panel posts to `/assist/stream` (also `/assist`, `/assist/run`) — test the stream path. Needs
  Bearer + an existing `flow_id` + a provider key (keys bridge from `.env` into global variables on
  a fresh DB). `uvicorn --factory` does not load `.env`. The selector ignores `default_model`: it
  takes `enabled_models` and the first "strong" one, so Google shows `gemini-flash-latest`; enable
  a model in Settings → Model Providers before expecting it. The `message` table stores the composed
  prompt (longer than typed). Code-gen retries 500 with `content_blocks` on some models — match the
  UI's model before comparing. Per-vertex truth is the `transaction` table.
- **Agent**: structured output takes the native path only with ALL tools off (Current Date is on by
  default) → test both paths and say which. An empty chat reply with HTTP 200 = an empty final model
  turn after a tool call (reasoning budget / serving stack; check `finish_reason`), not Langflow.
- **MCP**: pydantic `2.14.0a1` "not fully defined" is whack-a-mole — test the MCP Tools component
  (client path, `MCPStructuredTool`), not only the server endpoint; force the pin with
  `uv pip install pydantic==2.14.0a1` + `uv run --no-sync`. stdio lockdown only bites under hardened
  config (`allow_custom_components=false` or `custom_component_admin_only=true`) **and** a
  non-superuser; prove the spawn with a bogus `uvx <pkg>`.
- **Hardened gates mask each other**: the first rejecting gate is the only error; flip each off one
  at a time (LE-2321 had two). The 500 body is generic — the cause is only in the log. Directory
  has its own root guard that pre-empts `enforce_local_file_access`.
- **Knowledge / Memory bases**: network backends (OpenSearch, Chroma Cloud) refuse any destination
  not in `LANGFLOW_KB_ALLOWED_HOSTS` (boot-time, restart) — anything configured in the UI is a
  global variable and always needs it; `test_connection` is liveness-only (`GET /`, 403 = success).
  `kb_name` is created once (`sanitize(name)_<8hex>`): rename/flush/regenerate never rebuild it, so
  a base made under a buggy rule stays dead after upgrade → legacy-base test, `warning` not `fail`.
  MB create: `POST /api/v1/memories {name, flow_id, embedding_model, backend_type, backend_config}`;
  prove ingest by seeding `message` rows + `POST /memories/{id}/flush {session_id}` +
  `GET /memories/{id}/mismatch` → `false`. Split Text merges lines up to `chunk_size` (N lines ≠ N
  chunks — phrase expectations as "count = chunks listed"); chunk overlap must be < chunk size; a run
  with Knowledge last ingests twice (LE-2912 F1, since 1.12.0). `opensearch-py` is not in the venv.
- **Files**: the File component validates extensions (`TEXT_FILE_TYPES`), `.bin` is refused before
  the size cap — build big fixtures as `.txt`, sized between the buggy and the configured cap, and
  `curl`-upload it once. API-built `File` node needs both `path.value` and `path.file_path` (upload
  paths from `POST /api/v2/files/`). `Read File` collapses selected files into one Message. S3:
  invalid dropdown default no-ops before boto3 (no infra); for real uploads `moto_server` in a
  throwaway venv + `AWS_ENDPOINT_URL_S3` exported in the launching shell (MinIO is not pullable
  anonymously).
- **Secret-key rotation** (`scripts/migrate_secret_key.py`): always `--config-dir` and
  `--database-url` (defaults write to the shared cache dir); fresh instances have
  `auth_settings='null'` / `store_api_key=''` which the script trips on (pre-existing); compare key
  derivations functionally (encrypt with the app, decrypt with the script), not as strings.
- **Security PoCs**: a retained helper (`remove_api_keys`) keeps reproducing at function level —
  verify at the endpoint; `strip_keys` fires only on the single-version read, create a version first
  or the test checks nothing. Enumerate every export boundary and assert each carried data.
- **Telemetry PRs**: assert on the wire (local OTLP collector decoding protobuf, grep `raw/` for the
  credential across traces/metrics/logs); in-memory exporters can't see redaction. `OTEL_EXPORTER_OTLP_*`
  are SDK vars exported in the launching shell.
- **Provider errors on demand** (retired model 404, quota): point the SDK at a local mock
  (`GOOGLE_GEMINI_BASE_URL`, exported in the launching shell), log requests as evidence;
  `validate_model_provider_key` calls the **first** catalog model, keep it answering 200.
- **crewai** is not shipped (httpx conflict); `uv pip install crewai==0.134.0` into the venv then
  `wt_restart`. AST-extract `convert_llm` for a standalone test.

## Product behaviour (facts that shape a test, not derivable from one grep)

- **`session_id` defaults to the flow id** — without a custom one every caller shares one chat
  history (and the Playground caches per session, see "API testing"). Per-request global
  variables go in `X-LANGFLOW-GLOBAL-VAR-<NAME>` headers; a flow's **Endpoint Name** lets you
  call `/api/v1/run/<name>` instead of the UUID.
- **Env keys become global variables at boot** (`OPENAI_API_KEY`… via
  `LANGFLOW_VARIABLES_TO_GET_FROM_ENVIRONMENT`), only on a fresh DB bridge.
- **Playground needs Chat Input + Chat Output**; a flow exposed as an MCP tool needs a Chat
  Output; MCP tool names default to the flow id (`/api/v1/mcp/project/{id}/streamable`;
  `LANGFLOW_ADD_PROJECTS_TO_MCP_SERVERS=false` disables auto-exposure). Freeze cascades upstream.
  Prompt templates: `{name}` is a variable, `{{literal}}` escapes.
- **New component not in the palette?** Components load from a prebuilt index: run with
  `LFX_DEV=1` (hot reload) or rebuild it (`uv run python scripts/build_component_index.py`)
  before calling a component PR broken. Base class: `lfx.custom.custom_component.component.Component`;
  built-ins under `src/lfx/src/lfx/components/<category>/`, registered in the category `__init__.py`.
- **Default `LANGFLOW_LOG_LEVEL` is `critical`** — a silent log is not a healthy log (`wt_env`
  sets INFO). Pre-release builds use `langflow-pre.db`, not `langflow.db`.
- **Postgres URL** `postgresql://…` is rewritten to the async `psycopg` driver automatically; the
  PG server version is checked at boot and startup fails fast if too old.
- Starter projects: `GET /api/v1/starter-projects/` lists them live (33 on 1.10); the Simple
  Agent one ships a flagship model — re-point before running.

## Reporting calibration

- `fail` = defect in the deliverable; a wrong SHA in an internal Jira comment, background context, a
  coverage gap the PR closes → `pass`/`na` with a note. Quantify before it earns a number.
- Write the finding in Alice's wording and from the screenshot she chose; say an assumption in one
  line instead of building on it. Never ask her to re-verify what she reported.
- Before lowering a finding's status, ask whose evidence it is; downgrade only your own weak evidence,
  one finding at a time.

## RC / release regressions (wheel + Docker), learned on 1.13.0rc2 (2026-10-20)

- **`uv pip install langflow==<rc>` fails to resolve** ("no version of langflow-base==<rc>… pre-releases
  weren't enabled"): uv allows the pre-release only for the package named on the command line. Use
  `uv pip install --prerelease=allow langflow==<rc>` (also for the in-place upgrade of an older venv).
- **Ports for non-worktree instances** come from `_wt_own_claim <ticket> <ref>` (7840–7852, recorded in
  `worktrees/.own/<ticket>`); `qa_instances` then shows them as `reservation:<ticket>`. Still counts
  against the 4-instance cap — pause your own instance before a Docker/aux boot.
- **`openapi.json` hides many routers** (`include_in_schema=False`: variables, api_key, login, models,
  knowledge_bases, flow versions, mcp v1). Route shapes: `grep -rn '@router\.' site-packages/langflow/api/v1/<file>.py`.
  Flow versions: `GET /api/v1/flows/{id}/versions/` → `{"entries":[…]}`, `POST …/versions/{vid}/activate`
  restores `data` only (not `description`). MCP tool counts: `GET /api/v2/mcp/servers?action_count=true`.
  `POST /api/v1/models/enabled_models` body: `[{"provider":"OpenAI","model_id":"gpt-5.4-mini","enabled":true}]`
  — mini models are **disabled by default** on a fresh 1.13 instance (only the newest gpt-6.x are on);
  enable gpt-5.4-mini + text-embedding-3-small before a UI plan.
- **Language Model / Agent model selector via API**: `template.model.value` is a list with one dict
  `{"name":"gpt-5.4-mini","icon":"OpenAI","provider":"OpenAI","metadata":{…,"reasoning":true,"reasoning_models":["gpt-5.4-mini"]}}`
  and `model_name`/`provider` must be `""` (a value there → "Model name/provider overrides require a built-in
  model selection"). `api_key.value="OPENAI_API_KEY"` + `load_from_db=true`. The Orion OpenAI project has
  **no access to gpt-4.1-mini** (403 model_not_found) — use gpt-5.4-mini.
- **1.12 → 1.13 auto-login upgrade**: the 1.12 auto-login account has a generated bootstrap password;
  `LANGFLOW_SUPERUSER_PASSWORD` never overwrites it (sign-in 401 is documented). Follow the docs'
  "Recover access after upgrading": AUTO_LOGIN=true → `PATCH /api/v1/users/{id}` `{"password":…}` →
  AUTO_LOGIN=false. A boot that fails at the superuser check has already run the alembic migrations.
- **Knowledge storage auto-upgrade (Chroma → SQLite)** refuses with `legacy_workers_running` while ANY other
  `langflow run` process exists on the host (`remaining_legacy_workers` scans all processes) — on this Mac it
  never runs on a wheel instance while pool slots are up. Prove the happy path in a container instead
  (one process): 1.12.6 image → rc image on the same volume completes it at boot.
- **Docker images (1.12.6 and 1.13)**: `HOME=/app/data`; the SQLite DB is written inside
  `/app/.venv/lib/python3.14/site-packages/langflow/langflow.db` unless `LANGFLOW_SAVE_DB_IN_CONFIG_DIR=true`
  (docs' upgrade recipe: `-v vol:/app/langflow -e LANGFLOW_CONFIG_DIR=/app/langflow -e LANGFLOW_SAVE_DB_IN_CONFIG_DIR=true`);
  add `-e LANGFLOW_KNOWLEDGE_BASES_DIR=/app/langflow/knowledge_bases` or the KBs land in `/app/data/.langflow/`.
  zsh does not word-split `$ENV` — use `${=ENV}` when passing a string of `-e` flags to `podman run`.
- **1.12.6 `/api/v1/all` and big lists come back gzip-compressed**: `curl --compressed`.
- The 1.12.6 container once exited (code 0, not OOM) right after "Starting ingestion" of a KB upload; the
  retry worked. Not an rc2 behaviour.
- **Flows seeded through the API from `/api/v1/starter-projects/` data (1.12.6) drew four empty node frames
  in the rc2 canvas** (UI-002, 2026-10-20) although they ran through `/run`. A flow Alice built in the
  1.12.6 UI migrated and opened fine. For migration/UI items, build the source flows in the UI (or ask
  Alice to) instead of posting template data via API.
- **Two slots from one session (parallel subagents)**: `wt_mine` with no argument resolves by host session id,
  so every subagent of the same session gets the FIRST claimed slot. Each agent must call `wt_mine LE-XXXX`.

## RC regressions + multi-worker, learned on 1.13.0rc4 (2026-10-22)

- **Multi-worker = Docker image + `langflow run --workers N` + `LANGFLOW_JOB_QUEUE_TYPE=redis`**
  (`LANGFLOW_REDIS_QUEUE_URL=redis://<redis>:6379/<db>`, `LANGFLOW_RATE_LIMIT_STORAGE_URI` for a shared login
  limit). Without redis the image refuses `--workers >1` (exit 1, same since 1.12.7). Each worker then logs
  "scaled background backend is not available; falling back" — expected in 1.13. Podman VM here: 4 CPU / 6 GB;
  a 4-worker container uses ~3.3 GB, so run one at a time. Postgres serializes migrations with an advisory lock;
  **SQLite + workers crashes the first boot** (migration race, second boot works — pre-existing).
- **Knowledge storage upgrade refuses with more than one worker** (`single_host_required`, documented). Restart
  once with `--workers 1`, wait for Ready, go back to N workers.
- **Podman volumes: always `:Z`/`:z`** when a new container (e.g. rc image replacing 1.12.x) reuses a volume.
  Without it, files the old container created keep its SELinux MCS label → `Permission denied` (avatars 500).
  Never mount a running container's volume in a second container with `:Z` (relabels it under the running
  server → "unable to open database file"/"locking protocol").
- **Podman port forwarder on the Mac resets reused keep-alive sockets** ("Connection reset by peer", no server
  error). Clients hitting containers: disable keep-alive (httpx `Limits(max_keepalive_connections=0)`).
- **Login rate limit is 5/minute per client IP** (successful sign-ins included) — scripted suites hit 429;
  reuse one token and wait 60 s before a re-run.
- **Containers reaching host fixtures** (`host.containers.internal`) are blocked by SSRF protection: add
  `LANGFLOW_SSRF_ALLOWED_HOSTS=host.containers.internal`.
- API shapes: `GET /api/v1/triggers?flow_id=` (flow_id required); schedule trigger body
  `{"kind":"schedule","flow_id":…,"config":{"cron":"* * * * *","timezone":"UTC"},"state":"active"}`, then
  `POST /triggers/{id}/disable` when done (otherwise it runs every minute). `GET /api/v1/mcp/project/{id}`
  lists only enabled tools unless `?mcp_enabled=false`. Polling `/build/{job}/events` returns NDJSON text and
  long-polls after `end` — stop at `end`. `/api/v2/workflows` authenticates by the session cookie before
  `x-api-key`: keep a second user's login out of the client's cookie jar.
- The 1.12.7 Docker image already requires `LANGFLOW_SUPERUSER`/`PASSWORD` (AUTO_LOGIN=false in the image), so
  the Docker upgrade path is "same env on the rc image" — the auto-login recovery path only applies to wheels.
- `zsh`: `$RANDOM` inside `VAR=$RANDOM cmd | tail` in a loop repeats (subshell); `set -- $X` does not split.
