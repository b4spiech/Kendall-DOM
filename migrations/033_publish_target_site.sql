-- 033_publish_target_site.sql
-- Records which SharePoint site each publish_target row files into, so the
-- Power Automate flow knows where to put a document, not just which folder.
-- Depends on: 028 (publish_target), 029 (SYS-001 / SYS-004 site URLs)
--
-- WHY
--
-- publish_target holds the folder within a library. The flow also needs the
-- site the library lives on, and until now that was known only to each
-- department's pipeline configuration. Recording it here makes the full
-- destination (site + folder) readable from one row.
--
-- NOTE ON DUPLICATION
--
-- system.base_url for SYS-001 (PMO) and SYS-004 (CI) already holds these same
-- two URLs. This column is a second copy of that fact, kept per-row because
-- the flow reads publish_target directly. If a site ever moves, both places
-- need to change.
--
-- COLUMN POSITION
--
-- Postgres appends new columns at the end; it cannot insert one beside
-- folder_path without rebuilding the table. Column order has no effect on
-- queries or on the document_publish_target view, so the column is added
-- at the end rather than rebuilding a table that a view and grants depend on.

BEGIN;

ALTER TABLE publish_target ADD COLUMN target_site text;

COMMENT ON COLUMN publish_target.target_site IS
    'SharePoint site URL the publish flow files documents into. folder_path is relative to a library on this site.';

UPDATE publish_target pt
SET    target_site = 'https://kendallgroup.sharepoint.com/sites/PMO',
       updated_at  = now()
FROM   business_unit bu
WHERE  bu.id = pt.business_unit_id
  AND  bu.business_unit_code = 'PMO';

UPDATE publish_target pt
SET    target_site = 'https://kendallgroup.sharepoint.com/sites/CI',
       updated_at  = now()
FROM   business_unit bu
WHERE  bu.id = pt.business_unit_id
  AND  bu.business_unit_code = 'CI';

ALTER TABLE publish_target ALTER COLUMN target_site SET NOT NULL;

ALTER TABLE publish_target
    ADD CONSTRAINT publish_target_site_https CHECK (target_site ~ '^https://');

INSERT INTO schema_migration (filename, notes)
VALUES ('033_publish_target_site.sql',
        'publish_target.target_site (NOT NULL); PMO -> /sites/PMO, CI -> /sites/CI.');

COMMIT;
