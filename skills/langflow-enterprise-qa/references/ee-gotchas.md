# EE gotchas — grep this, don't read it

Traps met in real Enterprise QA runs. `grep -i -A4 <keyword>`. Dates = last confirmed.

## Repo, PRs, pins

- Repo is `github.ibm.com/WatsonOrchestrate/IBM-Langflow` (renamed from `Langflow-Enterprise`
  2026-08-13; old name redirects). `GH_HOST=github.ibm.com`, account Alice-Reis (`lice-reis` has no
  access). Without `GH_HOST`, `--repo WatsonOrchestrate/…` resolves against github.com and 404s.
- **`enterprise_pr_url`** on the Jira card (live since 2026-08-31) is the first place to look. Empty
  → `git ls-remote --heads` on the EE clone for `fix/le-XXXX-*`, then commit subjects on the release
  branch (`gh api "repos/WatsonOrchestrate/IBM-Langflow/commits?sha=release-1.x.0"`) → `gh pr list`.
  EE PR titles rarely carry the key. A closed PR's closing comment names its successor (LE-2319:
  #318 closed → #317 shipped it); walk revert chains (#296 → #311 revert → #318 → #317).
- **The EE clone has a single-branch refspec** (`+refs/heads/main`): `git fetch origin release-1.12.0`
  updates only `FETCH_HEAD`, so `reset --hard origin/release-1.12.0` lands on a stale ref with no
  error (82 commits behind, wrong `oss-version`). Fetch explicitly:
  `git fetch origin <br>:refs/remotes/origin/<br> --force` and verify with `git ls-remote origin`.
- **OSS-seam PRs**: an OSS PR that only adds a no-op seam (`customization/components/*.tsx`
  returning `null`) has its visible half in `frontend-overrides/`. Check the override exists (tree
  listing `git/trees/main?recursive=1`, GHES code search is unreliable), the `oss-version` pin
  contains the wiring (`git merge-base --is-ancestor <merge> <pin>` + `git show <pin>:<path>`), and
  who writes the data (EE OIDC claims). EE can land before OSS; an EE half may have no PR link.
  "No Share option on OSS" for non-flow resources is correct (LE-1906).
- **OSS pin regression window** (main between `a45da8d1` and `6ba56ed8`, 2026-10-07): every
  non-superuser 500s on `/flows/`, `/projects/`, `/variables/` ("Could not load flows from database",
  `TypeError: ResourceVisibilityScope.__init__() … exclude_personal_projects`). Fixed at `6ba56ed8`.
  Grep the log for that TypeError before blaming a PR; check the pin contains every OSS merge the EE
  code needs.

## Bring-up

- **Fast path (~5 min)**: when a sibling `ee-worktrees/<X>/.frontend-dev` has the same
  `oss-version`, `cp -cR <X>/.frontend-dev/langflow <new>/.frontend-dev/langflow` (APFS clone,
  ~1 min) then `scripts/dev-frontend.sh` only re-links overrides (verify `readlink
  …/src/customization/enterprise-admin` → new worktree); `npm run build` ~60 s. Don't run
  `dev-frontend.sh` while a build runs.
- **Single-port production-like instance**: `scripts/dev-frontend.sh` (no `--serve`) → `npm run
  build` in `.frontend-dev/langflow/src/frontend` → `run-with-oss.sh langflow run --host 0.0.0.0
  --port <p> --frontend-path <mirror>/src/frontend/build`. Env via a scratchpad file (`set -a`),
  `LANGFLOW_CONFIG_DIR=<wt>/.langflow-dev` with `lfx.toml` copied there (else the OSS pass-through
  authz service stays registered — grep the boot log for "no enforcement plugin found"),
  `LANGFLOW_SAVE_DB_IN_CONFIG_DIR=true`. Cold ≈ 6 min. Backend-only boots need `--backend-only`
  (the git-installed OSS has no built frontend).
- **`scripts/dev-backend.sh` (`--reload`) never binds** — WatchFiles indexes `.frontend-dev/…/node_modules`.
  Run uvicorn without `--reload`: `uv run --extra dev --with "langflow @ git+https://github.com/langflow-ai/langflow.git@$(./scripts/read-oss-version.sh)" uvicorn --factory langflow.main:create_app --port <p>`.
  A killed reloader leaves a child holding the port (`lsof -ti :<port>`).
