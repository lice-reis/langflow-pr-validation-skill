# Test assets — provision, configure, verify, then hand over

**Rule (Alice, 2026-10-08): a plan item is only valid if everything it needs already exists when
she opens it.** "Connect OpenSearch" is not an item; "select the OpenSearch provider — it is
already configured" is. For every item ask: *what infrastructure, data, credentials or state does
this click need?* Provide it, configure it **in the instance**, verify it with one API call, and
write the URL / user / password in the plan's `environment`. She never sets anything up herself.
If an asset genuinely cannot be provided (no account, no image, no licence), the item is
`blocked` with the reason — never "configure X yourself".

Conventions: containers, volumes and networks are named `qa-<ticket>-<svc>` — **no other name**:
that is how `qa_cleanup` finds them at sign-off (pre-authorized removal; a `lf-qa2953-pg` or a
`lf-qa-pg` is an orphan). `podman ps -a` first and reuse what is already up (never a duplicate); env vars go into the slot `.env` by `>>` then `wt_restart`
(EE: `qa-run.env` then `ee_restart`); ticket containers are named `qa-<ticket>-<svc>` precisely so `qa_cleanup <ticket>` removes them at her sign-off.

## OpenSearch (vector store, KB backend, Data connections)

**Standing fixture: `lf-qa-opensearch` → `http://127.0.0.1:9201`** (no auth, data volume
`lf-qa-opensearch-data`). `podman start lf-qa-opensearch` if it is stopped; **never remove it**.
Only if it is genuinely gone, recreate it with its original definition:
```bash
podman run -d --name lf-qa-opensearch -p 127.0.0.1:9201:9200 -e discovery.type=single-node \
  -e DISABLE_SECURITY_PLUGIN=true -e DISABLE_INSTALL_DEMO_CONFIG=true \
  -e OPENSEARCH_JAVA_OPTS="-Xms512m -Xmx512m" -v lf-qa-opensearch-data:/usr/share/opensearch/data \
  docker.io/opensearchproject/opensearch:2
until curl -s 127.0.0.1:9201 | grep -q cluster_name; do sleep 3; done
```
Ticket about credentials/TLS → drop `DISABLE_SECURITY_PLUGIN`, add
`-e OPENSEARCH_INITIAL_ADMIN_PASSWORD='Qa-<T>-Open1!'` (HTTPS self-signed on 9200, user `admin`;
Langflow side `use_ssl=true`, `verify_certs=false`; probe with `curl -k -u admin:…`).

Langflow side, **before** the plan:
1. OSS: `wt_up --extras opensearch LE-XXXX <pr>` (the `opensearch` extra brings `opensearch-py`; a manual
   `uv pip install` is stripped by the next `make`). EE: add `--with "opensearch-py>=2.8"` to the run line.
2. `LANGFLOW_KB_ALLOWED_HOSTS=localhost,127.0.0.1` appended to `.env` + restart — network KB
   backends refuse any destination not listed, and everything the UI configures is a global variable.
3. Global variables via `POST /api/v1/variables/` (`default_fields: []`): `OPENSEARCH_URL` and
   `OPENSEARCH_USERNAME` as `Generic`, `OPENSEARCH_PASSWORD` as `Credential`. A Credential-typed URL
   makes the provider modal read "Needs setup".
4. Verify: `POST /api/v1/knowledge_bases/test-connection` (body per `/openapi.json`) → 200.
5. Hand over: `environment.OpenSearch = "http://localhost:9200 — admin / <pw> — already configured
   as global variables"`; `notes`: a no-auth cluster accepts any password and Test Connection is
   liveness-only, so a wrong password still passes.

## Postgres (DB backend, pgvector, migration tests)

Homebrew PG 17 on `localhost:5432`, user `alice`, no password (`/opt/homebrew/opt/postgresql@17/bin`
on PATH): `createdb qa_<ticket>`; `CREATE EXTENSION vector` when pgvector is in scope. Container
alternative: `podman run -d --name qa-<T>-pg -p 5433:5432 -e POSTGRES_PASSWORD=qa postgres:16-alpine`.
Langflow: bring the slot up with `wt_up --extras "postgresql pgvector" LE-XXXX <pr>` (the extras are
re-added after `run_clic`'s `uv sync --frozen` and the relaunch goes through `.venv/bin/langflow`, so
they survive restarts); `LANGFLOW_DATABASE_URL=postgresql://alice@localhost:5432/qa_<ticket>` appended
to `.env`, `wt_restart`. Never `uv pip install` by hand, never `uv run`/`make` afterwards. Verify `/health_check` 200
and `psql qa_<ticket> -c '\dt'` lists the langflow tables.

