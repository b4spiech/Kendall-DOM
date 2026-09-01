-- 008_schema_migration_ledger.sql
-- Records which migrations have been applied to this database.
-- Depends on: nothing structurally; run after 001-007.
--
-- WHY
--
-- Handbook rule 3 says never edit an applied migration. That rule only works if
-- you can tell which ones have been applied. Right now that lives in memory,
-- which is the exact failure mode this whole project exists to remove.
--
-- Backfills 001-007 as applied, since running this file means they already are.

BEGIN;

CREATE TABLE schema_migration (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    filename    text NOT NULL UNIQUE,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    applied_by  text NOT NULL DEFAULT current_user,
    notes       text
);

INSERT INTO schema_migration (filename, notes) VALUES
    ('001_lookup_tables.sql',       'Controlled vocabularies.'),
    ('002_role_and_system.sql',     'Foundational entities.'),
    ('003_process.sql',             'Process container.'),
    ('004_document.sql',            'Document, references, approvers.'),
    ('005_metric.sql',              'Metric and process linkage.'),
    ('006_document_review.sql',     'Review cycle history.'),
    ('007_seed_pilot_sop.sql',      'Pilot seed data.'),
    ('008_schema_migration_ledger.sql', 'This ledger.');

COMMIT;

-- From here on, every migration ends with its own INSERT:
--
--     INSERT INTO schema_migration (filename) VALUES ('009_whatever.sql');
--
-- inside the same BEGIN/COMMIT, so the record and the change land together.
