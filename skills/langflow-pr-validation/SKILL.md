---
name: langflow-pr-validation
description: >
  Langflow PR validation orchestrator driven by a Jira ticket. Given a Jira link/ID (or a PR
  number) it reads the ticket via the qa-platform MCP, finds the linked PR, analyzes the diff,
  brings the PR up in a claimed worktree slot with one command (wt_up), runs the API checks,
  hands Alice an interactive UI test plan, writes the findings doc for the dev and registers the
  checklist run on the QA request. Use it whenever the user wants to validate/QA a Langflow PR or
  Jira ticket, test a Langflow branch, or build a test plan for Langflow changes. Also triggers
  on: "valida esse ticket", "valida essa PR", "testar PR", "test PR", "QA dessa PR", "plano de
  teste", "link do jira", "LE-XXXX", "langflow.works/tasks", and any Langflow + PR / Jira +
  test/QA combination. Delegates to langflow-enterprise-qa (EE tickets) and langflow-instance-migration-qa
  (LE-2395) when the PR matches.
---

# Langflow PR Validation

PT-BR with Alice; English in every artifact (findings doc, checklist, bug text). Rules that apply
to every session in this folder are in `../../../CLAUDE.md` — they are not repeated here.

```
SKILL_DIR=~/Langflow/pr-validation/.claude/skills/langflow-pr-validation
SPECS=~/Langflow/pr-validation/_specs            # worktree-claim.sh, templates, lookup recipe
export PATH="/opt/homebrew/bin:$HOME/bin:$PATH"  # before gh / make / npm / uv
```

## Scope — what a validation is (Alice, 2026-10-08)

Test what the Jira description and the PR promise. Nothing else unless she asks.

- Jira has "Steps to Reproduce" → run them **literally first**, with the ticket's own values.
  Variants and edge cases come after, never instead.
- Bugfix PR → **one** fail-before check: show the bug on the parent commit, then the fix
  (recipe in § 2). Feature PR → no fail-before.
- Run the PR's **own** test files once. Not the whole suite, not a baseline on `main`.
- Do **not**: check CI, hunt for reverts, grep other branches, root-cause a failure, measure
  things the ticket does not claim, run provider smoke tests. Something outside scope looks
  broken → one line in chat; Alice decides.
- Models: **mini tier only** (`gpt-*-mini`, `gemini-*-flash`, Haiku). Starter projects and the
  Assistant selector default to a flagship — re-point the model before the first run.
- **Fixed problems are not news.** A trap you hit and solved (a stripped driver, a port clash, a
  rebuild) is never narrated to Alice — not in the hand-over, not as a "ressalva". She hears about
  something only when it still blocks her or changes what she must do.
- **Questions are the exception.** The flow runs end to end on its own. It stops only for a command
  error, an input nobody else can supply (Jira description null, no PR anywhere) or a decision that is
  genuinely hers (which slot to free when the pool is full, an asset that cannot be provided). Never "posso
  prosseguir?", "quer que eu escreva?", "como você quer seguir?". When she says she sent the plan
  ("enviei", "testes enviados"), § 5 and § 6 run to the end without a single question.
- When something looks wrong and you don't know why: `grep -i <keyword> ${SKILL_DIR}/references/gotchas.md`
  (EE: `~/Langflow/.claude/skills/langflow-enterprise-qa/references/ee-gotchas.md`). Do not read
  those files top to bottom.

## 0 · Ticket → PR

1. `mcp__langflow-qa-platform__jira_cards_get(issue_key: "LE-XXXX")` → `summary`, `description`
   (**the spec**), `labels`, `pr_url`, `enterprise_pr_url`, `status`.
   `description: null` → ask Alice to paste it; never plan from the diff alone.
   Then rename the session to her pattern (load the deferred tool first with ToolSearch
   `select:mcp__ccd_session_mgmt__set_session_title`):
   `mcp__ccd_session_mgmt__set_session_title(session_id: "self", title: "Jira issue LE-XXXX")`.
2. PR = `pr_url` (OSS, `langflow-ai/langflow`) or `enterprise_pr_url` (EE → load
   `langflow-enterprise-qa`; the environment is `ee_up`, § 2 does not apply). Neither → ask Alice.
   If the diff does not touch what the ticket describes, ask her for the Jira **Web links** panel
   (a ticket can carry a second PR the MCP does not return) before reporting anything missing.
