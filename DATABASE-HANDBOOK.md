# Kendall DOM — Database Build Handbook

**Repository:** `Kendall-DOM`
**Database:** PostgreSQL 18, hosted on Railway (project *PMO Digital Operating Model*, service `DOM1`)
**Audience:** anyone writing migrations or loading data for this project

---

## 1. What we are building

We modeled part of the PMO's project intake process as a set of entities and the relationships between them — process steps, gates, decisions, artifacts, workflow paths, roles, systems, metric hooks, governance items, and source documents. That model currently lives in spreadsheets and a SharePoint-shaped schema design.

We are moving it into a **relational PostgreSQL database**.

### Why a database and not a spreadsheet

A spreadsheet can *record* that GATE-002 requires ART-003. It cannot *enforce* it, and it cannot answer a question that requires following a chain of relationships to an unknown depth.

The questions we want to answer are chain questions:

- If we eliminate this approval gate, what stops working?
- Which process steps have no owning role?
- Which artifacts are produced but never consumed by anything downstream?
- Which metrics have no source system behind them?

Those require real foreign keys and recursive queries. That is what a relational database gives us and a spreadsheet cannot.

### Scope: the PMO, and only the PMO

**Build this for the PMO's intake process specifically. Do not try to make it serve other departments yet.**

There is a longer-term idea that the same approach could model Purchasing or IT processes. That is a later step, and deliberately so. Designing for a second department before we have modeled one means designing for imagined requirements — and would likely produce something that fits neither domain well. The right time to generalize is after there is a real second process to compare against.

So: model the PMO's process accurately and specifically. Do not add abstraction layers, department columns, or configuration tables for use cases that do not exist yet.

There is exactly one cheap hedge, in section 7.4. It costs nothing and is worth taking.

---

## 2. Ground rules

These are the non-negotiables. Everything else in this document is explanation.

| # | Rule |
|---|------|
| 1 | **Never commit a password, connection string, or credential.** Not in a `.sql` file, not in a comment, not "temporarily." |
| 2 | **All schema changes go in a numbered migration file.** Never change structure by clicking around in a GUI. |
| 3 | **Once a migration has been run against the real database, never edit it.** Write a new migration to fix it. |
| 4 | **Test every migration against your local sandbox first.** Commit only after it runs clean. |
| 5 | **Wrap every migration in `BEGIN;` / `COMMIT;`.** |
| 6 | **Do not prefix table names.** `gate`, not `pmo_gate`. See 7.4. |
| 7 | **You do not have access to the production database.** Brad applies migrations. This is by design, not distrust. |

---

## 3. One-time setup

You only do this section once (or again if your Codespace is rebuilt).

### 3.1 Open the repository

Open `Kendall-DOM` in a **GitHub Codespace** (green *Code* button on the repo page → *Codespaces* → create). A Codespace is a full Linux machine in the cloud with the repo already cloned. Your terminal opens in `/workspaces/Kendall-DOM`.

Everything below happens in that terminal.

### 3.2 Install the PostgreSQL client

`psql` is the command-line tool that talks to a Postgres database. It is not a database itself.

```bash
psql --version
```

If that says "command not found":

```bash
sudo apt update && sudo apt install -y postgresql-client
```

### 3.3 Install a local sandbox database

This is *your* database. It is disposable, nobody else can reach it, and breaking it costs nothing. This is where you test everything.

```bash
sudo apt install -y postgresql
sudo service postgresql start
```

Create a role and database matching your Linux user so you never need a password:

```bash
sudo su -c "psql -U postgres" postgres
```

At the `postgres=#` prompt:

```sql
CREATE ROLE codespace LOGIN SUPERUSER;
CREATE DATABASE codespace OWNER codespace;
\q
```

> If your Linux username is not `codespace`, use whatever `whoami` prints.

Now test it:

```bash
psql
```

You should land at `codespace=#` with no password prompt. That is your sandbox.

### 3.4 After every Codespace restart

The Postgres *service* does not auto-start. Your data survives; the service needs waking up:

```bash
sudo service postgresql start
```

If the Codespace is ever **rebuilt** (not just restarted), everything installed above is gone and you repeat section 3. Your migration files are safe — they live in git.

---

## 4. The daily workflow

```
  git pull                    ← get the latest before you start
     ↓
  write migrations/0NN_*.sql  ← in the editor
     ↓
  test against sandbox        ← psql -f
     ↓
  fix and re-test             ← repeat until clean
     ↓
  git add / commit / push     ← share it
     ↓
  Brad applies it to DOM1     ← you are done
```

### 4.1 Start every session with a pull

```bash
git pull
```

This pulls down anything Brad or anyone else changed. Doing this first avoids merge conflicts later.

### 4.2 Write the migration

Create the file in the `migrations/` folder, named `NNN_short_description.sql`:

