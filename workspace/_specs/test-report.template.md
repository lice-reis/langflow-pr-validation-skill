# Chat report (to Alice, inline — not what the dev receives)

Five lines (six when the Jira repro was not exact), observed / expected in a few words. Defects are described in the findings doc, not here.

```markdown
**LE-XXXX / PR #N** — `<headRefName>` @ `<short sha>` · slot `active2` · http://localhost:7864
API: x/y pass · UI: x/y pass (or: plan handed over, N items) · Jira repro: before ✓/✗ · after ✓/✗ · exact / not exact
<only when not exact: "Não reproduzi exatamente os passos do bug: <motivo 1>, <motivo 2>.">
Jira claims: <claim 1> ✓ · <claim 2> ✗ (see F1) · …
Findings: N → [findings](files/LE-XXXX-qa-findings.md)
Checklist: run #<id> registered and completed
```

Rules: tie results to the Jira `description`, not only to the diff; say which planned test was
skipped and why; no severity. Checklist items: one `checklist_result_record` per test, graded by
impact on the deliverable (an internal slip is `pass`/`na` with a note), and **self-sufficient**:
the note holds the observed result or the full finding text — never a file path, plan URL, port or
pointer to the findings doc (the chat link above is fine; the checklist must survive the cleanup).
