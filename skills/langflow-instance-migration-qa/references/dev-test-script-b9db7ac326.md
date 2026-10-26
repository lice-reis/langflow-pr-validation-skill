---
type: test-script
status: current
created: 2026-10-06
updated: 2026-10-07
tags: [migration, LE-2395, qa, admin-ui]
---

# QA test script: Settings > Migration ("Move to a new instance")

**Verified on: b9db7ac326 (2026-10-07).**

The branch moves when a fix lands in a layer below it. The fixes of 2026-10-07 are in the pause API. They change
what a refused pause says, and no step of this script.

How this script was verified:

- Every command of sections 1, 3 and 4 was run on `b9db7ac326`, on an Apple Silicon Mac, with new containers
  and a new source folder.
- Every row of tests 1 to 9 was done in Chromium, in one tab, on a source that section 3 had just made new.
  A script pressed and typed what each row says. Every expected text was read from the page as a person
  sees it, in English.
- The browser saved the downloads to a scratch folder. The `sqlite3` command of test 5, row 3 ran on the
  file in that folder.

## What this covers

The page moves one Langflow instance to a new instance in ordered steps. This script tests steps 1 to 8 of
the page, and the way back ("Turn changes back on"). Steps 9 and 10 are not built yet. The page shows
"Coming soon" on them.

The script uses a small source instance that holds every awkward kind of row. The script uses a local
PostgreSQL database and a local S3 store as the new instance's storage. The script does not start a second
Langflow.

You need Docker, `uv`, Node 20.19 or newer, `psql`, `sqlite3`, `curl`, `python3`, and a checkout of the
branch under test. One full pass takes about 30 minutes.

## 1. Setup

Run every command from the root of the checkout, in one terminal, unless a step says otherwise.

If the shell has `AWS_PROFILE` or `PGVECTOR_CONNECTION_STRING` set, run this command first in every terminal
that this script uses:

```bash
unset AWS_PROFILE PGVECTOR_CONNECTION_STRING
```

### 1.1 Install

```bash
uv sync --frozen --extra postgresql --extra pgvector
(cd src/frontend && npm ci)
```

Do not run `make init`, `make install_backend`, `make backend` or `make run_cli` afterwards. Each of these
targets runs `uv sync --frozen --extra "postgresql"`. That command removes the `pgvector` package. Test 2
then stops at "Knowledge bases" with this line:

> This Langflow server doesn't have the pgvector package. Install it, restart Langflow, then test again.

If the page shows that line, stop terminal A. Run the `uv sync` command of this section again. Start
terminal A again.

### 1.2 Storage for the new instance

On an Apple Silicon Mac where Docker defaults to amd64, add `--platform linux/arm64` to both `docker run`
commands.

```bash
docker run -d --name lf-qa-pg -e POSTGRES_PASSWORD=qa-destination \
  -p 127.0.0.1:55440:5432 pgvector/pgvector:pg17
docker run -d --name lf-qa-s3 -p 127.0.0.1:28340:8333 \
  chrislusf/seaweedfs:4.47 server -s3 -s3.port=8333

# Wait about 10 seconds, then:
PGPASSWORD=qa-destination psql -h 127.0.0.1 -p 55440 -U postgres -c "create database langflow_new"
curl -s -o /dev/null -w '%{http_code}\n' -X PUT http://127.0.0.1:28340/lf-qa-files
```

Expected: `CREATE DATABASE`, and `200` from the `curl` command.

Do not run `CREATE EXTENSION vector` yet. Test 2 needs the database without the extension first.

### 1.3 The source instance

```bash
export QA=$HOME/langflow-migration-qa
mkdir -p $QA
uv run python -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode(), end='')" \
  > $QA/secret_key.txt

cat > $QA/source.env <<EOF
export LANGFLOW_SECRET_KEY=$(cat $QA/secret_key.txt)
export LANGFLOW_DATABASE_URL=sqlite:///$QA/langflow.db
export LANGFLOW_CONFIG_DIR=$QA/config
export LANGFLOW_KNOWLEDGE_BASES_DIR=$QA/kb
export LANGFLOW_FEATURE_INSTANCE_MIGRATION=true
export LANGFLOW_AUTO_LOGIN=true
export LANGFLOW_SUPERUSER=langflow
export LANGFLOW_SUPERUSER_PASSWORD=qa-source-admin
export DO_NOT_TRACK=true
EOF

source $QA/source.env
uv run python scripts/migration_rehearsal/seed_instance.py --chunks 300 --manifest $QA/manifest.json
sqlite3 $QA/langflow.db "select name, backend_type, chunks from knowledge_base order by name"
```

