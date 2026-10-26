# Engineering Plan: OSS to Enterprise Migration Path (as shared by Alice, 2026-10-07)

## Problem & Desired Outcome
A team running Langflow OSS in production cannot become an IBM Langflow customer without abandoning their
work. Flows export. Credentials, files, knowledge bases, agent memory, run history, and user accounts do not.

**Done means:** a person signs in with the account they already had, opens the project they already had,
and runs a flow that reads a credential, a file, and a knowledge base.

## Assumptions & Scope Boundaries
**Delivered.** An IBM Langflow deployment adopts the existing OSS database rather than importing an export.
Knowledge base and memory base vectors and uploaded files relocate to the configured backends. Role
assignments survive, so the people who had access keep it. Secrets keep working. Someone other than the
author can follow the documented path.

**Not delivered:**
- No portable file. Nothing is exported. If the new deployment cannot reach the old database, this does not help.
- Flows are not guaranteed to run. The enterprise image disables custom components, the code interpreter,
  local file access, loopback connectors, and unlisted MCP packages. Flows using those break by policy.
- Enforcement stays off. Migration makes role assignments resolve. Setting `AUTHZ_ENABLED`, and checking the
  result as an ordinary user, is an operator step.
- Authorship is not recovered. Under auto-login every flow belongs to one account and nothing recorded who made what.
- SSO identity mapping is Eric's, tracked separately.
- No rollback. Attaching the deployment migrates the schema forward and the team's own install may no longer
  open its database. A snapshot is the only way back.
- Serving plane is out of scope. OSS has no concept of one.

## Solution Shape
Local Python Process → Hosted Application: filesystem state and auto-login on one side, shared backing
services and an external secret key on the other.

- **Database adopted in place.** `langflow-enterprise` defines no tables and re-exports its models from
  Langflow, so an OSS database is already an IBM Langflow database. Attaching it is configuration. A portable
  bundle format was dropped.
- **Secrets re-encrypted** under the new instance's key (alternative: carry the customer's key across).
  Neither helps a team whose key is already lost.
- **Roles need no remapping.** System role ids are the only per-install ids; rewriting the target's three to
  match the source, before any other row is copied, lets everything else carry verbatim (three UPDATEs inside
  the conversion). See migration-path.md.
- **Build 1 — vectors and files move.** A memory base refers to a `knowledge_base` row, so one path covers
  both. Reading chunks with vectors works on Chroma, OpenSearch, pgvector. Langflow's interface had no
  vector-preserving write (only re-embed, which needs provider credentials and changes vectors). OpenSearch
  and Chroma accept precomputed vectors → one interface method, two thin adapters, one real Postgres
  implementation. Vectors copy where embedding model and dimensions match, decided **per knowledge base**.
  Files go to object storage.
- **Build 2 — SQLite → Postgres.** No dump tool crosses engines. A naive row copy failed all eight tables
  holding data (SQLite has no boolean; alembic seeds rows the source also has). Shipping behaviour: type
  coercion + **upsert** (not skip) for seeded tables — four hold customer configuration. Secondary priority
  (SQLite + local Chroma + auto-login = an individual, not a team).

## Sizing & Risks
3 weeks. Relocation drives existing backend interfaces + one write method. Conversion = row move with type
coercion, upsert for co-seeded rows, three UPDATEs to align role ids, idempotent re-runs. Re-encryption reuses
existing helpers. **Version preflight, image label, telemetry field are hours each.** Paused runs carry live
state that has to move. Every copy needs reconciling against a count (default vector store truncates silently).

Verification is easy to get wrong: `AUTHZ_SUPERUSER_BYPASS` defaults true, and ownership still grants access,
so an ordinary user opening their own flows proves nothing. Use a check the owner override cannot mask
(e.g. creating a project).

Risks, most significant first:
- **Silent failure modes.** Wrong secret key returns an empty string (warning hidden by default log level).
  Chroma stops mid-read on error → partial copy looks complete; reconcile against a count. `authz_share` has
  no FK on either id → stale values insert cleanly and grant nothing. A WAL-mode SQLite file copy can open fine
  and be empty. Ownership masks failed role migration.
- **Nothing enterprise tested yet.** DB move and vector copy (Chroma → pgvector, all vectors preserved) were
  run; files not; no Casbin, SSO, image hardening or operator behaviour.
- "Their flows still work" may be false for policy reasons (relax a default or rework flows).
- Population unknown: telemetry omits the database dialect.
- Identity is on someone else's path: no SSO sign-in for migrated users until mapping lands.
- Documentation will mislead: contradicts the operator CRD on attaching a database, never mentions the secret
  key, describes a licence key nothing validates.
