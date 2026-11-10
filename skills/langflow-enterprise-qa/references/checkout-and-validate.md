# EE PR checkout + validation runbook

One command brings an EE PR up the way the QA sessions actually run it — never `wt_up` /
`make run_clic` (those are OSS-only; EE has no frontend toolchain and runs over the OSS pin):

```bash
source ~/Langflow/pr-validation/_specs/ee-worktree.sh
ee_up LE-XXXX <pr>          # Bash timeout 600000. Warm ≈ 3-5 min, cold ≈ 8 min; ~17 min when another
                            # session is building at the same time -> just run `ee_wait LE-XXXX` again
```

**EE pool (since 2026-10-16).** Five permanent, warm worktrees `ee-worktrees/ee1`…`ee5` on fixed ports
7820/7822/7824/7826/7828, claimed like the OSS slots (claims in `ee-worktrees/.claims`, keeper,
LIVE/STALE/EXPIRED). A slot keeps its `.venv` and `.frontend-dev` mirror across tickets; its app state
(`.langflow-dev` DB/config/knowledge bases, `qa-run.env`, logs) is scrubbed when a new ticket takes it
and at sign-off. Worktrees made before the pool (`ee-worktrees/<ticket>`, e.g. LE-2921) still work the
old way on 7866–7898 until their sign-off removes them.