```bash
touch migrations/003_add_artifact_table.sql
```

The number is the **run order**. Look at what already exists and take the next number. Never reuse one.

Click the file in the Explorer panel on the left to edit it. Save with `Ctrl+S`.

### 4.3 Test against your sandbox

```bash
psql -f migrations/003_add_artifact_table.sql
```

`-f` means "run the SQL in this file." You will see one line of output per statement (`CREATE TABLE`, `INSERT 0 1`, and so on), or an error naming the exact problem.

**If it errors:** fix the file and run it again. Because the migration is wrapped in `BEGIN`/`COMMIT`, a failure rolls back everything — the database is untouched and you can just re-run.

### 4.4 Reset the sandbox when you need a clean slate

Testing repeatedly leaves leftovers. To start over from nothing:

```bash
psql -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
```

Then run every migration in order to rebuild:

```bash
for f in migrations/*.sql; do psql -f "$f" || break; done
```

**Do this before your final test.** It proves your migrations work from an empty database, which is exactly the condition they will face on the real one.

### 4.5 Commit and push

```bash
git status
```

Always look before you add. Confirm you see only the files you meant to change.

```bash
git add migrations/003_add_artifact_table.sql
git commit -m "Add artifact table with FK to process_step"
git push
```

- **`add`** stages the file — marks it for inclusion
- **`commit`** records it in your local history with a message
- **`push`** sends it to GitHub where Brad can see it

Write commit messages for the person reading them in six months. `"Add artifact table with FK to process_step"` is useful. `"updates"` is not.

### 4.6 Tell Brad

Commit and push does not apply the migration to the real database. Say when something is ready.

---

## 5. Migration file structure

Every migration follows this shape:

```sql
-- 003_add_artifact_table.sql
-- Adds the artifact entity and its link to the producing process step.
-- Depends on: 002 (process_step)

BEGIN;

CREATE TABLE artifact (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    artifact_code     text   NOT NULL UNIQUE,
    name              text   NOT NULL,
    description       text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT artifact_code_format CHECK (artifact_code ~ '^ART-[0-9]{3}$')
);

COMMIT;
```

### Why `BEGIN` / `COMMIT`

Without them, if statement 7 of 12 has a typo, statements 1–6 already ran and 7–12 did not. You are left with a half-built schema, and re-running fails because the first six objects now exist.

With them, Postgres treats the file as one unit. Any error rolls the whole thing back. You fix the typo and re-run cleanly.

**This is the single most valuable habit in this project.**

### The header comment

Three lines: filename, what it does, what it depends on. Costs ten seconds. Saves an hour when someone is trying to reconstruct the order six months from now.

---

## 6. SQL conventions

Follow these exactly so the schema stays consistent.

### Naming

| Thing | Convention | Example |
|---|---|---|
| Table | `snake_case`, **singular**, **no prefix** | `process_step`, not `ProcessSteps` or `pmo_step` |
| Column | `snake_case` | `sequence_no` |
| Primary key | always `id` | `id` |
| Foreign key | `<referenced_table>_id` | `process_step_id` |
| Business key | `<table>_code` | `gate_code` |
| Boolean | starts with `is_` or `has_` | `is_mandatory` |
| Constraint | `<table>_<column>_<rule>` | `artifact_code_format` |

No spaces, no capitals, no reserved words (`order`, `user`, `group` — add a prefix if you need them).

### Every table gets these

```sql
id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
<x>_code     text NOT NULL UNIQUE,
name         text NOT NULL,
created_at   timestamptz NOT NULL DEFAULT now(),
updated_at   timestamptz NOT NULL DEFAULT now()
```

**Two keys, on purpose.** `id` is the surrogate key — a meaningless number the database assigns, used by foreign keys. `<x>_code` is the business key — `GATE-001`, the thing humans read and say out loud.

Why both: business keys sometimes have to change. If forty foreign keys point at `id`, renaming `GATE-001` to `GATE-010` is a one-row update. If they pointed at the code, it is a forty-table cascade.

Always use `timestamptz`, never plain `timestamp`. It stores the timezone.

### Constraints go in the table definition

Not added later, not enforced by the app. In the table.

```sql
name              text   NOT NULL,                               -- required
gate_code         text   NOT NULL UNIQUE,                        -- required and no duplicates
process_step_id   bigint NOT NULL REFERENCES process_step(id),   -- must point at a real row
sequence_no       integer,                                       -- nullable, deliberately
is_active         boolean NOT NULL DEFAULT true,                 -- filled in if omitted

CONSTRAINT gate_code_format CHECK (gate_code ~ '^GATE-[0-9]{3}$')    -- pattern enforced
```

Decide nullability **per column**. "Can this legitimately be blank?" If no, `NOT NULL`.

The `CHECK` constraint with `~` (regex match) is what turns our ID prefix convention from a habit into something the database enforces. Every entity table should have one.