Expected from the last command:

```
fixture_memory_00000001|sqlite|2
kb-no-model|sqlite|5
kb-ok|sqlite|300
kb-stubbed-backend|astra|0
```

### 1.4 Start the source

Terminal A:

```bash
source $HOME/langflow-migration-qa/source.env
uv run uvicorn --factory langflow.main:create_app --host localhost --port 7860 --loop asyncio
```

Expected: terminal A prints `Uvicorn running on http://localhost:7860`.

Terminal B:

```bash
cd src/frontend
VITE_PROXY_TARGET=http://localhost:7860 VITE_PORT=3000 npm start -- --port 3000 --strictPort
```

Expected: terminal B prints a line that holds `http://localhost:3000/`.

If port 7860 or 3000 is in use, pick other ports. Use the same numbers in both commands, and in every
address and command of the tests.

### 1.5 Open the page

Open `http://localhost:3000/settings/migration`.

Expected:

- The settings menu has an entry "Migration". The page title is "Move to a new instance".
- The card "This instance" shows "Langflow 1.13.0", "SQLite database", "Knowledge bases on this server"
  and "Files on this server".
- Only the first step, "Check this instance", can be used. Every later step shows a lock in place of its
  number, and has no button.

## 2. Tests

Do the tests in order. Each test starts where the test before it ended.

- `<time>` stands for a date and a time.
- Use the terminal of section 1 for the commands in the tests. A new terminal needs
  `export QA=$HOME/langflow-migration-qa` first.

### Test 1: Check this instance

| # | Do | Expect |
| --- | --- | --- |
| 1 | In "New instance's Langflow version", type `0.1`. Press "Run the check". | "Older than this instance. Use 1.13.0 or newer. Preview builds of that version count as older." No check runs. |
| 2 | Type `1.13.0` (the field shows it as its placeholder). Press "Run the check". | A progress line that starts at "Checking: 0 of 12". Then "Problems that stop the move: 2" and "Checked <time> by langflow against Langflow 1.13.0." |
| 3 | Read the groups. | "Fix or accept": "Files" and "Knowledge bases". "Read these": "Embedding models" and "Roles". "Passed: 8". 12 checks in total. |
| 4 | Open "Details" on "Files". | "1 of 2 file rows point at bytes storage does not hold", and a line that ends with "(absolute.txt): no bytes in storage". |
| 5 | Open "Details" on "Knowledge bases". | "1 of 4 knowledge bases have a backend that cannot be built or reached", and a line that starts with "langflow/kb-stubbed-backend (astra)". |
| 6 | Look at step 2, "Where your data goes". | Still locked: a lock in place of its number, and no button. |
| 7 | On "Files", tick "Accept. These files stay missing on the new instance." | Under the checkbox: "Accepted by langflow on <time>." Step 1 shows "Problems that stop the move: 1". |
| 8 | On "Knowledge bases", tick "Accept. They're listed on the new instance but won't work." | Under the checkbox: "Accepted by langflow on <time>." Step 1 shows "Checked <time>. Nothing stops the move." Step 2 opens with its form. |
| 9 | At the end of the page, press "Download the migration record (for support)". | A file `langflow-migration-<date>.json` downloads. `<date>` is the date as 8 digits. |

### Test 2: Where your data goes

Values for the form:

| Field | Value |
| --- | --- |
| Connection address | `postgresql://postgres:qa-destination@127.0.0.1:55440/langflow_new` |
| Bucket | `lf-qa-files` |
| Folder in the bucket | `files` (the field already holds it) |
| Access key ID | `qa` |
| Secret access key | `qa-secret` |
| Endpoint | `http://127.0.0.1:28340` |

"Connection address" and "Secret access key" show dots in place of the text. Paste those two values.

| # | Do | Expect |
| --- | --- | --- |
| 1 | Fill the form, but use `wrong-pass` in place of `qa-destination`. Press "Test and save". | Database: "Can't connect to this database.", with the database's own message below it. The message ends with "password authentication failed for user "postgres"". Knowledge bases: the same two lines. Files: "Ready." The form keeps its values. The step stays open. |
| 2 | Enter the connection address again, with the correct password. Press "Test and save". | Database: "Ready." Knowledge bases: "The database needs the pgvector extension. Ask your database admin to turn it on." and "Run CREATE EXTENSION vector; in this database, then test again." Files: "Ready." The step stays open. |
| 3 | In a terminal: `PGPASSWORD=qa-destination psql -h 127.0.0.1 -p 55440 -U postgres -d langflow_new -c "create extension vector"`. Press "Test and save" again. | The step closes. It shows "Database: 127.0.0.1:55440/langflow_new · Knowledge bases: PostgreSQL · Files: lf-qa-files", "Saved <time> by langflow." and a button "Change or enter again". Step 3 opens. |
| 4 | Read the whole page. | The words `qa-destination`, `wrong-pass` and `qa-secret` appear nowhere. |
| 5 | In a terminal: `grep -c "qa-destination\|qa-secret" $QA/config/migrations/migration.json`. | `0`. |

