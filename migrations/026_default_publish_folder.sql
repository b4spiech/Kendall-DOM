-- 026_default_publish_folder.sql
-- Gives each document type a default SharePoint folder.
-- Depends on: 001 (document_type), 016 (document.publish_folder_path)
--
-- WHY
--
-- publish_folder_path is optional on the onboarding form, and leaving it blank
-- means "not published by this pipeline" — post_to_flow.py skips the document
-- entirely. That is correct behaviour and a reasonable state to record, but it
-- is a poor default: someone registering an SOP almost always wants it
-- published, and a blank field does not look like a decision.
--
-- CI-SOP-002 was registered with it blank, built a PDF, and silently never
-- reached SharePoint. Nothing was wrong; nothing was published either.
--
-- WHY ON document_type RATHER THAN IN THE APP
--
-- The alternative is a map in the form's JavaScript: SOP goes here, FORM goes
-- there. That copy would then have to be kept in step with the database, and a
-- document type added later would fall through it silently — exactly what
-- happened with the review frequency intervals.
--
-- Putting it here means the form reads the default from the row, adding a type
-- is one INSERT, and there is no case the client does not know about.
--
-- WHY NOT ON business_unit
--
-- The LIBRARY differs by department and is already handled outside the DOM —
-- each department's pipeline has its own FLOW_URL pointing at its own site. What
-- varies by document type is the FOLDER within that library: procedures in one,
-- forms and templates in another. That is what this column holds.
--
-- Still overridable. The form pre-fills from here; a submitter who needs a
-- different folder can type one, and a document that genuinely should not be
-- published can have it cleared.

BEGIN;

ALTER TABLE document_type ADD COLUMN default_publish_folder text;

COMMENT ON COLUMN document_type.default_publish_folder IS
    'Folder within the department library where documents of this type are published, relative to the drive root. Pre-fills the onboarding form; NULL means no default and the submitter must choose.';

UPDATE document_type SET default_publish_folder = 'SOPs'
WHERE  code IN ('SOP', 'WI');

UPDATE document_type SET default_publish_folder = 'Templates & Forms'
WHERE  code IN ('FORM', 'TMP');

-- POL is left NULL deliberately: no policy has been onboarded yet, so where
-- policies are filed has not been decided. A guess here would look like a
-- decision and get followed.

INSERT INTO schema_migration (filename, notes)
VALUES ('026_default_publish_folder.sql',
        'document_type.default_publish_folder; SOP/WI -> SOPs, FORM/TMP -> Templates & Forms.');

COMMIT;