## MCP testbed (any MCP ticket)

**Standing fixture: `testbed-http`** (Streamable HTTP on `localhost:8766`, admin API on `:9999`;
`curl localhost:9999/admin/health`). `podman start testbed-http` if stopped; **never remove it**.
Recreate only if gone: `podman run -d --name testbed-http -p 8766:8766 -p 9999:9999 -e TRANSPORT=http
-e PORT=8766 -e ADMIN_PORT=9999 -e NOOP_COUNT=50 -e AUTH_MODE=none localhost/langflow-mcp-testbed:latest http`
(the `docker-compose.yml` in `~/Langflow/langflow-mcp-testbed` also defines `testbed-sse` 8765/9998
and `testbed-http-auth` 8767/9997 for header/auth repros; stdio via `run-stdio.sh`). Skill:
`langflow-mcp-test-bed` for the tool families and the issue→tool matrix.
Register it in the instance: `POST /api/v2/mcp/servers/{name}` (payload shape in `/openapi.json`;
stdio = `{"command": …, "args": […]}`, http = `{"url": …}`), then `GET /api/v2/mcp/servers/{name}`
must return the tool list — that is the proof the MCP Tools component will load. Hand over the
server name as registered, the tools to expect, and a prebuilt flow with the MCP Tools node when the
item is "run a flow".

## Mock IdP / SSO (EE)

`~/Langflow/langflow-oidc-mock` (skill `langflow-oidc-mock`): detached
`uv run --with pyjwt --with cryptography python mock_oidc.py --port 5557`, verify
`curl localhost:5557/.well-known/openid-configuration`. Instance with `ee_up --sso`; create the
connection via API and run the test-login promotion so it is **enabled** (a PATCH never enables);
log each seeded identity in once. `Login` carries the IdP users (`admin.idp@orion.test`, "no
password — pick it in the mock"). Seed "Testing…" rows right before her item (they expire in 10 min).

## Provider keys and models

`set -a; source ${SKILL_DIR}/config/provider-secrets.env; set +a` → `POST /api/v1/variables/`
(`type: "Credential"`, `default_fields: ["api_key"]`) for the provider the ticket needs — only that
one — and verify with `GET /api/v1/models/enabled_models` or a single `/run`. Mini model always;
re-point any starter flow before the first run; name the model to pick in `notes`.

## Flows, data, files, personas

- Flow she must open: build it via API with the UI node shape (gotchas → "API-built flows"), open
  it in the browser once to see it draw, name it `QA <ticket> — <purpose>`, cite that name in the item.
  The flow lives in the instance; its JSON is built in the scratchpad and not saved anywhere.
- Knowledge / memory base: create via API, ingest a few chunks, verify `/mismatch` → false (or the
  chunk count) and cite the base name.
- Upload fixture: generate a whitelisted type (`.txt`, `.pdf`), sized for the test, **in the
  scratchpad**, upload once via `POST /api/v2/files/`, state the filename. The local copy is not
  kept — never in `files/`.
- EE personas: seed users / roles / teams via API (ee-gotchas → "Seed API shapes"), log each in once,
  one `*.localhost:<port>` host per persona in `Login`.
- Audit / history volume: seed via API with spread timestamps when the item is about ordering or
  relative time.

## S3 (file-storage tickets)

`python3 -m venv <scratch>/motoenv && <scratch>/motoenv/bin/pip install "moto[server]"`, run
`moto_server -H 127.0.0.1 -p 9000` detached; export `AWS_ENDPOINT_URL_S3=http://127.0.0.1:9000`,
`AWS_ACCESS_KEY_ID=test`, `AWS_SECRET_ACCESS_KEY=test`, `LANGFLOW_STORAGE_TYPE=s3` and the bucket
vars **in the shell that launches Langflow** (not `.env`); create the bucket with boto3; verify one
upload lands (`aws --endpoint-url … s3 ls` or boto3). MinIO is not pullable anonymously.

## Before handing over

One `environment` row per asset (URL, user, password, "already configured"); every credential she
might type in `Login`; `notes` only for traps. Re-check each asset is still up right before you
send the URL — a container that died during the build is her first "bug".