If row 2 shows "This Langflow server doesn't have the pgvector package. Install it, restart Langflow, then
test again." under "Knowledge bases", the server runs without the `pgvector` extra. Do what section 1.1
says. Then fill the form again and press "Test and save".

### Test 3: Hand over the secret key

| # | Do | Expect |
| --- | --- | --- |
| 1 | Read the step. | "This instance's secret key is set in its LANGFLOW_SECRET_KEY environment variable." The step shows the command `printf '%s' "$LANGFLOW_SECRET_KEY" \| sha256sum \| cut -c1-12` and the note "On macOS, use shasum -a 256 in place of sha256sum." The key itself is not on the page. |
| 2 | Type `aaaaaaaaaaaa` in "What the command printed". Press "Verify". | The field turns red. "This doesn't match this instance's key. Paste all 12 characters as printed. If it still doesn't match, the new instance has a different or empty key." |
| 3 | In a terminal: `source $QA/source.env; printf '%s' "$LANGFLOW_SECRET_KEY" \| shasum -a 256 \| cut -c1-12` (on Linux, `sha256sum` in place of `shasum -a 256`). Paste the result. Press "Verify". | "Verified <time> by langflow." Step 4 opens. |

### Test 4: Pause changes

The source holds one run that waits for a person's answer. That run does not stop the pause.

| # | Do | Expect |
| --- | --- | --- |
| 1 | Press "Pause changes". | A dialog "Pause changes now?" with "Tell people first. Changes stay paused until the move is done or you turn them back on." and the buttons "Pause" and "Cancel". |
| 2 | Press "Pause". | The step shows "Changes are paused. Running the check again… Checking: 0 of 12" and counts up. Then "Paused <time> by langflow." A banner on the page: "Changes are paused on this instance. Paused <time> by langflow." with a button "Turn changes back on". Step 5 opens. |
| 3 | In a terminal, try a write: `curl -s -X POST http://localhost:7860/api/v1/flows/ -H 'Content-Type: application/json' -H "Authorization: Bearer $(curl -s http://localhost:7860/api/v1/auto_login \| python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')" -d '{"name":"qa-paused","data":{"nodes":[],"edges":[]}}'` | `{"detail":"This instance is being migrated."}` |
| 4 | Open `http://localhost:3000/` in the browser. | The page loads. It shows the projects "nested-project" and "root-project", and the flow "shared-flow". Reading still works. |

### Test 5: Back up this instance

| # | Do | Expect |
| --- | --- | --- |
| 1 | Open `http://localhost:3000/settings/migration` again. Read step 5. | A button "Download the database". "Knowledge bases folder: <path>" and "Files folder: <path>", with the paths under `$QA`. The button "I've backed up everything" cannot be pressed. Under it: "Download the database first." |
| 2 | Press "Download the database". | A file `langflow-backup-<date>.db` downloads. The step shows "Downloaded <time>." The line "Download the database first." is gone. |
| 3 | In a terminal: `sqlite3 ~/Downloads/langflow-backup-*.db "pragma integrity_check; select count(*) from flow"`. | `ok`, and the same number as `sqlite3 $QA/langflow.db "select count(*) from flow"`. |
| 4 | Leave "Where is the backup?" empty. Press "I've backed up everything". | The cursor moves to the field. The browser shows its own message at the field. In Chrome the message is "Please fill out this field." The step stays open. |
| 5 | Type `qa bucket, folder backups/2026-10` in "Where is the backup?". Press "I've backed up everything". | "Backed up <time> to qa bucket, folder backups/2026-10." Step 6 opens. |

### Test 6: Copy the database

| # | Do | Expect |
| --- | --- | --- |
| 1 | Read step 6. | "Copies every table in one go. If anything fails, nothing is kept and you can copy again." One button: "Copy the database". |
| 2 | Press "Copy the database". | For a few seconds the step shows a button "Stop" and progress lines such as "Preparing the new database…" and "Rows: <n> of 106". Then the step shows "Tables: 59. Rows: 106." and a button "Copy again". Step 7 opens. |
| 3 | In a terminal: `PGPASSWORD=qa-destination psql -h 127.0.0.1 -p 55440 -U postgres -d langflow_new -Atc "select count(*) from flow"`. | The same number as `sqlite3 $QA/langflow.db "select count(*) from flow"`. |

