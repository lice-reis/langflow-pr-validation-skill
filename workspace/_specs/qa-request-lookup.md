# Locating the QA request for a Jira ticket

Every Langflow Jira card has (or will have) a QA request on the platform (langflow.works). The
platform syncs from Jira on a **cron, not instantly** — a lookup can return null at minute T and the
record at T+30min. **NEVER tell Alice "no QA request exists"** until the full recipe below fails AND
you have asked her for the URL.

**A Jira card is not a task.** The board shows Jira cards as **phantoms** — previews built from the
`jira_board_cards` cache with no row behind them. A `qa_requests` row exists only after someone
clicks **"Open as task"**. So a null lookup has two meanings — sync lag, *or* nobody opened it yet
(no row exists, and sweeping will never find one). **Settle it in one call, before the sweep:**

```
jira_cards_task_state(issue_key: "LE-XXXX")   # -> no_card | phantom | open | soft_deleted
```
- `open` → `qa_requests_get(jira_id:)` will find it; proceed.
- `phantom` → the ticket has no task yet. **Tell Alice and ask** before
  `jira_cards_open_as_task(issue_key: "LE-XXXX")`, which materializes it (idempotent on the issue
  key). This is the sanctioned path — the "never create a QA request" rule is about inventing new
  requests, not about opening a card as its own task. Never open one silently.
- `soft_deleted` → it was opened once and deleted; `jira_cards_open_as_task` restores that row.
- `no_card` → the board sync hasn't cached the issue at all; fall through to the steps below.

Run in order, stop at the first hit:

1. `qa_requests_get(jira_id: "LE-XXXX")` — canonical lookup, uppercase key. Matches
   `jira_issue_key` **or** `jira_id`; rows opened from a card carry the key.
2. If null, retry once after a short delay (sync may be in flight).
3. `qa_requests_list(search: "<title keywords from the Jira card>")` — note: `search` does **not**
   match `jira_id`/`jira_link`, but it often hits the title.
4. Sweep `qa_requests_list(status: <each>)` with `limit=100` across all statuses; grep the title
   client-side.
5. Still nothing → ask Alice for the QA-platform URL `https://langflow.works/tasks/<uuid>`. The
   `<uuid>` is the request `id` → `qa_requests_get(id: "<uuid>")`.
6. Only after 1–5 fail, ask whether to create — **never create silently**. (Per `../CLAUDE.md`, in
   the normal flow never create a QA request at all — one already exists per Jira task.)

**URL → id:** `https://langflow.works/tasks/99697375-9bff-485f-930d-459585a8591b` →
`id = 99697375-9bff-485f-930d-459585a8591b`.

**Mistakes this prevents:** ran the full sweep for LE-2306 and told Alice "no QA request exists"
when the card was simply still a phantom awaiting "Open as task" — created a duplicate request for LE-1184; told Alice "no request for
LE-1214" when the `langflow.works/tasks/<uuid>` URL was visible in the UI all along.
