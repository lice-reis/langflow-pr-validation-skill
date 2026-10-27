# langflow-pr-validation (backup)

_Also holds `langflow-instance-migration-qa` (retired 2026-10-26) and `langflow-enterprise-qa` (retired 2026-10-27)._

Backup of Alice's personal `langflow-pr-validation` Claude Code skill, retired on 2026-10-22 in favor of
the Orion catalog skills (`oriontech-me/orion-claudecode-skills`: qa-scenarios-from-story/jira,
qa-test-data, qa-regression-run, qa-verdict-check).

| Path | Was at |
|---|---|
| `skills/langflow-pr-validation/` | `~/Langflow/pr-validation/.claude/skills/langflow-pr-validation/` |
| `skills/langflow-instance-migration-qa/` | `~/Langflow/pr-validation/.claude/skills/langflow-instance-migration-qa/` (LE-2395 epic specialist, retired 2026-10-26) |
| `skills/langflow-enterprise-qa/` | `~/Langflow/.claude/skills/langflow-enterprise-qa/` (Langflow Enterprise env/pin/overlay + `ee_up` runbook, retired 2026-10-27) |
| `workspace/_specs/` | `~/Langflow/pr-validation/_specs/` (wt_up / ee_up / qa_cleanup + templates; still in use locally) |
| `workspace/CLAUDE.md` | `~/Langflow/pr-validation/CLAUDE.md` (folder rules at backup time) |

`config/provider-secrets.env` is **not** in this repo (real API keys). Only the key names are kept, in
`provider-secrets.env.example`.

## Restore

```bash
cp -r skills/langflow-pr-validation ~/Langflow/pr-validation/.claude/skills/
cp -r skills/langflow-instance-migration-qa ~/Langflow/pr-validation/.claude/skills/
cp -r skills/langflow-enterprise-qa ~/Langflow/.claude/skills/
cp ~/Langflow/pr-validation/provider-secrets.env ~/Langflow/pr-validation/.claude/skills/langflow-pr-validation/config/
```