### Test 7: Copy knowledge bases

| # | Do | Expect |
| --- | --- | --- |
| 1 | Read step 7. | "A test run says what would be copied and copies nothing. Copying again skips what is already there." Two buttons: "Copy knowledge bases" and "Test run". |
| 2 | Press "Test run". | After a few seconds: "Test run: nothing was copied. To copy: 0. Already copied: 0. Can't be copied: 4." A list of four. "kb-ok (langflow)", "kb-no-model (langflow)" and "fixture_memory_00000001 (langflow)" each say "The new instance ranks search results a different way for this one." "kb-stubbed-backend (langflow)" says "It uses a store this version can't open." Under the list, one checkbox: "Accept the new ranking for every knowledge base listed with it. Search order may change. Tell the owners." Step 8 stays locked. |
| 3 | Open "Details" on "kb-ok". | The tool's own words. They start with "the source ranks by l2 distance and the target by cosine". |
| 4 | Tick "Accept the new ranking for every knowledge base listed with it." | Under the checkbox: "Accepted by langflow on <time>." and "This applies to the next copy." |
| 5 | Press "Copy knowledge bases". | For a few seconds the step shows a button "Stop" and progress lines such as "Entries: 300 of 300". Then "Copied: 3. Already copied: 0. Not copied: 1." In red: "Some were not copied. Each one below says why." Then "Accepting a finding in 'Check this instance' lets the move go on. This copy names each one it left, so each is accepted here, for this copy only." The list holds only "kb-stubbed-backend (langflow)", with a checkbox "Leave it behind". The buttons are "Copy again" and "Test run". Step 8 stays locked. |
| 6 | Tick "Leave it behind". | The red line goes away. Under the checkbox: "Accepted by langflow on <time>." Step 7 shows "Copied: 3 of 4". Step 8 opens. |
| 7 | In a terminal: `PGPASSWORD=qa-destination psql -h 127.0.0.1 -p 55440 -U postgres -d langflow_new -Atc "select name, backend_type, chunks from knowledge_base order by name"`. | Four lines: `fixture_memory_00000001\|postgres\|2`, `kb-no-model\|postgres\|5`, `kb-ok\|postgres\|300`, `kb-stubbed-backend\|astra\|0`. |

### Test 8: Copy files

| # | Do | Expect |
| --- | --- | --- |
| 1 | Read step 8. | "A test run says what would be copied and copies nothing. Copying again skips what is already there." Two buttons: "Copy files" and "Test run". |
| 2 | Press "Test run". | After a few seconds: "Test run: nothing was copied. To copy: 1. Already copied: 0. Can't be copied: 1." One file in the list: "absolute.txt (00000001-aaaa-4000-8000-000000000000)", with "Nothing is stored for this name, so there is nothing to copy. It will show as missing." The list has no checkbox. |
| 3 | Press "Copy files". | After a few seconds: "Copied: 1. Already copied: 0. Not copied: 1." In red: "Some were not copied. Each one below says why." The list holds the same file, now with a checkbox "Move without this file". The buttons are "Copy again" and "Test run". |
| 4 | Tick "Move without this file". | The red line goes away. Under the checkbox: "Accepted by langflow on <time>." Step 8 shows "Copied: 1 of 2". Steps 9 and 10 show "Coming soon". |
| 5 | Untick "Move without this file". | The red line comes back. Steps 9 and 10 no longer show "Coming soon". |
| 6 | Tick "Move without this file" again. | The same as row 4. |
| 7 | In a terminal: `curl -s http://127.0.0.1:28340/lf-qa-files/files/00000001-aaaa-4000-8000-000000000000/logical.txt`. | `fixture-bytes` |

### Test 9: Turn changes back on

