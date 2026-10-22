# langflow-pr-validation (backup)

Backup of Alice's personal `langflow-pr-validation` Claude Code skill, retired on 2026-10-22 in favor of
the Orion catalog skills (`oriontech-me/orion-claudecode-skills`: qa-scenarios-from-story/jira,
qa-test-data, qa-regression-run, qa-verdict-check).

| Path | Was at |
|---|---|
| `skills/langflow-pr-validation/` | `~/Langflow/pr-validation/.claude/skills/langflow-pr-validation/` |
| `workspace/_specs/` | `~/Langflow/pr-validation/_specs/` (wt_up / ee_up / qa_cleanup + templates; still in use locally) |
| `workspace/CLAUDE.md` | `~/Langflow/pr-validation/CLAUDE.md` (folder rules at backup time) |

`config/provider-secrets.env` is **not** in this repo (real API keys). Only the key names are kept, in
`provider-secrets.env.example`.

## Restore

```bash
cp -r skills/langflow-pr-validation ~/Langflow/pr-validation/.claude/skills/
cp ~/Langflow/pr-validation/provider-secrets.env ~/Langflow/pr-validation/.claude/skills/langflow-pr-validation/config/
```
