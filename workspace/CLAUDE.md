# Langflow PR Validation — Rules

Alice's workspace for validating Langflow PRs from Jira tickets (Orion runs QA for Langflow).
Entry point: the **`langflow-pr-validation`** skill (`.claude/skills/`), which owns the procedure.
The rules below apply to every session in this folder, skill or not. They override defaults.

- 🌿 **Worktree pool, never the mirror.** OSS PR branches run in a pool of **five permanent, warm
  worktrees** — `worktrees/active` (7862), `active2` (7864), `active3` (7830), `active4` (7832),
  `active5` (7834) — claimed through `_specs/worktree-claim.sh` (`wt_up`). They are **never removed**:
  at sign-off `qa_cleanup` scrubs the slot (DB, `.env`, config dir, knowledge bases, logs, git tree,
  servers) and releases it, so the next session finds it clean with its deps in place. The mirror
  `~/Langflow/Local-instances/main/langflow` stays on `main`. Never touch a slot you did not claim;
  never kill a port that is not yours. **All five busy → `wt_up` exits 3 and you ask Alice** which
  slot to free (one option per slot: ticket, session title/state, instance, runner, results — from
  `wt_pool` + `get_session`) plus "dedicated worktree"; then `wt_up --take <slot>` or
  `wt_up --dedicated`. Never evict, build a dedicated worktree or wait on your own. **EE has the same
  pool**: `ee-worktrees/ee1`…`ee5` (7820–7828) through `ee_up` / `ee_free` (`_specs/ee-worktree.sh`).
  Ports come only from the helpers (`wt_up`/`ee_up`, `qa_ports` to inspect) — never hand-rolled.
- 🖥️ **The machine is small** (M1, 8 cores, 16 GB). Builds queue machine-wide, one at a time
  (`[queue] waiting` in a log is normal). At most **4 QA Langflow servers** run at once (OSS + EE + RC;
  the nightly does not count): over it `wt_up`/`ee_up` exit 4 and you ask Alice which instance to pause
  (`qa_instances`, then `qa_pause <port>`; idle/archived sessions first) or `--over-cap` with her OK.
  When your session's work is done but the ticket is still open, pause your instance (`wt_down`/`ee_down`).
- 🧾 **Jira description is the spec.** Diff = what changed; Jira = what must work. Test only what
  both promise; literal "Steps to Reproduce" first. Out-of-scope observations are one chat line.
- 🧰 **Proactive assets.** A test item she receives must be executable as written: whatever it needs
  (OpenSearch cluster, MCP testbed, mock IdP, Postgres, provider keys, flows, fixtures, seeded users)
  is provisioned, configured in the instance, verified and written into the plan's `environment`
  before hand-over. Never "configure X yourself"; if it cannot be provided, the item is `blocked`.
- 🟢 **QA platform, bounded:** register checklist runs/results on the request linked to the ticket.
  Never `qa_requests_create`, never move its status (synced from Jira). A null lookup is often a
  phantom card: `jira_cards_task_state` → ask Alice → `jira_cards_open_as_task`
  (`_specs/qa-request-lookup.md`). Tell her before a checklist run. **The checklist is the
  source of truth and self-sufficient**: notes carry the full finding text and observed results,
  never a local path, plan URL, port or "see the findings doc" — those vanish at cleanup. Every
  run is **closed** (`checklist_run_set_status … complete`) right after its last item; none stays open.
- 🖥️ **GitHub reads only** (`gh pr view/diff`). No comments, approvals or pushes on any PR/issue.
  The Desktop build trigger (`gh workflow run`) only when Alice asks.
- 🌐 **Language:** PT-BR with Alice; English in artifacts (findings doc, checklist notes, bug text).
- 🧪 **Models: mini tier only**, every provider, every run (Alice pays): `gpt-*-mini`,
  `gemini-*-flash`, Haiku. Never a flagship/pro/reasoning model; never `claude-opus-*` /
  `claude-fable-*`. Starter projects and the Assistant default to a flagship — re-point first.
- 📁 **`files/` holds deliverables only**: `plan-<ticket>-ui.json`, `runs/<plan>/` (her evidence),
  `<ticket>-qa-findings.md`, `<ticket>-assets/` (her screenshots). **Nothing else is saved** — test
  fixtures (`.txt`, `.pdf`, `.csv`), test flows (JSON), scripts, logs, API dumps live in the session
  scratchpad or inside the instance and die with the session. The file panel cannot open paths
  outside the cwd, so link as `[x](files/x.md)`; images relative to the doc's own folder. Findings Alice defers ("fica para
  depois") → `backlog-findings-and-feedbacks/<area>.md`, same findings format, assets alongside. Every finding
  there carries `**Type** — Bug report` (broken/wrong, incl. truncated text or tooltips, untranslated
  strings, layout overflow) or `**Type** — Feedback` (works, but a design change is suggested), under
  its `### F<N>` heading. Re-read the file before appending: other sessions write there too.
- 🛑 **While a ticket is in QA, never delete** its test flows/data, plan, `files/runs/` (her
  evidence) or findings; never restart or edit a UI plan she is executing. **After her sign-off
  the cleanup is total** — `qa_cleanup LE-XXXX` (`_specs/worktree-claim.sh`): plan, runs,
  `qa-<ticket>-*` containers; the pool slot is scrubbed and freed (never removed), a dedicated/EE
  worktree is removed. Nothing of a closed ticket is kept — the findings doc and its
  `<ticket>-assets/` go too (Alice, 2026-10-16: she registers everything before saying "pode limpar").
  **"cleanup" / "pode limpar" from Alice is the sign-off itself** — run it without asking;
  "cleanup geral" covers every closed ticket. `backlog-findings-and-feedbacks/` stays until she
  files its tickets.
- 🚦 **No permission questions.** The flow runs end to end: after Alice says she sent the plan
  ("enviei"), the findings doc, the chat report and the checklist registration happen without a
  single question (notify, don't ask). Ask only what nobody else can answer — the pool-full
  question (which slot to free) is one of those.
- 🛑 **Stop and report on command errors** — do not self-fix.
- Podman / shared nightly rules: `~/Langflow/CLAUDE.md`.
