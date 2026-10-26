---
name: langflow-instance-migration-qa
description: TEMPORARY feature specialist for the Langflow OSS→Enterprise / instance-migration epic (LE-2395, release 1.13.0) — the `migration-preflight` / `check-integrity` CLIs, the `/api/v1/migration` API, and the Settings > Migration ("Move to a new instance") page. Knows the PR stack, which ticket each step of the dev's test script covers, and the setup traps. Load it from langflow-pr-validation whenever a ticket's parent is LE-2395 or it touches migration_preflight / integrity / api/v1/migration / MigrationPage. Also triggers on: "LE-2395", "migração de instância", "migration page", "migration-preflight", "check-integrity", "Move to a new instance", "LANGFLOW_FEATURE_INSTANCE_MIGRATION". Alice will delete this skill once the epic is validated.
---

# Instance migration (LE-2395) — QA specialist (temporary)

Use together with `langflow-pr-validation` (it still owns slots, worktree, report, checklist).

## What the epic is
Epic **LE-2395 "OSS-to-Enterprise Migration Path"** (1.13.0, Enterprise-GA). Not a full migration
tool: a compatibility + bootstrapping layer so an OSS instance's data can be attached to a new
(Enterprise) instance. Problem areas in the epic: SQLite→Postgres copy, pointing EE at an existing
Postgres, bootstrapping EE features on existing data (SSO identity mapping), moving local vector
stores (KBs / memory bases) and files to the new backend, re-encrypting secrets under the new
`LANGFLOW_SECRET_KEY`, and which settings carry over.

**Engineering plan** (full text: `references/engineering-plan.md`). Epic acceptance: *a person signs in
with the account they already had, opens the project they already had, and runs a flow that reads a
credential, a file, and a knowledge base.* Key decisions that shape what "correct" means:
- The DB is **adopted in place** (EE defines no tables) — no export file. Attaching migrates the schema
  **forward with no rollback** (snapshot is the only way back) → that is why the preflight refuses an
  older target (`version` check, LE-2914) and why the page forces a backup before copying.
- Secrets are **re-encrypted** under the new key. Roles: the target's 3 system-role ids are rewritten to
  match the source, then every row carries verbatim. Vectors copy only where embedding model + dimensions
  match, **per knowledge base**. SQLite→Postgres needs type coercion + **upsert** (not skip) of co-seeded rows.
- Out of scope (not bugs): flows broken by EE policy (custom components, code interpreter, local files,
  loopback, unlisted MCP), authz enforcement left OFF, authorship not recovered, SSO mapping (Eric), no
  portable export, no rollback.

**Silent-failure traps the plan names — every acceptance check must defeat these:**
- Wrong secret key → decrypt returns **empty string**, warning hidden at default log level. Prove a
  credential's *value* round-trips, not just that the row exists.
- Chroma stops mid-read on error → a partial copy looks complete. **Reconcile counts** (rows/chunks/vectors).
- `authz_share` has no FK → stale ids insert cleanly and grant nothing.
- WAL-mode SQLite copy can open fine and be empty (see memory `sqlite-wal-snapshot-trap`).
- `AUTHZ_SUPERUSER_BYPASS` defaults true and ownership grants access → "user opens own flows" proves
  nothing; test something ownership can't mask (e.g. creating a project as a non-superuser with a role).

