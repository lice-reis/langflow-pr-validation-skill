# Findings document (what goes to the developer)

English, saved as `files/<TICKET>-qa-findings.md` inside the workspace (the desktop file panel
refuses any path outside the session cwd — never `~/Langflow/files/`, never a `../` link). Start it
on the **first** observation and append; Alice forwards the whole thing in one go.

**The voice: Alice ran a test, it failed, she is telling the dev.** Not an investigation. The dev
owns the code and will find the cause once he can reproduce it.

🛑 **Exactly two parts — the table, then the findings.** No Notes section, no environment or coverage
rundown, no assessment, no recommendation. Calibration detail, "verified green" prose and things
ruled out stay in chat.

## Part 1 — Tests performed

```markdown
## Tests performed

| ID | Test | Result |
|---|---|---|
| API-001 | <what was exercised, one short line> | Pass |
| UI-004 | Clean Data toggle on a single Table — see F2 | Fail |
```

- `ID` = the id the test already had (`API-001…`, `UI-001…`); never renumber.
- `Test` = one short line, what was exercised. A failed row may point at its finding (`— see F2`).
- `Result` = **Pass** / **Fail**; `Warning` / `N/A` / `Blocked` only when the UI runner reported it.
- Every item in `files/runs/<plan_id>/results.json` and every API test run appears exactly once.
  A planned test that did not run is not a row — say so in chat.
- Re-test rounds → one table per round, headed by the round.

## Part 2 — Findings

Flat list ordered by user impact, each opening with an H3 **`### F1 — Title`** (em dash; she pastes
the doc into Jira). Report everything found, whether or not this PR introduced it (*"eu não me
importo se o erro foi implementado por essa PR ou não, eu só quero reportar ele"*); attribution, if
it matters, is one clause inside the Description.

**Bug — four parts:**
```markdown
### F1 — Tooltip truncated when "Add User" is disabled

**Description** — The tooltip is truncated when "Add User" is disabled (SSO policy set to SSO-only).

**Expected Behavior** — The entire tooltip stays within the window and is readable.

**Steps to Reproduce**
1. Configure SSO-only and log in as admin (break-glass works).
2. Open the Users tab at full width and hover the disabled Add user button.
3. Observe the tooltip is truncated.
```
Length is the target above (Alice's rewrite, 2026-10-07): **Description = one sentence**, symptom +
condition; **Expected = one sentence**, no design suggestion; **Steps** = setup in a single step,
then navigate / act / observe. Optional: her screenshot as a rendered image + one italic caption
line, path relative to the doc's folder (`<TICKET>-assets/x.png`, `runs/<plan_id>/attachments/x.png`).

**UI feedback — three parts:** `### F<N> — Title`, **Short Description**, **Suggestion**.

**Findings Alice added herself** (the runner's "＋ Adicionar finding" → `results.json → extras[]`, or
sent in chat) are findings like any other: her text is the Description (English, kept to one
sentence), her attachment is embedded under it, Expected and Steps are written from what she
described. They are never discussed, re-verified or attributed in chat first — the doc comes first.

## Never include

Root cause, mechanism, call chain, file/line references, log excerpts, token or time counts,
severity, "Note on…" asides, secondary masked sites, recommendations, an assessment paragraph, the
same point in three registers. **If a sentence explains *why* rather than *what happened*, cut it.**

## Before something earns a number

**Who has to do something differently because of this, and what does it cost them if they don't?**
No answer → not a finding (a ~115 ms loading blink with a real mechanism is still not one). Steps I
tried and did not see are not steps to reproduce — "observed once, unreproduced" is a chat sentence.
A behaviour Alice saw in her own browser is already confirmed; write it in her wording and from the
screenshot she chose.
