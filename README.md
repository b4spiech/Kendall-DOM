# Kendall-DOM — PMO Digital Operating Model

## Overview

The Digital Operating Model (DOM) is a relational PostgreSQL database that
models how Kendall's departments govern their processes and procedures — the
steps, roles, gates, decisions, documents, metrics, and systems involved, and
the relationships between them. It replaces a spreadsheet-and-SharePoint
design that could record those relationships but not enforce or query them.

What began as a PMO-only model of document governance (who owns a procedure,
who approves it, where it's published, when it's due for review) now also
covers the CI (Continuous Improvement) department, and is growing a second
layer: a full process-implementation model (projects, requests, process
steps, activities, decisions, business rules, requirements, and traceability
from problem statement through acceptance criteria), seeded with the PMO
Process Implementation Service itself as its first real process.

The database is hosted on Railway (project *PMO Digital Operating Model*,
service `DOM1`) and has no public endpoint by default — see
**DATABASE-HANDBOOK.md** for how to connect.

---

## What's modeled

- **Document governance** — documents (SOPs, forms, policies, work
  instructions), their approvers, review cycles and outcomes, version
  labels, and where each one publishes (SharePoint folder, resolved per
  department and document type).
- **Organizational structure** — business units (PMO, CI), roles, and the
  external systems each department's procedures live in (SharePoint,
  Azure DevOps), including per-role identities in those systems (e.g. which
  ADO group a role resolves to).
- **Metrics** — defined metrics, their source systems, and recorded
  readings, linked to the processes they measure.
- **Process implementation (MVP)** — projects, intake requests, process
  steps and activities, decisions and the business rules behind them, data
  entities, requirements and acceptance criteria, and configuration
  components — with the PMO Process Implementation Service (8 steps, 51
  activities) seeded as the first fully modeled process.
- **Service accounts** — `dom_reader` (read-only, used by automation like
  the ADO governance-check pipeline), `dom_writer` (narrow, column-level
  write access for recording process outcomes), and `dom_app` (insert-only,
  for the document onboarding application). None of them can alter
  governance decisions like ownership, approvers, or document location —
  those require a migration.

For the full current schema, see `DOM-REFERENCE.md` (generated from the
database; regenerate it after any migration lands) or connect directly and
run `\dt` / `\d <table>`.

---

## Repository structure

```text
Kendall-DOM/
├── DATABASE-HANDBOOK.md      convention, ground rules, and full workflow
├── DOM-REFERENCE.md          generated schema reference
├── README.md                 this file
├── migrations/                numbered .sql migrations, 001 through the current head
│   ├── 001_lookup_tables.sql
│   ├── ...
│   └── 031_dom_mvp_process_implementation.sql
└── scripts/
    ├── dom1-tunnel.sh         opens the Railway tunnel to DOM1; run in its own terminal, leave it open
    ├── load-env.sh            sources .env into the current shell (source scripts/load-env.sh)
    └── apply-migrations.sh    applies migrations/*.sql in order, stops at the first failure
```

`.env` (git-ignored) holds `DOM1_URL` and the service-role connection
strings; it's never committed.

---

## Working with the database

Full setup, conventions, and the day-to-day workflow (writing a migration,
testing it, applying it) live in **DATABASE-HANDBOOK.md** — that's the
source of truth, not this file. In short:

1. Every schema or data change is a new numbered file in `migrations/`,
   wrapped in `BEGIN`/`COMMIT`, never edited once applied.
2. Table names aren't prefixed (`gate`, not `pmo_gate`) — the model is built
   for the PMO's and CI's processes specifically, not speculatively
   generalized.
3. Every table has a surrogate `id` and, where it's an entity, a
   human-readable `<x>_code` business key with a format `CHECK` constraint.
4. Foreign keys are resolved by business code in seed data, never by a
   hardcoded id.
5. Applying a migration to the real database (`DOM1`) goes through the
   Railway tunnel described in the handbook — there's no public endpoint by
   default, and access is intentionally limited.

---

## Current status

31 migrations applied. Active development, currently extending the model
from document governance into full process implementation (projects,
requests, activities, decisions, and traceability from problem statement to
acceptance criteria), using the PMO Process Implementation Service as the
first process built out end to end.
