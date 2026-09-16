-- 029_ci_sharepoint_site.sql
-- Adds CI's own SharePoint site, repoints CI's documents at it, and makes
-- "has anyone actually confirmed this folder exists" a queryable fact.
-- Depends on: 002 (system), 004 (document), 028 (publish_target)
--
-- THREE PROBLEMS, ONE MIGRATION
--
-- 1. No system row existed for CI's SharePoint site. Only SYS-001 (PMO's) did.
--
-- 2. CI-SOP-001 and CI-SOP-002 both carried storage_system_id = SYS-001, so
--    both claimed to live on PMO's site. Not a decision anyone made — the
--    onboarding app hardcodes SYS-001 when it inserts a document, because when
--    it was written there was only one SharePoint site to choose from. That
--    hardcode is now wrong and is noted at the end of this file.
--
-- 3. publish_target's CI rows all said "assumed to match PMO". The SOP folder
--    has since been confirmed; the Templates & Forms folder has not — it does
--    not exist yet. Both facts were sitting in a free-text notes column, where
--    "which of these has anyone actually checked" cannot be asked as a query.
--    That is the thing this project exists to replace, so it becomes a column.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. CI's SharePoint site
--
-- system_type is 'Document Library' rather than 'Repository'. SYS-002 and
-- SYS-003 are git repositories and SYS-001 is a SharePoint site, and all three
-- currently read 'Repository' — so the column distinguishes nothing. Two rows
-- is the cheapest moment to start using it properly; twelve rows is not.
-- SYS-001 is corrected below to match.
--
-- The site goes here; the library and folder do not. The library is pipeline
-- configuration that changes if IT rebuilds the site, and the folder is a
-- governance decision recorded in publish_target. Different lifecycles.
-- ---------------------------------------------------------------------------
INSERT INTO system (system_code, name, system_type, current_state_role, base_url, owner_role_id, notes)
SELECT 'SYS-004',
       'SharePoint (CI)',
       'Document Library',
       'Employee-facing published documents for Continuous Improvement.',
       'https://kendallgroup.sharepoint.com/sites/CI',
       r.id,
       'CI department site. The Procedures library holds published SOPs and forms; folder names are in publish_target, not here.'
FROM   role r
WHERE  r.role_code = 'R-004';   -- CI Leader owns CI's published documents

UPDATE system
SET    system_type = 'Document Library',
       updated_at  = now()
WHERE  system_code = 'SYS-001';

-- ---------------------------------------------------------------------------
-- 2. Repoint CI's documents
-- ---------------------------------------------------------------------------
UPDATE document d
SET    storage_system_id = s.id,
       updated_at        = now()
FROM   system s
WHERE  s.system_code = 'SYS-004'
  AND  d.business_unit_code = 'CI';

-- ---------------------------------------------------------------------------
-- 3. Verified, as a column rather than as prose
--
-- A folder that nobody has checked is a different thing from one that has been.
-- An unverified folder files documents somewhere that may not exist, or exists
-- and is not where anyone looks — and unlike a missing folder, nothing reports
-- it. Being able to ask "what has nobody confirmed" is the point.
--
-- Defaults to false: a row added without anyone saying they checked has not
-- been checked, and that should be the state it lands in.
-- ---------------------------------------------------------------------------
ALTER TABLE publish_target ADD COLUMN is_verified boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN publish_target.is_verified IS
    'Whether someone has confirmed this folder exists in that department''s library. False means the path is an assumption; documents filed there may land somewhere nobody looks, and nothing will report it.';

-- PMO's folders came from the existing library and are real.
UPDATE publish_target pt
SET    is_verified = true,
       notes       = 'Carried over from the existing PMO library.',
       updated_at  = now()
FROM   business_unit bu
WHERE  bu.id = pt.business_unit_id
  AND  bu.business_unit_code = 'PMO';

-- CI's SOP and Work Instruction folder has been checked directly.
UPDATE publish_target pt
SET    is_verified = true,
       notes       = 'Confirmed at /sites/CI/Procedures/SOPs.',
       updated_at  = now()
FROM   business_unit bu
WHERE  bu.id = pt.business_unit_id
  AND  bu.business_unit_code = 'CI'
  AND  pt.document_type_code IN ('SOP', 'WI');

-- CI's forms and templates folder does not exist yet. The site and library are
-- confirmed; the folder name is still borrowed from PMO.
UPDATE publish_target pt
SET    is_verified = false,
       notes       = 'Site and library confirmed at /sites/CI/Procedures. Folder name assumed to match PMO and not yet created — verify once it exists.',
       updated_at  = now()
FROM   business_unit bu
WHERE  bu.id = pt.business_unit_id
  AND  bu.business_unit_code = 'CI'
  AND  pt.document_type_code IN ('FORM', 'TMP');

-- ---------------------------------------------------------------------------
-- 4. Surface it where the answer is already resolved
--
-- The view keeps its name and every column it already had, so post_to_flow.py
-- needs no change. publish_folder_verified is added alongside, so a caller that
-- wants to care can, and one that does not is unaffected.
-- ---------------------------------------------------------------------------
DROP VIEW document_publish_target;

CREATE VIEW document_publish_target AS
SELECT d.document_code,
       d.name,
       d.is_published,
       bu.business_unit_code,
       d.document_type_code,
       d.publish_folder_path                           AS folder_override,
       pt.folder_path                                  AS unit_type_folder,
       COALESCE(d.publish_folder_path, pt.folder_path) AS publish_folder,
       -- An override is the submitter's own choice and carries no verification
       -- claim either way; only an inherited folder can be said to be verified.
       CASE WHEN d.publish_folder_path IS NOT NULL THEN NULL
            ELSE pt.is_verified
       END                                             AS publish_folder_verified,
       (d.is_published
        AND COALESCE(d.publish_folder_path, pt.folder_path) IS NULL)
                                                       AS is_misconfigured
FROM   document d
JOIN   business_unit bu ON bu.id = d.business_unit_id
LEFT   JOIN publish_target pt
         ON pt.business_unit_id = d.business_unit_id
        AND pt.document_type_code = d.document_type_code;

COMMENT ON VIEW document_publish_target IS
    'Resolves where a document publishes: its own override if set, otherwise how its department files that type. is_misconfigured flags documents marked for publication with no folder anywhere; publish_folder_verified is NULL for overrides, which carry no verification claim.';

GRANT SELECT ON document_publish_target TO dom_reader, dom_writer, dom_app;

INSERT INTO schema_migration (filename, notes)
VALUES ('029_ci_sharepoint_site.sql',
        'SYS-004 CI SharePoint site; CI documents repointed; publish_target.is_verified replaces notes-as-data.');

COMMIT;

-- ---------------------------------------------------------------------------
-- STILL WRONG AFTER THIS MIGRATION
--
-- The onboarding app hardcodes SYS-001 as storage_system_id when it inserts a
-- document. Every CI document registered through the form will point at PMO's
-- SharePoint site until that is fixed, and this migration will have to be
-- repeated.
--
-- The fix belongs in the app, not here: it should read the storage system from
-- the department, the same way it already reads repo_system_id from
-- business_unit.repo_system_id. That needs a business_unit.storage_system_id
-- column — the mirror of the repo one — and a one-line change in main.py.
--
-- Recorded here rather than fixed here because it is a change to how documents
-- are created, not a correction to the ones that exist.
-- ---------------------------------------------------------------------------