| # | Do | Expect |
| --- | --- | --- |
| 1 | In the banner, press "Turn changes back on". | A dialog "Turn changes back on?" with "People can work again. The backup and any copies made so far become out of date, so you'll pause and make them again before you move." and the buttons "Resume" and "Cancel". |
| 2 | Press "Resume". | The banner goes away. Steps 1 to 3 keep their results. Step 4 shows the button "Pause changes" again. Steps 5 to 10 show a lock and no button. |
| 3 | In a terminal, run the `curl` command of test 4, row 3 again. | An answer that starts with `{"name":"qa-paused"`. The write works again. |
| 4 | Press "Pause changes". | The dialog "Pause changes now?". |
| 5 | Press "Pause". | The same as test 4, row 2. Step 5 opens again. The button "I've backed up everything" cannot be pressed. Under it: "Download the database first." |
| 6 | Press "Download the database". | The step shows "Downloaded <time>." |
| 7 | Type `qa bucket, folder backups/2026-10-b` in "Where is the backup?". Press "I've backed up everything". | Step 6 opens. It shows "This copy is out of date, so it no longer counts. Copy again." and one button: "Copy again". |
| 8 | Press "Copy again". | "Tables: 59. Rows: 107." The count is one more than in test 6: the flow from row 3. Step 7 opens. It shows "This copy is out of date, so it no longer counts. Copy again." and the buttons "Copy again" and "Test run". |

### Test 10: A user who is not an admin

Not a browser test. The source signs every visitor in as the admin, so the browser cannot show this case.

On `b9db7ac326`, each of the 14 routes under `/api/v1/migration` answered 403 to a signed-in user who is not
a superuser. Each route also answered 403 to a request with no sign-in.

## 3. Start over

Stop terminals A and B first. If you added `--platform linux/arm64` in section 1.2, add it to the
`docker run` command here too. Then:

```bash
rm -rf $HOME/langflow-migration-qa
PGPASSWORD=qa-destination psql -h 127.0.0.1 -p 55440 -U postgres \
  -c "drop database if exists langflow_new" -c "create database langflow_new"
docker rm -f lf-qa-s3
docker run -d --name lf-qa-s3 -p 127.0.0.1:28340:8333 \
  chrislusf/seaweedfs:4.47 server -s3 -s3.port=8333

# Wait about 10 seconds, then:
curl -s -o /dev/null -w '%{http_code}\n' -X PUT http://127.0.0.1:28340/lf-qa-files
```

Expected: `DROP DATABASE`, `CREATE DATABASE`, and `200` from the `curl` command.

Then do sections 1.3, 1.4 and 1.5 again.

## 4. Remove everything

Stop terminals A and B first. Then:

```bash
docker rm -f lf-qa-pg lf-qa-s3
rm -rf $HOME/langflow-migration-qa
```

## 5. Which tickets each test shows

This section is a map. It was written on 2026-10-07 from the "Done when" line of each ticket. It is not part
of the walk that verified sections 1 to 4.

Use the branch `fix/migration-page-rehearsal-findings` (PR #15624). The branch holds every layer that this
script tests, so one pass of this script exercises every ticket in the table.

| Where | Tickets |
| --- | --- |
| Section 1.3 | LE-2897: the fixture seeds on 1.13, and the stores read back 300, 5 and 2 chunks. |
| Test 1 | LE-2913, LE-2914, LE-2915, LE-2916 |
| Test 2 | LE-2943, LE-2947. Row 1 is LE-2946: knowledge bases fail as the database did. |
| Test 3 | LE-2944, LE-2948 |
| Test 4 | LE-2910, LE-2942, LE-2949 |
| Test 5 | LE-2945, LE-2950 |
| Test 6 | LE-2918, LE-2951, LE-2966 |
| Test 7 | LE-2893, LE-2952, LE-2953, LE-2967, LE-2968. Row 4 is LE-2969: "This applies to the next copy." |
| Test 8 | LE-2952, LE-2953, LE-2967. Rows 3 to 6 are the "Done when" of LE-2968. |
| Test 9 | LE-2942, LE-2949. Row 2 is LE-2950: the backup step locks again. Rows 7 and 8 are LE-2951: a copy counts only for its own pause. |
| Test 10 | LE-2915: a user who is not a superuser gets 403. |

Seven tickets are for an API with no page of its own: LE-2942 to LE-2945 and LE-2951 to LE-2953. Each of
their PR descriptions has a curl session, and the ticket is done when that session gives the answers it shows.
The tests above exercise the same routes through the page. The tests do not send every refusal of a curl
session.

This script does not show these parts of a "Done when" line:

- LE-2910: a paused record changes nothing while the feature flag is off.
- LE-2913 and LE-2914: the two commands in a terminal. The page runs both commands in test 1.
- LE-2916: the page with the feature flag off.
- LE-2947: a wrong port. Row 1 of test 2 uses a wrong password in its place.
- LE-2954: another folder of the bucket, saved after the three copies.
- LE-2966: a reload of the page during the copy, and a restart of the backend after the copy.
- LE-2969: the console check of the PR description.
- LE-2918 and LE-2965: each ticket is done when its test file passes in CI.
