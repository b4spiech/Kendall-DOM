-- 011_repo_locations.sql
-- Records where the controlled source of a document lives, separately from where
-- the published copy lives.
-- Depends on: 002 (system), 004 (document), 009 (pilot data)
--
-- WHY A SECOND SYSTEM COLUMN
--
-- document already has storage_system_id + published_url, which answer "where do
-- employees read this." repo_path was added in 004 to answer "where is the
-- controlled source," but had no system to hang off — it was implicitly assumed
-- to mean Azure DevOps. Implicit is how these things go wrong.
--
-- After this migration the two locations are symmetric:
--
--   published:  storage_system_id + published_url    (SharePoint, PDF)
--   controlled: repo_system_id    + repo_path        (ADO Git, Markdown)
--
-- Also clears the [FILL] base_url placeholders left in 007, which 009 missed.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Real system locations
-- ---------------------------------------------------------------------------
UPDATE system
SET    base_url   = 'https://kendallgroup.sharepoint.com/sites/PMO',
       updated_at = now()
WHERE  system_code = 'SYS-001';

UPDATE system
SET    base_url   = 'https://dev.azure.com/BradSpiech/PMO%20-%20Procedure%20review/_git/PMO%20-%20Procedure%20review',
       notes      = 'Kendall-owned ADO organization; the org name derives from the account it was created under, not from personal ownership.',
       updated_at = now()
WHERE  system_code = 'SYS-002';

-- ---------------------------------------------------------------------------
-- 2. Which system holds the controlled source
-- ---------------------------------------------------------------------------
ALTER TABLE document ADD COLUMN repo_system_id bigint REFERENCES system(id);

COMMENT ON COLUMN document.repo_system_id IS
    'System holding the controlled source (ADO Git). Pairs with repo_path. Distinct from storage_system_id, which holds the published copy.';

-- ---------------------------------------------------------------------------
-- 3. SOP-001's actual repository path
--
-- Corrects the assumed 'SOPs/SOP-001.md' set in 009. The real filename is
-- descriptive; the SOP-001 prefix is what a path parser keys on, so the rest of
-- the name is free to be readable.
-- ---------------------------------------------------------------------------
UPDATE document d
SET    repo_path      = 'SOPs/SOP-001-Project_Request_Framework.md',
       repo_system_id = s.id,
       updated_at     = now()
FROM   system s
WHERE  d.document_code = 'SOP-001'
  AND  s.system_code = 'SYS-002';

INSERT INTO schema_migration (filename, notes)
VALUES ('011_repo_locations.sql',
        'repo_system_id column; real system base_urls; SOP-001 actual repo path.');

COMMIT;