- `uv run` without `--no-sync` re-syncs to the OSS lockfile and strips `langflow-enterprise`,
  `casbin`, `psycopg`, `opensearch-py` (use `--with "opensearch-py>=2.8"`). Restart with
  `uv run --no-sync` or re-install first. A backend-only EE push needs no frontend rebuild: fetch,
  `checkout -B`, restart with the env captured from the live process (`ps eww -p <pid>`).
- **Feature flags are build-time**: `frontend-overrides/src/customization/shared/feature-flags.ts`
  `ENTERPRISE_FEATURES`, no env, no backend gate. Flag-on QA = second bundle (`sed` the flag, build,
  copy `build/`, `git checkout` the file back; confirm with `grep -rho '<flag>:![01]' build/assets`)
  served by its own backend + `LANGFLOW_CONFIG_DIR` on `on.localhost:P1` / `off.localhost:P2`; mark
  it "locally patched" in the plan. Runtime flags (e.g. `LANGFLOW_FEATURE_DATA_SUBJECT_REQUESTS`)
  show in `/api/v1/config` → `feature_flags`.
- **Licence**: no key → "Enterprise license validation is unavailable" (503, fail-closed) on
  projects/users/roles. Opt-in `LANGFLOW_ENTERPRISE_ALLOW_UNLICENSED_TIER_GATES=true` (restart;
  uncapped). `LANGFLOW_TIER` only sets the SSO connection limit; tiers come as JWT claims. SSO admin
  API additionally needs `LANGFLOW_ENTERPRISE_ALLOW_UNLICENSED_SSO=true` + `LANGFLOW_SSO_CONNECTION_LIMIT`
  (`1|3|unlimited`).
