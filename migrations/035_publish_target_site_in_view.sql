-- 035_publish_target_site_in_view.sql
-- Exposes publish_target.target_site through document_publish_target, so the
-- publish pipeline can read the full destination (site + folder) from the one
-- view it already queries.
-- Depends on: 029 (document_publish_target), 033 (publish_target.target_site)
--
-- WHY THE VIEW AND NOT A NEW COLUMN ON document
--
-- The destination is a fact about the pairing of department and document
-- type, and publish_target already holds it, keyed on exactly that pair.
-- document carries both halves of the key, so the row is derivable. Storing
-- a publish_target_id on document would be a second copy that drifts the
-- first time a document's business unit or type is corrected -- the same
-- duplication 028 and 030 removed. The view resolves it at read time and
-- cannot go stale.
--
-- target_site is appended as the last column: CREATE OR REPLACE VIEW can add
-- columns at the end without dropping the view, so existing readers and
-- grants are untouched. Every existing column keeps its name, type, and
-- position.
--
-- A per-document folder override (document.publish_folder_path) still wins
-- over the folder, as before. It does not override the site: a document
-- filed into a different folder is still filed on its department's site.

BEGIN;

CREATE OR REPLACE VIEW document_publish_target AS
SELECT d.document_code,
       d.name,
       d.is_published,
       bu.business_unit_code,
       d.document_type_code,
       d.publish_folder_path                           AS folder_override,
       pt.folder_path                                  AS unit_type_folder,
       COALESCE(d.publish_folder_path, pt.folder_path) AS publish_folder,
       CASE WHEN d.publish_folder_path IS NOT NULL THEN NULL
            ELSE pt.is_verified
       END                                             AS publish_folder_verified,
       (d.is_published
        AND COALESCE(d.publish_folder_path, pt.folder_path) IS NULL)
                                                       AS is_misconfigured,
       pt.target_site                                  AS target_site
FROM   document d
JOIN   business_unit bu ON bu.id = d.business_unit_id
LEFT   JOIN publish_target pt
         ON pt.business_unit_id = d.business_unit_id
        AND pt.document_type_code = d.document_type_code;

COMMENT ON VIEW document_publish_target IS
    'Resolves where a document publishes: its own folder override if set, otherwise how its department files that type; target_site is the department''s SharePoint site. is_misconfigured flags documents marked for publication with no folder anywhere; publish_folder_verified is NULL for overrides, which carry no verification claim.';

INSERT INTO schema_migration (filename, notes)
VALUES ('035_publish_target_site_in_view.sql',
        'document_publish_target exposes publish_target.target_site (appended column; no drop).');

COMMIT;
