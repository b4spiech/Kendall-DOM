-- 018_business_unit_links.sql
-- Attaches documents, roles, and processes to the business unit that owns them.
-- Depends on: 017 (business_unit)
--
-- WHICH TABLES GET THE COLUMN
--
-- document, role, process — these are the things a department owns.
--
-- Not system: SharePoint and Azure DevOps are shared infrastructure, not PMO's.
-- Not metric: a metric measures a process, and the process already carries the
--             department. Adding it here would be a second copy of the same fact,
--             free to disagree with the first.
-- Not the junction tables: document_approver joins a document to a role, and
--             both ends already carry their own unit.
--
-- REQUIRED vs NULLABLE
--
-- document  NOT NULL — every governed document belongs to exactly one department.
--                      One that does not is a gap, and the database should say so.
-- process   NOT NULL — same reasoning.
-- role      NULLABLE — deliberately. Roles come in two kinds:
--
--                        department-specific: PMO Manager, CI Leader
--                        company-wide:        EVP of Operations
--
--                      Forcing a unit onto every role would mean either
--                      duplicating shared roles per department or assigning them
--                      arbitrarily to one. NULL means "spans the company", which
--                      is a real distinction and the one that matters when a
--                      document needs approval from outside its own department.
--
-- ADDING A REQUIRED COLUMN TO A TABLE THAT ALREADY HAS ROWS
--
-- ALTER TABLE ... ADD COLUMN ... NOT NULL fails immediately on a populated table:
-- the existing rows would have no value, which is exactly what NOT NULL forbids.
--
-- The three-step pattern below is the standard way round it:
--
--   1. add the column nullable        (existing rows get NULL, which is allowed)
--   2. backfill every row             (now nothing is NULL)
--   3. SET NOT NULL                   (Postgres verifies, then enforces from here)
--
-- Step 3 scans the table to confirm the claim before accepting it, so it cannot
-- be used to assert something untrue.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Add the columns, nullable for now
-- ---------------------------------------------------------------------------
ALTER TABLE document ADD COLUMN business_unit_id bigint REFERENCES business_unit(id);
ALTER TABLE process  ADD COLUMN business_unit_id bigint REFERENCES business_unit(id);
ALTER TABLE role     ADD COLUMN business_unit_id bigint REFERENCES business_unit(id);

COMMENT ON COLUMN role.business_unit_id IS
    'Department this role belongs to. NULL means the role spans the company (e.g. EVP of Operations).';

-- ---------------------------------------------------------------------------
-- 2. Backfill
--
-- Everything that exists today is PMO — it was built before there was anything
-- else to be.
-- ---------------------------------------------------------------------------
UPDATE document d
SET    business_unit_id = bu.id, updated_at = now()
FROM   business_unit bu
WHERE  bu.business_unit_code = 'PMO';

UPDATE process p
SET    business_unit_id = bu.id, updated_at = now()
FROM   business_unit bu
WHERE  bu.business_unit_code = 'PMO';

-- Roles individually, because they are not all PMO.
UPDATE role r
SET    business_unit_id = bu.id, updated_at = now()
FROM   business_unit bu
WHERE  bu.business_unit_code = 'PMO'
  AND  r.role_code IN ('R-001', 'R-003');   -- PMO Manager, Project Manager

-- R-002 (EVP of Operations) is left NULL: the role spans the company rather than
-- belonging to any one department.

-- ---------------------------------------------------------------------------
-- 3. Enforce
-- ---------------------------------------------------------------------------
ALTER TABLE document ALTER COLUMN business_unit_id SET NOT NULL;
ALTER TABLE process  ALTER COLUMN business_unit_id SET NOT NULL;

CREATE INDEX document_business_unit_id_idx ON document (business_unit_id);
CREATE INDEX process_business_unit_id_idx  ON process  (business_unit_id);
CREATE INDEX role_business_unit_id_idx     ON role     (business_unit_id);

INSERT INTO schema_migration (filename, notes)
VALUES ('018_business_unit_links.sql',
        'business_unit_id on document (required), process (required), role (nullable); existing rows backfilled to PMO.');

COMMIT;