3. Alice sent a PR number instead → find the key in title/body/branch → step 1.
4. `labels` contains `release-v1.13.0` → lean UI plan (§ 4).

## 1 · Read the PR, decide the tests

```bash
gh pr view N --repo langflow-ai/langflow --json title,body,state,headRefName,headRefOid,baseRefName,files
gh pr diff N --repo langflow-ai/langflow
```
Route first: EE repo (`enterprise_pr_url`) → `langflow-enterprise-qa` — its environment is **`ee_up`**,
never `wt_up`/`make run_clic`; parent LE-2395, `migration_preflight`, `/api/v1/migration` →
`langflow-instance-migration-qa`.

Merged PR: validate the **squash-merge commit** on the base branch, not a dev-cited SHA
(`gh api repos/langflow-ai/langflow/compare/<parent>...<merge>`).

Tell Alice, in ≤ 8 lines: what the PR changes (as she can observe it), the customer scenario from
Jira, the assets the tests need (§ 4 — you provide them), `HAS_API` / `HAS_UI` (UI = any frontend file, any component field/default/output change, any
endpoint the UI calls — in doubt, yes), and the test list with ids (`API-001…`, `UI-001…`). Then go
straight to § 2 — do not wait for an answer.

## 2 · Environment — one command (OSS PRs)

**EE PR → not this section.** `source ~/Langflow/pr-validation/_specs/ee-worktree.sh && ee_up LE-XXXX <pr>`
(runbook in `langflow-enterprise-qa`): EE has no `make run_clic`; it runs `run-with-oss.sh` over the OSS pin.
Same pool model (`ee1`…`ee5`), same exit codes (3 = pool full, 4 = instance cap) and the same questions.

```bash
source ~/Langflow/pr-validation/_specs/worktree-claim.sh && wt_up LE-XXXX <pr>   # Bash timeout 600000
```
`wt_up` claims a free slot of the **pool** (`active` 7862, `active2` 7864, `active3` 7830, `active4`
7832, `active5` 7834 — permanent, deps already installed), fetches `pull/N/head`, `checkout -B pr-N-qa`,
scrubs the slot state, writes `.env` (`wt_env`: per-slot config dir + knowledge-bases dir), runs
`make run_clic port=$PORT`, waits for `/api/v1/version` and proves a Credential write returns 201. It
prints slot, URL, HEAD and the log paths. Branch tip instead of a PR: `wt_up --ref origin/release-1.13.0 LE-XXXX tip`.

- **Pool full → `wt_up` exits 3** and prints `wt_pool` (one line per slot). Stop and ask Alice with
  `AskUserQuestion`: one option per slot — ticket, the session's title and state (look up each
  `host_session` with `mcp__ccd_session_mgmt__get_session`: archived / not found / running / idle
  since), `instance`, `runner`, `results` (whether she already submitted the plan) — plus a last option
  "Worktree dedicado (do zero, ~10–15 min)". Archived/not-found sessions first. Freeing a slot wipes
  that ticket's test flows and DB: say so in the option when its ticket is still in QA. Then
  `wt_up --take <slot> LE-XXXX <pr>` (frees it — `wt_free --force` — and claims it for you) or
  `wt_up --dedicated LE-XXXX <pr>`. Never evict, build a dedicated worktree or wait on your own.
- **Instance cap → `wt_up` exits 4** (4 QA Langflow servers already running, OSS + EE + RC). Ask Alice
  with `AskUserQuestion`: one option per instance from `qa_instances` (port, ticket, session title/state
  via `get_session`; idle/archived first) plus "subir mesmo assim". Then `qa_pause <port>` and re-run
  `wt_up` (your slot stays claimed), or `wt_up --over-cap …` if she chose that.
- **Builds queue machine-wide** (one at a time, OSS and EE). `[queue] waiting for the build lock` in
  `.run.<slot>.log` is normal; `wt_wait` does not count queued time against its timeout.
- Probe fails or build dies → stop and report; don't self-fix.
- Timed out while still building (first run on a slot is cold) → `wt_wait`.
- Every later Bash call is a new shell: start it with
  `source ~/Langflow/pr-validation/_specs/worktree-claim.sh && wt_mine || exit 1`.