### Insert data by lookup, not by hardcoded ID

**Do not do this:**

```sql
INSERT INTO gate (gate_code, name, process_step_id)
VALUES ('GATE-001', 'Intake Review', 3);
```

The `3` assumes that process step happened to get id 3. Rebuild the database in a different order and this silently attaches to the wrong thing.

**Do this:**

```sql
INSERT INTO gate (gate_code, name, process_step_id)
SELECT 'GATE-001', 'Intake Review', ps.id
FROM   process_step ps
WHERE  ps.step_code = 'STEP-002';
```

`SELECT` instead of `VALUES`. It looks up the row by its business code and uses whatever id it actually has. Portable, order-independent, correct every time.

**This is the most common mistake in seed data. Do not skip it.**

### Multiple rows in one statement

```sql
INSERT INTO gate (gate_code, name)
VALUES
    ('GATE-001', 'Intake Review'),
    ('GATE-002', 'Funding Approval'),
    ('GATE-003', 'Charter Approval');
```

All rows land or none do.

---

## 7. Schema design guidance

This is the thinking part, and it matters more than the syntax.

### 7.1 The SharePoint lists are not the tables

The schema design has 11 SharePoint lists. **Do not transcribe them one-for-one into 11 tables.**

Some of those lists exist only because SharePoint could not do real relationships. Now that we have foreign keys:

- Several **paired forward/reverse relationships** collapse into a single foreign key. A reverse view is generated with a query, not stored as duplicate rows. Storing both directions means they can disagree, and eventually they will.
- Some lists are **lookup tables** (entity types, statuses, path types), not entities. They get their own small tables with a code and a name.
- The **polymorphic `Entity Type` + `Entity ID` text pattern** was a workaround for a SharePoint limitation. See below.

Do a deliberate pass over the Entity Definitions and Schema v1 with fresh eyes before writing anything. **Ask about anything that looks like it exists only because of a tool limitation.**

### 7.2 Polymorphic references

Where a field can point at more than one kind of entity, we no longer need the text-prefix hack. Two better options:

**Option A — one nullable FK column per target, with a check that exactly one is set:**

```sql
CREATE TABLE relationship (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_step_id     bigint REFERENCES process_step(id),
    from_gate_id     bigint REFERENCES gate(id),
    from_artifact_id bigint REFERENCES artifact(id),

    CONSTRAINT one_source CHECK (
        (from_step_id IS NOT NULL)::int
      + (from_gate_id IS NOT NULL)::int
      + (from_artifact_id IS NOT NULL)::int = 1
    )
);
```

Good for 3–5 possible targets. Real referential integrity on every column.

**Option B — a supertype `element` table** that every entity registers in, with relationships pointing at `element(id)`. Cleaner if the number of targets is large or growing. More upfront work.

**Discuss which before building.** This decision shapes everything downstream, including whether the impact-analysis queries are easy or painful.

### 7.3 Relationships need three extra columns

This is important and easy to miss. A relationship is not just "A connects to B." Add:

```sql
relationship_type   text    NOT NULL REFERENCES relationship_type(code),
is_mandatory        boolean NOT NULL DEFAULT true,
alternative_group   text
```

- **`relationship_type`** — `produces`, `requires`, `governs`, `measures`, `informs`. Different types fail differently. Removing a *governing* policy does not stop a gate; removing a *required* input does.
- **`is_mandatory`** — an optional input missing means the gate runs **degraded**, not blocked. That distinction is where the most interesting findings live: the approval that still happens, but with less evidence behind it.
- **`alternative_group`** — relationships sharing a group value are OR'd. If a gate accepts either a Business Case *or* an executive sponsor memo, they share a group, and losing one changes nothing.

**These three columns come from interviews, not from the existing documents.** For each of the 47 relationships you will need to ask the process owner: *is this required, or does it just inform? Is there an alternative that satisfies the same need?*

That question usually has a real answer that nobody has ever written down. Capturing it is the highest-value work in this project.

### 7.4 The one free hedge: do not prefix table names

Call the table `gate`, not `pmo_gate`. Same for every other table.

This is **not** a request to build for other departments — section 1 is clear that we are not doing that. It is simply that the unprefixed name costs exactly the same to type today. If the PMO stays the only user of this database forever, nothing has been lost. If a second department ever comes along, we have avoided a pointless rename.

Free options are worth taking. Paid ones are not, which is why there is no department column, no configuration table, and no abstraction layer in this schema.

If a general concept has a natural name, use it (`gate`, `artifact`, `decision`). If a concept is genuinely specific to how the PMO works, name it accurately rather than contorting it into something generic. **Accuracy beats generality.** A wrong general name is worse than a right specific one.

---

## 8. Loading data