- **Two ports, two cookies**: `ana.localhost:7867` / `vic.localhost:7867` per persona.
- **Images**: Slack ships `ibm-langflow-<date>-{amd64,arm64}.tar` (same build; arm64 on this Mac);
  `index.json` written last = download done; `podman load` names it `docker.io/library/ibm-langflow-<date>`
  → retag `localhost/ibm-langflow:<date>`; needs ~3.5 GB free inside the Podman VM (daily nightly
  updater leaves a dangling image per day — removal needs Alice's OK). Baked-in hardening:
  `AUTO_LOGIN=false`, `ACCESS/REFRESH_SECURE=true` (override to false on http), custom components
  blocked, `LANGFLOW_ENV=local|prod` presets. Run pattern = `~/Langflow/scripts/run-ee*.sh`.
  Recreating a container over an existing named volume breaks image-seeded files (SELinux MCS
  relabel → profile pictures 500 `Permission denied`); fix `podman run --rm -v <vol>:/v:z alpine true`
  and mount with `:z`. Containers vanishing during an `rmi` were Podman Desktop — `podman events`
  + the VM journal settle it.
- **Mock IdP inside the container netns**: run `mock_oidc.py` as a second container
  `--network container:<ee> --host 0.0.0.0 --port 5557` (issuer derives from `Host`); both sides
  then use `localhost:5557`. Mock users are hardcoded in `USERS` (admin API only edits groups); add
  identities by editing the file + restart, reuse mapped groups (`qa-admins`→admin, `qa-editors`→
  developer, `qa-viewers`→viewer, `qa-unmapped`→none).

## Auth gates and personas

- **Bootstrap admin is password-gated on first login** (`must_change_password`, re-stamped on every
  boot until changed): probe `GET /api/v1/sso/settings` (403) — `/users/whoami` and `/users/` are
  allowlisted and lie. Clear with `POST /api/v1/account/force-password-change {current_password,
  new_password}` (new ≠ current, 8+ chars); record the new password for the plan.
- **`/login` is rate-limited** (5/min per IP, 429): reuse sessions, space logins; a 429 is not an
  auth failure. A browser login right after a burst silently stays on `/login`.
- **Bootstrap admin = break-glass** (permanent superuser since EE #317 / `ff9a8627`): demote,
  deactivate, delete → 409. Password login lives at `/login/break-glass`
  (`GET /auth/methods?context=break_glass`); `/login` hides the form once SSO is enabled — by
  design. `PATCH /sso/settings {break_glass_enabled:true}` before enabling any connection.
  Diagnostic for narrowing bugs: `whoami.is_superuser` vs the row in `GET /users/`.
- **Two grants for one privilege**: the boot reconciler gives every active superuser a durable
  global `admin` assignment; revoking Super Admin leaves it (user can still create roles/assignments).
  Open defect, 2026-09-08, reproduced from the UI (promote → revoke → keep using Admin Settings);
  inspect `authz_role_assignment` after any revocation. Check whether a Jira exists before refiling.
- **Seed API shapes**: `POST /authz/teams {team_name, adom_name}` (`adom_name` unique, 409);
  roles `{name, permissions:["user:manage"]}`; assignments `{user_id, role_id, domain_type:
  global|workspace|project, domain_id}` or `POST /authz/users/{id}/roles {role_name, domain_type,
  domain_id}`; `GET /users/?skip=&limit=50` → `{users,total_count}` (paginated — look up by name
  from a full page); `POST /users/me/deletion-request` seeds "Deletion requested"; system roles
  admin/developer/viewer; a `user:manage`-only delegate 403s on sso/roles/teams (Groups/Role render
  "—"). Pre-check each persona via API before handing over the plan. Seed helpers: return `None`
  on 409 and resume from GET lists.
- **Custom-role assignment** (LE-2921): `POST /authz/users/{id}/roles` accepts only system role names
  (400 "must be one of admin/developer/viewer"); a custom role goes through
  `POST /authz/admin/role-assignments {user_id, role_id, domain_type:"global"}` (201) + `POST /authz/policy/sync`.
  A `user:manage`-only delegate then lists `/users/` (200), `capabilities.administration` = `{user:true, role:false}`,
  `/sso/admin/identities` 403, `/authz/me/rbac-admin` false.
- **SSO profile claims** (LE-2921): OIDC JIT login stores `given_name`/`family_name`/`picture` (http only on
  loopback hosts, https elsewhere) in `SSOUserProfile`; the connection **test-login promotion does not** — the
  promoted admin has null names until one regular `/sso/login`. JIT username came out as the full e-mail even
  with `username_claim=preferred_username`. `mock_oidc.py` has no per-user profile claims (and a hard-coded
  "Mike O'Brien" hack from LE-2317): patch a scratch copy — per-user keys emitted when present + an
  `/avatar/*.svg` route — and run it on another port (5559).
- **Viewer / no-role users**: cannot create their own file, project or global variable (403), can
  create flows (201) — Alice's rule says own resources are manageable → defect (LE-2567 F1).
  Re-check per build. `POST /authz/me/permissions` resolves project grants only with
  `domain: "project:<folder_id>"`. Public share must be `permission_level: execute`. Deleting a
  flow/user leaves `authz_access_exception` rows on SQLite. `/authz/role-visible` does not subtract
  exceptions (revoked flow stays listed → 404).
- RBAC enforcement needs `LANGFLOW_AUTHZ_ENABLED=true` + `LANGFLOW_AUTHZ_SUPERUSER_BYPASS=false`,
  one `POST /authz/policy/sync` after bootstrap; deny = 404 when the resource is invisible, 403 on a
  visible one. Reconcile interval var: `LANGFLOW_AUTHZ_RECONCILE_INTERVAL_SECONDS`.

## SSO

- **Enabling is not a toggle**: `PATCH {enabled:true}` always 409; only
  `POST /sso/connections/{id}/test-login/start` (step-up password; 200 JSON `{authorization_url}`)
  → IdP → callback promote sets it. Needs a real or mock IdP (`~/Langflow/langflow-oidc-mock`, see
  its skill). Disable is a plain toggle; the last active method cannot be removed (409).
- **One host spelling everywhere**: the test-login binding cookie is host-scoped; start on
  `127.0.0.1`, callback on `localhost` → `invalid_state` that looks like a real bug. Keep one cookie
  jar across start → mock `/authorize` (POST with `email=`) → callback.
- **`LANGFLOW_PUBLIC_URL` / `LANGFLOW_FRONTEND_BASE_URL` must be the UI origin**, read at boot. A
  successful login otherwise lands on `<backend>/admin-ee/security` → `{"detail":"Not Found"}`.
  Verify from the live process (`ps eww -p <pid> | tr ' ' '\n' | grep PUBLIC_URL`), restart after
  changing. Split-origin (Vite :3000 → backend): set both to the Vite origin.
- **A started-but-abandoned test-login stays "Testing" 600 s, then reads as Error** (lazy, on next
  read). Seed "Testing" rows right before Alice's item, or let her start it from the switch.
- Mock requirements: RS256 + `kid`-matched JWKS, `iss` == discovery issuer, `aud` == client_id, the
  id_token must echo the `nonce`; JIT keys on `sub`. JIT users are active regardless of
  `LANGFLOW_NEW_USER_IS_ACTIVE`; test-login promote makes the IdP admin an active superuser.
- **Directory sync / SCIM** (LE-2316): `LANGFLOW_DIRECTORY_SYNC_ENABLED=true`; trust lifecycle
  `PUT /authz/directory/connection` → `POST …/validate` (fetches JWKS; HTTPS required) → `…/enable`
  (409 if out of order). SCIM at `/scim/v2/*` (not `/api/v1`), bearer verified against the DB row,
  `exp - iat ≤ 900 s`, `azp`/`appid` == allowed_client_id. Reconcile preview returns `id`, feed it
  as `run_id`. The JWKS client ignores the repo's `tls_trust` helper → an internal-CA JWKS gives a
  permanent 503 `directory_trust_unavailable`; `SSL_CERT_FILE` doesn't help (httpx uses certifi) and
  breaks `uv` — use a public-chained cert or a combined bundle.

## Frontend and tests

- **The EE jest suite fails on its own base commit**: 7 suites / 146 tests on `main` @ `9225c4cb`
  (one cause: `No QueryClient set` from OSS `request-processor.ts`). Run on the PR commit AND its
  parent in a separate worktree + mirror (never `git checkout` the one Alice is testing — vite serves
  overrides by symlink), diff the failing suite set. Authors' containers mask these, so "passes for
  me" refutes nothing. `routes.test.tsx` uses `it.each(ENTERPRISE_ADMIN_TABS)` — a new tab adds one
  failing case. Run jest directly: `cd <mirror>/src/frontend; LF_FRONTEND_MIRROR=$PWD
  ./node_modules/.bin/jest --config <wt>/frontend-overrides/jest.config.js --maxWorkers=2 <names>`.
- **The dev UI (:3001) compiles OSS at the pin**, not an OSS PR head: OSS frontend fixes are
  invisible there. Run a second vite from the OSS PR worktree (`VITE_PROXY_TARGET=… npm run start
  -- --port 3000`) and split the plan by port. Restart Vite after any pull (HMR misses overrides).
- **EE `t()` delegates to OSS i18next** (`registerMessages` → `addResourceBundle`), so locale
  switching is a valid EE UI test. Language = `localStorage.languagePreference` (en, pt, de, es,
  fr, ja, ko, zh-Hans): flip + reload by script; diff en vs target text nodes + `aria-label/title/
  placeholder/alt` per state, plus an English-word leak regex (ja/ko/zh make leaks obvious).
  Count strings ("N of M", pagination) are the classic scrambled-order bug. Admin console i18n is
  tracked separately: LE-2987 (EE #502; 16 findings left as of 2026-10-07) — don't return another
  PR for it.
- **Data connections tab**: rows = configured providers (`isDBProviderConfigured`: OpenSearch needs
  URL + username vars and a password var with `has_value`); the empty state needs
  `local_vector_store_available=false` (prod profile → unreachable locally; cover with a throwaway
  jest). "Search connections…" in the bundle is the Add/Edit dialog's own search, not a leftover.
- **Knowledge base without a model provider**: `POST /knowledge_bases` → 404 under the EE provider
  policy; for share tests insert a `KnowledgeBaseRecord(name, user_id)` via `run-with-oss.sh python`.
  Deployments need a WxO provider account → share dialog N/A locally.
- **Catalog policy staleness (LE-2332, deferred to EE dev stage 2 by Alice, 2026-09-01)**: the block
  set comes from `/config` (page-load only) and the palette from `/all` (per flow open), so mid-session
  block/unblock disagree in both directions (drag → 400 "catalog policy blocks components"; or a
  disabled row with `blocked: []`). Steady state is PRD-correct. Re-measure against each catalog
  change before refiling. Write-up: `files/LE-2332-pr14827-findings.md`.
- **Audit seed rows**: `langflow_le1905_ee` carries ~50k rows tagged `details.seed=le1905-ceiling-test`
  (1 s apart, null user) — filter `(details->>'seed') is null` before reasoning about volume; one
  audit page read writes one `audit:read` row.
- Fyre OpenShift metering e2e (LE-1981): cluster `langflow-performance.cp.fyre.ibm.com` (IBM VPN,
  `oc login -u kubeadmin`, password from Ram Katakam in Slack, rotated); plan =
  `e2e-icr-validation-plan.md` on `langflow-operator` `develop`; `hack/spin-up-personal-instance.sh`;
  empty-node flows never fire `log_package_run()`.

## Admin console: catalog / providers seeding and measuring (LE-2576, 2026-10-08)

- `GET /api/v1/enterprise-admin/catalog/components` → `{components: {<bundle_key>: {<ComponentName>:
  {policy_keys:[…]}}}, policy_candidates}` — keyed by **bundle**, not component. Block with
  `PUT /api/v1/policy-bundle` carrying ALL lists + `expected_revision` and the component's
  `policy_keys[0]`; a key in no visible bundle lands in the synthetic "Policy-only entries" row
  (Blocked / "Fix Catalog") — expected. The Jira's "Approve Entire <bundle>" label no longer exists.
- Providers/Models rows: `POST /api/v1/model-provider-governance` (provider_id, provider_type
  "model", letters-only display_name, workspaces ["all"], environments, data_policy, kebab
  credential_alias, production_requirement, observability_required, expected_revision from
  `GET /api/v1/policy-bundle`); status "active" renders "Pending" until credentials exist — fine for
  layout tests. Data-requests row: a user → `POST /api/v1/users/me/deletion-request`.
- Measuring in the Browser pane: Admin tabs are `[role=tab]` (not links), click by exact text and
  wait ~3.5 s (Catalog ~9 s after a full navigate); for Models find the outermost `tbody td .grid`.
  The pane can re-sync the tab to the light theme mid-session — read
  `html/body.classList.contains('dark')` before assuming. Operations pages are unreachable in a stock
  build (build-time flags).
- A sibling session's EE instance at the merge-base is a free "before"; log in on
  `base.localhost:<port>` to keep cookies apart.
- The UI-plan runner's derived port can collide with another live plan's — never kill it, relaunch
  with an explicit free `--port`.
- `ee_up` on a worktree that was built by hand (or any path with a different case, e.g.
  `local-instances` vs `Local-instances`) does not stop the old instance: `_ee_stop` greps the
  worktree path case-sensitively, so the old backend keeps its port and DB while a second one boots
  on the next free port against the SAME SQLite file. After `ee_up`, check `lsof -ti :<old port>`
  and kill your own old process. To keep the DB/key/data across an update, create `qa-run.env`
  (same key, config dir) and `.qa-port` before `ee_up`, and set the admin password to
  `Qa-<ticket>-admin` first so `ee_wait`'s gate probe logs in.
- Users created by an admin (UI or API) are NOT sent to the forced-password-change screen; only the
  env-provisioned bootstrap superuser is. To see that screen, boot a second disposable instance on a
  fresh `LANGFLOW_CONFIG_DIR` (new key) with the same frontend build and log in as `admin` with the
  bootstrap password.
- Recovery URL / break-glass card lives inside the Local user sign-in card and opens only with local
  sign-in OFF, which `PATCH /sso/settings` refuses from a Local session (409) — needs an SSO-signed
  admin. Read the `<code>` text from the DOM, but say you did not see the card open.
