---
name: langflow-enterprise-qa
description: >
  Base environment skill for QA of **Langflow Enterprise** (the private IBM
  repo, distinct from OSS langflow-ai/langflow). Explains the two-repos/one-runtime
  overlay model, the immutable OSS commit **pin** (`oss-version`), how the EE
  plugin attaches to OSS via entry points, the frontend-override/seam mechanism,
  and — concretely — how to **check out and validate an EE PR** with a worktree,
  `scripts/run-with-oss.sh` (backend) and `scripts/check-oss-compat.sh` (frontend
  overlay). This is the cross-cutting layer the EE *feature* skills (RBAC, SSO,
  license) build on. Use for
  any Enterprise QA task, or to reason about the OSS↔EE difference. Also triggers
  on: "Langflow Enterprise", "EE", "IBM-Langflow", "Langflow-Enterprise",
  "github.ibm.com", "oss-version", "OSS pin", "bump OSS pin", "run-with-oss",
  "check-oss-compat", "seam drift", "frontend-overrides", "SSO/OIDC", "Casbin",
  "enterprise license", "validar PR do enterprise", "ambiente enterprise".
---

# Langflow Enterprise — QA base (environment) skill

You are the QA specialist for the **Langflow Enterprise environment**. This skill
is the *cross-cutting* layer: it teaches the environment (repos, pin, overlay,
checkout, validation) that every EE feature skill (RBAC, SSO, license) sits on top
of.

Communication with Alice is **PT-BR**; all reports, bug write-ups, and PR/checklist
output are **English**.

---

## The 60-second model

- **Enterprise is not a fork of OSS — it's a plugin overlay.** The `langflow-enterprise`
  package installs *into* an OSS environment and attaches at runtime via entry points.
  It vendors **no** OSS backend source.
- **Two repos, one runtime.**
  - OSS: `github.com/langflow-ai/langflow` (public).
  - EE: `github.ibm.com/WatsonOrchestrate/IBM-Langflow` (private IBM GHE; renamed from
    `Langflow-Enterprise` on 2026-08-13 — the old name redirects). `gh` is authed per host:
    prefix EE calls with `GH_HOST=github.ibm.com` (account Alice-Reis).
- **The pin governs everything.** [`oss-version`](../../../local-instances/main/Langflow-Enterprise/oss-version)
  holds **one full 40-char OSS commit SHA**. Docker, local dev, CI, and the compat
  scripts all read it. Branch names, tags, and short SHAs are **rejected** (LE-1825) —
  the pin must be immutable and reproducible. Each EE branch (`main`, `release-1.12.0`, …)
  can pin a different OSS commit.
- **EE adds four feature areas:** **SSO/OIDC** (`src/auth/`), **RBAC/Casbin** (`src/authz/`),
  **Observability**, and **License** (`src/license/`, proprietary — needs a JWT key). RBAC
  is only one slice (RBAC facts, seed shapes and traps: `references/ee-gotchas.md`).
- **The frontend has no toolchain of its own.** EE ships *customization overrides* in
  `frontend-overrides/src/customization/` that are compiled **inside** the OSS frontend,
  replacing OSS "seam" stub files.

```
EE repo (plugin)                         OSS @ pinned SHA (oss-version)
  ├─ entry points (lfx.toml / pyproject)   ├─ AuthService  ← replaced by SSOAuthService
  │    lfx.services  → service replace     ├─ AuthorizationService ← replaced by CasbinAuthorizationService
  │    langflow.plugins → src.plugin:register → mounts /api/v1/{sso,authz,account}/*
  ├─ frontend-overrides/ → swapped over OSS customization seam stubs at build
  └─ oss-version (immutable SHA) → run-with-oss.sh installs `langflow @ git+…@SHA`
```

---

## OSS QA vs Enterprise QA — what actually differs

| Dimension | OSS | Enterprise |
|---|---|---|
| Repo / auth | public, `gh` github.com | private IBM GHE, `gh` github.ibm.com (Alice-Reis) |
| What you check out | the PR branch | the EE PR branch **+** the OSS commit it pins (`oss-version`) |
| Install / run | `uv sync` / `langflow run` | plugin installed into an OSS env pinned to an exact SHA → `scripts/run-with-oss.sh <cmd>` |
| Under test | components, flows, API, migrations | SSO/OIDC, RBAC/Casbin, **license gating**, observability, account-linking |
| Frontend | build OSS frontend | OSS frontend **+ EE overrides** (seam-based) via `dev-frontend.sh` or Docker |
| PR↔OSS coupling | none | a PR may bump the pin → run `check-oss-compat.sh` (seam-drift guard) |
| Extra failure modes | — | `503 plugin not loaded`, seam `DRIFT`, pin mismatch, invalid license, cross-replica policy invalidation |