Once the schema is stable, most data entry will happen through **NocoDB** — a spreadsheet-style interface pointed at the real database. You will get a URL and a login. You will never need a connection string or a Railway account.

NocoDB gives you dropdowns for foreign keys and enforces required fields, so it is much safer than typing raw SQL against production.

**Important:** NocoDB may appear to let you add a column. It cannot — the account it uses has no permission to change structure. Structural changes always come back to a migration file.

Small reference data (lookup tables, entity types, statuses) should live in migration files as seed inserts, so a rebuilt database comes up complete. Bulk transactional data goes through NocoDB.

---

## 9. Command reference

```bash
# --- git ---
git pull                          # get latest changes
git status                        # what has changed (run this constantly)
git add <file>                    # stage a specific file
git add .                         # stage everything not gitignored
git commit -m "message"           # record locally
git push                          # send to GitHub
git log --oneline                 # recent history
git diff                          # what you changed but have not staged

# --- postgres service ---
sudo service postgresql start     # after every Codespace restart
sudo service postgresql status    # is it running

# --- sandbox database ---
psql                              # interactive prompt
psql -f migrations/003_x.sql      # run a migration file
psql -c "SELECT * FROM gate;"     # run one statement and exit

# reset to empty
psql -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# rebuild from all migrations, stopping at the first failure
for f in migrations/*.sql; do psql -f "$f" || break; done
```

### Inside psql

```
\dt                 list tables
\d table_name       describe a table — columns, types, constraints
\du                 list roles
\l                  list databases
\q                  quit
\?                  all backslash commands
\h CREATE TABLE     help on a SQL command
```

Backslash commands need no semicolon. **SQL statements do.** If your prompt turns into `codespace-#` and nothing happens, you forgot the semicolon — type `;` and press Enter.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `relation "x" does not exist` | Referencing a table that has not been created yet | Check migration order — parents before children |
| `bash: CREATE: command not found` | You typed SQL at the bash prompt | Run `psql` first; look for `codespace=#` |
| Prompt shows `codespace-#` and hangs | Missing semicolon | Type `;` and Enter |
| `duplicate key value violates unique constraint` | That code already exists | Working as designed — check your data |
| `violates foreign key constraint` | Pointing at a row that does not exist | Insert the parent first, or fix the lookup |
| `violates check constraint` | Value does not match the required pattern | Check the ID format, e.g. `GATE-001` not `G-1` |
| `psql: could not connect` | Service not running | `sudo service postgresql start` |
| `permission denied for table` | Wrong role | You should be on your sandbox, not production |
| Merge conflict on push | Someone else changed the same file | `git pull`, resolve, commit, push |

**When something is confusing, ask before working around it.** A workaround that ships is much more expensive than a question that takes five minutes.

---

## 11. Glossary

| Term | Meaning |
|---|---|
| **Migration** | A numbered `.sql` file that changes the database. Run in order, never edited after being applied. |
| **Schema** | The structure — tables, columns, constraints. Not the data. |
| **Primary key** | The column uniquely identifying a row. Always `id` here. |
| **Foreign key** | A column that must match a real row in another table. The database enforces this. |
| **Surrogate key** | A meaningless generated number (`id`). |
| **Business key** | The human-readable identifier (`GATE-001`). |
| **Constraint** | A rule the database enforces on every write. |
| **Transaction** | Statements between `BEGIN` and `COMMIT` that all succeed or all fail. |
| **Lookup table** | A small table of allowed values, referenced by FK instead of free text. |
| **Polymorphic reference** | A relationship that can point at more than one kind of entity. |
| **Seed data** | Reference rows loaded by a migration so a rebuilt database comes up complete. |
| **psql** | The Postgres command-line client. |
| **DDL / DML** | Data Definition Language (`CREATE`, `ALTER`) vs Data Manipulation Language (`INSERT`, `UPDATE`). |

---

## 12. Where things live

| What | Where |
|---|---|
| Migration files | `Kendall-DOM/migrations/` |
| Your sandbox database | Inside your Codespace — disposable |
| The real database | Railway, service `DOM1` — Brad has access |
| Data entry interface | NocoDB (browser) — coming once the schema is stable |
| Design source documents | Entity Definitions, Schema v1, Data Dictionary, Relationship Matrix |

---

## 13. If you remember nothing else

1. **Build for the PMO.** Model the real process accurately. Do not design for departments we have not modeled yet.
2. **Test on your sandbox before you commit.** Every time.
3. **`BEGIN;` and `COMMIT;` around everything.**
4. **Never edit a migration that has already been applied.** Write a new one.
5. **No credentials in the repo.** Ever.
6. **Look up foreign keys by business code, never hardcode an id.**
7. **No table name prefixes.** `gate`, not `pmo_gate`.
8. **Ask when the model does not match reality.** The documents describe how the process was designed. Process owners know how it actually runs. The gap between those two is the most valuable thing you will find.