- **Ports are never picked by hand.** `wt_up`/`ee_up` allocate them (`lsof` + the claim/`.own`/`.qa-port`
  registries) and `wt_mine`/`ee_env` give them back; talk only to `$PORT`. Never hand-roll a worktree or
  a `langflow run` on a port you chose — if the helper fails, stop and report. Before any unavoidable
  manual launch, and whenever a reply looks like it came from someone else's server (a 409 on a fresh
  DB, data you never created), run `qa_ports` to see who owns what.
- Extra env var → `echo 'LANGFLOW_X=1' >> "$WT/.env"` then `wt_restart` (relaunch without rebuilding,
  ~1 min). Never write `.env` with `>`. Scratch files go in the scratchpad, never in the worktree.
- Needs a Postgres/pgvector driver or another uv extra → `wt_up --extras "postgresql pgvector" LE-XXXX <pr>`
  (`make run_clic` strips extras; the flag re-adds them and relaunches via `.venv/bin/langflow`, where
  they survive). Never `uv pip install` by hand and never tell Alice about it.
- **Fail-before (bugfix PRs):** after the build is up, `git -C "$WT" checkout <parent> -- <files>`
  → `wt_restart` (backend) or run the PR's test file (frontend/unit) → observe the bug →
  `git -C "$WT" checkout HEAD -- <files>` → `wt_restart`. Never swap files while a build runs.
  Saved flows embed component code — create the flow on the build you are testing.
- Hand-over to Alice: slot + `http://localhost:$PORT`. Details: `_specs/worktree-checkout.md`.

## 3 · API checks (inline, no subagent)

```bash
B=http://localhost:$PORT
TOKEN=$(curl -s $B/api/v1/auto_login | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')   # GET, not POST
KEY=$(curl -s -X POST $B/api/v1/api_key/ -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"name":"qa"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["api_key"])')
# Bearer for everything; /api/v1/run needs  -H "x-api-key: $KEY"  even with AUTO_LOGIN.
```
One result per test id. Flows/data you created stay **in the instance** (Alice inspects them there);
scripts, fixtures, flow JSONs, API dumps and logs stay in the **scratchpad** — never in `files/`.
`files/` receives exactly four things per ticket: the plan JSON, `runs/`, the findings doc, `<ticket>-assets/`.

## 4 · UI plan — interactive runner

Write `files/plan-<JIRA>-ui.json` from `${SKILL_DIR}/assets/ui-plan-template.json`, in PT-BR, terse:
`environment` = `UI` + `Login` (list form, one object per credential) + one row per provisioned asset
she must use (URL, user, password, "already configured"); `pr_summary` = 3–4 bullets of
what she can see on screen; `notes` ≤ 5 one-liners, only what prevents a false bug report (expected
failures, the mini model to pick, traps); items: `actions` = the clicks, `expected` = the observable
result with the exact strings. `release-v1.13.0` → **8–10 main items** (one per Jira behaviour, the
riskiest diff paths, one per persona); other tickets: full list, still terse. Everything you can run
yourself (jest, API, bundle grep) stays full — the cut is only on what she clicks.
**One behaviour per item** (Alice, 2026-10-16): never bundle unrelated checks in one item (ingestion
and retrieval, create and delete, sidebar and dropdown, "a) b) c)" sub-steps). The same check on
different flows or paths is one item each, so each gets its own pass/fail.

**Every item must be executable as written.** If a click needs infrastructure, data, credentials or
state (an OpenSearch cluster, the MCP testbed, a mock IdP, a Postgres DB, provider keys, a flow, a
fixture file, seeded users), **provision it, configure it in the instance, verify it with one API
call, and write URL / user / password in `environment`** before the plan goes out. "Connect
OpenSearch" is never an item; "select the OpenSearch provider — already configured" is. Cannot be
provided → the item is `blocked` with the reason. Recipes per asset: `${SKILL_DIR}/references/test-assets.md`.
Every container, volume or network you create is named **`qa-<ticket>-<svc>`** — that name is what
`qa_cleanup` removes at sign-off (pre-authorized; the general "no `podman rm`" rule is about
everything else). Reuse the standing fixtures (`lf-qa-opensearch`, `testbed-http`) instead of
creating your own when they fit.

