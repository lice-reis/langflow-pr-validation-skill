# EE environment, config & tooling

## Environment variables (the ones QA sets)

| Var | Default | Meaning |
|---|---|---|
| `LANGFLOW_AUTHZ_ENABLED` | `false` | Master RBAC switch. Off = OSS pass-through, everything allowed. |
| `LANGFLOW_AUTHZ_SUPERUSER_BYPASS` | `true` | Superusers skip all checks. **Set `false`** to test enforcement as a superuser. |
| `LANGFLOW_AUTHZ_AUDIT_ENABLED` | `false` | Write every authz decision to `authz_audit_log`. |
| `LANGFLOW_SSO_ENABLED` | `false` | Enable SSO/OIDC. |
| `LANGFLOW_SSO_CONFIG_FILE` | — | Path to `sso-config.yaml` (providers, redirect_uri). |
| `LANGFLOW_ENTERPRISE_LICENSE_KEY` | — | JWT license key. EE is proprietary; missing/invalid key is testable behavior. |
| `LANGFLOW_AUTO_LOGIN` | — | `true` lets the FE call `/authz/*` unauthenticated (dev only). `false` for real auth/SSO. |
| `LANGFLOW_DATABASE_URL` | SQLite | Point at the **same** DB as OSS to keep data. Postgres for multi-worker/prod. |
| `LANGFLOW_SECRET_KEY` | generated | **Must persist across restarts** or tokens/API keys break (`InvalidSignatureError`). |
| `LANGFLOW_AUTHZ_REDIS_URL` / `_POLICY_NAMESPACE` / `_INSTANCE_ID` / `_RECONCILE_INTERVAL_SECONDS` | see architecture.md | Multi-replica Casbin policy invalidation. |

### `#1 "why is nothing blocked?"` gotcha
`AUTHZ_ENABLED=true` but logged in as a superuser with bypass still on → everything allowed.
Set **both** `AUTHZ_ENABLED=true` and `SUPERUSER_BYPASS=false`.

## Env template for local RBAC-enforcement QA

The EE repo root ships a ready `rbac.env` (untracked) as a concrete example — **SSO dormant, real
enforcement, Postgres**. Pattern (fill your own secret/paths; don't reuse a checked-in key):

```bash
export LANGFLOW_AUTHZ_ENABLED=true
export LANGFLOW_AUTHZ_SUPERUSER_BYPASS=false
export LANGFLOW_AUTHZ_AUDIT_ENABLED=true
export LANGFLOW_AUTO_LOGIN=false
export LANGFLOW_SSO_ENABLED=false
export LANGFLOW_SUPERUSER=admin
export LANGFLOW_SUPERUSER_PASSWORD=<choose>
export LANGFLOW_SECRET_KEY=<stable-base64-key>          # keep constant across restarts
export LANGFLOW_DATABASE_URL=postgresql://langflow:langflow@localhost:5433/langflow
export LANGFLOW_PORT=7862
export LANGFLOW_CONFIG_DIR=<scratch dir>
```
Run with `source rbac.env && ./scripts/run-with-oss.sh langflow run`. Roles, sharing and persona seed shapes: `ee-gotchas.md`.

## SSO config

Copy `sso-config.example.yaml` → `sso-config.yaml`; set provider `client_id`/`client_secret`/
`discovery_url` and a `redirect_uri` that matches the running host+port (e.g. `.../api/v1/sso/callback`).
`auto_link_by_email: true` links SSO identities to existing users by email (used in OSS→EE migration).
The EE login page is served at **`/login`**; `/logout` clears cookies and returns there.

## Ports (defaults; override on the CLI)

| Port | What | Source |
|---|---|---|
| 7860 | backend (README quick-start / matches SSO redirect_uri) | README |
| 7861 | backend that `dev-frontend.sh` proxies to; EE container host port | Makefile `EE_PORT`, dev-frontend default |
| 7862 | backend in `rbac.env` | rbac.env |
| 3000 / 3001 | Vite dev server | dev-frontend.sh (:3000) / Makefile `VITE_PORT` (3001) |

Keep backend port and the frontend `VITE_PROXY_TARGET` consistent, and the SSO `redirect_uri` on the
same host+port, or SSO/login round-trips break.

## Make targets

| Target | Does |
|---|---|
| `make init` | `uv sync --extra dev` + install pre-commit hooks |
| `make format` / `make lint` | ruff format / check |
| `make test` | `./scripts/run-with-oss.sh pytest` (backend, against the pin) |
| `make dev` | backend (`LANGFLOW_REPO` OSS checkout, `login=true`, :7860) **+** Vite mirror (:3001) together |
| `make setup-frontend` | one-time FE mirror (clone OSS@pin, symlink overrides, npm install) |
| `make dev-frontend` | Vite mirror only |
| `make build` / `make up` / `make down` / `make logs` | **Docker** image / run (:7861) / stop / logs — **GCP VM only** |
| `make clean-frontend` | remove `.frontend-dev/` (force a clean re-clone at the current pin) |

`make dev` expects a local OSS checkout via `LANGFLOW_REPO` (defaults to `~/Documents/langflow` in the
Makefile — override to `~/Langflow/local-instances/main/langflow`). `run-with-oss.sh` needs **no** local
OSS checkout (it installs from the pin), so backend testing is self-contained.

## Docker parity → GCP VM

The IBM Mac has no Docker, so `make build`/`make up` and the production-parity image (UBI10, OSS built
from `oss-version` + EE layered) can't run locally. Route those to the GCP VM (`docker-real-qa-via-gcp-vm`
memory). Everything else — `run-with-oss` backend tests, `check-oss-compat`, `dev-frontend` — runs on the Mac.

## CI (for context)

- `.github/workflows/ci.yml` — lint + backend suite via the pinned OSS contract.
- `.github/workflows/oss-compat.yml` — nightly `check-oss-compat` across the pinned SHA **and** OSS `main`,
  so seam drift is caught before a bump. A red nightly on `main` = OSS moved a seam the overrides depend on.