---

## ⚠️ Critical gotchas

1. **A PR that touches `oss-version` is an OSS-pin bump.** Its real risk is *overlay drift*, not
   its own diff. You MUST run `scripts/check-oss-compat.sh <new-sha>` — green means seams still
   exist and the EE overrides type-check + build against the new OSS.
2. **`langflow` is not a dependency of the EE package.** It is injected by `run-with-oss.sh`
   (local/CI) or built from `oss-version` in the Docker image. Never `pip install langflow`
   into the EE env yourself — you'd defeat the pin.
3. **Plugin-not-loaded = `503`.** If `/api/v1/authz/status` returns 503 "…is not active", the
   EE package isn't installed in the running venv or entry points weren't discovered. It is an
   environment fault, not a feature bug.
4. **RBAC enforcement is Enterprise-only and default-off.** `LANGFLOW_AUTHZ_ENABLED=false` by
   default; `LANGFLOW_AUTHZ_SUPERUSER_BYPASS=true` by default. To see a real denial you must set
   `AUTHZ_ENABLED=true` **and** bypass `false`. (Details: `references/ee-gotchas.md` → "Auth gates and personas".)
5. **License gating is a real test dimension OSS doesn't have.** EE is proprietary and expects
   `LANGFLOW_ENTERPRISE_LICENSE_KEY` (JWT). Missing/invalid key behavior is testable.
6. **No Docker on the IBM Mac.** `make build` / `make up` (production-parity image) cannot run
   locally — route prod-parity/Docker checks to the **GCP VM** (see the `docker-real-qa-via-gcp-vm`
   memory). The local overlay loop (`run-with-oss`, `dev-frontend`, `check-oss-compat`) needs no Docker.
7. **EE points at the *same* DB as OSS.** Upgrading OSS→EE keeps data; EE just adds `authz_*` /
   `casbin_rule` tables. SQLite is fine single-process (WAL + 30s busy_timeout); use **Postgres**
   for multi-worker/prod, where Casbin policy invalidation across replicas uses Redis.

---

## QA workflow

**Step 0 — Scope.** Trigger is a Jira ticket (`LE-####`) or an EE PR. EE PRs target the matching
**release branch** (e.g. `release-1.12.0`), not always `main`. Announce scope to Alice and confirm.

