-- 019_document_unit_code.sql
-- Puts the business unit code on document itself, so a single CHECK can validate
-- the full document code format in 020.
-- Depends on: 018 (business_unit_id on document)
--
-- THE PROBLEM THIS SOLVES
--
-- The target format is three segments:
--
--     CI-SOP-001
--     ^^ ^^^ ^^^
--     |   |   +-- sequence, three digits, restarting per department
--     |   +------ document_type.code
--     +---------- business_unit.business_unit_code
--
-- A CHECK constraint can only see columns in its own row. document already has
-- document_type_code as a text column, so the existing constraint can reference
-- it. But the business unit arrives as business_unit_id — an id, not the code —
-- and a CHECK cannot join to business_unit to look the code up.
--
-- So the code has to be on the row.
--
-- WHY THIS REDUNDANCY IS ACCEPTABLE
--
-- Storing the same fact twice is normally how data goes wrong: the two copies
-- drift and nothing notices.
--
-- A compound foreign key removes that risk entirely. Rather than two independent
-- references to business_unit, the pair (business_unit_id, business_unit_code)
-- is checked together against the same pair in business_unit. A row claiming
-- business unit 2 with code 'PMO' is rejected unless unit 2 really is PMO.
--
-- The redundancy is therefore visible in the schema and impossible to violate —
-- which is a different thing from redundancy that merely happens to be correct
-- today.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. A compound foreign key needs a matching unique constraint on the target.
--
-- id is already the primary key, so (id, business_unit_code) is trivially unique
-- — but Postgres requires the constraint to exist explicitly before anything can
-- reference that pair.
-- ---------------------------------------------------------------------------
ALTER TABLE business_unit
    ADD CONSTRAINT business_unit_id_code_unique UNIQUE (id, business_unit_code);

-- ---------------------------------------------------------------------------
-- 2. Add the column, nullable, and backfill it from the unit it already points at
-- ---------------------------------------------------------------------------
ALTER TABLE document ADD COLUMN business_unit_code text;

UPDATE document d
SET    business_unit_code = bu.business_unit_code,
       updated_at         = now()
FROM   business_unit bu
WHERE  bu.id = d.business_unit_id;

ALTER TABLE document ALTER COLUMN business_unit_code SET NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. Tie the two columns together
--
-- From here, the id and the code cannot disagree. Changing a document's
-- department means changing both, together, to a pair that really exists.
-- ---------------------------------------------------------------------------
ALTER TABLE document
    ADD CONSTRAINT document_business_unit_pair_fkey
    FOREIGN KEY (business_unit_id, business_unit_code)
    REFERENCES business_unit (id, business_unit_code);

COMMENT ON COLUMN document.business_unit_code IS
    'Denormalized from business_unit so the document code format can be validated in a CHECK. Held consistent with business_unit_id by a compound foreign key — the two cannot disagree.';

INSERT INTO schema_migration (filename, notes)
VALUES ('019_document_unit_code.sql',
        'document.business_unit_code with compound FK to business_unit(id, code).');

COMMIT;