```bash
( nohup python3 ${SKILL_DIR}/assets/ui-plan-runner.py --plan files/plan-<JIRA>-ui.json \
    > files/.runner.log 2>&1 < /dev/null & ); sleep 1; grep Abra files/.runner.log
```
No `--port`: the runner derives a stable one per `plan_id`. **Hand-over message — this shape and
nothing else:**
```
Plano: http://localhost:8922 — 7 itens. Login: langflow (sem senha).
<one line she must know, only if there is one — e.g. "Não reinicie o Langflow: a senha do destino só vive na memória.">
```
No list of the items (they are on the page), no API recap (it is in the findings doc), no
environment story or "ressalva" (what broke and how you fixed it is yours, not hers), no recap of
what you verified. Everything else she needs is in the plan's `environment` / `notes`. Then the plan is **frozen** — no edits, no relaunch (her marks live in
browser localStorage) — unless she asks: keep `plan_id` and item ids, append only, tell her to refresh.
Results: `files/runs/<plan_id>/results.json` + `attachments/` — kept until her sign-off (`qa_cleanup`). The page also has
**"＋ Adicionar finding"** (always available): what she saw outside the plan arrives as
`results.json → extras[]` (`id`, `text`, `attachments`). Each one becomes an `F<N>` in the findings
doc, in her wording, with her attachments embedded — they are not rows of the tests table.

## 5 · Results → findings doc → chat report (no questions in between)

**Trigger:** `files/runs/<plan_id>/results.json` exists (she submitted), or she says "enviei" /
"testes enviados", or she sends findings in chat. Then, in this order, without asking anything:

1. Read `results.json`, its `extras[]` and `attachments/`; `Read` each image so the caption is right.
2. Write `files/<JIRA>-qa-findings.md` — **English, always**, format in
   `${SPECS}/findings-doc.template.md`: the `ID | Test | Result` table of every test that ran (API +
   every plan item), then `### F1 — Title` findings ordered by user impact, each with **Description**
   (one sentence), **Expected Behavior** (one sentence), **Steps to Reproduce** (numbered); UI feedback =
   **Short Description** + **Suggestion**. Every non-pass item and every `extras[]` entry is a finding:
   her text becomes the Description (translated, kept short), her screenshot is embedded under it
   (`cp` from `attachments/` or from the `[Image: source: …]` path into `files/<JIRA>-assets/`, path
   relative to the doc, `test -f` each).
3. Post the chat report — **5 lines**, `${SPECS}/test-report.template.md`, linking
   `[findings](files/<JIRA>-qa-findings.md)` — then go straight to § 6: one line saying the checklist
   is being registered, not a request for permission.

What this phase is **not**: no analysis of her findings in chat, no "quer que eu escreva?", no
attribution hunt (`git log -S`, blame, "this text came from commit X") — the doc reports everything
found whether or not this PR introduced it, and a *why* never goes in it. A finding of hers that
lacks a step you need: write the doc with what you have, then ask that one question. What she saw
in her browser is confirmed evidence — never re-verified before it goes in.

During the run, start the doc at the first observation (an API failure counts) and append.
"fica para depois" → `backlog-findings-and-feedbacks/<area>.md`, same format.

## 6 · QA platform

Locate the request per `${SPECS}/qa-request-lookup.md` (`jira_cards_task_state` first; `phantom` →
ask Alice → `jira_cards_open_as_task`). Never `qa_requests_create`, never move status. Say in one
line that you are registering the run, then register it — the only question allowed here is the
phantom-card one.
**The checklist is the source of truth and must stand on its own.** Everything a reader needs is
inside the run. Never a local path, a file name, a `runs/` dir, a plan URL, a port, a worktree or
"see F2 in the findings doc" — all of that is gone after `qa_cleanup`; the platform is what remains.

