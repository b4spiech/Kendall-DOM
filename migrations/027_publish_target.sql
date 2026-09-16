-- 027_publish_target.sql
-- Separates "should this be published" from "where does it go", and makes the
-- folder inherit from the document type instead of being copied onto every row.
-- Depends on: 026 (document_type.default_publish_folder)
--
-- THE PROBLEM
--
-- document.publish_folder_path currently means two different things at once:
--
--     NULL  -> do not publish this document
--     'SOPs' -> publish it to the SOPs folder
--
-- So a document that should be published but whose folder nobody filled in is
-- indistinguishable from one deliberately excluded. CI-SOP-002 was registered
-- with it blank, built a PDF, and silently never reached SharePoint. Nothing
-- errored. Nothing published.
--
-- It also copies the same string onto every row. Twenty-six SOPs would each
-- carry 'SOPs' independently, and renaming that folder would be twenty-six
-- updates — the staleness problem this whole project exists to remove,
-- reintroduced one column at a time.
--
-- THE SHAPE
--
--     document.is_published        boolean, explicit. Should this be published?
--     document.publish_folder_path override only. NULL means inherit the type's.
--     document_type.default_publish_folder   the folder for that type.
--
-- Three states, each meaning exactly one thing:
--
--     is_published = true,  path NULL  -> publish to the type's folder
--     is_published = true,  path set   -> publish somewhere else, deliberately
--     is_published = false             -> do not publish, deliberately
--
-- Renaming the SOPs folder becomes one UPDATE on document_type.
--
-- WHY A VIEW RESOLVES IT
--
-- Three columns across two tables now determine one answer. Putting that
-- resolution in a view means post_to_flow.py asks a question rather than
-- reimplementing the rule — and any other consumer gets the same answer.
--
-- The view also surfaces the one bad state the model still allows: marked for
-- publication, no folder anywhere. That is not skippable and not guessable, so
-- it is reported rather than silently ignored.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Explicit publish intent
--
-- Defaults to true because publishing is the norm — a governed procedure that
-- employees cannot read is the exception, and exceptions should be the thing
-- you have to say out loud.
-- ---------------------------------------------------------------------------
ALTER TABLE document ADD COLUMN is_published boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN document.is_published IS
    'Whether the pipeline publishes this document. False means deliberately not published — a form maintained by hand, say — rather than an unfilled field.';

-- FORM-001's source is not in the repository and nothing generates it. It is
-- maintained by hand in SharePoint, so the pipeline must not publish it. This
-- is the one existing document where false is correct.
UPDATE document
SET    is_published = false,
       updated_at   = now()
WHERE  document_code = 'PMO-FORM-001';

-- ---------------------------------------------------------------------------
-- 2. Clear paths that merely repeat the type's default
--
-- After this, publish_folder_path holds only genuine overrides. A row with the
-- same value as its type is not an override, it is a copy — and copies drift.
-- ---------------------------------------------------------------------------
UPDATE document d
SET    publish_folder_path = NULL,
       updated_at          = now()
FROM   document_type dt
WHERE  dt.code = d.document_type_code
  AND  d.publish_folder_path IS NOT NULL
  AND  d.publish_folder_path = dt.default_publish_folder;

COMMENT ON COLUMN document.publish_folder_path IS
    'Override only. NULL means inherit document_type.default_publish_folder. Whether the document is published at all is is_published, not this.';

-- ---------------------------------------------------------------------------
-- 3. One place that answers "where does this go"
-- ---------------------------------------------------------------------------
CREATE VIEW document_publish_target AS
SELECT d.document_code,
       d.name,
       d.is_published,
       d.publish_folder_path                              AS folder_override,
       dt.default_publish_folder                          AS type_default_folder,
       COALESCE(d.publish_folder_path, dt.default_publish_folder) AS publish_folder,
       -- Marked for publication with no folder on either side. Not skippable
       -- and not guessable, so the caller is told rather than left to wonder.
       (d.is_published
        AND COALESCE(d.publish_folder_path, dt.default_publish_folder) IS NULL)
                                                          AS is_misconfigured
FROM   document d
JOIN   document_type dt ON dt.code = d.document_type_code;

COMMENT ON VIEW document_publish_target IS
    'Resolves where a document publishes: its own override if set, otherwise its type default. is_misconfigured flags documents marked for publication with no folder anywhere.';

GRANT SELECT ON document_publish_target TO dom_reader, dom_writer, dom_app;

-- dom_app sets publish intent when onboarding; dom_writer can correct it later.
-- Neither can change what a document TYPE defaults to — that is a governance
-- decision about where a whole class of document is filed, and stays in a
-- migration.
GRANT UPDATE (is_published, publish_folder_path) ON document TO dom_writer;

INSERT INTO schema_migration (filename, notes)
VALUES ('027_publish_target.sql',
        'document.is_published; publish_folder_path becomes an override; document_publish_target view resolves the two.');

COMMIT;