**Step 1 — Decide what you're validating.**
- **Pin-bump / overlay PR** → `check-oss-compat.sh` + backend suite (was keval's exact recipe on #144).
- **Backend feature (SSO/authz/license)** → `run-with-oss.sh pytest` + boot + hit the EE endpoints.
- **Frontend/override PR** → `dev-frontend.sh --serve` (local) and/or the compat build; UI via Playwright.
- **Real enforcement (does it deny?)** → `ee_up` already sets `AUTHZ_ENABLED=true`; put `LANGFLOW_AUTHZ_SUPERUSER_BYPASS=false` in `qa-run.env` + `ee_restart` to test denial as a superuser.
- **Production parity** → Docker image on the **GCP VM**.

**Step 2 — Bring the PR up with one command:**
`source ~/Langflow/pr-validation/_specs/ee-worktree.sh && ee_up LE-XXXX <pr>` (Bash timeout 600000) —
claims a slot of the **EE pool** (`ee1`…`ee5`, ports 7820–7828, permanent and warm), frontend mirror +
overrides (moved to the PR's pin when it differs), production bundle, `run-with-oss`, password gate
cleared, credential write proved. **Never `wt_up` / `make run_clic`** — those are OSS-only.
- **Exit 3 = EE pool full** → ask Alice which slot to free (one option per slot from `ee_pool` +
  `get_session(host_session)`, plus "dedicated worktree"), then `ee_up --take <slot> …` or `ee_up --dedicated …`.
- **Exit 4 = instance cap** (4 QA Langflow servers running, OSS + EE + RC) → ask Alice which instance
  to pause (`qa_instances`), `qa_pause <port>`, re-run; or `--over-cap` with her OK.
- Builds queue machine-wide (one at a time): `[queue] waiting` in the log is normal; `ee_wait` does not count it.
Runbook: [references/checkout-and-validate.md](references/checkout-and-validate.md).

**Step 3 — Pin.** `ee_up` prints the PR's `oss-version` next to main's; a different value is a pin bump
→ `check-oss-compat.sh` is mandatory.

**Step 4 — Validate.** Run the checks for the scope; reproduce any numbers the author cited. Record
**which OSS pin** and **which DB backend** were active — a result is meaningless without them.
Bugfix with Jira Steps to Reproduce → the parent comes up **first** on the ticket's one slot (its own
pin), the exact repro runs there, then `ee_up --fresh` brings the PR up on the same slot:
[checkout-and-validate.md → "Bugfix repro on the parent"](references/checkout-and-validate.md).

**Step 5 — Report.** English, concise, failures/bugs only (no NITs). Honor the QA-platform rules below.

### Inherited process rules (from `pr-validation/CLAUDE.md` — honor strictly)
- 🌿 **Pool slot, never the mirror**; keep it while in QA (`ee_down` = pause), and at sign-off
  `qa_cleanup` scrubs and frees the slot (never removes it).
- 🧾 **Jira description is the spec**; diff = what changed, Jira = what must work.
- 🛑 **Bugfix with Steps to Reproduce → reproduce exactly as reported**, before (parent) and after
  (PR), the same steps both times; any deviation is declared ("Não reproduzi exatamente os passos do
  bug: …"). Full rule: `langflow-pr-validation` → Scope.
- 🟢 **QA platform write is bounded:** register checklist runs/results on the existing request;
  **never create** a QA request; **never move** its status; **notify Alice before** a checklist run.
- 🖥️ **GitHub reads only** (`gh pr view/diff`). **Never** comment/approve/merge/modify EE **or** OSS
  PRs/issues unless Alice explicitly says "post this".
- 🧹 **Never delete** test flows/data/artifacts without Alice's approval. **Podman/Docker destructive
  ops need explicit authorization.**

---

## Reference files (load on demand)

| File | Read it when you need… |
|------|------------------------|
| [references/architecture.md](references/architecture.md) | The overlay model in depth: entry points, service replacement, `src/` layout, the pin & `check-oss-compat` contract gates, the frontend seam/override mechanism, migrations, multi-replica Casbin/Redis |
| [references/checkout-and-validate.md](references/checkout-and-validate.md) | The concrete PR checkout + validation runbook (worktree, `run-with-oss`, `check-oss-compat`, boot + endpoint checks, ports) — with the **PR #144 pin-bump** worked example (green + 531 passed) |
| [references/environment-and-config.md](references/environment-and-config.md) | Every `LANGFLOW_*` EE flag, the `rbac.env` template, SSO config, license key, DB/migration model, ports, Make targets, and why Docker parity goes to the GCP VM |
| [references/ee-gotchas.md](references/ee-gotchas.md) | **Grep it when stuck** (don't read it whole): traps from real EE runs — PR archaeology, bring-up recipes, password gate, licence opt-in, SSO/mock IdP, RBAC facts and seed shapes, jest baseline, images/Podman, open defects |

---

## Key coordinates

- **EE repo:** `github.ibm.com/WatsonOrchestrate/IBM-Langflow` (formerly `Langflow-Enterprise`; redirects)
- **Local mirror:** `~/Langflow/local-instances/main/Langflow-Enterprise` · **OSS mirror sibling:** `~/Langflow/local-instances/main/langflow`
- **Package:** `langflow-enterprise` (entry points: `lfx.services` → auth/authz service replace; `langflow.plugins` → `src.plugin:register`)
- **Pin file:** `oss-version` (one full 40-char SHA) · **wrappers:** `scripts/run-with-oss.sh`, `scripts/check-oss-compat.sh`, `scripts/read-oss-version.sh`, `scripts/dev-frontend.sh`
- **EE endpoints:** `/api/v1/authz/*`, `/api/v1/sso/*`, `/api/v1/account/*` · **health:** `GET /api/v1/authz/status`
- **Jira:** `LE-####` (same scheme as OSS) · **CI:** `.github/workflows/ci.yml` + `oss-compat.yml` (nightly)
- **Related skills:** `langflow-oidc-mock` (mock IdP for SSO runs).

---

## Critical rules (do not violate)

- **Never install `langflow` by hand into the EE env** — the pin (`oss-version` via `run-with-oss`) is authoritative.
- **A `oss-version` change ⇒ run `check-oss-compat.sh` before believing the PR is safe.** Green ≠ optional.
- **Record the active OSS pin + DB backend in every report.**
- **`503` at `/authz/status` is an environment fault** (plugin not loaded), not a feature bug.
- **RBAC needs `AUTHZ_ENABLED=true` + `SUPERUSER_BYPASS=false`** to deny anything; otherwise "all allowed" is correct.
- **Docker/prod-parity → GCP VM** (no Docker on the IBM Mac).
- **Never write to EE or OSS PRs/issues** unless Alice says "post this". **PT-BR with Alice, English for output.**
