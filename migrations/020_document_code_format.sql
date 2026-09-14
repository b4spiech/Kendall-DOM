-- 020_document_code_format.sql
-- Renames the existing PMO documents to the three-segment format and replaces
-- the code format constraint.
-- Depends on: 019 (document.business_unit_code)
--
--     SOP-001   ->  PMO-SOP-001
--     FORM-001  ->  PMO-FORM-001
--
-- WHY RETROFIT RATHER THAN LEAVE THEM
--
-- Leaving SOP-001 as it is would mean two conventions coexisting permanently,
-- and every regex in every pipeline script — four scripts, duplicated across two
-- repositories — would have to match both. There are two documents in the
-- system. This is the cheapest this will ever be.
--
-- THE CONSTRAINT
--
-- Old (from 004):   ^<type>-[0-9]{3}$
-- New:              ^<unit>-<type>-[0-9]{3}$
--
-- Both segments are built from columns in the same row, which is why 019 had to
-- put business_unit_code on document first. Both columns are foreign keys, so
-- the segments are guaranteed to name a real unit and a real type; the CHECK
-- adds that the code agrees with them.
--
-- The sequence restarts per department: PMO-SOP-001 and CI-SOP-001 can both
-- exist. The prefix already makes them unique, so there is no reason to make CI
-- start at 101 and no reason for anyone to have to remember which block belongs
-- to whom.
--
-- ORDER MATTERS INSIDE THIS FILE
--
-- The rename has to happen before the new constraint is added. A CHECK added
-- while SOP-001 still exists would be rejected outright — Postgres validates
-- every existing row before accepting a new constraint, which is the behaviour
-- you want and the reason this cannot be split across two migrations.
--
-- >>> THIS MIGRATION HAS A COUNTERPART OUTSIDE THE DATABASE <<<
--
-- repo_path below points at the file in the ADO repository. Renaming it here
-- does not rename the file there. Until the file is renamed to match, the
-- publish pipeline will look for a path that does not exist.
--
-- In the PMO repo, on a branch:
--
--     git mv SOPs/SOP-001-Project_Request_Framework.md \
--            SOPs/PMO-SOP-001-Project_Request_Framework.md
--
-- Do that in the same sitting as applying this migration.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Drop the old constraint first
--
-- The renames below would violate it: PMO-SOP-001 does not match ^SOP-[0-9]{3}$.
-- ---------------------------------------------------------------------------
ALTER TABLE document DROP CONSTRAINT document_code_matches_type;

-- ---------------------------------------------------------------------------
-- 2. Rename
--
-- document_code is referenced by foreign keys from nothing — document_approver,
-- document_reference, and document_review all join on document.id, not on the
-- code. So these updates are safe and nothing cascades.
--
-- That is the payoff for the handbook rule about looking rows up by business key
-- but relating them by id: the business key can be corrected without rewriting
-- half the database.
-- ---------------------------------------------------------------------------
UPDATE document
SET    document_code = 'PMO-SOP-001',
       updated_at    = now()
WHERE  document_code = 'SOP-001';

UPDATE document
SET    document_code = 'PMO-FORM-001',
       updated_at    = now()
WHERE  document_code = 'FORM-001';

-- ---------------------------------------------------------------------------
-- 3. Follow the rename through to the repository path
--
-- The filename in ADO must be changed to match — see the note at the top.
-- ---------------------------------------------------------------------------
UPDATE document
SET    repo_path  = 'SOPs/PMO-SOP-001-Project_Request_Framework.md',
       updated_at = now()
WHERE  document_code = 'PMO-SOP-001';

-- ---------------------------------------------------------------------------
-- 4. The new format rule
-- ---------------------------------------------------------------------------
ALTER TABLE document
    ADD CONSTRAINT document_code_matches_unit_and_type
    CHECK (document_code ~ ('^' || business_unit_code || '-' || document_type_code || '-[0-9]{3}$'));

COMMENT ON COLUMN document.document_code IS
    'Business key, format <UNIT>-<TYPE>-<NNN> e.g. PMO-SOP-001. Validated against business_unit_code and document_type_code in the same row. Sequence restarts per department.';

-- ---------------------------------------------------------------------------
-- 5. Record the rename in the review history
--
-- Anyone reading the 2026 review later will see the code change explained rather
-- than having to work out why the document appears to have two identities.
-- ---------------------------------------------------------------------------
UPDATE document_review dr
SET    notes = COALESCE(dr.notes || ' ', '')
               || 'Document code changed from SOP-001 to PMO-SOP-001 when the '
               || 'Continuous Improvement department was added to the model.',
       updated_at = now()
FROM   document d
WHERE  dr.document_id = d.id
  AND  d.document_code = 'PMO-SOP-001';

INSERT INTO schema_migration (filename, notes)
VALUES ('020_document_code_format.sql',
        'PMO documents renamed to <UNIT>-<TYPE>-<NNN>; format constraint replaced.');

COMMIT;