**Run Information is filled completely** — every field, from these sources:
```
checklist_runs_start(template_id: "custom", qa_request_id: <from the lookup>,
  tester_name: "Alice",
  langflow_version: "<version> (<base branch> + PR <n> @ <short sha>)",
      # /api/v1/version + git: "1.13.0 (release-1.13.0 + PR 15566 @ e11cbd0)"
      # EE: "1.13.0 (IBM-Langflow PR #502 @ 7329b6c2, OSS pin 294dbe94)"
  operating_system: "macOS Apple Silicon",
  python_version: "<`$WT/.venv/bin/python --version`, e.g. 3.14>",
  database_type: "SQLite" | "PostgreSQL",
  distribution: "python-package",            # source worktree; "Langflow Docker" when an image was tested
  general_notes: "<the environment in prose — see below>")
```
`general_notes` (English, 4–6 lines, self-contained):
```
Jira LE-XXXX — <summary>. PR <url> @ <sha> on <base branch>[; EE PR <url>, OSS pin <sha>].
Instance: <wt_up slot / dedicated worktree / ee_up>, <DB>, <env that matters: AUTHZ on, flag X on, Postgres at …>.
Assets: <OpenSearch no-auth / mock IdP / testbed http / seeded users …>.
Scope: <what was tested>. Out of scope: <what was deliberately not tested, and why>.
Round N (re-test of run #M): <what changed since>.          # only on a re-test
```
`evidence_folder_link` stays empty (no local folder survives the cleanup) unless there is a durable
URL. Never a path, a port or a plan URL anywhere in the run.

**Close the run.** After the last `checklist_result_record`:
`checklist_run_set_status(run_id, action: "complete")`, then `checklist_run_get(run_id)` and confirm
`is_completed: true` with no item left `pending` (completing turns pending items into N/A, so every
item is recorded first). A run left open is an unfinished validation — never hand the ticket back
to Alice with the run open. A re-test gets a **new** run ("Round N" in `general_notes`), also closed
at the end.
checklist_result_record(run_id, item_id: "API-001" | "UI-003" | "EXTRA-1", item_description: <what was
  exercised, one line, EN>, item_category, status: pass|fail|warning|na, notes: <see below>,
  ticket_links: [<durable URLs only: Jira issue, GitHub/GHE PR, a ticket opened for the finding>])
```
`notes` per status — pasted, never referenced:
- `pass` → the observed result in one sentence (the value, text or count actually seen).
- `fail` / `warning` → the finding **in full**: Description, Expected Behavior, Steps to Reproduce —
  the same English text as the findings doc. A screenshot is described by what it shows.
- `na` / blocked → why, in one sentence.
Findings she added via "Adicionar finding" are items of their own (`EXTRA-1`, category "Finding
outside the plan"). Same ids as the plan and the doc. Grade by impact on the deliverable: an internal
slip is `pass`/`na` with a note, not a `fail`.

## Lifecycle

- Dev pushed a fix → `wt_up LE-XXXX <pr>` again (same ticket re-uses your slot, DB re-zeroed).
- Session done, ticket still in QA → `wt_down` / `ee_down` = **pause**: stops the slot's servers,
  keeps the claim, DB and checkout for the re-test (`wt_restart` / `ee_restart` resumes). It does not
  release: a released slot must be a clean one. Pausing also frees room under the 4-instance cap.
- **Alice's sign-off** (she commented the PR and the checklist is registered, or she says "pode
  limpar") → `qa_cleanup LE-XXXX`: **everything of the ticket goes** — plan JSON, runner,
  `files/runs/<plan>/`, `qa-<ticket>-*` containers, and the instance: a **pool
  slot is scrubbed and released, never removed** (`wt_free`: every server in it, DB, `.env` back to
  baseline with a fresh key, config dir + knowledge bases, logs, tree reset to a detached
  `origin/main`, the ticket's branches); a dedicated or EE worktree is removed with its branch.
  Nothing of a closed ticket is kept: the record is her PR comment and the platform checklist.
- **The findings doc goes too** (Alice, 2026-10-16): `qa_cleanup` removes `files/<JIRA>-qa-findings.md`
  and `<JIRA>-assets/` with the rest — by sign-off she has already registered everything. Never
  restore it, never keep it, never tell her it is being kept.
- **When Alice says "cleanup", "pode limpar", "limpa" — that *is* the sign-off.** Run `qa_cleanup`
  at once for the ticket in context: no list, no confirmation, no "are you sure". "Cleanup geral" /
  "limpa tudo" → every ticket whose Jira card is Done or whose QA request is `completed` /
  `release_approved` (`qa_requests_list` by status + `jira_cards_get`), one `qa_cleanup` each, then one
  line with what went. Only open tickets and the standing fixtures survive. Never part of it: `lf-qa-*`/`testbed-*`/nightly
  containers and `backlog-findings-and-feedbacks/`.
- Provider smoke test only on explicit request: `${SKILL_DIR}/references/provider-smoke.md`.
