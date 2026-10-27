# Langflow Enterprise — architecture (for QA)

How the EE overlay attaches to OSS, so you can judge whether observed behavior is
correct and know which layer a failure belongs to.

## The overlay: plugin, not fork

`langflow-enterprise` is a Python package installed **into** an OSS Langflow
environment. It contains **no OSS backend source**. It attaches at runtime through
two entry-point channels, declared in both `lfx.toml` and `pyproject.toml`:

```toml
# lfx.toml — highest priority, override=True → replaces core services
[services]
auth_service          = "src.auth.sso_auth_service:SSOAuthService"
authorization_service = "src.authz.casbin_authorization_service:CasbinAuthorizationService"
```
```toml
# pyproject.toml
[project.entry-points."lfx.services"]        # same two service replacements
[project.entry-points."langflow.plugins"]
enterprise = "src.plugin:register"           # mounts EE API routes
```

- **Service replacement:** OSS ships a default `AuthService` and a no-op pass-through
  `AuthorizationService`. EE's entry points swap in `SSOAuthService` and
  `CasbinAuthorizationService`. This is *why* real allow/deny only exists on EE.
- **Route registration:** `src.plugin:register` mounts `/api/v1/sso/*`,
  `/api/v1/authz/*`, `/api/v1/account/*`.
- **Discovery is automatic:** with the package installed in the running venv,
  `langflow run` loads it. If it isn't installed there, `/api/v1/authz/status` → `503`.

### `src/` layout (what lives where)
- `src/plugin.py`, `src/startup.py` — plugin registration / startup hooks.
- `src/auth/` — SSO/OIDC: `sso_auth_service.py`, `oidc_service.py`, `sso_config*.py`.
- `src/authz/` — RBAC/Casbin: `casbin_authorization_service.py`, `policy_sync.py`,
  `routes.py`, `model.conf`, `share_sync.py`, `policy_invalidation.py`, `roles.py`.
- `src/api/` — `sso.py`, `account_linking.py`.
- `src/license/` — `manager.py`, `models.py` (proprietary license gating; JWT key).
- `src/db/models.py` — EE data models. `src/frontend/login.html` — SSO login page served at `/login`.

## The pin (`oss-version`) — the load-bearing concept

A single file with **one full lowercase 40-char OSS commit SHA**. `scripts/read-oss-version.sh`
enforces exactly that (rejects multi-line, tags, branch names, short SHAs). Everything
resolves through it:

- `scripts/run-with-oss.sh <cmd>` → `uv run --extra dev --with "langflow @ git+<oss>@<SHA>" <cmd>`.
  Installs OSS from the exact ref, then runs the command in the EE uv env. This is how
  backend tests and local `langflow run` get their OSS.
- Docker image: fetches one validated commit in a shared source stage, builds OSS backend +
  frontend from it, then layers `langflow-enterprise`.
- **Why a full SHA:** Docker layer caching won't re-ask a remote whether a branch moved; a
  moving `release-1.11.0` could silently reuse stale source or resolve FE and BE to different
  commits. Copying `oss-version` before the fetch makes every deliberate pin change invalidate
  the source layer (LE-1825 made the pin immutable + cache-safe).
- **Bumping the pin:** replace the SHA with a reviewed full SHA, run `check-oss-compat.sh <sha>`,
  rebuild. Roll back by restoring the previous SHA. No other file declares the OSS version.

## `check-oss-compat.sh <oss-ref>` — the seam-drift guard

Clones OSS at `<ref>` and runs a battery that a green exit (0) certifies. Observed gate order:

1. Clone OSS @ ref (rejects if a 40-char SHA resolves to a different commit).
2. Verify **enterprise-hardened bundle profile and lock**.
3. Verify **RBAC endpoint matrix and canonical OSS route inventory**.
4. Verify **authz share commit-before-refresh contract** (`check-authz-share-contract.py`).
5. Verify **authz identity lifecycle transaction contract**.
6. Verify **model-provider policy service contract**.
7. Verify **EE redis pin co-resolves with OSS** (`check-redis-constraint.py`).
8. Verify **customization seam files still exist** in OSS — else `DRIFT`, EE overrides need updating.
9. Swap EE overrides over the OSS stubs → `npm ci` → **typecheck only the EE override paths**
   (OSS carries unrelated type errors we must not fail on) → **`vite build`**.

Non-zero exit = drift: `2` (seam missing / build fail), `3` (type errors in EE override files).
Used by `.github/workflows/oss-compat.yml` (nightly across pinned + `main`) and locally before a bump.

The **seam files** EE overrides (tracked by the guard): `custom-store-sidebar.tsx`,
`custom-navigate.tsx`, `custom-flow-share-action.tsx`, `custom-wrapper.tsx`,
`utils/custom-routes-store.tsx` (+ `utils/custom-routes-store-pages.tsx`). If OSS removes/moves a
seam (e.g. #14141 removed the Store page), the matching override must be trimmed — that trim IS the
kind of change a pin-bump PR carries.

## Frontend override mechanism

EE has no FE toolchain. `frontend-overrides/src/customization/` holds:
- **Seam overrides** (files that replace OSS stubs of the same path).
- **EE-only feature dirs** (`access-control/`, `connected-accounts/`, `shared-with-me/`,
  `enterprise-admin/`) mounted through the seam route files.

- **Local dev** (`scripts/dev-frontend.sh`): clones OSS @ pin into gitignored `.frontend-dev/`,
  symlinks seam overrides + feature dirs into it, patches `vite.config.mts`
  (`resolve.preserveSymlinks = true`), `npm install`, serves Vite (:3000; Makefile passes
  VITE_PORT=3001) proxying API to `VITE_PROXY_TARGET` (default `http://localhost:7861`). The mirror
  must sit at the pinned commit or the script refuses to run — `make clean-frontend` to refresh.
- **Production** (Docker): the image fetches OSS @ pin once and builds the overrides + backend from
  the identical source tree.

## Data & migrations

- EE uses the **same database** as OSS (`LANGFLOW_DATABASE_URL`); OSS→EE upgrade keeps users, flows,
  and API keys. EE adds `authz_*` and `casbin_rule` tables, created on first run; `alembic/` carries
  EE migration state. `MIGRATION_SETUP.md` documents pip / Docker / Docker-Compose upgrade paths and
  SSO `auto_link_by_email` for seamless account migration.
- SQLite is fine for a single process (WAL + 30s `busy_timeout`). Use **Postgres** for multi-worker /
  production. Preserve `SECRET_KEY` across restarts or existing tokens/API keys break.

## Multi-replica policy invalidation (Casbin)

Each process holds its own in-memory Casbin enforcer. On a policy write the process reloads locally
and (if Redis configured) publishes a coarse `policy_changed`; other replicas reload from the shared
DB. Knobs: `LANGFLOW_AUTHZ_REDIS_URL`, `LANGFLOW_AUTHZ_POLICY_NAMESPACE`, `LANGFLOW_AUTHZ_INSTANCE_ID`,
`LANGFLOW_AUTHZ_RECONCILE_INTERVAL_SECONDS` (default 15), `LANGFLOW_AUTHZ_RECONNECT_INTERVAL_SECONDS`.
DB is source of truth; Redis is low-latency notification; without Redis, replicas converge via
reconciliation (polling-fallback). Worker/replica races reproduce **only** on Linux + Postgres, not macOS.
