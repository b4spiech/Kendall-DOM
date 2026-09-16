-- 028_publish_target_table.sql
-- Makes the publish folder a property of the department-and-type pairing rather
-- than of the document type alone.
-- Depends on: 026, 027
--
-- WHAT CHANGES AND WHY
--
-- 026 put default_publish_folder on document_type, so every department's SOPs
-- inherited the same folder name. That is only correct if every department's
-- library happens to use the same names.
--
-- The folder is not a property of being an SOP, and not a property of being the
-- CI department. It is a property of the pair: where does THIS department file
-- THIS kind of document. A column on either table cannot say that; a row keyed
-- on both can.
--
-- Same shape as document_approver, and for the same reason — an approver is not
-- a property of a document or of a role, it is a fact about the pairing.
--
-- WHAT STAYS OUTSIDE THE DOM
--
-- The LIBRARY — which SharePoint site and document library — is not here. Each
-- department's pipeline posts to its own Power Automate flow, and that flow
-- knows its own site. This table holds the folder within whatever library the
-- flow is pointed at.
--
-- That split is deliberate. The site address is deployment configuration that
-- changes if IT rebuilds a site; the folder is a governance decision about where
-- a department files a kind of document. Different lifecycles, different homes.
--
-- RESOLUTION ORDER, UNCHANGED IN SHAPE
--
--     document.publish_folder_path        a deliberate per-document override
--     publish_target(unit, type)          how this department files this type
--     nothing                             flagged as misconfigured
--
-- The view keeps its name and its output columns, so post_to_flow.py needs no
-- change — it asks the same question and gets a better answer.

BEGIN;

CREATE TABLE publish_target (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    business_unit_id    bigint NOT NULL REFERENCES business_unit(id) ON DELETE CASCADE,
    document_type_code  text   NOT NULL REFERENCES document_type(code),

    folder_path         text   NOT NULL,

    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT publish_target_unique UNIQUE (business_unit_id, document_type_code),
    -- Relative to the library root. A leading slash would be read as absolute by
    -- the SharePoint connector and quietly file things in the wrong place.
    CONSTRAINT publish_target_relative CHECK (folder_path !~ '^/')
);

COMMENT ON TABLE publish_target IS
    'Where each department files each kind of document, as a folder within that department''s library. The library itself is not here — each department''s Power Automate flow knows its own site.';

-- ---------------------------------------------------------------------------
-- Carry the type defaults across as the starting point for both departments
--
-- PMO's folders are known from the existing library. CI's are seeded with the
-- same names as a starting assumption — CORRECT THEM if CI's library uses
-- different ones. A wrong folder here files documents somewhere nobody looks,
-- which is worse than no folder, because no folder is reported as an error.
-- ---------------------------------------------------------------------------
INSERT INTO publish_target (business_unit_id, document_type_code, folder_path, notes)
SELECT bu.id, dt.code, dt.default_publish_folder,
       CASE WHEN bu.business_unit_code = 'PMO'
            THEN 'Carried over from the existing PMO library.'
            ELSE 'Assumed to match PMO. Verify against this department''s library.'
       END
FROM   business_unit bu
CROSS  JOIN document_type dt
WHERE  dt.default_publish_folder IS NOT NULL
  AND  bu.is_active;

-- ---------------------------------------------------------------------------
-- One place for the answer, so the column on document_type goes
-- ---------------------------------------------------------------------------
DROP VIEW document_publish_target;
ALTER TABLE document_type DROP COLUMN default_publish_folder;

CREATE VIEW document_publish_target AS
SELECT d.document_code,
       d.name,
       d.is_published,
       bu.business_unit_code,
       d.document_type_code,
       d.publish_folder_path                       AS folder_override,
       pt.folder_path                              AS unit_type_folder,
       COALESCE(d.publish_folder_path, pt.folder_path) AS publish_folder,
       (d.is_published
        AND COALESCE(d.publish_folder_path, pt.folder_path) IS NULL)
                                                   AS is_misconfigured
FROM   document d
JOIN   business_unit bu ON bu.id = d.business_unit_id
LEFT   JOIN publish_target pt
         ON pt.business_unit_id = d.business_unit_id
        AND pt.document_type_code = d.document_type_code;

COMMENT ON VIEW document_publish_target IS
    'Resolves where a document publishes: its own override if set, otherwise how its department files that type. is_misconfigured flags documents marked for publication with no folder anywhere.';

GRANT SELECT ON document_publish_target TO dom_reader, dom_writer, dom_app;
GRANT SELECT ON publish_target          TO dom_reader, dom_writer, dom_app;

INSERT INTO schema_migration (filename, notes)
VALUES ('028_publish_target_table.sql',
        'publish_target keyed on business unit and document type; document_type.default_publish_folder removed.');

COMMIT;