| Function | Does |
|---|---|
| `ee_up [--port N] [--merge-main] [--sso] [--fresh] [--ref <ref>] [--take <slot> \| --dedicated] [--over-cap] <ticket> <pr>` | claim an EE slot (same ticket + same session → re-used, DB kept) → fetch `pull/N/head` → branch `qa-<ticket>` → `qa-run.env` → instance-cap check → detached, **queued on the machine-wide build lock**: `uv sync --extra dev` → frontend mirror (moved to the PR's `oss-version` if it differs; else APFS clone of a same-pin sibling; else cold `dev-frontend.sh`) → `npm run build` → lock released → `run-with-oss.sh langflow run --frontend-path …/build` → `ee_wait`. **Exit 3** pool full · **exit 4** instance cap |
| `ee_wait <ticket>` | polls `/api/v1/version`, fails fast on a `FAILED` marker, clears the first-login password gate, proves a Credential write (201), prints READY. Time queued for the build lock does not count |
| `ee_env <ticket>` | later shells: exports `WT PORT EE_URL EE_PW` (resolves the ticket's slot, re-arms its keeper) |
| `ee_restart <ticket>` | backend relaunch without rebuild (backend-only push, env change, resuming a pause) |
| `ee_down <ticket>` | **pause**: stops the instance; slot claim, worktree and DB stay |
| `ee_free [--force] [slot]` | stop + scrub + reset to a detached `origin/main` (+ delete `qa-<ticket>` and the `pr-N` ref) + release; `--force` only for the slot Alice picked |
| `ee_warm <slot>` | build a missing/cold slot (worktree + uv sync + mirror + vite build), under the build lock; run in background |
| `ee_pool` | one `key=value` line per EE slot — input of the pool-full question |
| `ee_status` | EE pool + every EE worktree: head, pin, port, running/stopped |
| `qa_instances` / `qa_pause <port>` | (shared with OSS) QA servers running now and their owner / pause the one Alice picked |

`--merge-main` merges `origin/main` into the PR head (when the PR branch predates a pin fix);
`--sso` adds the SSO vars (`SSO_ENABLED`, `ALLOW_UNLICENSED_SSO`, `SSO_CONNECTION_LIMIT=unlimited`);
`--fresh` wipes the DB in `.langflow-dev`; `--ref origin/release-1.13.0 LE-XXXX tip` tests a branch tip.

**Login:** `admin` / `Qa-<ticket>-admin`. (`qa-run.env` carries the bootstrap password `Boot-<ticket>`,
used once to clear `must_change_password`.) Put it in the UI plan's `Login` list.

## What `qa-run.env` sets (and why)

| Var | Why |
|---|---|
| `LANGFLOW_CONFIG_DIR=<wt>/.langflow-dev` + `SAVE_DB_IN_CONFIG_DIR=true` | per-worktree DB + `lfx.toml` copied in, so the `[services]` override registers real Casbin |
| `LANGFLOW_SECRET_KEY` (minted once, kept) | credentials survive restarts and re-tests |
| `AUTO_LOGIN=false`, `SUPERUSER=admin`, `NEW_USER_IS_ACTIVE=true` | real auth; new users usable at once |
| `AUTHZ_ENABLED=true`, `AUTHZ_SUPERUSER_BYPASS=true` | RBAC on; set bypass `false` + `ee_restart` to test denial as a superuser |
| `ENTERPRISE_ALLOW_UNLICENSED_TIER_GATES=true` | without it projects/users/roles 503 "license validation is unavailable" |
| `PUBLIC_URL` / `FRONTEND_BASE_URL = http://localhost:<port>` | single origin, SSO redirects land on the UI |
| `ACCESS_SECURE` / `REFRESH_SECURE=false` | cookies on plain http |

## Scope-specific checks (after `ee_up`)

- **Pin bump** (`ee_up` prints the PR's `oss-version` next to main's): `scripts/check-oss-compat.sh <sha>`
  (exit 0 = seams present + overrides type-check + vite build) and `scripts/run-with-oss.sh pytest -q`.
- **Backend feature**: the PR's own test files via `scripts/run-with-oss.sh pytest <files>`; API probes
  against `$EE_URL` with a Bearer from `POST /api/v1/login` (form body).
- **Frontend override**: jest on the PR commit **and** its parent (the suite has pre-existing failures —
  `ee-gotchas.md` → "Frontend and tests"); grep the served bundle for each changed override.
- **Flag-gated UI**: flags are build-time (`ee-gotchas.md` → "Feature flags are build-time").
- **Personas**: seed via API and log each one in once before handing over the plan (`ee-gotchas.md` →
  "Seed API shapes"); one `*.localhost:<port>` hostname per persona.

## Bugfix repro on the parent (fail-before)

A bugfix whose Jira has Steps to Reproduce is reproduced **exactly**, on the parent and then on the
PR, with every deviation declared (`langflow-pr-validation` → Scope). Both runs use **the ticket's one
slot, in sequence**: the parent comes up first, the *before* runs, then the PR comes up on the same
slot — all before Alice's hand-over (`langflow-pr-validation` → § 2 "Bugfix"). The EE mirror's
single-branch refspec only knows `main` and the PR heads already fetched, so fetch the base branch and
the PR head before looking for the parent:

```bash
source ~/Langflow/pr-validation/_specs/ee-worktree.sh && _ee_path      # GH_HOST=github.ibm.com
M=$EE_MIRROR; R=WatsonOrchestrate/IBM-Langflow
B=$(gh pr view <pr> --repo $R --json baseRefName -q .baseRefName)
git -C "$M" fetch -q origin "$B:refs/remotes/origin/$B" "pull/<pr>/head:refs/remotes/origin/pr-<pr>" --force
P=$(git -C "$M" merge-base "origin/$B" "origin/pr-<pr>")                # open PR
# merged PR: P=$(git -C "$M" rev-parse "$(gh pr view <pr> --repo $R --json mergeCommit -q .mergeCommit.oid)^1")
git -C "$M" show "$P:oss-version" | cut -c1-8                           # the OSS pin the "before" runs
ee_up --ref "$P" [her flags, never --merge-main] LE-XXXX parent         # Bash timeout 600000
# … the before run on this instance …
ee_up --fresh [her flags] LE-XXXX <pr>                                   # same slot: PR head, new DB
```

- The parent carries its own `oss-version`: `ee_up` moves the slot's frontend mirror to it when it
  differs (APFS clone from a same-pin sibling, else ~3 min cold), and back to the PR's pin on the
  second `ee_up`. The "before" is the EE code **and** the OSS pin the bug was reported on — a fix that
  arrives through a pin bump is reproduced too. Record both pins in the `REPRO` result.
- Same setup on both builds: the same `--sso`; lines appended to `qa-run.env` survive the second
  `ee_up` (the file is kept); what lives in the DB — licence, SSO config, personas — is configured
  again after `--fresh`. Login `admin` / `Qa-LE-XXXX-admin` on both.
- Never `--merge-main` on the parent (`origin/main` may already hold the fix). The parent does not
  build or start → stop and report; a file swap on the PR build never stands in for the parent
  (`ee_restart` neither rebuilds the overrides bundle nor re-pins OSS).

## Lifecycle

Re-test after a push: `ee_up LE-XXXX <pr>` again (same slot, new head, DB kept). Backend-only
push: `ee_restart`. Done for the session: `ee_down` (pause). On Alice's sign-off, `qa_cleanup <ticket>`
(in `pr-validation/_specs/worktree-claim.sh`) **frees the pool slot** (`ee_free`: scrubbed, released,
deps kept) — or removes a per-ticket worktree with its branch — and every ticket artifact (plan, runs,
findings). Pool ports are claim-protected; per-ticket ports are not: `ee_status` / `qa_instances`
before killing anything, and never touch a port whose process names another worktree.

Mirror: `~/Langflow/Local-instances/main/Langflow-Enterprise` (remote `WatsonOrchestrate/IBM-Langflow`,
single-branch refspec — `ee_up` fetches `main` and the PR head explicitly). Report always states the
active OSS pin and DB backend.
