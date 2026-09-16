-- 030_business_unit_storage_system.sql
-- Records which system publishes each department's documents, so the onboarding
-- app stops hardcoding one.
-- Depends on: 017 (business_unit), 023 (repo_system_id), 029 (SYS-004)
--
-- THE GAP THIS FILLS
--
-- business_unit already answers "where does this department's controlled source
-- live" via repo_system_id. It has never answered the other half — where the
-- published copy goes.
--
--                        controlled source        published copy
--     department         repo_system_id           (nothing)
--     document           repo_system_id           storage_system_id
--
-- The document-level column exists on both sides. The department-level one only
-- existed for repositories, which is why dom_governance_check.py can resolve the
-- right ADO project per department while the onboarding app cannot resolve the
-- right SharePoint site — so it hardcodes SYS-001.
--
-- SYS-001 is PMO's site. Every CI document registered through the form has
-- therefore pointed at PMO's SharePoint, not by anyone's decision but because
-- there was nowhere to look the answer up. Migration 029 corrected two documents
-- and would have had to again.
--
-- This is the third time the same fix has applied: the review frequency
-- intervals, the publish folders, and the hardcoded SYS-002 in the governance
-- check all came down to a per-department or per-type fact frozen into code.
-- Each time the answer was to put the fact in the DOM and have the code ask.
--
-- NULLABLE ON PURPOSE
--
-- A department can exist in the model before it has a SharePoint site. NULL
-- means nothing is published for it yet, which is a real state — not a field
-- somebody forgot.

BEGIN;

ALTER TABLE business_unit
    ADD COLUMN storage_system_id bigint REFERENCES system(id);

COMMENT ON COLUMN business_unit.storage_system_id IS
    'System where this department''s published documents go, the mirror of repo_system_id. NULL means nothing is published for this department yet.';

UPDATE business_unit bu
SET    storage_system_id = s.id,
       updated_at        = now()
FROM   system s
WHERE  bu.business_unit_code = 'PMO'
  AND  s.system_code = 'SYS-001';

UPDATE business_unit bu
SET    storage_system_id = s.id,
       updated_at        = now()
FROM   system s
WHERE  bu.business_unit_code = 'CI'
  AND  s.system_code = 'SYS-004';

INSERT INTO schema_migration (filename, notes)
VALUES ('030_business_unit_storage_system.sql',
        'business_unit.storage_system_id; PMO -> SYS-001, CI -> SYS-004. Removes the need for the app to hardcode a SharePoint site.');

COMMIT;

-- ---------------------------------------------------------------------------
-- THE APP CHANGE THIS ENABLES
--
-- In DOM-App main.py, create_document currently inserts:
--
--     (SELECT id FROM system WHERE system_code = 'SYS-001'),
--
-- That becomes:
--
--     bu.storage_system_id,
--
-- The INSERT already joins business_unit as bu for business_unit_id and
-- repo_system_id, so the column is in scope. One line.
-- ---------------------------------------------------------------------------