Three layers, built bottom-up and **stacked PRs** (each PR's base is the PR below it):
1. **CLI** — `langflow check-integrity` and `langflow migration-preflight` (`src/backend/base/langflow/cli/integrity.py`, `cli/migration_preflight.py`, `__main__.py`). `--json` = one JSON object per line, then a `report` line.
2. **API** — `/api/v1/migration/*` (`api/v1/migration.py`), 14 routes, superuser-only (403 otherwise), behind `LANGFLOW_FEATURE_INSTANCE_MIGRATION=true`.
3. **Page** — Settings > Migration (`src/frontend/src/pages/SettingsPage/pages/MigrationPage/`): 10 ordered steps (1 Check, 2 Destination, 3 Secret key, 4 Pause, 5 Backup, 6 Copy DB, 7 Copy KBs, 8 Copy files, 9–10 "Coming soon").

Known PRs (langflow-ai/langflow): #15574 `feat/check-json-output` (→ release-1.13.0, `--json`),
#15575 `feat/preflight-target-version` (LE-2914, on 15574), … ,
#15624 `fix/migration-page-rehearsal-findings` (top of the stack, contains every layer; dev's script verified on `b9db7ac326`).
Check `git merge-base --is-ancestor pr-<ticket> pr-15624` to confirm a ticket's PR is in the rehearsal branch.

## Dev's test script
`references/dev-test-script-b9db7ac326.md` (by the dev, 2026-10-07). Section 5 maps tests → tickets:

| Script test | Tickets |
|---|---|
| §1.3 seed | LE-2897 |
| Test 1 Check | LE-2913, **LE-2914**, LE-2915, LE-2916 |
| Test 2 Destination | LE-2943, LE-2946, LE-2947 |
| Test 3 Secret key | LE-2944, LE-2948 |
| Test 4 Pause | LE-2910, LE-2942, LE-2949 |
| Test 5 Backup | LE-2945, LE-2950 |
| Test 6 Copy DB | LE-2918, LE-2951, LE-2966 |
| Test 7 Copy KBs | LE-2893, LE-2952, LE-2953, LE-2967, LE-2968, LE-2969 |
| Test 8 Copy files | LE-2952, LE-2953, LE-2967, LE-2968 |
| Test 9 Resume | LE-2942, LE-2949, LE-2950, LE-2951 |
| Test 10 non-admin 403 | LE-2915 |

The script itself lists what it does NOT cover per ticket (§5 tail) — each of those gaps is ours to
test: LE-2910 flag-off, LE-2913/2914 the terminal commands, LE-2916 page with flag off, LE-2947 wrong
port, LE-2954, LE-2966 reload mid-copy + backend restart, LE-2969 console check, LE-2918/2965 CI tests.
API-only tickets (LE-2942..2945, LE-2951..2953): replay the curl session in the PR description.

## How to validate a ticket of this epic
1. `jira_cards_get` the ticket — its **"Done when"** line is the acceptance criterion.
2. Check out **the ticket's own PR head** (it includes everything below it in the stack) for the
   ticket-specific checks; use the rehearsal branch (#15624) only for the page walk-through.
3. CLI tickets need no UI build: a migrated scratch DB is enough (recipe below).
4. Page tickets: follow the dev script's section 1 on the rehearsal branch, but adapt ports to the
   claimed slot and use **Podman** (CLAUDE.md: `podman ps -a`/`podman images` first; never prune).

### CLI scratch recipe (no frontend, slot port only)
```bash
S=<scratchpad>/<ticket>; mkdir -p $S/cfg
export LANGFLOW_CONFIG_DIR=$S/cfg LANGFLOW_DATABASE_URL=sqlite:///$S/src.db DO_NOT_TRACK=true \
       LANGFLOW_AUTO_LOGIN=true LANGFLOW_SECRET_KEY=$(grep ^LANGFLOW_SECRET_KEY $WT/.env | cut -d= -f2-)
# one boot migrates the DB (preflight never migrates; an empty DB fails "source: schema")
.venv/bin/python -m langflow run --backend-only --host 127.0.0.1 --port $PORT &   # wait for /api/v1/version, then kill $PORT
.venv/bin/python -m langflow migration-preflight --json --target-version 1.13.0
```

## Traps
- **`make init/install_backend/backend/run_cli` run `uv sync --extra postgresql` and strip `pgvector`** → page step 2 stops at "doesn't have the pgvector package". Re-run `uv sync --frozen --extra postgresql --extra pgvector` and launch `.venv/bin/...` directly.
- The Bash tool shell is **zsh**: `${PIPESTATUS[0]}` is empty; capture exit codes without a pipe.
- A fresh AUTO_LOGIN instance has a **never-signed-in default superuser that owns rows** → `default superuser` fails unless the target is known to keep the account. Since LE-2914, a passing `--target-version` (≥ source) counts as "keeps it". To isolate other checks, set `last_login_at` in a copy of the DB.
- A `warn` alone does not fail the command (exit 0); only `fail` does (exit 1).
- Version semantics (packaging.Version): `1.13`, `v1.13.0`, surrounding spaces = 1.13.0; `.devN` **and `rcN`** = older; `.postN` = newer. The page (#15624) additionally strips a leading `langflow ` / `v` before calling the same `check_target_version`.
- `--target-revision` always wins over `--target-version`.
- **Feature flag is read at import** (`FEATURE_FLAGS = FeatureFlags()`), before `langflow run --env-file`
  loads its file → a flag set ONLY in `--env-file` is ignored (reported as LE-2915 finding 1). The
  `langflow` launcher also runs a bare `load_dotenv()` that walks up from the package dir, so any instance
  started from the worktree venv picks up **the worktree's `.env`** (flag + DB URL!) unless the var is
  already in the process env. For a flag-off instance: `env -i HOME=$HOME PATH=… LANGFLOW_FEATURE_INSTANCE_MIGRATION=false <venv>/bin/langflow run --env-file …`.
- **Never `set -a; source .env`** in the Bash tool: the exports leak into later calls and every server you
  start inherits the slot's DB URL and flag. Pass env inline (`VAR=… cmd`) instead.
- zsh: never name a loop var `path` (it is tied to `$PATH`); `${PIPESTATUS[0]}` is empty (use `$pipestatus[1]`).
- With the UI served on the same port, ANY unknown `/api/v1/...` path is GET 404 / POST+DELETE 405
  (SPA catch-all allows HEAD, GET). So "flag off → 404" holds for GET only; 405 on POST is generic, not a bug.
- The seed at #15577 fails (`knowledge_base.storage_generation` NOT NULL); the fixed seed lives at
  #15624 (`3d84f1c27d`), no schema change in between — use `git show pr-15624:scripts/migration_rehearsal/seed_instance.py`.
- Slot `.env` has `LANGFLOW_LOG_FILE`; the backend `conftest` loads it, so `test_integrity.py::…keeps_the_logs_out`
  fails locally. Run pytest with `LANGFLOW_LOG_FILE=` (env), not a defect.
- Seeded users: `langflow` (superuser, never signed in), `alice`, `bob` (non-superusers, passwords unknown).
  For 403/UI non-admin checks use a separate instance with `AUTO_LOGIN=false` and a user created via API.
- `make run_clic` defaults `log_level=debug` → pass `log_level=info`.
- `uv sync --extra postgresql` installs `psycopg` WITHOUT a libpq here (no psycopg_binary, no brew libpq), so
  `test_integrity.py::TestSchema::test_a_database_that_cannot_be_reached…` errors instead of skipping
  (pytest 9 `importorskip` only skips ModuleNotFoundError). Environment, not a defect.
- Slot claims: `wt_claim` now starts its own detached keeper (fixed 2026-10-07; before that the claim died
  with the Bash shell and the LE-2912 claim on active2 was reaped). Don't hand-edit `pid=` or spawn a
  `nohup sleep` holder: a claim whose pid is not a `wt-keeper` reads as STALE. In each later Bash call run
  `source …/_specs/worktree-claim.sh && wt_mine`; release with `wt_release`. A STALE claim is refused,
  not reaped — `wt_claim --force` only with Alice's OK.
- Feature flags can't come from `--env-file` (LE-2991, pre-existing, every flag). Start instances with
  `env -i` and every var inline (`LANGFLOW_FEATURE_INSTANCE_MIGRATION`, DB URL, CONFIG_DIR, SECRET_KEY,
  AUTO_LOGIN…) via `.venv/bin/python -m langflow run --backend-only`; the worktree `.env` only fills unset vars.
- Stack rebases rewrite SHAs: compare with `git patch-id --stable` (334f4ec240 ≡ 4d4fbb4e8c) and
  `git range-diff old..head new..head` before re-testing what "changed".
- Record semantics: `acceptable_findings` = the FIXED set of 4 acceptable check names (always present),
  `blocking_findings` = failing checks of the last run not covered by an acceptance. An acceptance matches
  on (name, summary, problems) exactly, so any new problem re-blocks. `source: files` in both lists is normal.
- The files check names a file by the basename of its storage `path`, not `File.name` (what My Files shows):
  after a rename they differ (LE-2916 finding 1).
- The dev script says Docker; we use Podman. `docker rm -f` in its §3/§4 → only for containers we created for that run.

## Open questions for the dev (carry across tickets)
- LE-2914: CLI vs page disagree on an unparseable version. CLI: `--target-version latest`/`1.13.O` →
  one `warn version … the version was not checked` line among ~13 (next to the routine `warn target key`),
  no overall verdict line, **exit 0**. Page (#15624, read from code, not yet run): `POST /checks` turns the
  same verdict into 422 `version_invalid` → "Enter a version such as 1.13.0." and runs nothing; an empty
  field is refused too (the placeholder is not a value). The version is always typed by the admin — the
  preflight has no connection to the target. Ask whether the CLI should refuse like the page does.

## Alice's UX bar for this epic (from the LE-2916 round, 2026-10-07)
She grades the page as a non-developer admin: raw check text in "Details" (ValueError, "file rows",
"bytes storage does not hold") is a finding; counts must add up across groups; a free-text version
field should be a list of released versions; placeholders must not look like values; a CLI warn that
lets a bad input through with exit 0 should be an error. Expect the same lens on steps 2–8.

## Log of tickets validated (append)
- **LE-2914** (#15575, `bdd40dc229`) — 2026-10-07: CLI matrix all pass, unit file 46 passed. Findings doc `files/LE-2914-qa-findings.md`.
  F1 (invalid version only warns) fixed in `334f4ec240` → Round 2 all pass. F2 (non-existent versions accepted):
  Round 3 (2026-10-08, `1e2bc8c794`, own worktree `worktrees/LE-2914`, branch `qa-LE-2914`) = text only, still `ok`
  + "cannot confirm … check the number". Dev: "an install doesn't know later releases". Counterpoint: Langflow
  already fetches `https://pypi.org/pypi/langflow/json` (`utils/version.py:fetch_latest_version`, used by
  `langflow run`'s update notice; `store/utils.py:get_lf_version_from_pypi`), whose `releases` lists every
  version — but 1.13.0 itself isn't on PyPI yet (latest 1.12.5) and offline/EE installs can't reach it, so
  only a soft online check fits. No endpoint exposes available versions. An unconfirmed newer version also
  unlocks the default-superuser pass. #15574 (LE-2913) MERGED 2026-10-07 as `f83ecb5006`.
  APPROVED 2026-10-08 (Alice accepted the dev's answer on F2). Registered: QA request #1422, checklist run #736
  (37 items, left open). Cleanup done: worktree `worktrees/LE-2914` + branches `qa-LE-2914`, `pr-15575`,
  `pr-15575-qa` removed; `cli-clean/` deleted.
  The fix only touches the CLI path (`check_version_direction`); the page's API keeps `check_target_version`'s
  `warn` → 422 `version_invalid`. When the commit reaches #15576/#15577, re-test UI-03/04/05: the page must still say
  "Enter a version such as…", NOT "Older than this instance…".
- **LE-2913** (#15574, `6385ad66e3`) — 2026-10-07: 10 CLI checks pass, 87 unit passed. `files/LE-2913-qa-findings.md`.
- **LE-2915** (#15576, tested on #15577 head) — 2026-10-07: 16/17 API pass; finding 1 = flag ignored in `--env-file`, feedback 2 = `acceptable_findings` naming. `test_migration.py` 29 passed. `files/LE-2915-qa-findings.md`.
  Round 2 (2026-10-08, `996b5f1764`): F1 → LE-2991, F2 fixed (`acceptable_checks`); 21/21 API + 126 unit. APPROVED.
  Registered: QA request #1423 (`4ee46101-…`), checklist run #722 (31 items, left open). Cleanup done: `r2-le2915/`
  and `envfile-probe/` deleted; `nonadmin/`, `flagoff/`, `source/`, `cli-clean/` kept for LE-2916/LE-2914.
  #15577 moved to `e29c7b3f9e` and already reads `acceptable_checks` (page + types.ts) → LE-2916 re-test pending.
- **LE-2916** (#15577, `f0a5cf51c1`) — 2026-10-07: Jest 9/9 (Jira says 19), locales 108 keys × 8 complete. UI plan `files/plan-LE-2395-test1-ui.json` (runner :8923) with Alice. Instances: 7862 seeded main, 7866 flag-on/no-autologin (admin/qa-admin-2395, bob/qa-bob-2395), 7868 flag-off; data under `~/Langflow/Temp/le2395-qa/`.
- **LE-2949** (#15608, `17bcb03f40`) — 2026-10-09: pause step / banner / "If something goes wrong". Dedicated worktree `worktrees/LE-2949` (7842),
  source seeded with the PR's own `seed_instance.py` (DB + KBs under `~/Langflow/Temp/langflow-config-LE-2949/`), destination `lf-qa-pg`/`langflow_2949`
  + bucket `lf-qa-files-2949`, steps 1–3 done via API. 14 API + 10 UI all pass, Jest 46/46. `files/LE-2949-qa-findings.md`, no findings; one UX
  feedback (step 4 unchanged while a `pausing` is left behind) deferred to `backlog-findings-and-feedbacks/migration-page-feedbacks.md` F2.
  Registered: QA request #1444, checklist run #751 (24 items). Traps learned: `DELETE /accepted-findings` takes `?name=` (query, not body);
  `jobs_active` needs job rows `queued`/`in_progress` with `job_metadata.request.mode == "background"` for a cancel request (`suspended` is never
  listed, so the "Waiting for a person's answer" strings are unreachable); `requests_active` (a write > 5 s) renders as the generic
  "Something went wrong" — #15629 names it; the PR's Playwright spec needs its own backend on 7860/3000 and deletes the record, not run.
