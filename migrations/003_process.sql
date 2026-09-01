-- 003_process.sql
-- Creates the process container entity.
-- Depends on: 002 (role)
--
-- WHY THIS TABLE EXISTS
--
-- The Schema v1 workbook models Process Steps (ST-nnn) but has no entity for the
-- process those steps belong to. That gap does not matter while the only concern
-- is drawing a workflow. It matters immediately for SOP governance, because both
-- of the things we care about attach to the process, not to the document:
--
--   document GOVERNS process        (an SOP can be rewritten, merged, or retired
--                                    while the process continues unchanged)
--   metric   MEASURES process       (a KPI survives an SOP rewrite)
--
-- Linking metric directly to document is the shortcut that has to be unwound
-- around the eighth or ninth SOP. This table is the eight lines that avoid it.
--
-- process_step (ST-nnn) will later carry a process_id FK back to this table.

BEGIN;

CREATE TABLE process (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    process_code   text NOT NULL UNIQUE,
    name           text NOT NULL,
    purpose        text,
    owner_role_id  bigint REFERENCES role(id),
    is_active      boolean NOT NULL DEFAULT true,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT process_code_format CHECK (process_code ~ '^PROC-[0-9]{3}$')
);

COMMIT;
